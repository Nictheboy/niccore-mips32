
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
        MEM_ACCESS,
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

    // Abort：依赖的 ECR 为 10 时，丢弃当前指令
    logic abort_mispredict;

    // 指令资源需求（用于请求/释放资源）
    logic need_reg_read0, need_reg_read1, need_reg_write2;
    logic need_mem_read, need_mem_write;
    logic need_alu;

    // REQUEST_LOCKS 阶段的 grant 聚合
    logic all_granted;

    // 资源释放脉冲
    logic alu_release_pulse;

    // Reg 写回数据保持
    logic [31:0] reg_wdata_dst;

    // 是否持有有效 packet（用于对 RF 声明 PR 占用）
    logic holding_pkt;
    assign holding_pkt = (state != IDLE) && ((state != WAIT_PACKET) || packet_in.valid);

    // 组合逻辑计算锁请求
    always_comb begin
        // WAIT_PACKET 拍使用 packet_in 视图，其余拍使用已锁存的 pkt
        sic_packet_t pkt_v;
        pkt_v                = ((state == WAIT_PACKET) && packet_in.valid) ? packet_in : pkt;

        // 资源需求（由 decoder 给出）
        need_reg_read0       = pkt_v.info.read_rs;
        need_reg_read1       = pkt_v.info.read_rt;
        need_reg_write2      = pkt_v.info.write_gpr;
        need_mem_read        = pkt_v.info.mem_read;
        need_mem_write       = pkt_v.info.mem_write;
        need_alu             = pkt_v.info.use_alu;

        // 默认：寄存器文件不写回
        reg_req              = '0;
        mem_req              = '0;

        // 资源池锁结构体默认输出
        mem_rpl.req          = 0;
        mem_rpl.req_issue_id = pkt.issue_id;
        mem_rpl.release_lock = 0;
        alu_rpl.req          = 0;
        alu_rpl.req_issue_id = pkt.issue_id;
        alu_rpl.release_lock = alu_release_pulse;

        // PR 占用声明：持有 packet 时持续输出读写 PR，否则输出 0
        // 读地址：仅当该指令确实需要对应源寄存器时才声明占用，否则置 0。
        reg_req.rs_addr      = (holding_pkt && need_reg_read0) ? pkt_v.phy_rs : '0;
        reg_req.rt_addr      = (holding_pkt && need_reg_read1) ? pkt_v.phy_rt : '0;

        // 写地址：仅当该指令未来会写寄存器时才声明占用，否则置 0。
        // 注意：wcommit 仍在 COMMIT_WRITE 才会拉高；这里仅用于“占用/避免复用”的可见性。
        reg_req.waddr        = (holding_pkt && need_reg_write2) ? pkt_v.phy_dst : '0;
        reg_req.wdata        = reg_wdata_dst;

        // 外部资源请求策略：
        // - ALU：持有直到 RELEASE
        // - MEM：仅在 MEM_ACCESS 请求，并在 grant 当拍释放
        if (state == REQUEST_LOCKS || state == EXECUTE_READ || state == CHECK_ECR || state == COMMIT_WRITE) begin
            alu_rpl.req = need_alu;
        end
        if (state == MEM_ACCESS) begin
            mem_rpl.req = (need_mem_read || need_mem_write);
            // grant 当拍释放
            mem_rpl.release_lock = mem_grant;
        end

        // 组装 mem_req：地址/数据来自 hold 寄存器
        mem_req.addr  = mem_addr_hold[31:2];
        mem_req.wdata = mem_wdata_hold;
        // sw：在 MEM_ACCESS 且拿到 grant 的当拍写入
        mem_req.wen   = (state == MEM_ACCESS) && need_mem_write && mem_grant && !abort_mispredict;

        // 写回数据源：lw 直接用 mem_rdata，其余用 reg_wdata_dst
        if ((state == MEM_ACCESS) && need_mem_read && mem_grant) begin
            reg_req.wdata = mem_rdata;
        end else begin
            reg_req.wdata = reg_wdata_dst;
        end

        // 写回提交：lw 在 MEM_ACCESS 当拍，其余在 COMMIT_WRITE
        if ((state == MEM_ACCESS) && need_mem_read && mem_grant) begin
            reg_req.wcommit = need_reg_write2 && !abort_mispredict;
        end else if (state == COMMIT_WRITE) begin
            if (need_reg_write2 && (pkt_v.info.wb_sel != WB_MEM)) begin
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

    // ECR 读地址：0-based 编号
    assign ecr_read_addr = pkt.dep_ecr_id[$clog2(2)-1:0];

    // ECR 读使能：执行期间读取 dep_ecr
    assign ecr_read_en = (state != IDLE) && (state != WAIT_PACKET);

    // Abort 条件：依赖 ECR==10
    assign abort_mispredict = ecr_read_en && (ecr_read_data == 2'b10);

    // IDLE 或 WAIT_PACKET(无 valid) 时请求指令
    assign req_instr = (state == IDLE) || (state == WAIT_PACKET && !packet_in.valid);

    // 状态机逻辑
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
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
            // 默认清除单周期脉冲
            alu_release_pulse <= 0;
            ecr_wen           <= 0;
            pc_redirect_valid <= 0;

            // 若依赖 ECR 已为 Incorrect，则丢弃当前指令
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
                        // 等待所需资源满足
                        if (all_granted) state <= EXECUTE_READ;
                    end

                    EXECUTE_READ: begin
                        // 准备操作数/请求
                        if (need_alu) begin
                            // ALU
                            op_a_val <= reg_ans.rs_rdata;
                            op_b_val   <= pkt.info.alu_b_is_imm
                                         ? (pkt.info.alu_imm_is_zero_ext ? pkt.info.imm16_zero_ext
                                                                         : pkt.info.imm16_sign_ext)
                                         : reg_ans.rt_rdata;
                            alu_req.op <= pkt.info.alu_op;
                            alu_req.a <= reg_ans.rs_rdata;
                            alu_req.b  <= pkt.info.alu_b_is_imm
                                         ? (pkt.info.alu_imm_is_zero_ext ? pkt.info.imm16_zero_ext
                                                                         : pkt.info.imm16_sign_ext)
                                         : reg_ans.rt_rdata;
                        end else if (need_mem_read || need_mem_write) begin
                            // 地址计算（内部加法）
                            op_a_val <= reg_ans.rs_rdata;  // base
                            op_b_val <= reg_ans.rt_rdata;  // store data (sw)
                            mem_addr_hold <= reg_ans.rs_rdata + pkt.info.imm16_sign_ext;  // byte addr
                            mem_wdata_hold <= reg_ans.rt_rdata;
                            alu_req <= '0;
                        end else if (pkt.info.wb_sel == WB_LUI) begin
                            alu_req <= '0;
                        end else if (pkt.info.wb_sel == WB_LINK) begin
                            alu_req <= '0;
                        end else if (pkt.info.cf_kind == CF_JUMP_REG) begin
                            // JR
                            op_a_val <= reg_ans.rs_rdata;
                            alu_req  <= '0;
                        end
                        // 单周期进入下一阶段
                        state <= CHECK_ECR;
                    end

                    CHECK_ECR: begin
                        // 保存结果
                        result_val <= alu_ans.c;
                        zero_val   <= alu_ans.zero;

                        // 约定：00=Busy, 01=Correct, 10=Incorrect
                        if (ecr_read_data == 2'b10) begin
                            state <= RELEASE;
                        end else if (ecr_read_data == 2'b01) begin
                            // 准备写回数据
                            unique case (pkt.info.wb_sel)
                                WB_ALU:  reg_wdata_dst <= alu_ans.c;
                                WB_LUI:  reg_wdata_dst <= {pkt.info.imm16, 16'b0};
                                WB_LINK: reg_wdata_dst <= pkt.pc + 32'd4;
                                default: reg_wdata_dst <= reg_wdata_dst;
                            endcase
                            // lw/sw 进入 MEM_ACCESS
                            if (need_mem_read || need_mem_write) begin
                                state <= MEM_ACCESS;
                            end else begin
                                state <= COMMIT_WRITE;
                            end
                        end
                        // 00: Busy，保持等待
                    end

                    MEM_ACCESS: begin
                        // lw/sw：等待 mem grant；grant 当拍完成访存
                        if (mem_grant) begin
                            state <= RELEASE;
                        end else begin
                            state <= MEM_ACCESS;
                        end
                    end

                    COMMIT_WRITE: begin
                        // 提交点：写回/更新 ECR/输出重定向

                        if (pkt.info.write_ecr) begin
                            // 判断分支结果
                            logic actual_taken;
                            // BEQ：zero_val==1 表示 taken
                            actual_taken = zero_val;

                            // 更新 ECR
                            ecr_wen <= 1;
                            ecr_write_addr <= pkt.set_ecr_id[$clog2(2)-1:0];
                            if (actual_taken == pkt.pred_taken) ecr_wdata <= 2'b01;  // Correct
                            else ecr_wdata <= 2'b10;  // Incorrect

                        end

                        // JR：提交时输出 PC 重定向
                        if (pkt.info.cf_kind == CF_JUMP_REG) begin
                            pc_redirect_valid <= 1;
                            pc_redirect_pc <= op_a_val;  // rs 值已在 EXECUTE_READ 采样
                            pc_redirect_issue_id <= pkt.issue_id;
                        end

                        // SYSCALL
                        if (pkt.info.is_syscall) begin
`ifndef SYNTHESIS
                            $display("[SIC%0d] SYSCALL at PC=%h, finishing simulation.", SIC_ID,
                                     pkt.pc);
                            $finish;
`endif
                        end

                        // 下一状态释放
                        state <= RELEASE;
                    end

                    RELEASE: begin
                        // 释放资源
                        if (need_alu) alu_release_pulse <= 1;
                        state <= IDLE;
                    end
                endcase
        end
    end

endmodule
