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

module data_memory_with_lock #(
    parameter int MEM_DEPTH,
    parameter int NUM_PORTS,
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
    // 写提交：解耦“占用内存写锁”和“真正写入内存”
    // 只有 write_commit=1 的那个周期，write_enable 才会对 mem_core 生效
    input logic                write_commit[NUM_PORTS],
    input logic [        31:0] wdata       [NUM_PORTS],

    // === 输出 ===
    output logic [31:0] rdata[NUM_PORTS],
    output logic        grant[NUM_PORTS]
);

    // ============================================================
    // 1. 锁信号与请求聚合
    // ============================================================
    logic       pool_req                [NUM_PORTS];
    logic       pool_busy;  // 调试用

    // alloc_id 在只有 1 个资源时其实没用 (总是0)，但为了匹配端口定义需要声明
    // clog2(1) = 0, 所以这里定义为 [0:0] 1bit 宽是安全的
    logic [0:0] alloc_id                [NUM_PORTS];

    // 将读写请求合并为通用请求
    always_comb begin
        for (int i = 0; i < NUM_PORTS; i++) begin
            pool_req[i] = req_read[i] | req_write[i];
        end
    end

    // 实例化资源池锁 (NUM_RESOURCES = 1)
    resource_pool_lock #(
        .NUM_RESOURCES(1),          // 关键：只有一个内存实例
        .NUM_PORTS    (NUM_PORTS),
        .ID_WIDTH     (ID_WIDTH)
    ) mem_lock (
        .clk         (clk),
        .rst_n       (rst_n),
        .req         (pool_req),
        .req_issue_id(req_issue_id),
        .release_lock(release_lock),
        .grant       (grant),
        .alloc_id    (alloc_id),      // 忽略，因为肯定分配的是资源 0
        .pool_busy   (pool_busy)
    );

    // ============================================================
    // 2. 输入多路选择 (Mux: SIC -> Data Memory)
    // ============================================================
    // 单端口内存的输入信号
    logic [31:2] mem_addr_in;
    logic        mem_wen_in;
    logic [31:0] mem_wdata_in;
    logic [31:0] mem_rdata_out;

    always_comb begin
        // 默认值
        mem_addr_in  = 0;
        mem_wen_in   = 0;
        mem_wdata_in = 0;

        // 遍历端口，找到获得 Grant 的那个 SIC
        for (int i = 0; i < NUM_PORTS; i++) begin
            if (grant[i]) begin
                mem_addr_in  = addr[i][31:2];  // 转换字节地址到字地址
                // 只有提交时才真正写入（解决投机写内存的问题）
                mem_wen_in   = req_write[i] && write_commit[i];
                mem_wdata_in = wdata[i];
            end
        end
    end

    // ============================================================
    // 3. 实例化现有内存模块
    // ============================================================
    data_memory #(
        .MEM_DEPTH(MEM_DEPTH)
    ) mem_core (
        .reset       (~rst_n),        // 假设 data_memory reset 是高电平有效
        .clock       (clk),
        .address     (mem_addr_in),
        .write_enable(mem_wen_in),
        .write_input (mem_wdata_in),
        .read_result (mem_rdata_out)
    );

    // ============================================================
    // 4. 输出分发 (Demux: Data Memory -> SIC)
    // ============================================================
    always_comb begin
        for (int i = 0; i < NUM_PORTS; i++) begin
            rdata[i] = 32'b0;  // 默认数据

            // 如果该端口获得授权且是读操作，则输出数据
            if (grant[i] && req_read[i]) begin
                rdata[i] = mem_rdata_out;
            end
        end
    end

endmodule
