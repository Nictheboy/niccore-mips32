
`include "structs.svh"

module issue_controller #(
    parameter int NUM_SICS,
    parameter int NUM_PHY_REGS,
    parameter int NUM_ECRS,
    parameter int ID_WIDTH,
    parameter int BRANCH_PREDICTOR_TABLE_SIZE
) (
    input logic clk,
    input logic rst_n,

    // 指令内存接口
    output logic [31:0] imem_addr,
    input logic [NUM_SICS-1:0][31:0] imem_data,

    // SIC 交互接口
    input logic sic_req_instr[NUM_SICS],
    output sic_packet#(NUM_PHY_REGS, ID_WIDTH, NUM_ECRS)::t sic_packet_out[NUM_SICS],
    input logic sic_pc_redirect_valid[NUM_SICS],
    input logic [31:0] sic_pc_redirect_pc[NUM_SICS],
    input logic [ID_WIDTH-1:0] sic_pc_redirect_issue_id[NUM_SICS],

    output logic rollback_trigger,

    output logic rf_alloc_wen[NUM_SICS],
    output logic [$clog2(NUM_PHY_REGS)-1:0] rf_alloc_pr[NUM_SICS],

    input logic [NUM_PHY_REGS-1:0] pr_not_idle,

    input logic [1:0] ecr_monitor[NUM_ECRS],
    input logic [NUM_ECRS-1:0] ecr_in_use,

    output ecr_reset_for_issue#(NUM_ECRS)::t ecr_update,

    input bp_update_t bp_update
);

    localparam int ECR_W = (NUM_ECRS > 1) ? $clog2(NUM_ECRS) : 1;
    localparam int PR_W = (NUM_PHY_REGS > 1) ? $clog2(NUM_PHY_REGS) : 1;

    // PC / Issue ID
    logic [31:0] pc;
    logic [ID_WIDTH-1:0] global_issue_id;

    // JR：发射后暂停，直到收到匹配 issue_id 的重定向
    logic jr_waiting;
    logic [ID_WIDTH-1:0] jr_wait_issue_id;

    logic pending_valid;
    cf_kind_t pending_kind;
    logic [31:0] pending_target_pc;
    logic [31:0] pending_alt_pc;
    logic pending_pred_taken;
    logic [ECR_W-1:0] pending_ecr;
    logic [ECR_W-1:0] pending_parent;
    logic [ID_WIDTH-1:0] pending_issue_id;

    logic [NUM_ECRS-1:0] ecr_poison_pending;
    logic [NUM_ECRS-1:0] ecr_free_pending;

    // 当前依赖链 ECR（写入 packet.dep_ecr_id）
    logic [ECR_W-1:0] active_ecr;
    logic [ECR_W-1:0] ecr_alloc_ptr;

    // 逻辑寄存器映射表（RAT）：只跟踪 1..31，$0 恒为 PR0
    typedef struct {logic [PR_W-1:0] rat[31:1];} rename_state_t;

    rename_state_t                cur_state;

    // 检查点：每个 ECR 一份（保存 RAT）
    rename_state_t                ckpt_state       [NUM_ECRS];
    logic                         ckpt_valid       [NUM_ECRS];
    logic          [        31:0] ckpt_alt_pc      [NUM_ECRS];
    logic          [ID_WIDTH-1:0] ckpt_age         [NUM_ECRS];

    logic                         ckpt_has_child   [NUM_ECRS];
    logic                         rb_found;
    logic          [   ECR_W-1:0] rb_id;
    logic          [        31:0] rb_target_pc;
    // parent 指针：记录该检查点创建前的依赖链，用于回滚时恢复 active_ecr
    logic          [   ECR_W-1:0] ckpt_parent      [NUM_ECRS];
    logic                         ckpt_parent_valid[NUM_ECRS];
    // 本地保留位：用于避免同一拍/相邻拍对同一 ECR 误分配
    logic                         ecr_pending_busy [NUM_ECRS];
    // 记录该检查点是否进入过非空闲态（00/10），用于回收策略
    logic                         ckpt_seen_nonfree[NUM_ECRS];

    // branch predictor + decoder（按取指 slot 索引）
    logic                         pred_taken_w     [NUM_SICS];
    instr_info_t                  dec_info         [NUM_SICS];

    genvar k;
    generate
        for (k = 0; k < NUM_SICS; k++) begin : decoders
            instruction_decoder idec (
                .instr(imem_data[k]),
                .info (dec_info[k])
            );
            branch_predictor #(
                .TABLE_SIZE(BRANCH_PREDICTOR_TABLE_SIZE)
            ) bp (
                .clk(clk),
                .rst_n(rst_n),
                .query_pc(pc + (k << 2)),
                .pred_taken(pred_taken_w[k]),
                .bp_update(bp_update)
            );
        end
    endgenerate

    // 基本连线
    assign imem_addr = pc;

    // 从“当前 + 所有有效快照”求一个 used bitmap（只做一次，后续本周期分配只会把 0->1）
    // Map logical register to physical register; $0 is always PR0.
    function automatic logic [PR_W-1:0] map_lr(input rename_state_t st, input logic [4:0] lr);
        if (lr == 5'd0) return '0;
        else return st.rat[lr];
    endfunction

    function automatic logic [NUM_PHY_REGS-1:0] calc_used_pr(input rename_state_t st);
        logic [NUM_PHY_REGS-1:0] used;
        used = '0;
        // 0..31 永久保留（架构初值映射）
        for (int pr = 0; pr < 32 && pr < NUM_PHY_REGS; pr++) begin
            used[pr] = 1'b1;
        end
        // only logical regs 1..31 are tracked by RAT
        for (int lr = 1; lr < 32; lr++) begin
            used[st.rat[lr]] = 1'b1;
        end
        return used;
    endfunction

    function automatic int find_free_pr(input logic [NUM_PHY_REGS-1:0] used);
        int found;
        found = -1;
        for (int pr = 32; pr < NUM_PHY_REGS; pr++) begin
            if (!used[pr]) begin
                found = pr;
                break;
            end
        end
        return found;
    endfunction

    always_comb begin
        logic [ID_WIDTH-1:0] best_age;
        for (int e = 0; e < NUM_ECRS; e++) ckpt_has_child[e] = 1'b0;
        for (int e = 0; e < NUM_ECRS; e++) begin
            if (ckpt_valid[e] && ckpt_parent_valid[e]) ckpt_has_child[ckpt_parent[e]] = 1'b1;
        end

        rb_found = 1'b0;
        rb_id = '0;
        rb_target_pc = 32'b0;
        best_age = '0;
        for (int e = 1; e < NUM_ECRS; e++) begin
            if (ckpt_valid[e] && (ecr_monitor[e] == 2'b10)) begin
                if (!rb_found || (ckpt_age[e] < best_age)) begin
                    rb_found = 1'b1;
                    rb_id = e[ECR_W-1:0];
                    best_age = ckpt_age[e];
                end
            end
        end
        if (rb_found) rb_target_pc = ckpt_alt_pc[rb_id];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc <= 32'h0000_3000;
            global_issue_id <= '0;
            jr_waiting <= 1'b0;
            jr_wait_issue_id <= '0;
            pending_valid <= 1'b0;
            pending_kind <= CF_NONE;
            pending_target_pc <= 32'b0;
            pending_alt_pc <= 32'b0;
            pending_pred_taken <= 1'b0;
            pending_ecr <= '0;
            pending_parent <= '0;
            pending_issue_id <= '0;
            rollback_trigger <= 1'b0;
            ecr_poison_pending <= '0;
            ecr_free_pending <= '0;
            active_ecr <= '0;
            if (NUM_ECRS > 1) ecr_alloc_ptr <= ECR_W'(1);
            else ecr_alloc_ptr <= '0;
            ecr_update <= '0;
            // 初始化 RAT：lr[i] -> pr[i] (exclude $0)
            for (int i = 1; i < 32; i++) begin
                cur_state.rat[i] <= PR_W'(i);
            end
            for (int e = 0; e < NUM_ECRS; e++) begin
                ckpt_valid[e] <= 1'b0;
                ckpt_alt_pc[e] <= 32'b0;
                ckpt_age[e] <= '0;
                ckpt_parent[e] <= '0;
                ckpt_parent_valid[e] <= 1'b0;
                ecr_pending_busy[e] <= 1'b0;
                ckpt_seen_nonfree[e] <= 1'b0;
                for (int i = 1; i < 32; i++) begin
                    ckpt_state[e].rat[i] <= PR_W'(i);
                end
            end
            for (int s = 0; s < NUM_SICS; s++) begin
                sic_packet_out[s] <= '0;
                rf_alloc_wen[s]   <= 1'b0;
                rf_alloc_pr[s]    <= '0;
            end
        end else begin
            // 默认：不更新 ECR / 不分配 RF 生命周期 / 不发射
            ecr_update <= '0;
            rollback_trigger <= rb_found;
            for (int s = 0; s < NUM_SICS; s++) begin
                sic_packet_out[s] <= '0;
                sic_packet_out[s].valid <= 1'b0;
                rf_alloc_wen[s]   <= 1'b0;
                rf_alloc_pr[s]    <= '0;
            end

            // 1) 快照回收：ECR 回到 01 且不再被依赖，则该检查点失效
            for (int e = 0; e < NUM_ECRS; e++) begin
                // 观察到非空闲态（00/10）
                if (ckpt_valid[e] && (ecr_monitor[e] != 2'b01)) begin
                    ckpt_seen_nonfree[e] <= 1'b1;
                end
                // ECR 离开空闲态后清除 pending
                if (ecr_pending_busy[e] && (ecr_monitor[e] != 2'b01)) begin
                    ecr_pending_busy[e] <= 1'b0;
                end
                if (ckpt_valid[e] &&
                    (ecr_monitor[e] == 2'b01) &&
                    ckpt_seen_nonfree[e] &&
                    !ecr_pending_busy[e] &&
                    !ckpt_has_child[e]) begin
                    ckpt_valid[e] <= 1'b0;
                    ckpt_parent_valid[e] <= 1'b0;
                    ckpt_seen_nonfree[e] <= 1'b0;
                end
            end

            if (|ecr_poison_pending) begin
                for (int e = 1; e < NUM_ECRS; e++) begin
                    if (ecr_poison_pending[e]) begin
                        ecr_update.wen <= 1'b1;
                        ecr_update.addr <= e[ECR_W-1:0];
                        ecr_update.do_reset <= 1'b1;
                        ecr_update.reset_data <= 2'b10;
                        ecr_poison_pending[e] <= 1'b0;
                        break;
                    end
                end
            end else if (|ecr_free_pending) begin
                for (int e = 1; e < NUM_ECRS; e++) begin
                    if (ecr_free_pending[e] && !ecr_in_use[e]) begin
                        ecr_update.wen <= 1'b1;
                        ecr_update.addr <= e[ECR_W-1:0];
                        ecr_update.do_reset <= 1'b1;
                        ecr_update.reset_data <= 2'b01;
                        ecr_free_pending[e] <= 1'b0;
                        break;
                    end
                end
            end else if (rb_found) begin
                int                  rid;
                logic [   ECR_W-1:0] rid_bits;
                logic [   ECR_W-1:0] parent_id;
                logic                parent_valid;
                logic [NUM_ECRS-1:0] kill_ckpt;
                rid = rb_id;
                pc <= rb_target_pc;
                // 恢复检查点（若不存在则不改 RAT）
                if (ckpt_valid[rid]) begin
                    for (int i = 1; i < 32; i++) begin
                        cur_state.rat[i] <= ckpt_state[rid].rat[i];
                    end
                end
                rid_bits = rb_id;
                parent_id = ckpt_parent[rid];
                parent_valid = ckpt_parent_valid[rid];

                kill_ckpt = '0;
                kill_ckpt[rid] = 1'b1;
                for (int it = 0; it < NUM_ECRS; it++) begin
                    for (int e = 0; e < NUM_ECRS; e++) begin
                        if (!kill_ckpt[e] && ckpt_valid[e] && ckpt_parent_valid[e] &&
                            kill_ckpt[ckpt_parent[e]]) begin
                            kill_ckpt[e] = 1'b1;
                        end
                    end
                end

                for (int e = 0; e < NUM_ECRS; e++) begin
                    if (kill_ckpt[e]) begin
                        ckpt_valid[e] <= 1'b0;
                        ckpt_parent_valid[e] <= 1'b0;
                        ckpt_seen_nonfree[e] <= 1'b0;
                        ecr_pending_busy[e] <= 1'b0;
                    end
                end
                jr_waiting <= 1'b0;
                for (int e = 1; e < NUM_ECRS; e++) begin
                    if (kill_ckpt[e]) begin
                        ecr_free_pending[e] <= 1'b1;
                        if (e[ECR_W-1:0] != rb_id) ecr_poison_pending[e] <= 1'b1;
                    end
                end
                // 恢复依赖链到 parent（未知则置 00）
                if (parent_valid) active_ecr <= parent_id;
                else active_ecr <= '0;
                pending_valid <= 1'b0;
            end else if (jr_waiting) begin
                // 3) JR 等待：暂停发射直到重定向到来
                logic got;
                logic [31:0] rpc;
                got = 1'b0;
                rpc = 32'b0;
                for (int i = 0; i < NUM_SICS; i++) begin
                    if (sic_pc_redirect_valid[i] &&
                        (sic_pc_redirect_issue_id[i] == jr_wait_issue_id)) begin
                        got = 1'b1;
                        rpc = sic_pc_redirect_pc[i];
                    end
                end
                if (got) begin
                    pc <= rpc;
                    jr_waiting <= 1'b0;
                end
            end else begin
                // 4) 主发射逻辑：按 slot 顺序把取指槽位映射到请求的 SIC
                int issued;
                logic [31:0] next_pc;
                logic cut_packet;
                logic stall;
                logic branch_issued;

                rename_state_t st_work;
                logic [NUM_PHY_REGS-1:0] used_work;
                logic [ECR_W-1:0] active_ecr_work;
                logic [ECR_W-1:0] ecr_alloc_ptr_work;
                logic pend_v;
                cf_kind_t pend_k;
                logic [31:0] pend_target;
                logic [31:0] pend_alt;
                logic pend_pred_taken;
                logic [ECR_W-1:0] pend_ecr;
                logic [ECR_W-1:0] pend_parent;
                logic [ID_WIDTH-1:0] pend_issue_id;
                int ds_slot;

                issued = 0;
                next_pc = pc;
                cut_packet = 1'b0;
                stall = 1'b0;
                branch_issued = 1'b0;

                // 工作副本：同周期按发射顺序滚动更新
                st_work = cur_state;
                active_ecr_work = active_ecr;
                ecr_alloc_ptr_work = ecr_alloc_ptr;

                pend_v = pending_valid;
                pend_k = pending_kind;
                pend_target = pending_target_pc;
                pend_alt = pending_alt_pc;
                pend_pred_taken = pending_pred_taken;
                pend_ecr = pending_ecr;
                pend_parent = pending_parent;
                pend_issue_id = pending_issue_id;
                ds_slot = pend_v ? 0 : -1;

                // used = cur_state + 所有有效 ckpt_state + pr_not_idle
                used_work = calc_used_pr(st_work);
                for (int e = 0; e < NUM_ECRS; e++) begin
                    if (ckpt_valid[e]) begin
                        used_work |= calc_used_pr(ckpt_state[e]);
                    end
                end
                used_work |= pr_not_idle;

                for (int sic = 0; sic < NUM_SICS; sic++) begin
                    if (sic_req_instr[sic] && !cut_packet && !stall) begin
                        // Vivado 兼容：过程块内变量声明必须出现在 begin 的最前面
                        int slot;
                        int pr;
                        logic has_dst;
                        logic [4:0] dst_lr;
                        logic [ECR_W-1:0] alloc_e;
                        logic [31:0] ip;
                        logic [31:0] br_tgt;
                        logic [31:0] j_tgt;
                        logic is_delay_slot;
                        logic [NUM_ECRS-1:0] forbid_ecr;
                        logic [ECR_W-1:0] walk;
                        logic alloc_ok;
                        int cand;

                        slot = issued;
                        is_delay_slot = pend_v && (slot == ds_slot);

                        // 默认发射（后续按需要覆盖字段）
                        sic_packet_out[sic] <= '0;
                        sic_packet_out[sic].valid <= 1'b1;
                        sic_packet_out[sic].pc <= pc + (slot << 2);
                        sic_packet_out[sic].issue_id <= global_issue_id + ID_WIDTH'(slot);
                        sic_packet_out[sic].info <= dec_info[slot];
                        sic_packet_out[sic].pred_taken <= pred_taken_w[slot];
                        sic_packet_out[sic].dep_ecr_id <= active_ecr_work;
                        sic_packet_out[sic].set_ecr_id <= '0;
                        sic_packet_out[sic].next_pc_pred <= (pc + (slot << 2)) + 32'd4;
                        // 默认 phy_dst=PR0；若有真实 dst 将在下方覆盖
                        sic_packet_out[sic].phy_dst <= '0;

                        // 源寄存器映射：未使用的 phy_* 置 0
                        sic_packet_out[sic].phy_rs <= dec_info[slot].read_rs ? map_lr(
                            st_work, dec_info[slot].rs
                        ) : '0;
                        sic_packet_out[sic].phy_rt <= dec_info[slot].read_rt ? map_lr(
                            st_work, dec_info[slot].rt
                        ) : '0;
                        sic_packet_out[sic].phy_rd <= (dec_info[slot].dst_field == DST_RD) ? map_lr(
                            st_work, dec_info[slot].rd
                        ) : '0;

                        // 目的寄存器重命名
                        has_dst = dec_info[slot].write_gpr;
                        dst_lr  = dec_info[slot].dst_lr;

                        if (has_dst) begin
                            if (dst_lr == 5'd0) begin
                                // 写 $0：不分配、不更新 RAT
                                sic_packet_out[sic].phy_dst <= '0;
                            end else begin
                                pr = find_free_pr(used_work);
                                if (pr < 0) begin
                                    // 无可用 PR：本周期从该条开始停止发射
                                    sic_packet_out[sic] <= '0;
                                    sic_packet_out[sic].valid <= 1'b0;
                                    stall = 1'b1;
                                end else begin
                                    used_work[pr] = 1'b1;  // 本周期单调增加
                                    st_work.rat[dst_lr] = PR_W'(pr);
                                    sic_packet_out[sic].phy_dst <= PR_W'(pr);
                                    rf_alloc_wen[sic] <= 1'b1;
                                    rf_alloc_pr[sic] <= PR_W'(pr);
                                    // 覆盖对应字段映射（便于调试）
                                    if (dec_info[slot].dst_field == DST_RD)
                                        sic_packet_out[sic].phy_rd <= PR_W'(pr);
                                    else sic_packet_out[sic].phy_rt <= PR_W'(pr);
                                end
                            end
                        end

                        // 分支：分配 ECR + 保存检查点 + 预测 PC/altPC
                        if (pend_v && (slot != ds_slot)) begin
                            sic_packet_out[sic] <= '0;
                            sic_packet_out[sic].valid <= 1'b0;
                            stall = 1'b1;
                        end else if (!stall && !is_delay_slot && (dec_info[slot].cf_kind == CF_BRANCH) && branch_issued) begin
                            // 每周期最多发射一个分支（ecr_update/ckpt 为单端口）
                            sic_packet_out[sic] <= '0;
                            sic_packet_out[sic].valid <= 1'b0;
                            stall = 1'b1;
                        end else if (!stall && !is_delay_slot && (dec_info[slot].cf_kind == CF_BRANCH)) begin
                            forbid_ecr = '0;
                            walk = active_ecr_work;
                            for (int it = 0; it < NUM_ECRS; it++) begin
                                forbid_ecr[walk] = 1'b1;
                                if (walk == '0) break;
                                if (!ckpt_parent_valid[walk]) break;
                                walk = ckpt_parent[walk];
                            end

                            alloc_ok = 1'b0;
                            alloc_e  = '0;
                            for (int off = 0; off < (NUM_ECRS - 1); off++) begin
                                cand = int'(ecr_alloc_ptr_work) + off;
                                if (cand >= NUM_ECRS) cand = cand - (NUM_ECRS - 1);
                                if (!alloc_ok &&
                                    !forbid_ecr[cand] && !ckpt_valid[cand] &&
                                    !ecr_pending_busy[cand] && (ecr_monitor[cand] == 2'b01)) begin
                                    alloc_ok = 1'b1;
                                    alloc_e  = cand[ECR_W-1:0];
                                end
                            end

                            if (!alloc_ok) begin
                                sic_packet_out[sic] <= '0;
                                sic_packet_out[sic].valid <= 1'b0;
                                stall = 1'b1;
                            end else begin
                                ecr_pending_busy[alloc_e] <= 1'b1;
                                ckpt_seen_nonfree[alloc_e] <= 1'b0;

                                sic_packet_out[sic].set_ecr_id <= alloc_e;

                                ecr_update.wen <= 1'b1;
                                ecr_update.addr <= alloc_e;
                                ecr_update.do_reset <= 1'b1;
                                ecr_update.reset_data <= 2'b00;
                                ecr_update.do_bpinfo <= 1'b1;
                                ecr_update.bpinfo_pc <= pc + (slot << 2);
                                ecr_update.bpinfo_pred_taken <= pred_taken_w[slot];

                                ecr_alloc_ptr_work = (alloc_e == (NUM_ECRS-1)) ? ECR_W'(1) : (alloc_e + 1);

                                branch_issued = 1'b1;

                                ckpt_age[alloc_e] <= global_issue_id + ID_WIDTH'(slot);

                                ip = pc + (slot << 2);
                                br_tgt = ip + 32'd4 + (dec_info[slot].imm16_sign_ext << 2);
                                sic_packet_out[sic].next_pc_pred <= pred_taken_w[slot] ? br_tgt : (ip + 32'd8);

                                pend_v = 1'b1;
                                pend_k = CF_BRANCH;
                                pend_ecr = alloc_e;
                                pend_parent = active_ecr_work;
                                pend_pred_taken = pred_taken_w[slot];
                                pend_target = pred_taken_w[slot] ? br_tgt : (ip + 32'd8);
                                pend_alt = pred_taken_w[slot] ? (ip + 32'd8) : br_tgt;
                                ds_slot = slot + 1;
                            end
                        end else if (!stall && !is_delay_slot && (dec_info[slot].cf_kind == CF_JUMP_IMM)) begin
                            ip = pc + (slot << 2);
                            j_tgt = {ip[31:28], dec_info[slot].jump_target, 2'b00};
                            sic_packet_out[sic].next_pc_pred <= j_tgt;
                            if (dec_info[slot].opcode == OPC_JAL) begin
                                sic_packet_out[sic].pc <= ip + 32'd4;
                            end
                            pend_v = 1'b1;
                            pend_k = CF_JUMP_IMM;
                            pend_pred_taken = 1'b0;
                            pend_target = j_tgt;
                            ds_slot = slot + 1;
                        end else if (!stall && !is_delay_slot && (dec_info[slot].cf_kind == CF_JUMP_REG)) begin
                            sic_packet_out[sic].next_pc_pred <= 'x;
                            pend_v = 1'b1;
                            pend_k = CF_JUMP_REG;
                            pend_pred_taken = 1'b0;
                            pend_issue_id = global_issue_id + ID_WIDTH'(slot);
                            ds_slot = slot + 1;
                        end

                        if (!stall) begin
                            issued++;
                            if (pend_v && (slot == ds_slot)) begin
                                if (pend_k == CF_BRANCH) begin
                                    ckpt_state[pend_ecr] <= st_work;
                                    ckpt_valid[pend_ecr] <= 1'b1;
                                    ckpt_parent[pend_ecr] <= pend_parent;
                                    ckpt_parent_valid[pend_ecr] <= 1'b1;
                                    ckpt_alt_pc[pend_ecr] <= pend_alt;
                                    ckpt_seen_nonfree[pend_ecr] <= 1'b1;
                                    active_ecr_work = pend_ecr;
                                    if (pend_pred_taken) begin
                                        next_pc = pend_target;
                                        cut_packet = 1'b1;
                                    end
                                end else if (pend_k == CF_JUMP_IMM) begin
                                    next_pc = pend_target;
                                    cut_packet = 1'b1;
                                end else if (pend_k == CF_JUMP_REG) begin
                                    jr_waiting <= 1'b1;
                                    jr_wait_issue_id <= pend_issue_id;
                                    next_pc = pc + ((slot + 1) << 2);
                                    cut_packet = 1'b1;
                                end
                                pend_v  = 1'b0;
                                ds_slot = -1;
                            end
                        end
                    end
                end

                // 提交本周期状态
                cur_state <= st_work;
                active_ecr <= active_ecr_work;
                ecr_alloc_ptr <= ecr_alloc_ptr_work;
                global_issue_id <= global_issue_id + ID_WIDTH'(issued);
                pending_valid <= pend_v;
                pending_kind <= pend_k;
                pending_target_pc <= pend_target;
                pending_alt_pc <= pend_alt;
                pending_pred_taken <= pend_pred_taken;
                pending_ecr <= pend_ecr;
                pending_parent <= pend_parent;
                pending_issue_id <= pend_issue_id;
                if (issued > 0) begin
                    if (cut_packet) pc <= next_pc;
                    else pc <= pc + (issued << 2);
                end
            end
        end
    end

endmodule
