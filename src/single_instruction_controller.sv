module single_instruction_controller #(
    parameter int SIC_ID,
    parameter int NUM_PHY_REGS,
    parameter int ID_WIDTH
) (
    input logic clk,
    input logic rst_n,

    // 与 Issue Controller 交互
    output logic        req_instr,
    input  sic_packet_t packet_in,

    // 与 Register Module 交互 (3 个端口: 0,1读, 2写)
    // 端口索引是相对于 SIC 的 (0, 1, 2)
    output logic [$clog2(NUM_PHY_REGS)-1:0] reg_addr        [3],
    output logic                            reg_req_read    [3],
    output logic                            reg_req_write   [3],
    // 写提交：只在真正提交写回的那个周期拉高
    output logic                            reg_write_commit[3],
    output logic [            ID_WIDTH-1:0] reg_issue_id    [3],
    output logic                            reg_release     [3],
    output logic [                    31:0] reg_wdata       [3],
    input  logic [                    31:0] reg_rdata       [3],
    input  logic                            reg_grant       [3],

    // 与 Memory 交互
    output logic [        31:0] mem_addr,
    output logic                mem_req_read,
    output logic                mem_req_write,
    output logic [ID_WIDTH-1:0] mem_issue_id,
    output logic                mem_release,
    output logic [        31:0] mem_wdata,
    output logic                mem_write_commit,
    input  logic [        31:0] mem_rdata,
    input  logic                mem_grant,

    // 与 ALU 交互
    output logic                alu_req,
    output logic [ID_WIDTH-1:0] alu_issue_id,
    output logic                alu_release,
    output logic [        31:0] alu_op_a,
    output logic [        31:0] alu_op_b,
    output logic [         5:0] alu_opcode,
    input  logic [        31:0] alu_res,
    input  logic                alu_zero,
    input  logic                alu_over,
    input  logic                alu_grant,

    // 与 ECR 交互 (简化接口)
    // 读接口：直接输出地址，组合逻辑读取
    output logic [$clog2(2)-1:0] ecr_read_addr,  // 假设 NUM_ECRS=2
    input  logic [          1:0] ecr_read_data,

    // 写接口：写使能和地址数据
    output logic                 ecr_wen,
    output logic [$clog2(2)-1:0] ecr_write_addr,
    output logic [          1:0] ecr_wdata,

    // 分支预测更新 (简单直连 BP)
    output logic                bp_update_en,
    output logic [        31:0] bp_update_pc,
    output logic                bp_actual_taken,
    // === 反馈给 Issue Controller 的 ECR 使用情况（用于判断 ECR 是否仍被至少一个 SIC 依赖）===
    output logic                dep_ecr_active,
    output logic [         1:0] dep_ecr_id_out,
    // === JR：提交后 PC 重定向反馈 ===
    output logic                pc_redirect_valid,
    output logic [        31:0] pc_redirect_pc,
    output logic [ID_WIDTH-1:0] pc_redirect_issue_id
);

    // 状态机
    typedef enum logic [3:0] {
        IDLE,
        WAIT_PACKET,
        REQUEST_LOCKS,
        EXECUTE_READ,
        CHECK_ECR,
        COMMIT_WRITE,
        RELEASE
    } state_t;

    state_t state;
    sic_packet_t pkt;

    // 内部暂存
    logic [31:0] op_a_val, op_b_val, result_val;
    logic zero_val;
    logic locks_acquired;

    // 指令分类（由 info.opcode + funct 推导，供 always_comb/always_ff 共用）
    logic op_alu_r, op_ori, op_lui, op_lw, op_sw, op_beq, op_j, op_jal, op_jr, op_syscall;

    // 该指令实际需要哪些资源（用于正确释放锁，避免依赖 state 门控的 req 信号导致“永不释放”）
    logic need_reg_read0, need_reg_read1, need_reg_write2;
    logic need_mem_read, need_mem_write;
    logic need_alu;

    // REQUEST_LOCKS 阶段的 grant 聚合（避免在 always_ff 里声明局部变量触发 Vivado 警告）
    logic all_granted;

    // 组合逻辑计算锁请求
    always_comb begin
        op_ori = (pkt.info.opcode == OPC_ORI);
        op_lui = (pkt.info.opcode == OPC_LUI);
        op_lw = (pkt.info.opcode == OPC_LW);
        op_sw = (pkt.info.opcode == OPC_SW);
        op_beq = (pkt.info.opcode == OPC_BEQ);
        op_j = (pkt.info.opcode == OPC_J);
        op_jal = (pkt.info.opcode == OPC_JAL);
        op_alu_r = (pkt.info.opcode == OPC_SPECIAL) &&
                   ((pkt.info.funct == 6'h21) || (pkt.info.funct == 6'h23));
        op_jr = (pkt.info.opcode == OPC_SPECIAL) && (pkt.info.funct == 6'h08);
        op_syscall = (pkt.info.opcode == OPC_SPECIAL) && (pkt.info.funct == 6'h0c);

        // 先根据指令类型计算“资源需求”（与 state 无关）
        need_reg_read0 = (op_alu_r || op_beq || op_sw || op_ori || op_lw || op_jr);
        need_reg_read1 = (op_alu_r || op_beq || op_sw);
        need_reg_write2 = (op_alu_r || op_lw || op_ori || op_lui || op_jal);

        need_mem_read = op_lw;
        need_mem_write = op_sw;

        // 当前 ALU 仅用于：R-Type / ORI / BEQ。LUI/LW/SW 由内部简单逻辑完成（避免不必要的 ALU 锁）
        need_alu = (op_alu_r || op_ori || op_beq);

        // 默认全 0
        reg_req_read[0] = 0;
        reg_req_read[1] = 0;
        reg_req_read[2] = 0;
        reg_req_write[0] = 0;
        reg_req_write[1] = 0;
        reg_req_write[2] = 0;
        reg_write_commit[0] = 0;
        reg_write_commit[1] = 0;
        reg_write_commit[2] = 0;
        mem_req_read = 0;
        mem_req_write = 0;
        alu_req = 0;
        mem_write_commit = 0;

        reg_addr[0] = pkt.phy_rs;
        reg_addr[1] = pkt.phy_rt;
        reg_addr[2] = pkt.phy_dst;

        // 读锁：读到操作数就可以释放，所以只在 REQUEST_LOCKS/EXECUTE_READ 阶段请求
        if (state == REQUEST_LOCKS || state == EXECUTE_READ) begin
            reg_req_read[0] = need_reg_read0;
            reg_req_read[1] = need_reg_read1;
        end

        // 写锁/外部资源：需要持有到提交或回滚，所以在整个关键区间持续请求
        if (state == REQUEST_LOCKS || state == EXECUTE_READ || state == CHECK_ECR || state == COMMIT_WRITE) begin
            reg_req_write[2] = need_reg_write2;
            mem_req_read     = need_mem_read;
            mem_req_write    = need_mem_write;
            alu_req          = need_alu;
        end

        // 仅在提交写回状态，且确实是写寄存器类指令时，拉高 commit
        if (state == COMMIT_WRITE) begin
            if (op_alu_r || op_lw || op_ori || op_lui || op_jal) begin
                reg_write_commit[2] = 1;
            end
            if (op_sw) begin
                mem_write_commit = 1;
            end
        end
    end

    // 聚合 grant（避免在 always_ff 内部声明 all_granted 变量）
    always_comb begin
        all_granted = 1;
        if (state == REQUEST_LOCKS) begin
            if (reg_req_read[0] && !reg_grant[0]) all_granted = 0;
            if (reg_req_read[1] && !reg_grant[1]) all_granted = 0;
            if (reg_req_write[2] && !reg_grant[2]) all_granted = 0;
            if (mem_req_read && !mem_grant) all_granted = 0;
            if (mem_req_write && !mem_grant) all_granted = 0;
            if (alu_req && !alu_grant) all_granted = 0;
        end
    end

    // 发射 ID 赋值
    assign reg_issue_id[0] = pkt.issue_id;
    assign reg_issue_id[1] = pkt.issue_id;
    assign reg_issue_id[2] = pkt.issue_id;
    assign mem_issue_id    = pkt.issue_id;
    assign alu_issue_id    = pkt.issue_id;

    // ECR 读地址：统一采用 0-based 编号（ECR0=0, ECR1=1）
    assign ecr_read_addr = pkt.dep_ecr_id[$clog2(2)-1:0];

    // 反馈：当 SIC 持有一条正在执行的指令时，认为它“仍在依赖/读取 dep_ecr”
    assign dep_ecr_active = (state != IDLE) && (state != WAIT_PACKET);
    assign dep_ecr_id_out = dep_ecr_active ? pkt.dep_ecr_id : 'x;

    // 如果处于 IDLE，或者处于 WAIT 且还没收到 Valid 数据，则请求指令
    // 一旦收到 packet_in.valid，req_instr 会立即拉低，防止发射控制器在下一个沿误判
    assign req_instr = (state == IDLE) || (state == WAIT_PACKET && !packet_in.valid);

    // 状态机逻辑
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            reg_release <= '{0, 0, 0};
            mem_release <= 0;
            alu_release <= 0;
            ecr_wen <= 0;
            bp_update_en <= 0;
            reg_wdata <= '{default: 32'b0};
            pc_redirect_valid <= 0;
            pc_redirect_pc <= 32'b0;
            pc_redirect_issue_id <= '0;
        end else begin
            // 默认清除 Release 信号 (Release 仅维持一个周期)
            reg_release       <= '{0, 0, 0};
            mem_release       <= 0;
            alu_release       <= 0;
            ecr_wen           <= 0;
            bp_update_en      <= 0;
            pc_redirect_valid <= 0;

            case (state)
                IDLE: begin
                    state <= WAIT_PACKET;
                end

                WAIT_PACKET: begin
                    if (packet_in.valid) begin
                        pkt   <= packet_in;
                        state <= REQUEST_LOCKS;
                    end
                end

                REQUEST_LOCKS: begin
                    // 在此状态下，组合逻辑已经发出了所有 req 信号
                    // 我们检查是否所有需要的 Grant 都已获得
                    // 注意：ECR 读取现在是组合逻辑，不需要 Grant
                    // 简化：如果所有请求的锁都 Grant，进入执行

                    // ECR 读取现在是组合逻辑，不需要 Grant
                    if (all_granted) state <= EXECUTE_READ;
                end

                EXECUTE_READ: begin
                    // 锁已持有，读取数据是瞬时的 (Flash Read)
                    // 准备操作数
                    if (op_alu_r) begin
                        op_a_val   <= reg_rdata[0];
                        op_b_val   <= reg_rdata[1];
                        alu_opcode <= pkt.info.funct;
                        // 关键修复：ALU 输入不要转发 op_*_val（同一拍会拿到旧值），直接用 reg_rdata
                        alu_op_a   <= reg_rdata[0];
                        alu_op_b   <= reg_rdata[1];
                    end else if (op_ori) begin
                        op_a_val   <= reg_rdata[0];
                        op_b_val   <= pkt.info.imm16_zero_ext;
                        alu_opcode <= 6'h25;  // OR
                        alu_op_a   <= reg_rdata[0];
                        alu_op_b   <= pkt.info.imm16_zero_ext;
                    end else if (op_beq) begin
                        op_a_val   <= reg_rdata[0];
                        op_b_val   <= reg_rdata[1];
                        alu_opcode <= 6'h22;  // SUB (Check Zero)
                        alu_op_a   <= reg_rdata[0];
                        alu_op_b   <= reg_rdata[1];
                    end else if (op_lw || op_sw) begin
                        // 地址计算（内部加法，不走 ALU 资源池）
                        op_a_val  <= reg_rdata[0];  // base
                        op_b_val  <= reg_rdata[1];  // store data (sw)
                        mem_addr  <= reg_rdata[0] + pkt.info.imm16_sign_ext;  // byte addr
                        mem_wdata <= reg_rdata[1];
                        // 不使用 ALU 资源池，避免遗留旧值造成波形困惑
                        alu_op_a  <= 32'b0;
                        alu_op_b  <= 32'b0;
                    end else if (op_lui) begin
                        // LUI 无需读寄存器
                        // 保持 op_a/op_b 不用
                        alu_op_a <= 32'b0;
                        alu_op_b <= 32'b0;
                    end else if (op_jal) begin
                        // JAL 无需读寄存器，写回在 CHECK_ECR 准备
                        alu_op_a <= 32'b0;
                        alu_op_b <= 32'b0;
                    end else if (op_jr) begin
                        // JR 需要读取 rs 作为跳转目标
                        op_a_val <= reg_rdata[0];
                        alu_op_a <= 32'b0;
                        alu_op_b <= 32'b0;
                    end
                    // ... 其他指令解码到 ALU Opcode ...

                    // 读完寄存器操作数即可释放读锁（避免长时间占用）
                    if (need_reg_read0) reg_release[0] <= 1;
                    if (need_reg_read1) reg_release[1] <= 1;

                    // 可以在这里等待 ALU 结果稳定，或假设单周期
                    state <= CHECK_ECR;
                end

                CHECK_ECR: begin
                    // 保存计算结果
                    result_val <= alu_res;
                    zero_val   <= alu_zero;

                    // 检查依赖的 ECR
                    // ecr_read_data 是组合逻辑输出，直接可用
                    // 约定：00=不确定(Busy), 01=预测正确, 10=预测错误
                    if (ecr_read_data == 2'b10) begin
                        // 预测错误！回滚 (Abort)：释放所有锁，不写回
                        state <= RELEASE;
                    end else if (ecr_read_data == 2'b01) begin
                        // 预测正确，继续
                        // 关键：提前准备好写回数据，使其在 COMMIT_WRITE 的时钟沿稳定
                        if (op_alu_r || op_ori) begin
                            reg_wdata[2] <= alu_res;
                        end
                        if (op_lui) begin
                            reg_wdata[2] <= {pkt.info.imm16, 16'b0};
                        end
                        if (op_jal) begin
                            // 约定：无延迟槽，link = PC+4
                            reg_wdata[2] <= pkt.pc + 32'd4;
                        end
                        if (op_lw) begin
                            reg_wdata[2] <= mem_rdata;
                        end
                        state <= COMMIT_WRITE;
                    end
                    // 若为 00 (Busy)，保持此状态等待
                end

                COMMIT_WRITE: begin
                    // 执行写操作 (写 Reg 或 Mem 或 ECR)

                    // 寄存器写回由 reg_write_commit[2] + reg_wdata[2] 在本周期时钟沿完成
                    // reg_wdata 已在 CHECK_ECR 中提前准备好，这里不再修改它，避免时序错拍

                    if (op_beq) begin
                        // 判断分支结果
                        logic actual_taken;
                        // 这里只支持 BEQ：ALU 做 SUB，zero_val==1 表示相等 -> taken
                        actual_taken = zero_val;

                        // 更新 ECR
                        ecr_wen <= 1;
                        ecr_write_addr <= pkt.set_ecr_id[$clog2(2)-1:0];  // 0-based
                        if (actual_taken == pkt.pred_taken) ecr_wdata <= 2'b01;  // Correct
                        else ecr_wdata <= 2'b10;  // Incorrect

                        // 更新 BP
                        bp_update_en <= 1;
                        bp_update_pc <= pkt.pc;
                        bp_actual_taken <= actual_taken;
                    end

                    // JR：提交时输出 PC 重定向（issue_controller 会暂停发射直到收到它）
                    if (op_jr) begin
                        pc_redirect_valid <= 1;
                        pc_redirect_pc <= op_a_val;  // rs 值已在 EXECUTE_READ 采样
                        pc_redirect_issue_id <= pkt.issue_id;
                    end

                    // SYSCALL：仿真最小实现，提交点直接结束仿真
                    if (op_syscall) begin
`ifndef SYNTHESIS
                        $display("[SIC%0d] SYSCALL at PC=%h, finishing simulation.", SIC_ID,
                                 pkt.pc);
                        $finish;
`endif
                    end

                    // 同步写在时钟沿生效，下一状态释放
                    state <= RELEASE;
                end

                RELEASE: begin
                    // 发出释放信号
                    // 注意：这里不能依赖 reg_req_*/mem_req_*/alu_req，
                    // 因为这些 req 信号在 RELEASE 状态会被组合逻辑门控为 0。
                    if (need_reg_read0) reg_release[0] <= 1;
                    if (need_reg_read1) reg_release[1] <= 1;
                    if (need_reg_write2) reg_release[2] <= 1;
                    if (need_mem_read || need_mem_write) mem_release <= 1;
                    if (need_alu) alu_release <= 1;
                    // ECR 不再需要释放信号

                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
