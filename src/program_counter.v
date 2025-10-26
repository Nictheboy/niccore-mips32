/* 
 *  Description : MIPS Program Counter.
 *  Author      : nictheboy <nictheboy@outlook.com>
 *  Create Date : 2025/10/26
 * 
 */

module program_counter (
    input reset,
    input clock,
    input jump_enable,
    input [31:2] jump_input,
    output reg [31:2] pc_value
);
    localparam RESET_ADDR = 32'h00003000;
    always @(posedge clock) begin
        if (reset) pc_value <= RESET_ADDR[31:2];
        else if (jump_enable) pc_value <= jump_input;
        else pc_value <= pc_value + 1;
    end
endmodule
