
`include "structs.svh"

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

    // 与 Register File 交互（打包接口）
    output reg_req#(NUM_PHY_REGS)::t reg_req,
    input  reg_ans_t                 reg_ans,

    // 与 Memory 交互（打包接口）
    output rpl_req#(ID_WIDTH)::t        mem_rpl,
    output mem_req_t                    mem_req,
    input  logic                 [31:0] mem_rdata,
    input  logic                        mem_grant,

    // 与 ALU 交互
    output rpl_req#(ID_WIDTH)::t alu_rpl,
    output alu_req_t             alu_req,
    input  alu_ans_t             alu_ans,
    input  logic                 alu_grant,

    // 与 ECR 交互 (简化接口)
    // 读接口：直接输出地址，组合逻辑读取
    output logic                 ecr_read_en,
    output logic [$clog2(2)-1:0] ecr_read_addr,   // 假设 NUM_ECRS=2
    input  logic [          1:0] ecr_read_data,
    // 写接口：写使能和地址数据
    output logic                 ecr_wen,
    output logic [$clog2(2)-1:0] ecr_write_addr,
    output logic [          1:0] ecr_wdata,

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
    logic [31:0] mem_addr_hold;  // byte addr
    logic [31:0] mem_wdata_hold;

    // Abort (mispredict squash):
    // 只要依赖的 ECR 被置为 10(Incorrect)，则无论当前处于何状态，都中止本 SIC 正在执行的指令。
    logic abort_mispredict;

    // 指令分类（由 info.opcode + funct 推导，供 always_comb/always_ff 共用）
    logic op_alu_r, op_ori, op_lui, op_lw, op_sw, op_beq, op_j, op_jal, op_jr, op_syscall;

    // 该指令实际需要哪些资源（用于正确释放锁，避免依赖 state 门控的 req 信号导致“永不释放”）
    logic need_reg_read0, need_reg_read1, need_reg_write2;
    logic need_mem_read, need_mem_write;
    logic need_alu;

    // REQUEST_LOCKS 阶段的 grant 聚合（避免在 always_ff 里声明局部变量触发 Vivado 警告）
    logic all_granted;

    // release_lock 需要是单周期脉冲（由时序逻辑产生），通过结构体输出给资源池锁
    logic mem_release_pulse;
    logic alu_release_pulse;

    // Reg 写回数据保持（在 CHECK_ECR 提前准备，COMMIT_WRITE 只拉高 wcommit）
    logic [31:0] reg_wdata_dst;

    // Whether this SIC is currently holding a valid packet (so it should advertise PR usage).
    logic holding_pkt;
    assign holding_pkt = (state != IDLE) && (state != WAIT_PACKET);

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

        // 默认：寄存器文件不写回
        reg_req = '0;
        mem_req = '0;

        // 资源池锁结构体默认输出
        mem_rpl.req = 0;
        mem_rpl.req_issue_id = pkt.issue_id;
        mem_rpl.release_lock = mem_release_pulse;
        alu_rpl.req = 0;
        alu_rpl.req_issue_id = pkt.issue_id;
        alu_rpl.release_lock = alu_release_pulse;

        // Register usage advertisement:
        // - When holding a valid pkt, continuously advertise the PRs we will read/write.
        // - When not holding a pkt (IDLE/WAIT_PACKET), drive 0 so RF can see PR is not in-use.
        // 读地址：仅当该指令确实需要对应源寄存器时才声明占用，否则置 0。
        reg_req.rs_addr = (holding_pkt && need_reg_read0) ? pkt.phy_rs : '0;
        reg_req.rt_addr = (holding_pkt && need_reg_read1) ? pkt.phy_rt : '0;

        // 写地址：仅当该指令未来会写寄存器时才声明占用，否则置 0。
        // 注意：wcommit 仍在 COMMIT_WRITE 才会拉高；这里仅用于“占用/避免复用”的可见性。
        reg_req.waddr = (holding_pkt && need_reg_write2) ? pkt.phy_dst : '0;
        reg_req.wdata = reg_wdata_dst;

        // 外部资源：需要持有到提交或回滚，所以在整个关键区间持续请求
        if (state == REQUEST_LOCKS || state == EXECUTE_READ || state == CHECK_ECR || state == COMMIT_WRITE) begin
            mem_rpl.req = (need_mem_read || need_mem_write);
            alu_rpl.req = need_alu;
        end

        // 组装 mem_req：地址/数据来自 hold 寄存器，写使能仅在提交点拉高
        mem_req.addr  = mem_addr_hold[31:2];
        mem_req.wdata = mem_wdata_hold;
        // 注意：abort_mispredict 必须门控所有架构可见副作用，避免同一拍误提交
        mem_req.wen   = (state == COMMIT_WRITE) && op_sw && !abort_mispredict;

        // 仅在提交写回状态，且确实是写寄存器类指令时，拉高 commit
        if (state == COMMIT_WRITE) begin
            if (op_alu_r || op_lw || op_ori || op_lui || op_jal) begin
                reg_req.wcommit = need_reg_write2 && !abort_mispredict;
            end
        end
    end

    // 聚合 grant（避免在 always_ff 内部声明 all_granted 变量）
    always_comb begin
        all_granted = 1;
        if (state == REQUEST_LOCKS) begin
            if (need_reg_read0 && !reg_ans.rs_valid) all_granted = 0;
            if (need_reg_read1 && !reg_ans.rt_valid) all_granted = 0;
            if (mem_rpl.req && !mem_grant) all_granted = 0;
            if (alu_rpl.req && !alu_grant) all_granted = 0;
        end
    end

    // ECR 读地址：统一采用 0-based 编号（ECR0=0, ECR1=1）
    assign ecr_read_addr = pkt.dep_ecr_id[$clog2(2)-1:0];

    // ECR 读使能：SIC 在执行一条有效指令期间，认为自己“正在依赖/读取 dep_ecr”
    assign ecr_read_en = (state != IDLE) && (state != WAIT_PACKET);

    // Abort 条件：在持有有效 pkt 的期间，只要依赖 ECR==10，立即中止
    assign abort_mispredict = ecr_read_en && (ecr_read_data == 2'b10);

    // 如果处于 IDLE，或者处于 WAIT 且还没收到 Valid 数据，则请求指令
    // 一旦收到 packet_in.valid，req_instr 会立即拉低，防止发射控制器在下一个沿误判
    assign req_instr = (state == IDLE) || (state == WAIT_PACKET && !packet_in.valid);

    // 状态机逻辑
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            mem_release_pulse <= 0;
            alu_release_pulse <= 0;
            ecr_wen <= 0;
            reg_wdata_dst <= 32'b0;
            mem_addr_hold <= 32'b0;
            mem_wdata_hold <= 32'b0;
            alu_req <= '0;
            pc_redirect_valid <= 0;
            pc_redirect_pc <= 32'b0;
            pc_redirect_issue_id <= '0;
        end else begin
            // 默认清除 Release 信号 (Release 仅维持一个周期)
            mem_release_pulse <= 0;
            alu_release_pulse <= 0;
            ecr_wen           <= 0;
            pc_redirect_valid <= 0;

            // 最高优先级：若依赖 ECR 已判为 Incorrect，则无论状态立即中止
            // 并确保本拍不会产生任何提交副作用（组合/时序路径均已门控）
            if (abort_mispredict) begin
                state <= RELEASE;
            end else
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
                            op_a_val   <= reg_ans.rs_rdata;
                            op_b_val   <= reg_ans.rt_rdata;
                            alu_req.op <= pkt.info.funct;
                            // 关键修复：ALU 输入不要转发 op_*_val（同一拍会拿到旧值），直接用寄存器读数据
                            alu_req.a  <= reg_ans.rs_rdata;
                            alu_req.b  <= reg_ans.rt_rdata;
                        end else if (op_ori) begin
                            op_a_val   <= reg_ans.rs_rdata;
                            op_b_val   <= pkt.info.imm16_zero_ext;
                            alu_req.op <= 6'h25;  // OR
                            alu_req.a  <= reg_ans.rs_rdata;
                            alu_req.b  <= pkt.info.imm16_zero_ext;
                        end else if (op_beq) begin
                            op_a_val   <= reg_ans.rs_rdata;
                            op_b_val   <= reg_ans.rt_rdata;
                            alu_req.op <= 6'h22;  // SUB (Check Zero)
                            alu_req.a  <= reg_ans.rs_rdata;
                            alu_req.b  <= reg_ans.rt_rdata;
                        end else if (op_lw || op_sw) begin
                            // 地址计算（内部加法，不走 ALU 资源池）
                            op_a_val <= reg_ans.rs_rdata;  // base
                            op_b_val <= reg_ans.rt_rdata;  // store data (sw)
                            mem_addr_hold <= reg_ans.rs_rdata + pkt.info.imm16_sign_ext;  // byte addr
                            mem_wdata_hold <= reg_ans.rt_rdata;
                            // 不使用 ALU 资源池，避免遗留旧值造成波形困惑
                            alu_req <= '0;
                        end else if (op_lui) begin
                            // LUI 无需读寄存器
                            // 保持 op_a/op_b 不用
                            alu_req <= '0;
                        end else if (op_jal) begin
                            // JAL 无需读寄存器，写回在 CHECK_ECR 准备
                            alu_req <= '0;
                        end else if (op_jr) begin
                            // JR 需要读取 rs 作为跳转目标
                            op_a_val <= reg_ans.rs_rdata;
                            alu_req  <= '0;
                        end
                        // ... 其他指令解码到 ALU Opcode ...

                        // 可以在这里等待 ALU 结果稳定，或假设单周期
                        state <= CHECK_ECR;
                    end

                    CHECK_ECR: begin
                        // 保存计算结果
                        result_val <= alu_ans.c;
                        zero_val   <= alu_ans.zero;

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
                                reg_wdata_dst <= alu_ans.c;
                            end
                            if (op_lui) begin
                                reg_wdata_dst <= {pkt.info.imm16, 16'b0};
                            end
                            if (op_jal) begin
                                // 约定：无延迟槽，link = PC+4
                                reg_wdata_dst <= pkt.pc + 32'd4;
                            end
                            if (op_lw) begin
                                reg_wdata_dst <= mem_rdata;
                            end
                            state <= COMMIT_WRITE;
                        end
                        // 若为 00 (Busy)，保持此状态等待
                    end

                    COMMIT_WRITE: begin
                        // 执行写操作 (写 Reg 或 Mem 或 ECR)

                        // 寄存器写回由 reg_req.wcommit + reg_req.wdata 在本周期时钟沿完成
                        // reg_wdata_dst 已在 CHECK_ECR 中提前准备好，这里不再修改它，避免时序错拍

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
                        if (need_mem_read || need_mem_write) mem_release_pulse <= 1;
                        if (need_alu) alu_release_pulse <= 1;
                        // ECR 不再需要释放信号

                        state <= IDLE;
                    end
                endcase
        end
    end

endmodule
