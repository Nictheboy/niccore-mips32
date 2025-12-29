`include "structs.svh"

module muldiv_array_with_lock #(
    parameter int NUM_MDUS,
    parameter int NUM_PORTS,
    parameter int ID_WIDTH  = 16
) (
    input logic clk,
    input logic rst_n,

    input rpl_req#(ID_WIDTH)::t sic_rpl[NUM_PORTS],
    input muldiv_req_t          sic_req[NUM_PORTS],

    output muldiv_ans_t sic_ans      [NUM_PORTS],
    output logic        sic_grant_out[NUM_PORTS]
);
    localparam int IDX_W = (NUM_MDUS > 1) ? $clog2(NUM_MDUS) : 1;
    logic [IDX_W-1:0] allocated_idx[NUM_PORTS];
    logic pool_busy;

    muldiv_req_t in[NUM_MDUS];
    muldiv_ans_t out[NUM_MDUS];

    resource_pool_lock #(
        .NUM_RESOURCES(NUM_MDUS),
        .NUM_PORTS    (NUM_PORTS),
        .ID_WIDTH     (ID_WIDTH)
    ) pool_lock (
        .clk      (clk),
        .rst_n    (rst_n),
        .rpl_in   (sic_rpl),
        .grant    (sic_grant_out),
        .alloc_id (allocated_idx),
        .pool_busy(pool_busy)
    );

    always_comb begin
        for (int k = 0; k < NUM_MDUS; k++) begin
            in[k] = '0;
        end
        for (int p = 0; p < NUM_PORTS; p++) begin
            if (sic_grant_out[p]) begin
                in[allocated_idx[p]] = sic_req[p];
            end
        end
    end

    genvar k;
    generate
        for (k = 0; k < NUM_MDUS; k++) begin : mdus
            MultiplicationDivisionUnit u (
                .reset    (~rst_n),
                .clock    (clk),
                .operand1 (in[k].op1),
                .operand2 (in[k].op2),
                .operation(mdu_operation_t'(in[k].op)),
                .start    (in[k].start),
                .busy     (out[k].busy),
                .dataRead (out[k].data)
            );
        end
    endgenerate

    always_comb begin
        for (int p = 0; p < NUM_PORTS; p++) begin
            sic_ans[p] = '0;
            if (sic_grant_out[p]) begin
                sic_ans[p] = out[allocated_idx[p]];
            end
        end
    end
endmodule


