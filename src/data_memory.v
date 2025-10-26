/* 
 *  Description : Data Memory.
 *                It's implemented using registers for demo.
 *  Author      : nictheboy <nictheboy@outlook.com>
 *  Create Date : 2025/10/26
 * 
 */

module data_memory (
    input reset,
    input clock,
    input [31:2] address,
    input write_enable,
    input [31:0] write_input,
    output reg [31:0] read_result
);
    localparam UNIT_COUNT = 1024;
    localparam VALID_ADDRESS_WIDTH = 10;

    reg [31:0] data[UNIT_COUNT-1 : 0];
    wire [VALID_ADDRESS_WIDTH-1 : 0] valid_address = address[VALID_ADDRESS_WIDTH+2-1 : 2];
    wire address_is_valid = (address == valid_address);

    integer i;
    always @(posedge clock) begin
        if (reset) begin
            for (i = 0; i < UNIT_COUNT; i = i + 1) data[i] <= 32'h00000000;
            read_result <= 32'hxxxxxxxx;
        end else if (address_is_valid) begin
            if (write_enable) begin
                data[valid_address] <= write_input;
                read_result <= 32'hxxxxxxxx;
            end else read_result <= data[valid_address];
        end else read_result <= 32'hxxxxxxxx;
    end
endmodule
