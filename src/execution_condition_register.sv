/*
 * Description :
 *
 * 执行条件寄存器 (Execution Condition Register, ECR).
 *
 * 存储分支指令的预测验证结果。
 * 状态: 00=Undefined, 01=Correct, 10=Incorrect.
 * 使用 parallel_rw_lock 进行保护。
 *
 * Author      : nictheboy
 * Create Date : 2025/12/15
 *
 */

module execution_condition_register #(
    parameter int NUM_PORTS,
    parameter int ID_WIDTH
) (
    input logic clk,
    input logic rst_n,

    input logic                req_read    [NUM_PORTS],
    input logic                req_write   [NUM_PORTS],
    input logic [ID_WIDTH-1:0] req_issue_id[NUM_PORTS],
    input logic                release_lock[NUM_PORTS],
    input logic [         1:0] wdata       [NUM_PORTS],  // 2-bit 状态

    output logic [1:0] rdata,            // 组合逻辑直接输出，供读取者判断
    output logic       grant[NUM_PORTS]
);

    logic [1:0] state_data;
    logic       lock_busy;

    // 实例化锁
    parallel_rw_lock #(
        .NUM_PORTS(NUM_PORTS),
        .ID_WIDTH (ID_WIDTH)
    ) lock_inst (
        .clk         (clk),
        .rst_n       (rst_n),
        .req_read    (req_read),
        .req_write   (req_write),
        .req_issue_id(req_issue_id),
        .release_lock(release_lock),
        .grant       (grant),
        .lock_busy   (lock_busy)
    );

    // 读输出 (Flash Read)
    assign rdata = state_data;

    // 写逻辑
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_data <= 2'b00;  // 默认 Undefined
        end else begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                if (grant[i] && req_write[i]) begin
                    state_data <= wdata[i];
                end
            end
        end
    end

endmodule
