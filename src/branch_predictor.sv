module branch_predictor #(
    parameter int TABLE_SIZE
) (
    input logic clk,
    input logic rst_n,

    // 预测接口
    input  logic [31:0] query_pc,
    output logic        pred_taken,

    // 更新接口 (来自 SIC 执行结果)
    input logic        update_en,
    input logic [31:0] update_pc,
    input logic        actual_taken
);

    // 2-bit 饱和计数器表 (00,01: Not Taken; 10,11: Taken)
    logic [1:0] bht[TABLE_SIZE];
    logic [$clog2(TABLE_SIZE)-1:0] query_idx, update_idx;

    assign query_idx  = query_pc[$clog2(TABLE_SIZE)+1:2];
    assign update_idx = update_pc[$clog2(TABLE_SIZE)+1:2];

    assign pred_taken = bht[query_idx][1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < TABLE_SIZE; i++) bht[i] <= 2'b01;  // Weakly Not Taken
        end else if (update_en) begin
            case (bht[update_idx])
                2'b00: bht[update_idx] <= actual_taken ? 2'b01 : 2'b00;
                2'b01: bht[update_idx] <= actual_taken ? 2'b10 : 2'b00;
                2'b10: bht[update_idx] <= actual_taken ? 2'b11 : 2'b01;
                2'b11: bht[update_idx] <= actual_taken ? 2'b11 : 2'b10;
            endcase
        end
    end
endmodule
