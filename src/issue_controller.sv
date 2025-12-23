
`include "structs.svh"

// NOTE:
// - 该文件将被重写为“RAT 状态 + 最小快照 + 通过所有投机状态求 free PR”的版本。
// - 按用户要求：先删掉旧实现的大部分代码，再分段插入新实现。

module issue_controller #(
    parameter int NUM_SICS,
    parameter int NUM_PHY_REGS,
    parameter int ID_WIDTH,
    parameter int BRANCH_PREDICTOR_TABLE_SIZE
) (
    input logic clk,
    input logic rst_n,

    // 指令内存接口
    output logic [31:0] imem_addr,
    input logic [NUM_SICS-1:0][31:0] imem_data,

    // SIC 交互接口
    input  logic                       sic_req_instr           [NUM_SICS],
    output sic_packet_t                sic_packet_out          [NUM_SICS],
    input  logic                       sic_pc_redirect_valid   [NUM_SICS],
    input  logic        [        31:0] sic_pc_redirect_pc      [NUM_SICS],
    input  logic        [ID_WIDTH-1:0] sic_pc_redirect_issue_id[NUM_SICS],

    // 回滚指示（调试/监控用）
    output logic rollback_trigger,

    // === Register File Allocate (to register_file) ===
    output logic rf_alloc_wen[NUM_SICS],
    output logic [$clog2(NUM_PHY_REGS)-1:0] rf_alloc_pr[NUM_SICS],

    // ECR -> Issue：汇总状态（allocator + rollback + in_use）
    input ecr_status_for_issue#(2)::t ecr_status,
    // ECR monitor：提供每个 ECR 的真实 2-bit 状态（00/01/10），用于正确管理快照生命周期
    input logic [1:0] ecr_monitor[2],

    // Issue -> ECR：统一更新（reset + bpinfo + altpc）
    output ecr_reset_for_issue#(2)::t ecr_update,

    // ECR -> BP：更新由 ECR 产生（issue_controller 仅转接到 BP 实例）
    input bp_update_t bp_update
);

    localparam int NUM_ECRS = 2;
    localparam int ECR_W = (NUM_ECRS > 1) ? $clog2(NUM_ECRS) : 1;
    localparam int PR_W = (NUM_PHY_REGS > 1) ? $clog2(NUM_PHY_REGS) : 1;

    // PC / Issue ID
    logic [31:0] pc;
    logic [ID_WIDTH-1:0] global_issue_id;

    // JR 等待：发射到 JR 后暂停，直到收到匹配 issue_id 的 redirect
    logic jr_waiting;
    logic [ID_WIDTH-1:0] jr_wait_issue_id;

    // 当前“依赖链”的 ECR（把它塞进 packet.dep_ecr_id）
    logic [1:0] active_ecr;

    // -------- 私有状态定义：逻辑寄存器映射表（RAT）--------
    // RAT only tracks logical regs 1..31. $0 is excluded and always maps to PR0.
    typedef struct {logic [PR_W-1:0] rat[31:1];} rename_state_t;

    rename_state_t cur_state;

    // 最小快照：每个 ECR 一份（只保存 RAT）
    rename_state_t ckpt_state[NUM_ECRS];
    logic ckpt_valid[NUM_ECRS];

    // branch predictor + decoder (按取指 slot 索引)
    logic pred_taken_w[NUM_SICS];
    instr_info_t dec_info[NUM_SICS];

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
            active_ecr <= 2'b00;
            ecr_update <= '0;
            // 初始化 RAT：lr[i] -> pr[i] (exclude $0)
            for (int i = 1; i < 32; i++) begin
                cur_state.rat[i] <= PR_W'(i);
            end
            for (int e = 0; e < NUM_ECRS; e++) begin
                ckpt_valid[e] <= 1'b0;
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

            // 1) 快照回收：ECR 已回到 01 且不再被任何 SIC 依赖 => 该快照失效
            for (int e = 0; e < NUM_ECRS; e++) begin
                if (ckpt_valid[e] &&
                    (ecr_monitor[e] == 2'b01) &&
                    (ecr_status.in_use[e] == 1'b0)) begin
                    ckpt_valid[e] <= 1'b0;
                end
            end

            // 2) 回滚：由 ECR file 发起（任一 ECR==10）
            if (ecr_status.rollback_valid) begin
                int rid;
                rid = ecr_status.rollback_id;
                pc <= ecr_status.rollback_target_pc;
                // 恢复检查点（若该检查点不存在，退化为不改 RAT）
                if (ckpt_valid[rid]) begin
                    for (int i = 1; i < 32; i++) begin
                        cur_state.rat[i] <= ckpt_state[rid].rat[i];
                    end
                end
                // 回滚后：清掉所有快照（最保守，最不容易错）
                for (int e = 0; e < NUM_ECRS; e++) begin
                    ckpt_valid[e] <= 1'b0;
                end
                jr_waiting <= 1'b0;
                // Ack：把触发回滚的 ECR 写回 01，避免每周期重复回滚
                ecr_update.wen <= 1'b1;
                ecr_update.addr <= ecr_status.rollback_id;
                ecr_update.do_reset <= 1'b1;
                ecr_update.reset_data <= 2'b01;
                // 依赖链回到“已确定”的 ECR（它已被置 01）
                active_ecr <= {1'b0, ecr_status.rollback_id};
            end else if (jr_waiting) begin
                // 3) JR 等待：暂停发射直到匹配 issue_id 的重定向到来
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
                // 4) 主发射逻辑（最简）：按 slot 顺序把取指槽位映射到“请求的 SIC”
                int issued;
                logic [31:0] next_pc;
                logic cut_packet;
                logic stall;

                rename_state_t st_work;
                logic [NUM_PHY_REGS-1:0] used_work;
                logic [1:0] active_ecr_work;

                issued = 0;
                next_pc = pc;
                cut_packet = 1'b0;
                stall = 1'b0;

                // 工作副本：同周期 RAW 用（按发射顺序滚动更新）
                st_work = cur_state;
                active_ecr_work = active_ecr;

                // used = union(cur_state + all ckpt_state(valid))
                used_work = calc_used_pr(st_work);
                for (int e = 0; e < NUM_ECRS; e++) begin
                    if (ckpt_valid[e]) begin
                        used_work |= calc_used_pr(ckpt_state[e]);
                    end
                end

                for (int sic = 0; sic < NUM_SICS; sic++) begin
                    if (sic_req_instr[sic] && !cut_packet && !stall) begin
                        // Vivado 兼容：过程块内变量声明必须出现在 begin 的最前面
                        int slot;
                        int pr;
                        logic is_alu_r, is_ori, is_lui, is_lw, is_sw, is_beq, is_j, is_jal, is_jr;
                        logic has_dst;
                        logic [4:0] dst_lr;
                        logic [ECR_W-1:0] alloc_e;
                        logic [31:0] ip;
                        logic [31:0] br_tgt;
                        logic [31:0] fall;
                        logic [31:0] j_tgt;

                        slot = issued;

                        // 默认发射
                        sic_packet_out[sic] <= '0;
                        sic_packet_out[sic].valid <= 1'b1;
                        sic_packet_out[sic].pc <= pc + (slot << 2);
                        sic_packet_out[sic].issue_id <= global_issue_id + ID_WIDTH'(slot);
                        sic_packet_out[sic].info <= dec_info[slot];
                        sic_packet_out[sic].pred_taken <= pred_taken_w[slot];
                        sic_packet_out[sic].dep_ecr_id <= active_ecr_work;
                        sic_packet_out[sic].set_ecr_id <= 'x;
                        sic_packet_out[sic].next_pc_pred <= (pc + (slot << 2)) + 32'd4;
                        // Default to PR0 to avoid X-propagation. If instruction has a real dst,
                        // it will be overwritten below; if dst is $0, it stays PR0.
                        sic_packet_out[sic].phy_dst <= '0;

                        // 源寄存器映射
                        sic_packet_out[sic].phy_rs <= dec_info[slot].rs_valid ? map_lr(
                            st_work, dec_info[slot].rs
                        ) : 'x;
                        sic_packet_out[sic].phy_rt <= dec_info[slot].rt_valid ? map_lr(
                            st_work, dec_info[slot].rt
                        ) : 'x;
                        sic_packet_out[sic].phy_rd <= dec_info[slot].rd_valid ? map_lr(
                            st_work, dec_info[slot].rd
                        ) : 'x;

                        // 指令分类（只覆盖当前 core 用到的集合）
                        is_ori = (dec_info[slot].opcode == OPC_ORI);
                        is_lui = (dec_info[slot].opcode == OPC_LUI);
                        is_lw = (dec_info[slot].opcode == OPC_LW);
                        is_sw = (dec_info[slot].opcode == OPC_SW);
                        is_beq = (dec_info[slot].opcode == OPC_BEQ);
                        is_j = (dec_info[slot].opcode == OPC_J);
                        is_jal = (dec_info[slot].opcode == OPC_JAL);
                        is_alu_r = (dec_info[slot].opcode == OPC_SPECIAL) &&
                                   ((dec_info[slot].funct == 6'h21) || (dec_info[slot].funct == 6'h23));
                        is_jr = (dec_info[slot].opcode == OPC_SPECIAL) && (dec_info[slot].funct == 6'h08);

                        // 目的寄存器重命名
                        has_dst = is_alu_r || is_ori || is_lui || is_lw || is_jal;
                        dst_lr = 5'd0;
                        if (is_alu_r) dst_lr = dec_info[slot].rd;
                        else if (is_jal) dst_lr = 5'd31;
                        else if (is_ori || is_lui || is_lw) dst_lr = dec_info[slot].rt;

                        if (has_dst) begin
                            if (dst_lr == 5'd0) begin
                                // Writes to $0: no allocation, no RAT update. Keep phy_dst==PR0.
                                sic_packet_out[sic].phy_dst <= '0;
                            end else begin
                                pr = find_free_pr(used_work);
                                if (pr < 0) begin
                                    // 无可用物理寄存器：本周期从该条开始不再发射
                                    sic_packet_out[sic] <= '0;
                                    sic_packet_out[sic].valid <= 1'b0;
                                    stall = 1'b1;
                                end else begin
                                    used_work[pr] = 1'b1; // 本周期单调增加，避免同周期复用带来混乱
                                    st_work.rat[dst_lr] = PR_W'(pr);
                                    sic_packet_out[sic].phy_dst <= PR_W'(pr);
                                    rf_alloc_wen[sic] <= 1'b1;
                                    rf_alloc_pr[sic] <= PR_W'(pr);
                                    // 为了调试一致性：覆盖对应字段的映射展示
                                    if (is_alu_r) sic_packet_out[sic].phy_rd <= PR_W'(pr);
                                    else sic_packet_out[sic].phy_rt <= PR_W'(pr);
                                end
                            end
                        end

                        // 分支：分配 ECR + 保存快照 + 预测 PC/altPC
                        if (!stall && is_beq) begin
                            if (!ecr_status.alloc_avail) begin
                                sic_packet_out[sic] <= '0;
                                sic_packet_out[sic].valid <= 1'b0;
                                stall = 1'b1;
                            end else begin
                                alloc_e = ecr_status.alloc_id;

                                // 保存快照：以“分支点之前”的状态作为回滚恢复点
                                ckpt_state[alloc_e] <= st_work;
                                ckpt_valid[alloc_e] <= 1'b1;

                                sic_packet_out[sic].set_ecr_id <= {1'b0, alloc_e};

                                // 置 ECR busy + 写分支元信息 + 写 altpc
                                ecr_update.wen <= 1'b1;
                                ecr_update.addr <= alloc_e;
                                ecr_update.do_reset <= 1'b1;
                                ecr_update.reset_data <= 2'b00;
                                ecr_update.do_bpinfo <= 1'b1;
                                ecr_update.bpinfo_pc <= pc + (slot << 2);
                                ecr_update.bpinfo_pred_taken <= pred_taken_w[slot];
                                ecr_update.do_altpc <= 1'b1;

                                // 更新依赖链：后续指令依赖新 ECR
                                active_ecr_work = {1'b0, alloc_e};

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
                        end else if (!stall && (is_j || is_jal)) begin
                            ip = pc + (slot << 2);
                            j_tgt = {ip[31:28], dec_info[slot].jump_target, 2'b00};
                            sic_packet_out[sic].next_pc_pred <= j_tgt;
                            next_pc = j_tgt;
                            cut_packet = 1'b1;
                        end else if (!stall && is_jr) begin
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

                // 提交本周期 state
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

endmodule
