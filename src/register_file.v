/* 
 *  Description : MIPS-32 register file.
 *  Author      : nictheboy <nictheboy@outlook.com>
 *  Create Date : 2025/11/30
 * 
 */

module register_file (
    input reset,
    input clock,
    input [4:0] rs,
    input [4:0] rt,
    input [4:0] rd,
    input [31:0] write_data,
    input write_enable,
    output [31:0] rs_data,
    output [31:0] rt_data
);
    reg [31:0] registers[31:0];
    integer i;
    always @(negedge clock) begin
        if (reset) begin
            for (i = 0; i < 32; i = i + 1) begin
                registers[i] <= 32'b0;
            end
        end else if (write_enable) begin
            registers[rd] <= write_data;
        end
    end
    assign rs_data = registers[rs];
    assign rt_data = registers[rt];
endmodule
