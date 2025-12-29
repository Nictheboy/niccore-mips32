
`include "structs.svh"

// Issue controller:
// - 负责取指、重命名、分支检查点管理、以及向各 SIC 分发 packet

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

    // 回滚指示（调试/监控用）
    output logic rollback_trigger,

    output logic [$clog2(NUM_ECRS)-1:0] active_ecr_id,

    // Register File allocate
    output logic rf_alloc_wen[NUM_SICS],
    output logic [$clog2(NUM_PHY_REGS)-1:0] rf_alloc_pr[NUM_SICS],

    // Register File usage bitmap:
    // 1 表示该 PR 正被某个 SIC 引用（rs/rt/waddr），分配器不得复用
    input logic [NUM_PHY_REGS-1:0] pr_not_idle,

    // ECR -> Issue：汇总状态（allocator + rollback + in_use）
    input ecr_status_for_issue#(NUM_ECRS)::t ecr_status,
    // ECR monitor：提供每个 ECR 的 2-bit 状态（00/01/10），用于管理快照生命周期
    input logic [1:0] ecr_monitor[NUM_ECRS],

    // Issue -> ECR：统一更新（reset + bpinfo + altpc）
    output ecr_reset_for_issue#(NUM_ECRS)::t ecr_update,

    // ECR -> BP：由 ECR 产生更新，issue_controller 仅转接
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

    logic rollback_hold;
    logic [ECR_W-1:0] rollback_ecr;

    // 当前依赖链 ECR（写入 packet.dep_ecr_id）
    logic [ECR_W-1:0] active_ecr;

    // 逻辑寄存器映射表（RAT）：只跟踪 1..31，$0 恒为 PR0
    typedef struct {logic [PR_W-1:0] rat[31:1];} rename_state_t;

    rename_state_t             cur_state;

    // 检查点：每个 ECR 一份（保存 RAT）
    rename_state_t             ckpt_state       [NUM_ECRS];
    logic                      ckpt_valid       [NUM_ECRS];
    // parent 指针：记录该检查点创建前的依赖链，用于回滚时恢复 active_ecr
    logic          [ECR_W-1:0] ckpt_parent      [NUM_ECRS];
    logic                      ckpt_parent_valid[NUM_ECRS];
    // 本地保留位：用于避免同一拍/相邻拍对同一 ECR 误分配
    logic                      ecr_pending_busy [NUM_ECRS];
    // 记录该检查点是否进入过非空闲态（00/10），用于回收策略
    logic                      ckpt_seen_nonfree[NUM_ECRS];

    // branch predictor + decoder（按取指 slot 索引）
    logic                      pred_taken_w     [NUM_SICS];
    instr_info_t               dec_info         [NUM_SICS];

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
    assign rollback_trigger = ecr_status.rollback_valid;

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

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc <= 32'h0000_3000;
            global_issue_id <= '0;
            jr_waiting <= 1'b0;
            jr_wait_issue_id <= '0;
            rollback_hold <= 1'b0;
            rollback_ecr <= '0;
            active_ecr <= '0;
            ecr_update <= '0;
            // 初始化 RAT：lr[i] -> pr[i] (exclude $0)
            for (int i = 1; i < 32; i++) begin
                cur_state.rat[i] <= PR_W'(i);
            end
            for (int e = 0; e < NUM_ECRS; e++) begin
                ckpt_valid[e] <= 1'b0;
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
                    (ecr_status.in_use[e] == 1'b0) &&
                    ckpt_seen_nonfree[e] &&
                    !ecr_pending_busy[e]) begin
                    ckpt_valid[e] <= 1'b0;
                    ckpt_parent_valid[e] <= 1'b0;
                    ckpt_seen_nonfree[e] <= 1'b0;
                end
            end

            if (rollback_hold) begin
                if (!ecr_status.in_use[rollback_ecr]) begin
                    ecr_update.wen <= 1'b1;
                    ecr_update.addr <= rollback_ecr;
                    ecr_update.do_reset <= 1'b1;
                    ecr_update.reset_data <= 2'b01;
                    rollback_hold <= 1'b0;
                end
            end else if (ecr_status.rollback_valid) begin
                int rid;
                logic [ECR_W-1:0] rid_bits;
                rid = ecr_status.rollback_id;
                pc <= ecr_status.rollback_target_pc;
                // 恢复检查点（若不存在则不改 RAT）
                if (ckpt_valid[rid]) begin
                    for (int i = 1; i < 32; i++) begin
                        cur_state.rat[i] <= ckpt_state[rid].rat[i];
                    end
                end
                // 失效回滚检查点及其直接子节点（NUM_ECRS=2 时足够）
                rid_bits = ecr_status.rollback_id;
                ckpt_valid[rid] <= 1'b0;
                ckpt_parent_valid[rid] <= 1'b0;
                ckpt_seen_nonfree[rid] <= 1'b0;
                ecr_pending_busy[rid] <= 1'b0;
                for (int e = 0; e < NUM_ECRS; e++) begin
                    if (ckpt_valid[e] && ckpt_parent_valid[e] && (ckpt_parent[e] == rid_bits)) begin
                        ckpt_valid[e] <= 1'b0;
                        ckpt_parent_valid[e] <= 1'b0;
                        ckpt_seen_nonfree[e] <= 1'b0;
                        ecr_pending_busy[e] <= 1'b0;
                    end
                end
                jr_waiting <= 1'b0;
                rollback_hold <= 1'b1;
                rollback_ecr <= ecr_status.rollback_id;
                // 恢复依赖链到 parent（未知则置 00）
                if (ckpt_parent_valid[rid]) active_ecr <= ckpt_parent[rid];
                else active_ecr <= '0;
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

                issued = 0;
                next_pc = pc;
                cut_packet = 1'b0;
                stall = 1'b0;
                branch_issued = 1'b0;

                // 工作副本：同周期按发射顺序滚动更新
                st_work = cur_state;
                active_ecr_work = active_ecr;

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
                        logic [31:0] fall;
                        logic [31:0] j_tgt;

                        slot = issued;

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
                        if (!stall && (dec_info[slot].cf_kind == CF_BRANCH) && branch_issued) begin
                            // 每周期最多发射一个分支（ecr_update/ckpt 为单端口）
                            sic_packet_out[sic] <= '0;
                            sic_packet_out[sic].valid <= 1'b0;
                            stall = 1'b1;
                        end else if (!stall && (dec_info[slot].cf_kind == CF_BRANCH)) begin
                            // 若该 ECR 处于本地 pending，则视为不可分配
                            if (!ecr_status.alloc_avail || ecr_pending_busy[ecr_status.alloc_id]) begin
                                sic_packet_out[sic] <= '0;
                                sic_packet_out[sic].valid <= 1'b0;
                                stall = 1'b1;
                            end else begin
                                alloc_e = ecr_status.alloc_id;

                                // 保存检查点：以分支点之前状态作为回滚恢复点
                                ckpt_state[alloc_e] <= st_work;
                                ckpt_valid[alloc_e] <= 1'b1;
                                ckpt_parent[alloc_e] <= active_ecr_work;
                                ckpt_parent_valid[alloc_e] <= 1'b1;
                                // 本地保留直到 monitor 反映非空闲态
                                ecr_pending_busy[alloc_e] <= 1'b1;
                                ckpt_seen_nonfree[alloc_e] <= 1'b0;

                                sic_packet_out[sic].set_ecr_id <= alloc_e;

                                // 置 ECR busy，同时写分支信息与 altpc
                                ecr_update.wen <= 1'b1;
                                ecr_update.addr <= alloc_e;
                                ecr_update.do_reset <= 1'b1;
                                ecr_update.reset_data <= 2'b00;
                                ecr_update.do_bpinfo <= 1'b1;
                                ecr_update.bpinfo_pc <= pc + (slot << 2);
                                ecr_update.bpinfo_pred_taken <= pred_taken_w[slot];
                                ecr_update.do_altpc <= 1'b1;

                                // 更新依赖链：后续指令依赖新 ECR
                                active_ecr_work = alloc_e;
                                branch_issued = 1'b1;

                                ip = pc + (slot << 2);
                                br_tgt = ip + 32'd4 + (dec_info[slot].imm16_sign_ext << 2);
                                fall = ip + 32'd4;

                                if (pred_taken_w[slot]) begin
                                    sic_packet_out[sic].next_pc_pred <= br_tgt;
                                    ecr_update.altpc_pc <= fall;
                                    next_pc = br_tgt;
                                    cut_packet = 1'b1;
                                end else begin
                                    sic_packet_out[sic].next_pc_pred <= fall;
                                    ecr_update.altpc_pc <= br_tgt;
                                end
                            end
                        end else if (!stall && (dec_info[slot].cf_kind == CF_JUMP_IMM)) begin
                            ip = pc + (slot << 2);
                            j_tgt = {ip[31:28], dec_info[slot].jump_target, 2'b00};
                            sic_packet_out[sic].next_pc_pred <= j_tgt;
                            next_pc = j_tgt;
                            cut_packet = 1'b1;
                        end else if (!stall && (dec_info[slot].cf_kind == CF_JUMP_REG)) begin
                            // JR：等待 SIC 提交重定向
                            jr_waiting <= 1'b1;
                            jr_wait_issue_id <= global_issue_id + ID_WIDTH'(slot);
                            sic_packet_out[sic].next_pc_pred <= 'x;
                            cut_packet = 1'b1;
                        end

                        if (!stall) begin
                            issued++;
                        end
                    end
                end

                // 提交本周期状态
                cur_state <= st_work;
                active_ecr <= active_ecr_work;
                global_issue_id <= global_issue_id + ID_WIDTH'(issued);
                if (issued > 0) begin
                    if (!jr_waiting) begin
                        if (cut_packet) pc <= next_pc;
                        else pc <= pc + (issued << 2);
                    end
                end
            end
        end
    end

    assign active_ecr_id = active_ecr;

endmodule
