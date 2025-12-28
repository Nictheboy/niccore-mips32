/* 
 *  Description : MIPS alu_req.aLU.
 *  alu_req.author      : nictheboy <nictheboy@outlook.com>
 *  Create Date : 2025/10/11 
 * 
 */

`include "structs.svh"

module sra_unit (
    input [4:0] A,
    input signed [31:0] B,
    output signed [31:0] C
);
    assign C = B >>> A;
endmodule

module alu (
    input  alu_req_t alu_req,
    output alu_ans_t alu_ans
);
    wire [31:0] addu_r;
    wire addu_adder_c;
    adder adder_1 (
        alu_req.a,
        alu_req.b,
        addu_r,
        addu_adder_c
    );

    wire [31:0] add_r;
    wire add_c;
    assign add_r = addu_r;
    assign add_c = (alu_req.a[31] & alu_req.b[31] & ~addu_r[31]) | (~alu_req.a[31] & ~alu_req.b[31] & addu_r[31]);

    wire [31:0] subu_r;
    wire [31:0] neg_b_r;
    wire neg_b_adder_c;
    adder adder_2 (
        ~alu_req.b,
        32'b1,
        neg_b_r,
        neg_b_adder_c
    );
    wire subu_adder_c;
    adder adder_3 (
        alu_req.a,
        neg_b_r,
        subu_r,
        subu_adder_c
    );

    wire [31:0] sub_r;
    wire sub_c;
    assign sub_r = subu_r;
    assign sub_c = (alu_req.a[31] & neg_b_r[31] & ~(neg_b_r == 32'h80000000) & ~subu_r[31])
                   | (~alu_req.a[31] & ~neg_b_r[31] & subu_r[31])
                   | ((neg_b_r == 32'h80000000 ) & ~alu_req.a[31]);

    wire [31:0] sll_r;
    assign sll_r = alu_req.b << alu_req.a[4:0];

    wire [31:0] srl_r;
    assign srl_r = alu_req.b >> alu_req.a[4:0];

    wire [31:0] sra_r;
    sra_unit sra_unit_1 (
        alu_req.a[4:0],
        alu_req.b,
        sra_r
    );

    wire [31:0] and_r;
    assign and_r = alu_req.a & alu_req.b;

    wire [31:0] or_r;
    assign or_r = alu_req.a | alu_req.b;

    wire [31:0] xor_r;
    assign xor_r = alu_req.a ^ alu_req.b;

    wire [31:0] nor_r;
    assign nor_r = ~(alu_req.a | alu_req.b);

    wire [31:0] slt_r;
    assign slt_r = ($signed(alu_req.a) < $signed(alu_req.b)) ? 32'd1 : 32'd0;

    assign alu_ans.c = (alu_req.op == 6'b100000) ? add_r :
                       (alu_req.op == 6'b100001) ? addu_r :
                       (alu_req.op == 6'b100010) ? sub_r :
                       (alu_req.op == 6'b100011) ? subu_r :
                       (alu_req.op == 6'b000000) ? sll_r :
                       (alu_req.op == 6'b000010) ? srl_r :
                       (alu_req.op == 6'b000011) ? sra_r :
                       (alu_req.op == 6'b100100) ? and_r :
                       (alu_req.op == 6'b100101) ? or_r :
                       (alu_req.op == 6'b100110) ? xor_r :
                       (alu_req.op == 6'b100111) ? nor_r :
                       (alu_req.op == 6'b101010) ? slt_r :
                       32'b0 ;
    assign alu_ans.over = (alu_req.op == 6'b100000) ? add_c : (alu_req.op == 6'b100010) ? sub_c : 0;
    assign alu_ans.zero = (alu_ans.c == 32'b0);
endmodule
