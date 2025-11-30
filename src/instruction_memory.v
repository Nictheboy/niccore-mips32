/* 
 *  Description : A simple read-only instruction memory.
 *  Author      : nictheboy <nictheboy@outlook.com>
 *  Create Date : 2025/11/30
 * 
 */

module instruction_memory (
    input reset,
    input clock,
    input [31:2] address,
    output [31:0] instruction
);
    localparam START_BYTE_ADDR = 32'h00003000;
    localparam START_WORD_ADDR = START_BYTE_ADDR[31:2];

    reg [31:0] instructions[1023:0];
    assign instruction = instructions[address-START_WORD_ADDR];

    initial begin
        $readmemh("/home/nictheboy/Documents/niccore-mips32/test/mips1.txt", instructions);
    end

    always @(posedge clock) begin
        // do nothing
    end
endmodule
