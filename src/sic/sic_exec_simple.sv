`include "structs.svh"

module sic_exec_simple #(
    parameter int SIC_ID,
    parameter int NUM_PHY_REGS,
    parameter int ID_WIDTH
) (
    input logic clk,
    input logic rst_n,
    input sic_sub_in#(NUM_PHY_REGS, ID_WIDTH)::t in,
    output sic_sub_out#(NUM_PHY_REGS, ID_WIDTH)::t out
);

    // 本地别名：仅保留高频使用项
    sic_packet_t packet_in;
    reg_ans_t    reg_ans;

    assign packet_in = in.pkt;
    assign reg_ans   = in.reg_ans;

    // JR redirect registers
    logic pc_redirect_valid;
    logic [31:0] pc_redirect_pc;
    logic [ID_WIDTH-1:0] pc_redirect_issue_id;

    // 状态机
    typedef enum logic [3:0] {
        WAIT_PACKET,
        REQUEST_LOCKS,
        EXECUTE_READ,
        COMMIT_WRITE
    } state_t;

    state_t state;
    sic_packet_t pkt;

    logic [31:0] jr_target_r;

    // Abort：依赖的 ECR 为 10 时，丢弃当前指令
    logic abort_mispredict;

    // 指令资源需求（用于请求/释放资源）
    logic need_reg_read0, need_reg_read1, need_reg_write2;

    // REQUEST_LOCKS 阶段的 grant 聚合
    logic all_granted;

    // Reg 写回数据保持
    logic [31:0] reg_wdata_dst;
    sic_packet_t pkt_v;

    // 组合逻辑计算锁请求
    always_comb begin
        out               = '0;

        // WAIT_PACKET 拍使用 packet_in 视图，其余拍使用已锁存的 pkt
        pkt_v             = ((state == WAIT_PACKET) && packet_in.valid) ? packet_in : pkt;

        // 资源需求（由 decoder 给出）
        need_reg_read0    = pkt_v.info.read_rs;
        need_reg_read1    = pkt_v.info.read_rt;
        need_reg_write2   = pkt_v.info.write_gpr;

        // ECR read: dep_ecr_id 编码为 {valid,id}
        out.ecr_read_addr = pkt.dep_ecr_id[0];
        out.ecr_read_en   = (state != WAIT_PACKET) && pkt.dep_ecr_id[1];
        abort_mispredict  = out.ecr_read_en && (in.ecr_read_data == 2'b10);

        // req instr
        out.req_instr     = (state == WAIT_PACKET && !packet_in.valid);

        // RF commit (WB_LUI/WB_LINK only; addresses are driven by top-level)
        out.reg_req       = '0;
        out.reg_req.wdata = reg_wdata_dst;
        if (state == COMMIT_WRITE && need_reg_write2) begin
            out.reg_req.wcommit = !abort_mispredict;
        end

        // JR redirect is registered
        out.pc_redirect_valid    = pc_redirect_valid;
        out.pc_redirect_pc       = pc_redirect_pc;
        out.pc_redirect_issue_id = pc_redirect_issue_id;
    end

    // 聚合 grant（避免在 always_ff 内部声明 all_granted 变量）
    always_comb begin
        all_granted = 1;
        if (state == REQUEST_LOCKS) begin
            if (need_reg_read0 && !reg_ans.rs_valid) all_granted = 0;
            if (need_reg_read1 && !reg_ans.rt_valid) all_granted = 0;
        end
    end

    // 状态机逻辑
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= WAIT_PACKET;
            reg_wdata_dst <= 32'b0;
            jr_target_r <= 32'b0;
            pc_redirect_valid <= 1'b0;
            pc_redirect_pc <= 32'b0;
            pc_redirect_issue_id <= '0;
        end else begin
            pc_redirect_valid <= 0;

            // 若依赖 ECR 已为 Incorrect，则丢弃当前指令
            if (abort_mispredict) begin
                state <= WAIT_PACKET;
            end else
                case (state)
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
                        if (pkt.info.cf_kind == CF_JUMP_REG) begin
                            jr_target_r <= reg_ans.rs_rdata;
                        end
                        // 约定：00=Busy, 01=Correct, 10=Incorrect
                        if (!pkt.dep_ecr_id[1]) begin
                            unique case (pkt.info.wb_sel)
                                WB_LUI:  reg_wdata_dst <= {pkt.info.imm16, 16'b0};
                                WB_LINK: reg_wdata_dst <= pkt.pc + 32'd4;
                                default: reg_wdata_dst <= reg_wdata_dst;
                            endcase
                            state <= COMMIT_WRITE;
                        end else if (in.ecr_read_data == 2'b10) begin
                            state <= WAIT_PACKET;
                        end else if (in.ecr_read_data == 2'b01) begin
                            // 准备写回数据
                            unique case (pkt.info.wb_sel)
                                WB_LUI:  reg_wdata_dst <= {pkt.info.imm16, 16'b0};
                                WB_LINK: reg_wdata_dst <= pkt.pc + 32'd4;
                                default: reg_wdata_dst <= reg_wdata_dst;
                            endcase
                            state <= COMMIT_WRITE;
                        end else begin
                            // 00: Busy，保持等待（不额外消耗 CHECK_ECR 周期）
                            state <= EXECUTE_READ;
                        end
                    end

                    COMMIT_WRITE: begin
                        // 提交点：写回/更新 ECR/输出重定向

                        // JR：提交时输出 PC 重定向
                        if (pkt.info.cf_kind == CF_JUMP_REG) begin
                            pc_redirect_valid <= 1;
                            pc_redirect_pc <= jr_target_r;
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

                        state <= WAIT_PACKET;
                    end
                endcase
        end
    end

endmodule


