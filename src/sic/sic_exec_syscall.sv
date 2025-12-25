/*
 * Description :
 *
 * SYSCALL 子 SIC（ready-bit 风格）。
 *
 * - 等待 dep_ecr (若有效) 就绪后，在提交点触发 $finish（仅仿真）。
 * - ECR==10 则丢弃（不触发 $finish）。
 * - `req_instr` 必须在 `packet_in.valid==1` 的周期保持为 0，避免 issue 连发导致丢包。
 */

`include "structs.svh"

module sic_exec_syscall #(
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
    assign packet_in = in.pkt;

    logic busy;
    sic_packet_t pkt;

    logic abort_mispredict;
    logic ecr_ok;
    logic commit_now;

    always_comb begin
        out = '0;

        ecr_ok = (!pkt.dep_ecr_id[ECR_W]) || (in.ecr_read_data == 2'b01);

        out.ecr_read_addr = pkt.dep_ecr_id[ECR_W-1:0];
        out.ecr_read_en = busy && pkt.dep_ecr_id[ECR_W];
        abort_mispredict = out.ecr_read_en && (in.ecr_read_data == 2'b10);

        out.req_instr = !busy && !packet_in.valid;

        commit_now = busy && ecr_ok && !abort_mispredict;
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
                if (abort_mispredict) begin
                    busy <= 1'b0;
                end else if (commit_now) begin
`ifndef SYNTHESIS
                    $display("[SIC%0d] SYSCALL at PC=%h, finishing simulation.", SIC_ID, pkt.pc);
                    $finish;
`endif
                    busy <= 1'b0;
                end
            end
        end
    end

endmodule


