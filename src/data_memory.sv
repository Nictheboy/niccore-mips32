/* * Description : Data Memory (Parameterized).
 * Author      : nictheboy <nictheboy@outlook.com>
 * Create Date : 2025/10/26
 * Modified    : Parameterized version
 */

`include "structs.svh"

module data_memory #(
    parameter MEM_DEPTH
) (
    input reset,
    input clock,
    input mem_req_t mem_req,
    output reg [31:0] read_result
);
    // 自动计算所需的地址线位宽 (例如 2048 -> 11)
    localparam VALID_ADDRESS_WIDTH = $clog2(MEM_DEPTH);

    reg [31:0] data[MEM_DEPTH-1 : 0];  // 数组大小改为参数控制

    // 地址计算逻辑微调：[VALID_ADDRESS_WIDTH+2-1 : 2] 等价于 [VALID_ADDRESS_WIDTH+1 : 2]
    wire [VALID_ADDRESS_WIDTH-1 : 0] valid_address = mem_req.addr[VALID_ADDRESS_WIDTH+1 : 2];

    // 验证逻辑保持不变：检查除去有效位之外的高位是否全为0
    // 输入地址是 [31:2]，共 30 bit。
    wire address_is_valid = (mem_req.addr == {{(30 - VALID_ADDRESS_WIDTH) {1'b0}}, valid_address});

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
            for (i = 0; i < MEM_DEPTH; i = i + 1) begin  // 循环上限改为参数
                data[i] <= 32'h00000000;
            end
        end else if (mem_req.wen && address_is_valid) begin
            data[valid_address] <= mem_req.wdata;
        end
    end

endmodule
