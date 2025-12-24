`include "structs.svh"

module sic_exec_alu #(
    parameter int SIC_ID,
    parameter int NUM_PHY_REGS,
    parameter int ID_WIDTH
) (
    input logic clk,
    input logic rst_n,
    input sic_sub_in#(NUM_PHY_REGS, ID_WIDTH)::t in,
    output sic_sub_out#(NUM_PHY_REGS, ID_WIDTH)::t out
);

    // --- 本地别名：仅保留高频使用项 ---
    sic_packet_t packet_in;
    reg_ans_t    reg_ans;

    assign packet_in = in.pkt;
    assign reg_ans   = in.reg_ans;

    logic                 ecr_wen;
    logic [$clog2(2)-1:0] ecr_write_addr;
    logic [          1:0] ecr_wdata;

    // 状态机
    typedef enum logic [3:0] {
        WAIT_PACKET,
        REQUEST_LOCKS,
        EXECUTE_READ,
        CHECK_ECR,
        COMMIT_WRITE
    } state_t;

    state_t state;
    sic_packet_t pkt;

    logic zero_val;

    // Abort：依赖的 ECR 为 10 时，丢弃当前指令
    logic abort_mispredict;

    // 指令资源需求（用于请求/释放资源）
    logic need_reg_read0, need_reg_read1, need_reg_write2;
    logic need_alu;

    // REQUEST_LOCKS 阶段的 grant 聚合
    logic all_granted;

    // 资源释放脉冲
    logic alu_release_pulse;

    // Reg 写回数据保持
    logic [31:0] reg_wdata_dst;
    alu_req_t alu_req;
    sic_packet_t pkt_v;

    // 组合逻辑计算锁请求
    always_comb begin
        out                      = '0;

        // WAIT_PACKET 拍使用 packet_in 视图，其余拍使用已锁存的 pkt
        pkt_v                    = ((state == WAIT_PACKET) && packet_in.valid) ? packet_in : pkt;

        // 资源需求（由 decoder 给出）
        need_reg_read0           = pkt_v.info.read_rs;
        need_reg_read1           = pkt_v.info.read_rt;
        need_reg_write2          = pkt_v.info.write_gpr;
        need_alu                 = pkt_v.info.use_alu;

        // ECR read: dep_ecr_id 编码为 {valid,id}
        out.ecr_read_addr        = pkt.dep_ecr_id[0];
        out.ecr_read_en          = (state != WAIT_PACKET) && pkt.dep_ecr_id[1];
        abort_mispredict         = out.ecr_read_en && (in.ecr_read_data == 2'b10);

        // req instr
        out.req_instr            = (state == WAIT_PACKET && !packet_in.valid);

        // ALU lock + request
        out.alu_rpl.req_issue_id = pkt.issue_id;
        out.alu_rpl.release_lock = alu_release_pulse;
        if (state == REQUEST_LOCKS || state == EXECUTE_READ || state == CHECK_ECR || state == COMMIT_WRITE) begin
            out.alu_rpl.req = need_alu;
        end
        out.alu_req = alu_req;

        // 外部资源请求策略：
        // - ALU：持有直到提交（COMMIT_WRITE）/丢弃（abort）
        // RF commit (WB_ALU only; addresses are driven by top-level)
        out.reg_req = '0;
        out.reg_req.wdata = reg_wdata_dst;
        if (state == COMMIT_WRITE && need_reg_write2 && (pkt_v.info.wb_sel == WB_ALU)) begin
            out.reg_req.wcommit = !abort_mispredict;
        end

        // ECR write from regs
        out.ecr_wen        = ecr_wen;
        out.ecr_write_addr = ecr_write_addr;
        out.ecr_wdata      = ecr_wdata;
    end

    // 聚合 grant（避免在 always_ff 内部声明 all_granted 变量）
    always_comb begin
        all_granted = 1;
        if (state == REQUEST_LOCKS) begin
            if (need_reg_read0 && !reg_ans.rs_valid) all_granted = 0;
            if (need_reg_read1 && !reg_ans.rt_valid) all_granted = 0;
            if (need_alu && !in.alu_grant) all_granted = 0;
        end
    end

    // 状态机逻辑
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= WAIT_PACKET;
            alu_release_pulse <= 0;
            ecr_wen <= 0;
            reg_wdata_dst <= 32'b0;
            alu_req <= '0;
        end else begin
            // 默认清除单周期脉冲
            alu_release_pulse <= 0;
            ecr_wen           <= 0;

            // 若依赖 ECR 已为 Incorrect，则丢弃当前指令
            if (abort_mispredict) begin
                if (need_alu) alu_release_pulse <= 1;
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
                        // 准备操作数/请求
                        if (need_alu) begin
                            alu_req.op <= pkt.info.alu_op;
                            alu_req.a <= reg_ans.rs_rdata;
                            alu_req.b  <= pkt.info.alu_b_is_imm
                                         ? (pkt.info.alu_imm_is_zero_ext ? pkt.info.imm16_zero_ext
                                                                         : pkt.info.imm16_sign_ext)
                                         : reg_ans.rt_rdata;
                        end
                        // 单周期进入下一阶段
                        state <= CHECK_ECR;
                    end

                    CHECK_ECR: begin
                        // 约定：00=Busy, 01=Correct, 10=Incorrect
                        if (!pkt.dep_ecr_id[1]) begin
                            reg_wdata_dst <= in.alu_ans.c;
                            zero_val      <= in.alu_ans.zero;
                            state         <= COMMIT_WRITE;
                        end else if (in.ecr_read_data == 2'b10) begin
                            if (need_alu) alu_release_pulse <= 1;
                            state <= WAIT_PACKET;
                        end else if (in.ecr_read_data == 2'b01) begin
                            reg_wdata_dst <= in.alu_ans.c;
                            zero_val      <= in.alu_ans.zero;
                            state         <= COMMIT_WRITE;
                        end
                        // 00: Busy，保持等待
                    end

                    COMMIT_WRITE: begin
                        // 提交点：写回/更新 ECR

                        if (pkt.info.write_ecr) begin
                            // 更新 ECR
                            ecr_wen <= 1;
                            ecr_write_addr <= pkt.set_ecr_id[$clog2(2)-1:0];
                            ecr_wdata <= (zero_val == pkt.pred_taken) ? 2'b01 : 2'b10;
                        end

                        if (need_alu) alu_release_pulse <= 1;
                        state <= WAIT_PACKET;
                    end
                endcase
        end
    end

endmodule


