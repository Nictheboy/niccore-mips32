`include "structs.svh"

module sic_exec_muldiv #(
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
    typedef sic_packet#(NUM_PHY_REGS, ID_WIDTH, NUM_ECRS)::t sic_packet_t;
    sic_packet_t packet_in;
    reg_ans_t reg_ans;
    assign packet_in = in.pkt;
    assign reg_ans   = in.reg_ans;

    logic busy;
    sic_packet_t pkt;

    logic abort_mispredict;
    logic rf_ok;
    logic ecr_ok;
    logic commit_now;
    logic start_pulse;
    logic started;
    logic release_pulse;

    always_comb begin
        out = '0;

        rf_ok = (!pkt.info.read_rs || reg_ans.rs_valid) && (!pkt.info.read_rt || reg_ans.rt_valid);
        ecr_ok = (in.ecr_read_data == 2'b01);
        abort_mispredict = busy && (in.ecr_read_data == 2'b10);

        out.req_instr = !busy && !packet_in.valid;

        out.muldiv_rpl.req_issue_id = pkt.issue_id;
        out.muldiv_rpl.req = busy && pkt.info.use_muldiv && !abort_mispredict;
        out.muldiv_rpl.release_lock = release_pulse;

        start_pulse = busy && pkt.info.use_muldiv && pkt.info.muldiv_start && !started &&
                      in.muldiv_grant && !in.muldiv_ans.busy && rf_ok && ecr_ok && !abort_mispredict;

        out.muldiv_req.op1 = reg_ans.rs_rdata;
        out.muldiv_req.op2 = reg_ans.rt_rdata;
        out.muldiv_req.op = pkt.info.muldiv_op;
        out.muldiv_req.start = start_pulse;

        if (pkt.info.muldiv_start) begin
            commit_now = busy && started && !in.muldiv_ans.busy && in.muldiv_grant && rf_ok && ecr_ok &&
                         !abort_mispredict;
        end else begin
            commit_now = busy && in.muldiv_grant && !in.muldiv_ans.busy && rf_ok && ecr_ok && !abort_mispredict;
        end

        out.reg_req.wdata   = in.muldiv_ans.data;
        out.reg_req.wcommit = commit_now && pkt.info.write_gpr;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            pkt <= '0;
            started <= 1'b0;
            release_pulse <= 1'b0;
        end else begin
            release_pulse <= 1'b0;
            if (!busy) begin
                if (packet_in.valid) begin
                    pkt <= packet_in;
                    busy <= 1'b1;
                    started <= 1'b0;
                end
            end else begin
                if (abort_mispredict || commit_now) begin
                    release_pulse <= 1'b1;
                end
                if (abort_mispredict || commit_now) begin
                    busy <= 1'b0;
                    started <= 1'b0;
                end else if (start_pulse) begin
                    started <= 1'b1;
                end
            end
        end
    end
endmodule


