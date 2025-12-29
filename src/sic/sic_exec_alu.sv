`include "structs.svh"

module sic_exec_alu #(
    parameter int SIC_ID,
    parameter int NUM_PHY_REGS,
    parameter int NUM_ECRS,
    parameter int ID_WIDTH
) (
    input logic clk,
    input logic rst_n,
    input sic_sub_in#(NUM_PHY_REGS, ID_WIDTH, NUM_ECRS)::t in,
    output sic_sub_out#(NUM_PHY_REGS, ID_WIDTH, NUM_ECRS)::t out
);

    // --- 本地别名：仅保留高频使用项 ---
    localparam int ECR_W = (NUM_ECRS > 1) ? $clog2(NUM_ECRS) : 1;
    typedef sic_packet#(NUM_PHY_REGS, ID_WIDTH, NUM_ECRS)::t sic_packet_t;
    sic_packet_t packet_in;
    reg_ans_t    reg_ans;

    assign packet_in = in.pkt;
    assign reg_ans   = in.reg_ans;

    // “ready-bit”风格：用少量寄存器描述执行进度
    logic        busy;  // 已锁存 pkt，指令在飞
    sic_packet_t pkt;

    logic        abort_mispredict;
    logic        alu_release_pulse;
    logic        rf_ok;
    logic        ecr_ok;
    logic        commit_now;
    logic        need_alu;
    logic        br_taken;

    // 组合逻辑计算锁请求
    always_comb begin
        out = '0;

        need_alu = pkt.info.use_alu;
        rf_ok = (!pkt.info.read_rs || reg_ans.rs_valid) && (!pkt.info.read_rt || reg_ans.rt_valid);
        ecr_ok = (in.ecr_read_data == 2'b01);

        abort_mispredict = busy && (in.ecr_read_data == 2'b10);

        // req instr：必须把 packet_in.valid 也考虑进去，避免 issue 连发导致丢包
        out.req_instr = !busy && !packet_in.valid;

        // ALU lock
        out.alu_rpl.req_issue_id = pkt.issue_id;
        out.alu_rpl.req = busy && need_alu && !abort_mispredict;
        out.alu_rpl.release_lock = alu_release_pulse;

        // ALU request（组合生成；只有 grant=1 时 sic_alu_ans 才有效）
        out.alu_req.op = pkt.info.alu_op;
        out.alu_req.a = reg_ans.rs_rdata;
        out.alu_req.b  = pkt.info.alu_b_is_imm
                         ? (pkt.info.alu_imm_is_zero_ext ? pkt.info.imm16_zero_ext
                                                         : pkt.info.imm16_sign_ext)
                         : reg_ans.rt_rdata;

        commit_now = busy && rf_ok && ecr_ok && (!need_alu || in.alu_grant) && !abort_mispredict;

        // RF commit (WB_ALU)
        out.reg_req = '0;
        out.reg_req.wdata = in.alu_ans.c;
        out.reg_req.wcommit = commit_now && pkt.info.write_gpr && (pkt.info.wb_sel == WB_ALU);

        // ECR write (BEQ)
        out.ecr_wen = commit_now && pkt.info.write_ecr;
        out.ecr_write_addr = pkt.set_ecr_id;
        br_taken = (pkt.info.opcode == OPC_BNE) ? ~in.alu_ans.zero : in.alu_ans.zero;
        out.ecr_wdata = (br_taken == pkt.pred_taken) ? 2'b01 : 2'b10;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            pkt <= '0;
            alu_release_pulse <= 1'b0;
        end else begin
            alu_release_pulse <= 1'b0;

            if (!busy) begin
                if (packet_in.valid) begin
                    pkt  <= packet_in;
                    busy <= 1'b1;
                end
            end else begin
                if (abort_mispredict || commit_now) begin
                    if (need_alu) alu_release_pulse <= 1'b1;
                    busy <= 1'b0;
                end
            end
        end
    end

endmodule


