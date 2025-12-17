/*
 * Description :
 *
 * 数据内存顶层包装 (Data Memory Wrapper).
 *
 * 修改记录:
 * 1. 不再内部实现存储数组，改为实例化单端口 data_memory 模块。
 * 2. 锁机制替换为 resource_pool_lock。
 * 3. 由于 data_memory 是单端口的，因此资源池大小 (NUM_RESOURCES) 设为 1。
 * 这意味着同一时刻只有一个 SIC 能访问内存（严格串行化）。
 *
 * Author      : nictheboy
 * Date        : 2025/12/16
 *
 */

`include "structs.svh"

module data_memory_with_lock #(
    parameter int MEM_DEPTH,
    parameter int NUM_PORTS,
    parameter int ID_WIDTH
) (
    input logic clk,
    input logic rst_n,

    // 输入仅保留：资源池锁请求 + 内存请求包
    input rpl_req#(ID_WIDTH)::t rpl_req[NUM_PORTS],
    input mem_req_t             mem_req[NUM_PORTS],

    // === 输出 ===
    output logic [31:0] rdata[NUM_PORTS],
    output logic        grant[NUM_PORTS]
);

    // ============================================================
    // 1. 锁信号与请求聚合
    // ============================================================
    logic       pool_busy;  // 调试用

    // alloc_id 在只有 1 个资源时其实没用 (总是0)，但为了匹配端口定义需要声明
    // clog2(1) = 0, 所以这里定义为 [0:0] 1bit 宽是安全的
    logic [0:0] alloc_id                [NUM_PORTS];

    // 实例化资源池锁 (NUM_RESOURCES = 1)
    resource_pool_lock #(
        .NUM_RESOURCES(1),          // 关键：只有一个内存实例
        .NUM_PORTS    (NUM_PORTS),
        .ID_WIDTH     (ID_WIDTH)
    ) mem_lock (
        .clk      (clk),
        .rst_n    (rst_n),
        .rpl_in   (rpl_req),
        .grant    (grant),
        .alloc_id (alloc_id),  // 忽略，因为肯定分配的是资源 0
        .pool_busy(pool_busy)
    );

    // ============================================================
    // 2. 输入多路选择 (Mux: SIC -> Data Memory)
    // ============================================================
    // 单端口内存的输入信号
    mem_req_t mem_req_in;
    logic [31:0] mem_rdata_out;

    always_comb begin
        // 默认值
        mem_req_in = '0;

        // 遍历端口，找到获得 Grant 的那个 SIC
        for (int i = 0; i < NUM_PORTS; i++) begin
            if (grant[i]) begin
                // 选择该端口的内存请求
                mem_req_in = mem_req[i];
            end
        end
    end

    // ============================================================
    // 3. 实例化现有内存模块
    // ============================================================
    data_memory #(
        .MEM_DEPTH(MEM_DEPTH)
    ) mem_core (
        .reset      (~rst_n),        // 假设 data_memory reset 是高电平有效
        .clock      (clk),
        .mem_req    (mem_req_in),
        .read_result(mem_rdata_out)
    );

    // ============================================================
    // 4. 输出分发 (Demux: Data Memory -> SIC)
    // ============================================================
    always_comb begin
        for (int i = 0; i < NUM_PORTS; i++) begin
            rdata[i] = 32'b0;  // 默认数据

            // 只要该端口获得授权且本次是读（wen=0），就输出数据
            if (grant[i] && !mem_req[i].wen) begin
                rdata[i] = mem_rdata_out;
            end
        end
    end

endmodule
