/*
 * Description :
 *
 * 带锁 ALU 资源阵列 (ALU Array with Integrated Locks).
 *
 * 本模块模拟了一个计算资源池。包含 M 个 ALU，N 个 SIC 端口。
 *
 * 工作机制：
 * 1. 路由 (Routing):
 * SIC 发出的请求包含目标 ALU ID (alu_id)。
 * 模块内部通过 Crossbar 将请求路由到对应的 ALU 单元。
 *
 * 2. 锁定与执行:
 * 每个 ALU 单元配备一个 mutex_lock。
 * 只有获得 Grant 的 SIC 请求会被送入 ALU 进行计算。
 *
 * 3. 组合逻辑输出:
 * ALU 本身是组合逻辑。一旦获得锁 (Grant=1)，结果立即有效。
 * 对于多周期操作(如除法)，SIC 可以保持锁直到计算完成。
 *
 * Author      : nictheboy
 * Create Date : 2025/12/15
 *
 */

module alu_array_with_lock #(
    parameter int NUM_ALUS,
    parameter int NUM_PORTS,
    parameter int ID_WIDTH
) (
    input logic clk,
    input logic rst_n,

    // === SIC 接口 ===
    // 选择哪个 ALU
    input logic [$clog2(NUM_ALUS)-1:0] sic_alu_id  [NUM_PORTS],
    // 请求信号 (不分读写，ALU 操作视为独占使用)
    input logic                        sic_req     [NUM_PORTS],
    input logic [        ID_WIDTH-1:0] sic_issue_id[NUM_PORTS],
    input logic                        sic_release [NUM_PORTS],

    // ALU 操作数
    input logic [31:0] sic_op_a   [NUM_PORTS],
    input logic [31:0] sic_op_b   [NUM_PORTS],
    input logic [ 5:0] sic_op_code[NUM_PORTS],

    // === 输出 ===
    output logic [31:0] sic_res_out  [NUM_PORTS],
    output logic        sic_zero_out [NUM_PORTS],
    output logic        sic_grant_out[NUM_PORTS]
);

    // 内部互联信号
    logic        alu_req          [NUM_ALUS] [NUM_PORTS];
    logic        alu_grant        [NUM_ALUS] [NUM_PORTS];

    // ALU 输出暂存
    logic [31:0] alu_res_internal [NUM_ALUS];
    logic        alu_zero_internal[NUM_ALUS];

    // 1. 请求分发 (Demux: SIC -> ALU)
    always_comb begin
        for (int k = 0; k < NUM_ALUS; k++) begin
            for (int s = 0; s < NUM_PORTS; s++) begin
                alu_req[k][s] = 0;
            end
        end

        for (int s = 0; s < NUM_PORTS; s++) begin
            if (sic_alu_id[s] < NUM_ALUS) begin
                alu_req[sic_alu_id[s]][s] = sic_req[s];
            end
        end
    end

    // 2. 生成 ALU + Mutex 实例
    genvar k;
    generate
        for (k = 0; k < NUM_ALUS; k++) begin : alu_slots

            logic local_release[NUM_PORTS];
            logic unit_grant   [NUM_PORTS];
            logic busy;

            // 本地释放信号生成
            always_comb begin
                for (int s = 0; s < NUM_PORTS; s++) begin
                    local_release[s] = sic_release[s] && (sic_alu_id[s] == k);
                end
            end

            // 互斥锁实例化
            mutex_lock #(
                .NUM_PORTS(NUM_PORTS),
                .ID_WIDTH (ID_WIDTH)
            ) alu_lock (
                .clk         (clk),
                .rst_n       (rst_n),
                .req         (alu_req[k]),
                .req_issue_id(sic_issue_id),
                .release_lock(local_release),
                .grant       (unit_grant),
                .busy        (busy)
            );

            // 将 Grant 信号导出到内部网线
            assign alu_grant[k] = unit_grant;

            // ALU 实例化 (这里仅做简单的逻辑演示，实际可调用您的 alu 模块)
            logic [31:0] op_a_mux;
            logic [31:0] op_b_mux;
            logic [ 5:0] op_code_mux;

            // 输入数据多路选择：选择获得 Grant 的那个 SIC 的数据
            always_comb begin
                op_a_mux    = 0;
                op_b_mux    = 0;
                op_code_mux = 0;
                for (int s = 0; s < NUM_PORTS; s++) begin
                    if (unit_grant[s]) begin
                        op_a_mux    = sic_op_a[s];
                        op_b_mux    = sic_op_b[s];
                        op_code_mux = sic_op_code[s];
                    end
                end
            end

            // 简单的 ALU 行为 (或者实例化您现有的 ALU 模块)
            // 这里为了自包含，写一个简易版本
            always_comb begin
                case (op_code_mux)
                    6'h20:   alu_res_internal[k] = op_a_mux + op_b_mux;  // add
                    6'h22:   alu_res_internal[k] = op_a_mux - op_b_mux;  // sub
                    6'h24:   alu_res_internal[k] = op_a_mux & op_b_mux;  // and
                    6'h25:   alu_res_internal[k] = op_a_mux | op_b_mux;  // or
                    default: alu_res_internal[k] = 0;
                endcase
                alu_zero_internal[k] = (alu_res_internal[k] == 0);
            end

        end
    endgenerate

    // 3. 输出多路复用 (Mux: ALU -> SIC)
    always_comb begin
        for (int s = 0; s < NUM_PORTS; s++) begin
            sic_grant_out[s] = 0;
            sic_res_out[s]   = 'x;
            sic_zero_out[s]  = 0;

            if (sic_alu_id[s] < NUM_ALUS) begin
                sic_grant_out[s] = alu_grant[sic_alu_id[s]][s];

                if (sic_grant_out[s]) begin
                    sic_res_out[s]  = alu_res_internal[sic_alu_id[s]];
                    sic_zero_out[s] = alu_zero_internal[sic_alu_id[s]];
                end
            end
        end
    end

endmodule
