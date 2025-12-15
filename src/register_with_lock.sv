/*
 * Description :
 * 
 * 带锁物理寄存器单元 (Physical Register with Integrated Lock)。
 * 
 * 本模块将 32 位数据存储单元与 parallel_rw_lock 仲裁器封装在一起，
 * 构成一个具有原子性访问控制的物理寄存器。
 * 
 * 主要功能特性：
 * 1. 数据存储与写控制：
 * 内部包含一个 32 位寄存器 (reg_data)。写入操作严格受控于内部锁
 * 的 Grant 信号。只有获得写授权的端口，其数据才会被写入，确保了
 * 多端口并发写入时的数权安全。
 * 
 * 2. 组合逻辑读透传：
 * 读数据通路 (rdata) 采用组合逻辑直接输出。结合锁模块的 Flash Grant
 * 特性，允许外部控制器在获得锁的瞬间立即采样数据，无需额外的
 * 时钟周期等待。
 * 
 * 3. 多端口并行接口：
 * 利用 SystemVerilog 的多维数组特性，提供参数化的 N 端口接口，
 * 直接对接上层的互联网络。
 * 
 * Author      : nictheboy <nictheboy@outlook.com>
 * Create Date : 2025/12/15
 * 
 */

module register_with_lock #(
    parameter int NUM_PORTS,
    parameter int ID_WIDTH
) (
    input logic clk,
    input logic rst_n,

    input logic                req_read    [NUM_PORTS],
    input logic                req_write   [NUM_PORTS],
    input logic [ID_WIDTH-1:0] req_issue_id[NUM_PORTS],
    input logic                release_lock[NUM_PORTS],
    input logic [        31:0] wdata       [NUM_PORTS],

    // 输出
    output logic [31:0] rdata,
    output logic        grant[NUM_PORTS]
);

    logic [31:0] reg_data;
    logic        lock_busy;

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

    // 读数据: 
    // 这里我们直接输出内部数据，"屏蔽成 X" 的操作在顶层 register_module 做，
    // 因为这里不知道是哪个具体的端口在读。
    assign rdata = reg_data;

    // 写数据
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_data <= 32'b0;
        end else begin
            for (int i = 0; i < NUM_PORTS; i++) begin
                if (grant[i] && req_write[i]) begin
                    reg_data <= wdata[i];
                end
            end
        end
    end

endmodule
