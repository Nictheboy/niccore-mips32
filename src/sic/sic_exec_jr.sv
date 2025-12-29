/*
 * Description :
 *
 * JR 子 SIC（ready-bit 风格）。
 *
 * - 等待 RS 就绪与 dep_ecr (若有效) 就绪后，在同拍发出 pc_redirect_* 脉冲。
 * - ECR==10 则丢弃。
 * - `req_instr` 必须在 `packet_in.valid==1` 的周期保持为 0，避免 issue 连发导致丢包。
 */

`include "structs.svh"

module sic_exec_jr #(
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

    localparam int ECR_W = (NUM_ECRS > 1) ? $clog2(NUM_ECRS) : 1;
    typedef sic_packet#(NUM_PHY_REGS, ID_WIDTH, NUM_ECRS)::t sic_packet_t;

    sic_packet_t packet_in;
    reg_ans_t    reg_ans;

    assign packet_in = in.pkt;
    assign reg_ans   = in.reg_ans;

    logic busy;
    sic_packet_t pkt;

    logic abort_mispredict;
    logic rf_ok;
    logic ecr_ok;
    logic commit_now;

    always_comb begin
        out                      = '0;

        rf_ok                    = (!pkt.info.read_rs) || reg_ans.rs_valid;
        ecr_ok                   = (in.ecr_read_data == 2'b01);

        abort_mispredict         = busy && (in.ecr_read_data == 2'b10);

        out.req_instr            = !busy && !packet_in.valid;

        commit_now               = busy && rf_ok && ecr_ok && !abort_mispredict;

        out.pc_redirect_valid    = commit_now && (pkt.info.cf_kind == CF_JUMP_REG);
        out.pc_redirect_pc       = reg_ans.rs_rdata;
        out.pc_redirect_issue_id = pkt.issue_id;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            pkt  <= '0;
        end else begin
            if (!busy) begin
                if (packet_in.valid) begin
                    pkt  <= packet_in;
                    busy <= 1'b1;
                end
            end else begin
                if (abort_mispredict || commit_now) begin
                    busy <= 1'b0;
                end
            end
        end
    end

endmodule


