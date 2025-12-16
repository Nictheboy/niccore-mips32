/*
 * Description :
 * 带资源池锁的 ALU 阵列。
 * * 机制：
 * 1. SIC 发出 req，不指定具体 ALU。
 * 2. resource_pool_lock 返回 grant 和 allocated_res_id。
 * 3. 输入 Mux: 根据锁内部状态，将获得授权的 SIC 的数据路由给对应的 ALU。
 * 4. 输出 Mux: 根据 alloc_id，将对应 ALU 的结果路由回 SIC。
 */
module alu_array_with_lock #(
    parameter int NUM_ALUS  = 4,
    parameter int NUM_PORTS = 4,  // SIC 数量
    parameter int ID_WIDTH  = 16
) (
    input logic clk,
    input logic rst_n,

    // === SIC 接口 (Array) ===
    // 注意：不再需要 sic_alu_id 输入，因为是动态分配
    input logic                sic_req     [NUM_PORTS],
    input logic [ID_WIDTH-1:0] sic_issue_id[NUM_PORTS],
    input logic                sic_release [NUM_PORTS],

    // ALU 操作数
    input logic [31:0] sic_op_a   [NUM_PORTS],
    input logic [31:0] sic_op_b   [NUM_PORTS],
    input logic [ 5:0] sic_op_code[NUM_PORTS],

    // === 输出 ===
    output logic [31:0] sic_res_out[NUM_PORTS],
    output logic                       sic_zero_out [NUM_PORTS], // 虽然 ALU 没直接输出 Zero，这里演示根据结果生成
    output logic sic_over_out[NUM_PORTS],
    output logic sic_grant_out[NUM_PORTS]
);

    // 内部信号
    logic [$clog2(NUM_ALUS)-1:0] allocated_alu_idx[NUM_PORTS];
    logic                        pool_busy;

    // ALU 阵列信号
    logic [                31:0] alu_in_a         [ NUM_ALUS];
    logic [                31:0] alu_in_b         [ NUM_ALUS];
    logic [                 5:0] alu_in_op        [ NUM_ALUS];
    logic [                31:0] alu_out_c        [ NUM_ALUS];
    logic                        alu_out_v        [ NUM_ALUS];

    // ============================================================
    // 1. 实例化资源池锁
    // ============================================================
    resource_pool_lock #(
        .NUM_RESOURCES(NUM_ALUS),
        .NUM_PORTS    (NUM_PORTS),
        .ID_WIDTH     (ID_WIDTH)
    ) pool_lock (
        .clk         (clk),
        .rst_n       (rst_n),
        .req         (sic_req),
        .req_issue_id(sic_issue_id),
        .release_lock(sic_release),
        .grant       (sic_grant_out),
        .alloc_id    (allocated_alu_idx),
        .pool_busy   (pool_busy)
    );

    // ============================================================
    // 2. 输入交叉开关 (SIC -> ALU)
    // 需要反向查找：哪个 SIC 拿到了 ALU[k]?
    // 由于 resource_pool_lock 的 outputs 是基于 Port 的，我们需要转换视角，
    // 或者我们在 Mux 逻辑里遍历所有 Ports。
    // ============================================================
    always_comb begin
        // 默认输入清零
        for (int k = 0; k < NUM_ALUS; k++) begin
            alu_in_a[k]  = 0;
            alu_in_b[k]  = 0;
            alu_in_op[k] = 0;
        end

        // 遍历所有 SIC 端口，如果该端口获得了授权，且分配的是 ALU[k]，则连接数据
        for (int p = 0; p < NUM_PORTS; p++) begin
            if (sic_grant_out[p]) begin
                // 使用 allocated_alu_idx 直接定位 ALU
                alu_in_a[allocated_alu_idx[p]]  = sic_op_a[p];
                alu_in_b[allocated_alu_idx[p]]  = sic_op_b[p];
                alu_in_op[allocated_alu_idx[p]] = sic_op_code[p];
            end
        end
    end

    // ============================================================
    // 3. 实例化 ALU 阵列
    // ============================================================
    genvar k;
    generate
        for (k = 0; k < NUM_ALUS; k++) begin : alu_insts
            alu native_alu (
                .A   (alu_in_a[k]),
                .B   (alu_in_b[k]),
                .Op  (alu_in_op[k]),
                .C   (alu_out_c[k]),
                .Over(alu_out_v[k])
            );
        end
    endgenerate

    // ============================================================
    // 4. 输出交叉开关 (ALU -> SIC)
    // 直接根据 lock 返回的 allocated_alu_idx 选择 ALU 输出
    // ============================================================
    always_comb begin
        for (int p = 0; p < NUM_PORTS; p++) begin
            sic_res_out[p]  = 0;
            sic_over_out[p] = 0;
            sic_zero_out[p] = 0;

            if (sic_grant_out[p]) begin
                // 如果获得了锁，直接读取分配到的 ALU 的结果
                // 这里就是 Requirement 4 实现的关键：自动设置为正确信号
                // 且因为全是组合逻辑，配合 Requirement 5 实现 Flash Path
                sic_res_out[p]  = alu_out_c[allocated_alu_idx[p]];
                sic_over_out[p] = alu_out_v[allocated_alu_idx[p]];

                // 附加生成 Zero 标志
                sic_zero_out[p] = (alu_out_c[allocated_alu_idx[p]] == 0);
            end
        end
    end

endmodule
