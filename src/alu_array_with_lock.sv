/*
 * Description :
 * 带资源池锁的 ALU 阵列。
 * * 机制：
 * 1. SIC 发出 req，不指定具体 ALU。
 * 2. resource_pool_lock 返回 grant 和 allocated_res_id。
 * 3. 输入 Mux: 根据锁内部状态，将获得授权的 SIC 的数据路由给对应的 ALU。
 * 4. 输出 Mux: 根据 alloc_id，将对应 ALU 的结果路由回 SIC。
 */

`include "structs.svh"

module alu_array_with_lock #(
    parameter int NUM_ALUS,
    parameter int NUM_PORTS,  // SIC 数量
    parameter int ID_WIDTH  = 16
) (
    input logic clk,
    input logic rst_n,

    // === SIC 接口 (Array) ===
    // 注意：不再需要 sic_alu_id 输入，因为是动态分配
    input rpl_req#(ID_WIDTH)::t sic_rpl[NUM_PORTS],

    // ALU 请求（打包）
    input alu_req_t sic_alu_req[NUM_PORTS],

    // === 输出 ===
    output alu_ans_t sic_alu_ans[NUM_PORTS],
    output logic sic_grant_out[NUM_PORTS]
);

    // 内部信号
    logic     [$clog2(NUM_ALUS)-1:0] allocated_alu_idx[NUM_PORTS];
    logic                            pool_busy;

    // ALU 阵列信号（打包）
    alu_req_t                        alu_in           [ NUM_ALUS];
    alu_ans_t                        alu_out          [ NUM_ALUS];

    // ============================================================
    // 1. 实例化资源池锁
    // ============================================================
    resource_pool_lock #(
        .NUM_RESOURCES(NUM_ALUS),
        .NUM_PORTS    (NUM_PORTS),
        .ID_WIDTH     (ID_WIDTH)
    ) pool_lock (
        .clk      (clk),
        .rst_n    (rst_n),
        .rpl_in   (sic_rpl),
        .grant    (sic_grant_out),
        .alloc_id (allocated_alu_idx),
        .pool_busy(pool_busy)
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
            alu_in[k] = '0;
        end

        // 遍历所有 SIC 端口，如果该端口获得了授权，且分配的是 ALU[k]，则连接数据
        for (int p = 0; p < NUM_PORTS; p++) begin
            if (sic_grant_out[p]) begin
                // 使用 allocated_alu_idx 直接定位 ALU
                alu_in[allocated_alu_idx[p]] = sic_alu_req[p];
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
                .alu_req(alu_in[k]),
                .alu_ans(alu_out[k])
            );
        end
    endgenerate

    // ============================================================
    // 4. 输出交叉开关 (ALU -> SIC)
    // 直接根据 lock 返回的 allocated_alu_idx 选择 ALU 输出
    // ============================================================
    always_comb begin
        for (int p = 0; p < NUM_PORTS; p++) begin
            sic_alu_ans[p] = '0;

            if (sic_grant_out[p]) begin
                sic_alu_ans[p] = alu_out[allocated_alu_idx[p]];
            end
        end
    end

endmodule
