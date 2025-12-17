
`include "structs.svh"

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
    // SIC -> Issue：用于判断某个 ECR 是否仍被至少一个 SIC 依赖/读取
    input  logic                       sic_dep_ecr_active      [NUM_SICS],
    input  logic        [         1:0] sic_dep_ecr_id          [NUM_SICS],
    // SIC -> Issue：JR 提交后的 PC 重定向（当发射到 jr 后，Issue 会等待该重定向再继续发射）
    input  logic                       sic_pc_redirect_valid   [NUM_SICS],
    input  logic        [        31:0] sic_pc_redirect_pc      [NUM_SICS],
    input  logic        [ID_WIDTH-1:0] sic_pc_redirect_issue_id[NUM_SICS],

    // ECR 监控与回滚
    input  logic [1:0] ecr_states      [2],  // 监控 2 个 ECR 的状态
    output logic       rollback_trigger,     // 调试/监控用

    // ECR 写接口：用于在分配 ECR 时将其置为 Busy (00)
    output logic ecr_reset_wen,
    output logic [0:0] ecr_reset_addr,  // 假设 2 个 ECR，地址宽度为 1
    output logic [1:0] ecr_reset_data  // 固定为 2'b00 (Busy)
    ,  // === Register File Allocate (to register_file) ===
    output logic rf_alloc_wen[NUM_SICS],
    output logic [$clog2(NUM_PHY_REGS)-1:0] rf_alloc_pr[NUM_SICS]
);

    // PC 管理
    logic [31:0] pc, next_pc;
    logic [ID_WIDTH-1:0] global_issue_id;

    // JR 等待模式：一旦发射到 jr，停止继续发射，直到收到匹配 issue_id 的重定向
    logic jr_waiting;
    logic [ID_WIDTH-1:0] jr_wait_issue_id;

    // 寄存器别名表 (RAT) & 空闲列表 (Free List)
    // 简单实现：Logical Reg [0..31] -> Physical Reg [0..NUM_PHY_REGS-1]
    logic [$clog2(NUM_PHY_REGS)-1:0] rat[32];
    // 最简单可理解的回收：free_bitmap + “全空闲时回收（quiescent reclaim）”
    // - free_bitmap[pr]=1 表示该物理寄存器可分配
    // - 只在所有 SIC 都空闲时，把 pending_free 里的旧版本物理寄存器放回 free_bitmap
    logic [NUM_PHY_REGS-1:0] free_bitmap;
    logic [$clog2(NUM_PHY_REGS)-1:0] pending_free[NUM_PHY_REGS];
    int unsigned pending_free_cnt;

    // Vivado 兼容：不要在 always_ff 中声明 unpacked array 的局部变量
    // 这些“work shadow”仅用于同一个周期内多次分配时的临时计算
    logic [NUM_PHY_REGS-1:0] free_bitmap_work;
    logic [$clog2(NUM_PHY_REGS)-1:0] pending_free_work[NUM_PHY_REGS];
    int unsigned pending_free_cnt_work;
    logic all_sics_quiet;

    // 分支检查点（每个 ECR 一份）：用于预测失败时恢复重命名状态，保证正确性
    logic [$clog2(NUM_PHY_REGS)-1:0] rat_ckpt[2][32];
    logic [NUM_PHY_REGS-1:0] free_bitmap_ckpt[2];
    logic [$clog2(NUM_PHY_REGS)-1:0] pending_free_ckpt[2][NUM_PHY_REGS];
    int unsigned pending_free_cnt_ckpt[2];

    // ECR 管理
    logic [1:0] active_ecr;  // 当前依赖的 ECR (Latest Branch)

    // 分支预测实例接口
    // 注意：这些数组的索引是“取指槽位 slot”，不是 SIC 编号。
    logic pred_taken_w[NUM_SICS];

    // 内部解码连线（索引同样是取指槽位 slot）
    instr_info_t dec_info[NUM_SICS];

    // 实例化解码器组
    genvar k;
    generate
        for (k = 0; k < NUM_SICS; k++) begin : decoders
            instruction_decoder idec (
                .instr(imem_data[k]),
                .info (dec_info[k])
            );

            // 分支预测查询
            branch_predictor #(
                .TABLE_SIZE(BRANCH_PREDICTOR_TABLE_SIZE)
            ) bp (
                .clk(clk),
                .rst_n(rst_n),
                .query_pc(pc + (k << 2)),
                .pred_taken(pred_taken_w[k]),
                .update_en(1'b0),
                .update_pc('0),
                .actual_taken(1'b0)  // 更新由 SIC 做
            );
        end
    endgenerate

    // 回滚控制
    logic trigger_rollback;
    logic [31:0] rollback_target_pc;
    logic rollback_ecr_valid;
    logic rollback_ecr_idx;

    // 简单的回滚策略：如果有任何一个 ECR 报错，全流水线回滚
    // 在真实设计中需要知道是哪个 ECR 对应的哪个 PC，这里简化为回滚到已保存的 checkpoint
    // 由于 ECR 只有两个，我们这里做简化假设：
    // 统一采用 0-based：ECR0 对应 PC_A, ECR1 对应 PC_B。
    // 这里为了实现设想中的“回滚发射”，我们需要记录分支时的 Alternative PC。

    logic [31:0] saved_alt_pc[0:1];  // 对应 ECR0/ECR1 的备选 PC

    // 由 SIC 反馈计算：某个 ECR 是否仍被至少一个 SIC 依赖/读取
    logic ecr_in_use[2];

    assign imem_addr = pc;
    assign rollback_trigger = trigger_rollback;
    // ecr_reset_data 由时序逻辑驱动：
    // - 分配新分支时写 00(Busy)
    // - 发生回滚时对触发回滚的 ECR 写 01(已确定) 以“ack”该次回滚，避免每周期重复回滚

    always_comb begin
        trigger_rollback   = 0;
        rollback_target_pc = 0;
        rollback_ecr_valid = 0;
        rollback_ecr_idx   = 0;

        // 检查 ECR 状态 (10 = Predict Incorrect)
        if (ecr_states[0] == 2'b10) begin
            trigger_rollback   = 1;
            rollback_target_pc = saved_alt_pc[0];
            rollback_ecr_valid = 1;
            rollback_ecr_idx   = 0;
        end else if (ecr_states[1] == 2'b10) begin
            trigger_rollback   = 1;
            rollback_target_pc = saved_alt_pc[1];
            rollback_ecr_valid = 1;
            rollback_ecr_idx   = 1;
        end
    end

    // 计算 ECR 是否被至少一个 SIC 依赖
    always_comb begin
        ecr_in_use[0] = 0;
        ecr_in_use[1] = 0;
        for (int i = 0; i < NUM_SICS; i++) begin
            if (sic_dep_ecr_active[i]) begin
                if (sic_dep_ecr_id[i] == 0) ecr_in_use[0] = 1;
                else if (sic_dep_ecr_id[i] == 1) ecr_in_use[1] = 1;
            end
        end
    end

    // 主逻辑
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc <= 32'h0000_3000;
            global_issue_id <= 0;
            active_ecr <= 0;
            // 初始化 RAT：逻辑寄存器 0..31 映射到物理 0..31
            // 初始化 free_bitmap：物理 32..NUM_PHY_REGS-1 可分配
            free_bitmap <= '0;
            for (int pr = 32; pr < NUM_PHY_REGS; pr++) begin
                free_bitmap[pr] <= 1'b1;
            end
            pending_free_cnt <= 0;
            ecr_reset_wen <= 0;
            ecr_reset_addr <= '0;
            ecr_reset_data <= 2'b00;
            jr_waiting <= 0;
            jr_wait_issue_id <= '0;
            for (int i = 0; i < 32; i++) rat[i] <= i;
            for (int s = 0; s < NUM_SICS; s++) begin
                rf_alloc_wen[s] <= 0;
                rf_alloc_pr[s]  <= '0;
            end
            // 检查点初始化为当前状态
            for (int e = 0; e < 2; e++) begin
                for (int i = 0; i < 32; i++) rat_ckpt[e][i] <= i[$clog2(NUM_PHY_REGS)-1:0];
                free_bitmap_ckpt[e] <= free_bitmap;
                pending_free_cnt_ckpt[e] <= 0;
            end
            // 复位时所有输出包清零或置无效
            for (int i = 0; i < NUM_SICS; i++) begin
                sic_packet_out[i] <= '0; // 复位可以用 0，也可以用 x，这里用 0 比较干净
            end
        end else if (trigger_rollback) begin
            pc <= rollback_target_pc;
            // 预测失败：恢复该 ECR 对应的检查点（RAT/空闲表/待回收队列），保证正确性
            for (int i = 0; i < 32; i++) begin
                rat[i] <= rat_ckpt[rollback_ecr_idx][i];
            end
            free_bitmap <= free_bitmap_ckpt[rollback_ecr_idx];
            for (int k = 0; k < NUM_PHY_REGS; k++) begin
                pending_free[k] <= pending_free_ckpt[rollback_ecr_idx][k];
            end
            pending_free_cnt <= pending_free_cnt_ckpt[rollback_ecr_idx];

            // 回滚后让后续指令依赖于“刚被确定”的 ECR（我们会把它 ack 成 01）
            active_ecr <= rollback_ecr_idx;
            jr_waiting <= 0;
            // 关键修复：清除触发回滚的 ECR 的 10 状态，否则 trigger_rollback 会永远为真
            // 这里我们把它置为 01(已确定)，表示“这次回滚已处理完毕”
            if (rollback_ecr_valid) begin
                ecr_reset_wen  <= 1;
                // rollback_ecr_idx 本身就是 1-bit（ECR0/ECR1）
                ecr_reset_addr <= rollback_ecr_idx;
                ecr_reset_data <= 2'b01;
            end else begin
                ecr_reset_wen  <= 0;
                ecr_reset_addr <= '0;
                ecr_reset_data <= 2'b00;
            end
            // 回滚时，当前周期的输出应设为无效
            for (int i = 0; i < NUM_SICS; i++) begin
                sic_packet_out[i] <= 'x;
                sic_packet_out[i].valid <= 0;
            end
            for (int s = 0; s < NUM_SICS; s++) begin
                rf_alloc_wen[s] <= 0;
                rf_alloc_pr[s]  <= '0;
            end
        end else begin
            // =========================================================
            // 0. JR 等待模式：不发射，直到收到匹配 issue_id 的 PC 重定向
            // =========================================================
            if (jr_waiting) begin
                logic got_redirect;
                logic [31:0] redirect_pc;
                got_redirect = 0;
                redirect_pc  = 32'b0;

                for (int i = 0; i < NUM_SICS; i++) begin
                    if (sic_pc_redirect_valid[i] && (sic_pc_redirect_issue_id[i] == jr_wait_issue_id)) begin
                        got_redirect = 1;
                        redirect_pc  = sic_pc_redirect_pc[i];
                    end
                end

                // 默认：不发射任何指令
                for (int i = 0; i < NUM_SICS; i++) begin
                    sic_packet_out[i] <= 'x;
                    sic_packet_out[i].valid <= 0;
                end
                for (int s = 0; s < NUM_SICS; s++) begin
                    rf_alloc_wen[s] <= 0;
                    rf_alloc_pr[s]  <= '0;
                end

                // 默认不写 ECR
                ecr_reset_wen  <= 0;
                ecr_reset_addr <= '0;
                ecr_reset_data <= 2'b00;

                if (got_redirect) begin
                    pc <= redirect_pc;
                    jr_waiting <= 0;
                end
            end else begin
                // 变量声明
                int instructions_issued_this_cycle;
                logic [31:0] next_cycle_pc;
                logic branch_taken_in_packet;
                logic issue_stall;
                logic jr_issued_this_cycle;

                // Vivado 兼容：过程块内声明集中放在该 begin/end 的最前面（循环里只复用这些变量）
                logic has_dest;
                logic [4:0] dest_lr;
                logic [$clog2(NUM_PHY_REGS)-1:0] dest_pr;

                // 局部变量统计物理寄存器消耗量，用于最后一次性更新 FreeHead
                int regs_consumed;

                // 引入当前依赖 ECR 变量
                logic [1:0] current_active_ecr;
                // 为了支持“同周期内 RAW”，使用一个工作 RAT（按发射顺序滚动更新）
                logic [$clog2(NUM_PHY_REGS)-1:0] rat_work[32];

                instructions_issued_this_cycle = 0;
                regs_consumed = 0;
                next_cycle_pc = pc + 4;  // 默认下一周期 PC
                branch_taken_in_packet = 0;
                issue_stall = 0;
                jr_issued_this_cycle = 0;
                // 默认不写 ECR
                ecr_reset_wen  <= 0;
                ecr_reset_addr <= '0;
                ecr_reset_data <= 2'b00;

                // 工作副本：本周期内滚动修改，最后一次性提交
                free_bitmap_work = free_bitmap;
                pending_free_cnt_work = pending_free_cnt;
                for (int k = 0; k < NUM_PHY_REGS; k++) begin
                    pending_free_work[k] = pending_free[k];
                end

                // 默认：本周期不 allocate 新生命周期（仅当成功分配目的物理寄存器时才拉高对应端口）
                for (int s = 0; s < NUM_SICS; s++) begin
                    rf_alloc_wen[s] = 0;
                    rf_alloc_pr[s]  = '0;
                end

                // Quiescent reclaim：当所有 SIC 都空闲时，把旧版本物理寄存器放回 free_bitmap
                all_sics_quiet = 1;
                for (int s = 0; s < NUM_SICS; s++) begin
                    if (sic_dep_ecr_active[s]) all_sics_quiet = 0;
                end
                if (all_sics_quiet && (pending_free_cnt_work > 0)) begin
                    // 综合友好：循环上界必须是常量，不能用 pending_free_cnt_work
                    for (int k = 0; k < NUM_PHY_REGS; k++) begin
                        if (k < pending_free_cnt_work) begin
                            free_bitmap_work[pending_free_work[k]] = 1'b1;
                        end
                    end
                    pending_free_cnt_work = 0;
                end

                // 初始化为寄存器值
                current_active_ecr = active_ecr;
                for (int r = 0; r < 32; r++) begin
                    rat_work[r] = rat[r];
                end

                for (int i = 0; i < NUM_SICS; i++) begin
                    // 默认值（每轮复位，避免未赋值告警）
                    has_dest = 0;
                    dest_lr  = 5'd0;
                    dest_pr  = '0;

                    // 判断是否发射：请求指令 + 无跳转 + 无 Stall
                    if (sic_req_instr[i] && !branch_taken_in_packet && !issue_stall) begin : issue_block
                        // Vivado 兼容：该 begin/end 内的声明必须在最前面
                        int slot;
                        int alloc_pr;
                        logic [$clog2(NUM_PHY_REGS)-1:0] old_pr;
                        logic
                            is_alu_r,
                            is_ori,
                            is_lui,
                            is_lw,
                            is_sw,
                            is_beq,
                            is_j,
                            is_jal,
                            is_jr,
                            is_syscall;

                        // 关键：为“请求指令的 SIC”分配一个连续的取指槽位 slot，
                        // 解码/预测/PC 都以 slot 为准，而不是以 SIC 编号 i 为准。
                        slot = instructions_issued_this_cycle;
                        alloc_pr = -1;
                        old_pr = '0;
                        is_alu_r = 0;
                        is_ori = 0;
                        is_lui = 0;
                        is_lw = 0;
                        is_sw = 0;
                        is_beq = 0;
                        is_j = 0;
                        is_jal = 0;
                        is_jr = 0;
                        is_syscall = 0;

                        // === 1. 发射逻辑 ===
                        sic_packet_out[i].valid <= 1;

                        // PC
                        sic_packet_out[i].pc <= pc + (slot << 2);

                        // Issue ID (基准 + 偏移)
                        sic_packet_out[i].issue_id <= global_issue_id + ID_WIDTH'(slot);

                        // 解码信息透传
                        sic_packet_out[i].info <= dec_info[slot];
                        // is_branch 已迁移到 info 内，由 instruction_decoder 产生
                        sic_packet_out[i].pred_taken <= pred_taken_w[slot];
                        sic_packet_out[i].dep_ecr_id <= current_active_ecr;

                        // =========================================================
                        // 寄存器字段映射（按 decoder 的 rs/rt/rd_valid 决定是否有意义）
                        // 约定：若字段无意义，则对应物理号置为 'x 便于调试
                        // =========================================================
                        if (dec_info[slot].rs_valid)
                            sic_packet_out[i].phy_rs <= rat_work[dec_info[slot].rs];
                        else sic_packet_out[i].phy_rs <= 'x;

                        if (dec_info[slot].rt_valid)
                            sic_packet_out[i].phy_rt <= rat_work[dec_info[slot].rt];
                        else sic_packet_out[i].phy_rt <= 'x;

                        if (dec_info[slot].rd_valid)
                            sic_packet_out[i].phy_rd <= rat_work[dec_info[slot].rd];
                        else sic_packet_out[i].phy_rd <= 'x;

                        // 默认无目的寄存器
                        sic_packet_out[i].phy_dst <= 'x;

                        // =========================================================
                        // 寄存器重命名（真正写回目的寄存器 -> phy_dst）
                        // 规则：在同一个“无分支隔断”的发射窗口内，每次写同一逻辑寄存器都会分配新的物理寄存器，
                        // 且后续指令读取应看到最新映射（使用 rat_work 滚动更新）。
                        // =========================================================
                        // 指令分类（由 info.opcode + funct 推导）
                        is_ori = (dec_info[slot].opcode == OPC_ORI);
                        is_lui = (dec_info[slot].opcode == OPC_LUI);
                        is_lw = (dec_info[slot].opcode == OPC_LW);
                        is_sw = (dec_info[slot].opcode == OPC_SW);
                        is_beq = (dec_info[slot].opcode == OPC_BEQ);
                        is_j = (dec_info[slot].opcode == OPC_J);
                        is_jal = (dec_info[slot].opcode == OPC_JAL);
                        is_alu_r   = (dec_info[slot].opcode == OPC_SPECIAL) &&
                                 ((dec_info[slot].funct == 6'h21) || (dec_info[slot].funct == 6'h23));
                        is_jr      = (dec_info[slot].opcode == OPC_SPECIAL) && (dec_info[slot].funct == 6'h08);
                        is_syscall = (dec_info[slot].opcode == OPC_SPECIAL) && (dec_info[slot].funct == 6'h0c);

                        has_dest = (is_alu_r || is_ori || is_lui || is_lw || is_jal);
                        dest_lr = 5'd0;

                        if (is_alu_r) begin
                            dest_lr = dec_info[slot].rd;
                        end else if (is_jal) begin
                            dest_lr = 5'd31;
                        end else if (is_ori || is_lui || is_lw) begin
                            dest_lr = dec_info[slot].rt;
                        end

                        if (has_dest && (dest_lr != 0)) begin
                            // 只从 32..NUM_PHY_REGS-1 里分配（0..31 保留给架构初始映射）
                            for (int pr = 32; pr < NUM_PHY_REGS; pr++) begin
                                if (free_bitmap_work[pr]) begin
                                    alloc_pr = pr;
                                    break;
                                end
                            end

                            if (alloc_pr == -1) begin
                                // 没有可用物理寄存器：本周期停止发射
                                sic_packet_out[i] <= 'x;
                                sic_packet_out[i].valid <= 0;
                                issue_stall = 1;
                            end else begin
                                // 记录旧版本物理寄存器，等全空闲时再回收（最简单且安全）
                                old_pr = rat_work[dest_lr];
                                if (old_pr >= 32) begin
                                    pending_free_work[pending_free_cnt_work] = old_pr;
                                    pending_free_cnt_work++;
                                end

                                // 分配新物理寄存器
                                free_bitmap_work[alloc_pr] = 1'b0;
                                dest_pr = alloc_pr[$clog2(NUM_PHY_REGS)-1:0];
                                sic_packet_out[i].phy_dst <= dest_pr;
                                // 发出“开启新生命周期”脉冲给寄存器文件
                                rf_alloc_wen[i] = 1;
                                rf_alloc_pr[i]  = dest_pr;

                                // 同时把对应逻辑字段的物理映射更新为新值（便于调试观测）
                                if (is_alu_r) sic_packet_out[i].phy_rd <= dest_pr;
                                else if (is_ori || is_lui || is_lw)
                                    sic_packet_out[i].phy_rt <= dest_pr;

                                // 更新工作 RAT，供后续同周期指令读取
                                rat_work[dest_lr] = dest_pr;
                                regs_consumed++;
                            end
                        end

                        // 分支/跳转与 ECR
                        if (is_beq) begin
                            logic [ 1:0] next_ecr_candidate;
                            logic [31:0] current_instr_pc;
                            logic [31:0] branch_target;
                            logic [31:0] fall_through;

                            // 统一 0-based：在 ECR0/ECR1 之间翻转分配给下一条分支
                            next_ecr_candidate = (current_active_ecr == 0) ? 1 : 0;

                            // 等待 ECR 被确定 (Wait until determined)
                            // 假设 ECR 状态 2'b00 表示 Undefined/Busy，01/10 表示已确定
                            // 如果下一个要用的 ECR 还是 Busy，则必须 Stall，不能覆盖它
                            // 如果目标 ECR 仍 Busy，或者仍被至少一个 SIC 依赖，则必须 Stall，不能覆盖它
                            if (ecr_states[next_ecr_candidate] == 2'b00 || ecr_in_use[next_ecr_candidate]) begin
                                // 资源冲突，停止发射当前指令及后续指令
                                sic_packet_out[i] <= 'x;
                                sic_packet_out[i].valid <= 0;
                                issue_stall = 1;
                            end else begin
                                // ECR 可用，分配给当前分支
                                sic_packet_out[i].set_ecr_id <= next_ecr_candidate;

                                // 关键：保存检查点（用于该分支预测失败时恢复 RAT/free_bitmap/pending_free）
                                for (int r = 0; r < 32; r++) begin
                                    rat_ckpt[next_ecr_candidate][r] <= rat_work[r];
                                end
                                free_bitmap_ckpt[next_ecr_candidate] <= free_bitmap_work;
                                for (int k = 0; k < NUM_PHY_REGS; k++) begin
                                    pending_free_ckpt[next_ecr_candidate][k] <= pending_free_work[k];
                                end
                                pending_free_cnt_ckpt[next_ecr_candidate] <= pending_free_cnt_work;

                                // 立即将该 ECR 置为 Busy (00)
                                ecr_reset_wen <= 1;
                                ecr_reset_addr <= next_ecr_candidate[$bits(ecr_reset_addr)-1:0];
                                ecr_reset_data <= 2'b00;

                                // 更新循环变量，使得下一条指令依赖于这个新 ECR
                                current_active_ecr = next_ecr_candidate;

                                current_instr_pc = pc + (slot << 2);
                                branch_target = current_instr_pc + 4 + (dec_info[slot].imm16_sign_ext << 2);
                                fall_through = current_instr_pc + 4;

                                if (pred_taken_w[slot]) begin
                                    sic_packet_out[i].next_pc_pred   <= branch_target;
                                    saved_alt_pc[next_ecr_candidate] <= fall_through;
                                    next_cycle_pc = branch_target;
                                    branch_taken_in_packet = 1;
                                end else begin
                                    sic_packet_out[i].next_pc_pred   <= fall_through;
                                    saved_alt_pc[next_ecr_candidate] <= branch_target;
                                end
                            end
                        end else if (is_j || is_jal) begin
                            // J/JAL：目标地址在发射端即可确定，直接改变取指 PC，并截断本包后续发射
                            logic [31:0] current_instr_pc;
                            logic [31:0] jump_target;
                            current_instr_pc = pc + (slot << 2);
                            jump_target = {
                                current_instr_pc[31:28], dec_info[slot].jump_target, 2'b00
                            };
                            sic_packet_out[i].next_pc_pred <= jump_target;
                            next_cycle_pc = jump_target;
                            branch_taken_in_packet = 1;
                        end else if (is_jr) begin
                            // JR：目标地址需要等待 SIC 读取寄存器后提交
                            // 这里停止继续发射，直到收到 pc_redirect
                            jr_issued_this_cycle = 1;
                            jr_waiting <= 1;
                            jr_wait_issue_id <= global_issue_id + ID_WIDTH'(slot);
                            // 截断本包后续发射
                            branch_taken_in_packet = 1;
                            // next_pc_pred 对 JR 无意义，置 X 便于调试
                            sic_packet_out[i].next_pc_pred <= 'x;
                        end else begin
                            // 非分支指令
                            // 为了便于调试：当指令不需要写 ECR 时，将 set_ecr_id 置为 X
                            sic_packet_out[i].set_ecr_id <= 'x;
                            sic_packet_out[i].next_pc_pred <= (pc + (instructions_issued_this_cycle << 2)) + 4;
                        end

                        // 只有未发生 Stall 时才增加计数
                        if (!issue_stall) begin
                            instructions_issued_this_cycle++;
                        end

                    end else begin
                        // === 2. 空闲/无效逻辑 (本次修改核心) ===
                        // 当不发射指令时：
                        // 1. 先将整个包置为 'x (不定态)，包括所有数据字段
                        // 2. 紧接着覆盖 valid 位为 0
                        // 在 SystemVerilog 非阻塞赋值中，对同一变量的后一次赋值会覆盖前一次

                        sic_packet_out[i]       <= 'x;  // 全部弄脏
                        sic_packet_out[i].valid <= 0;  // 仅 Valid 设为明确的 0
                        rf_alloc_wen[i] = 0;
                        rf_alloc_pr[i]  = '0;
                    end
                end

                // === 3. 更新全局状态 ===

                // 更新 active_ecr 寄存器
                // 如果发生了 Stall，current_active_ecr 可能只更新了一半，或者保持原值
                // 如果没有 Stall，它保存的是最后一条指令产生的依赖
                if (!issue_stall) begin
                    active_ecr <= current_active_ecr;
                end

                // 更新 Issue ID
                global_issue_id <= global_issue_id + 16'(instructions_issued_this_cycle);

                // 提交本周期滚动更新后的 RAT（包含同周期内写回带来的新映射）
                rat <= rat_work;
                free_bitmap <= free_bitmap_work;
                pending_free_cnt <= pending_free_cnt_work;
                for (int k = 0; k < NUM_PHY_REGS; k++) begin
                    pending_free[k] <= pending_free_work[k];
                end

                // 更新 PC
                if (jr_issued_this_cycle) begin
                    // JR：PC 由重定向通路提交，发射端在等待期间保持不变
                    pc <= pc;
                end else if (branch_taken_in_packet && !issue_stall) begin
                    pc <= next_cycle_pc;
                end else begin
                    // 只有当有发射指令时才推进，避免空转时乱加
                    if (instructions_issued_this_cycle > 0)
                        pc <= pc + (instructions_issued_this_cycle << 2);
                end
            end  // !jr_waiting
        end
    end

endmodule
