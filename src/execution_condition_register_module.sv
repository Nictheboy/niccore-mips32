/*
 * Description :
 *
 * ECR 组模块 (ECR Module / ECR File).
 *
 * 这是一个容器模块，实例化了 NUM_ECRS 个 execution_condition_register。
 * 它负责处理 SIC (单指令控制器) 与 ECR 之间的互联矩阵。
 *
 * 主要功能:
 * 1. 信号转置 (Signal Transposition):
 * SIC 输出的信号格式通常是 sic_signal[SIC_ID][ECR_ID]。
 * 而单个 ECR 模块期望的输入是 ecr_input[SIC_ID]。
 * 本模块在内部处理这种维度变换，简化顶层连线。
 *
 * 2. 广播数据 (Broadcast Data):
 * 将单个 ECR 的状态值复制分发给所有连接的 SIC。
 *
 * Author      : nictheboy
 * Create Date : 2025/12/15
 *
 */

module execution_condition_register_module #(
    parameter int NUM_ECRS,
    parameter int NUM_SICS,
    parameter int ID_WIDTH
) (
    input logic clk,
    input logic rst_n,

    // === SIC 接口 (SIC-Major 维度) ===
    // 所有的输入输出都是二维数组: [SIC_INDEX][ECR_INDEX]
    // 这样顶层模块可以直接连接 SIC 的端口，无需手动切片

    input logic                sic_req_read [NUM_SICS][NUM_ECRS],
    input logic                sic_req_write[NUM_SICS][NUM_ECRS],
    input logic [ID_WIDTH-1:0] sic_issue_id [NUM_SICS][NUM_ECRS],
    input logic                sic_release  [NUM_SICS][NUM_ECRS],
    input logic [         1:0] sic_wdata    [NUM_SICS][NUM_ECRS],

    // 输出
    output logic [1:0] sic_rdata_out[NUM_SICS][NUM_ECRS],
    output logic       sic_grant_out[NUM_SICS][NUM_ECRS],

    // === 监控接口 (供 Issue Controller 使用) ===
    // 输出所有 ECR 的当前状态 [ECR_INDEX]
    output logic [1:0] monitor_states[NUM_ECRS]
);

    // =========================================================================
    // 内部信号定义 (ECR-Major 维度)
    // 用于连接到具体的 execution_condition_register 实例
    // =========================================================================
    logic                trans_req_read [NUM_ECRS]                                [NUM_SICS];
    logic                trans_req_write[NUM_ECRS]                                [NUM_SICS];
    logic [ID_WIDTH-1:0] trans_issue_id [NUM_ECRS]                                [NUM_SICS];
    logic                trans_release  [NUM_ECRS]                                [NUM_SICS];
    logic [         1:0] trans_wdata    [NUM_ECRS]                                [NUM_SICS];

    logic [         1:0] ecr_raw_rdata  [NUM_ECRS];  // 每个 ECR 的原始输出
    logic                trans_grant    [NUM_ECRS]                                [NUM_SICS];

    // =========================================================================
    // 1. 输入信号转置 (SIC -> ECR)
    // =========================================================================
    always_comb begin
        for (int e = 0; e < NUM_ECRS; e++) begin
            for (int s = 0; s < NUM_SICS; s++) begin
                trans_req_read[e][s]  = sic_req_read[s][e];
                trans_req_write[e][s] = sic_req_write[s][e];
                trans_issue_id[e][s]  = sic_issue_id[s][e];
                trans_release[e][s]   = sic_release[s][e];
                trans_wdata[e][s]     = sic_wdata[s][e];
            end
        end
    end

    // =========================================================================
    // 2. 实例化 ECRs
    // =========================================================================
    genvar i;
    generate
        for (i = 0; i < NUM_ECRS; i++) begin : ecr_units
            execution_condition_register #(
                .NUM_PORTS(NUM_SICS),
                .ID_WIDTH (ID_WIDTH)
            ) ecr_core (
                .clk         (clk),
                .rst_n       (rst_n),
                .req_read    (trans_req_read[i]),
                .req_write   (trans_req_write[i]),
                .req_issue_id(trans_issue_id[i]),
                .release_lock(trans_release[i]),
                .wdata       (trans_wdata[i]),

                // 输出
                .rdata(ecr_raw_rdata[i]),
                .grant(trans_grant[i])
            );
        end
    endgenerate

    // =========================================================================
    // 3. 输出信号转置与广播 (ECR -> SIC)
    // =========================================================================
    always_comb begin
        for (int s = 0; s < NUM_SICS; s++) begin
            for (int e = 0; e < NUM_ECRS; e++) begin
                // Grant 信号转置回 SIC 维度
                sic_grant_out[s][e] = trans_grant[e][s];

                // Rdata 广播：虽然 ECR 只输出一个 2bit 值，
                // 但为了方便 SIC 连接，我们将其复制到每个 SIC 接口上。
                sic_rdata_out[s][e] = ecr_raw_rdata[e];
            end
        end

        // 监控信号直接输出
        for (int e = 0; e < NUM_ECRS; e++) begin
            monitor_states[e] = ecr_raw_rdata[e];
        end
    end

endmodule
