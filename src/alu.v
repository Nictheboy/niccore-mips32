/* 
 *  Description : MIPS ALU.
 *  Author      : nictheboy <nictheboy@outlook.com>
 *  Create Date : 2025/10/11 
 * 
 */

module sra_unit (
    input [4:0] A,
    input signed [31:0] B,
    output signed [31:0] C
);
    assign C = B >>> A;
endmodule

module alu (
    input [31:0] A,
    input [31:0] B,
    input [5:0] Op,
    output [31:0] C,
    output Over
);
    wire [31:0] addu_r;
    wire addu_adder_c;
    adder adder_1 (
        A,
        B,
        addu_r,
        addu_adder_c
    );

    wire [31:0] add_r;
    wire add_c;
    assign add_r = addu_r;
    assign add_c = (A[31] & B[31] & ~addu_r[31]) | (~A[31] & ~B[31] & addu_r[31]);

    wire [31:0] subu_r;
    wire [31:0] neg_b_r;
    wire neg_b_adder_c;
    adder adder_2 (
        ~B,
        32'b1,
        neg_b_r,
        neg_b_adder_c
    );
    wire subu_adder_c;
    adder adder_3 (
        A,
        neg_b_r,
        subu_r,
        subu_adder_c
    );

    wire [31:0] sub_r;
    wire sub_c;
    assign sub_r = subu_r;
    assign sub_c = (A[31] & neg_b_r[31] & ~(neg_b_r == 32'h80000000) & ~subu_r[31])
                   | (~A[31] & ~neg_b_r[31] & subu_r[31])
                   | ((neg_b_r == 32'h80000000 ) & ~A[31]);

    wire [31:0] sll_r;
    assign sll_r = B << A[4:0];

    wire [31:0] srl_r;
    assign srl_r = B >> A[4:0];

    wire [31:0] sra_r;
    sra_unit sra_unit_1 (
        A,
        B,
        sra_r
    );

    wire [31:0] and_r;
    assign and_r = A & B;

    wire [31:0] or_r;
    assign or_r = A | B;

    wire [31:0] xor_r;
    assign xor_r = A ^ B;

    wire [31:0] nor_r;
    assign nor_r = ~(A | B);

    assign C = (Op == 6'b100000) ? add_r :
               (Op == 6'b100001) ? addu_r :
               (Op == 6'b100010) ? sub_r :
               (Op == 6'b100011) ? subu_r :
               (Op == 6'b000000) ? sll_r :
               (Op == 6'b000010) ? srl_r :
               (Op == 6'b000011) ? sra_r :
               (Op == 6'b100100) ? and_r :
               (Op == 6'b100101) ? or_r :
               (Op == 6'b100110) ? xor_r :
               (Op == 6'b100111) ? nor_r :
               32'b0 ;
    assign Over = (Op == 6'b100000) ? add_c : (Op == 6'b100010) ? sub_c : 0;
endmodule
