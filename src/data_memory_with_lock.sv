/*
 * Description :
 *
 * 带全局并行读写锁的数据内存 (Data Memory with Global Parallel Lock).
 *
 * 主要功能特性：
 * 1. 全局锁机制：
 * 利用 parallel_rw_lock 对整个内存空间进行保护。
 * 支持 N 个 SIC 端口竞争访问。
 * 严格遵循 Issue ID 的顺序进行读写授权。
 *
 * 2. 读写行为：
 * - 写 (Write): 同步写入 (Clocked)，只有获得 Grant 且 req_write 为 1 时写入。
 * - 读 (Read): 组合逻辑输出 (Flash Read)，获得 Grant 时立即由多路选择器输出数据。
 *
 * Author      : nictheboy
 * Create Date : 2025/12/15
 *
 */

module data_memory_with_lock #(
    parameter int MEM_DEPTH,  // 内存大小 (Word数)
    parameter int NUM_PORTS,     // SIC 端口数
    parameter int ID_WIDTH
) (
    input logic clk,
    input logic rst_n,

    // === SIC 接口 ===
    input logic [        31:0] addr        [NUM_PORTS],  // 字节地址
    input logic                req_read    [NUM_PORTS],
    input logic                req_write   [NUM_PORTS],
    input logic [ID_WIDTH-1:0] req_issue_id[NUM_PORTS],
    input logic                release_lock[NUM_PORTS],
    input logic [        31:0] wdata       [NUM_PORTS],

    // === 输出 ===
    output logic [31:0] rdata[NUM_PORTS],
    output logic        grant[NUM_PORTS]
);

    // 内存定义 (Word Addressable for implementation simplicity)
    logic [31:0] memory[MEM_DEPTH];

    // 锁状态
    logic lock_busy;

    // 实例化并行读写锁 (全局唯一)
    parallel_rw_lock #(
        .NUM_PORTS(NUM_PORTS),
        .ID_WIDTH (ID_WIDTH)
    ) global_mem_lock (
        .clk         (clk),
        .rst_n       (rst_n),
        .req_read    (req_read),
        .req_write   (req_write),
        .req_issue_id(req_issue_id),
        .release_lock(release_lock),
        .grant       (grant),
        .lock_busy   (lock_busy)
    );

    // 内存读写逻辑
    always_ff @(posedge clk) begin
        for (int i = 0; i < NUM_PORTS; i++) begin
            // 写操作：同步
            // 注意：这里将字节地址转换为字地址 (>> 2)
            if (grant[i] && req_write[i]) begin
                memory[addr[i][31:2]] <= wdata[i];
            end
        end
    end

    // 读操作：组合逻辑 (Flash Read)
    always_comb begin
        for (int i = 0; i < NUM_PORTS; i++) begin
            rdata[i] = 'x;  // 默认无效
            if (grant[i] && req_read[i]) begin
                rdata[i] = memory[addr[i][31:2]];
            end
        end
    end

    // 初始化内存用于测试
    initial begin
        for (int k = 0; k < MEM_DEPTH; k++) memory[k] = 0;
    end

endmodule
