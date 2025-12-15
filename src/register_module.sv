/*
 * Description :
 *
 * 参数化乱序寄存器堆顶层模块 (Top-Level Register File)。
 * 
 * 本模块实现了 N 个单指令控制器 (SIC) 到 M 个物理寄存器的全互联
 * 交叉开关 (Crossbar) 逻辑。
 * 
 * 主要功能特性：
 * 1. 动态路由与解复用 (Routing & Demux):
 * 根据 N 个 SIC 输入的地址信号 (sic_addr)，将读/写请求、发射序号、
 * 释放信号动态路由到对应的物理寄存器。每个物理寄存器只处理
 * 目标地址指向自己的请求。
 * 
 * 2. 结果复用与数据屏蔽 (Mux & Masking):
 * 从 M 个物理寄存器收集 Grant 信号和读数据。
 * 实现了数据屏蔽逻辑：当 SIC 未获得 Grant 或未发起读请求时，
 * 强制输出 'x (Unknown)，以便在仿真阶段快速定位非法读取行为。
 * 
 * 3. 完全参数化设计：
 * 支持通过 parameter 配置物理寄存器数量 (NUM_PHY_REGS)、
 * 并发端口数 (NUM_SICS) 以及发射序号位宽 (ID_WIDTH)，
 * 无需修改代码即可适应不同规模的处理器架构。
 * 
 * Author      : nictheboy <nictheboy@outlook.com>
 * Create Date : 2025/12/15
 * 
 */

module register_module #(
    parameter int NUM_PHY_REGS,
    parameter int NUM_SICS,
    parameter int ID_WIDTH
) (
    input logic clk,
    input logic rst_n,

    // === SIC 接口 ===
    input logic [$clog2(NUM_PHY_REGS)-1:0] sic_addr     [NUM_SICS],
    input logic                            sic_req_read [NUM_SICS],
    input logic                            sic_req_write[NUM_SICS],
    input logic [            ID_WIDTH-1:0] sic_issue_id [NUM_SICS],
    input logic                            sic_release  [NUM_SICS],
    input logic [                    31:0] sic_wdata    [NUM_SICS],

    // === 输出 ===
    output logic [31:0] sic_rdata_out[NUM_SICS],
    output logic        sic_grant_out[NUM_SICS]
);

    // 内部互联
    logic        reg_req_read [NUM_PHY_REGS] [NUM_SICS];
    logic        reg_req_write[NUM_PHY_REGS] [NUM_SICS];
    logic        reg_grant    [NUM_PHY_REGS] [NUM_SICS];
    logic [31:0] reg_data_out [NUM_PHY_REGS];

    // 1. 请求分发 (SIC -> Register)
    always_comb begin
        // 默认清零
        for (int r = 0; r < NUM_PHY_REGS; r++) begin
            for (int s = 0; s < NUM_SICS; s++) begin
                reg_req_read[r][s]  = 0;
                reg_req_write[r][s] = 0;
            end
        end

        // 路由
        for (int s = 0; s < NUM_SICS; s++) begin
            if (sic_addr[s] < NUM_PHY_REGS) begin
                reg_req_read[sic_addr[s]][s]  = sic_req_read[s];
                reg_req_write[sic_addr[s]][s] = sic_req_write[s];
            end
        end
    end

    // 2. 寄存器实例化
    genvar r;
    generate
        for (r = 0; r < NUM_PHY_REGS; r++) begin : phy_regs

            logic local_release[NUM_SICS];

            always_comb begin
                for (int s = 0; s < NUM_SICS; s++) begin
                    local_release[s] = sic_release[s] && (sic_addr[s] == r);
                end
            end

            register_with_lock #(
                .NUM_PORTS(NUM_SICS),
                .ID_WIDTH (ID_WIDTH)
            ) rw_lock (
                .clk         (clk),
                .rst_n       (rst_n),
                .req_read    (reg_req_read[r]),
                .req_write   (reg_req_write[r]),
                .req_issue_id(sic_issue_id),
                .release_lock(local_release),
                .wdata       (sic_wdata),
                .rdata       (reg_data_out[r]),
                .grant       (reg_grant[r])
            );
        end
    endgenerate

    // 3. 输出多路复用与数据屏蔽 (Output Mux & X-Masking)
    always_comb begin
        for (int s = 0; s < NUM_SICS; s++) begin
            // 默认值
            sic_grant_out[s] = 0;
            sic_rdata_out[s] = 'x;  // 默认输出 X

            if (sic_addr[s] < NUM_PHY_REGS) begin
                // 获取 Grant
                sic_grant_out[s] = reg_grant[sic_addr[s]][s];

                // 数据输出逻辑：只有当 (读请求 && 获得Grant) 时才输出有效数据
                // 否则保持为 'x'，以便在仿真中暴露非法读取
                if (sic_grant_out[s] && sic_req_read[s]) begin
                    sic_rdata_out[s] = reg_data_out[sic_addr[s]];
                end else begin
                    sic_rdata_out[s] = 'x;
                end
            end
        end
    end

endmodule
