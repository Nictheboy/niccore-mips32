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
    localparam UNIT_COUNT = 2048;
    localparam VALID_ADDRESS_WIDTH = 11;

    reg [31:0] data[UNIT_COUNT-1 : 0];
    wire [VALID_ADDRESS_WIDTH-1 : 0] valid_address = address[VALID_ADDRESS_WIDTH+2-1 : 2];
    wire address_is_valid = (address == {{(30 - VALID_ADDRESS_WIDTH) {1'b0}}, valid_address});

    always @(*) begin
        if (address_is_valid) begin
            read_result = data[valid_address];
        end else begin
            read_result = 32'hxxxxxxxx;
        end
    end

    integer i;
    always @(negedge clock) begin
        if (reset) begin
            for (i = 0; i < UNIT_COUNT; i = i + 1) begin
                data[i] <= 32'h00000000;
            end
        end else if (write_enable && address_is_valid) begin
            data[valid_address] <= write_input;
        end
    end

endmodule
