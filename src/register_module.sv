/*
 * Description :
 *
 * 参数化乱序寄存器堆顶层模块 (Top-Level Register File)。
 * 
 * 本模块实现了 N 个访问端口到 M 个物理寄存器的全互联
 * 交叉开关 (Crossbar) 逻辑。
 * 
 * 主要功能特性：
 * 1. 动态路由与解复用 (Routing & Demux):
 * 根据 N 个端口的地址信号，将读/写请求、发射序号、
 * 释放信号动态路由到对应的物理寄存器。每个物理寄存器只处理
 * 目标地址指向自己的请求。
 * 
 * 2. 结果复用与数据屏蔽 (Mux & Masking):
 * 从 M 个物理寄存器收集 Grant 信号和读数据。
 * 实现了数据屏蔽逻辑：当端口未获得 Grant 或未发起读请求时，
 * 强制输出 'x (Unknown)，以便在仿真阶段快速定位非法读取行为。
 * 
 * 3. 完全参数化设计：
 * 支持通过 parameter 配置物理寄存器数量 (NUM_PHY_REGS)、
 * 并发端口数 (TOTAL_PORTS) 以及发射序号位宽 (ID_WIDTH)，
 * 无需修改代码即可适应不同规模的处理器架构。
 * 
 * Author      : nictheboy <nictheboy@outlook.com>
 * Create Date : 2025/12/15
 * 
 */

module register_module #(
    parameter int NUM_PHY_REGS,  // 物理寄存器数量
    parameter int TOTAL_PORTS,   // 总访问端口数 (例如 4个SIC * 3端口 = 12)
    parameter int ID_WIDTH       // 发射 ID 位宽
) (
    input logic clk,
    input logic rst_n,

    // === 通用端口接口 (1D Arrays) ===
    // 索引 [0 ~ TOTAL_PORTS-1]
    input logic [$clog2(NUM_PHY_REGS)-1:0] port_addr     [TOTAL_PORTS],
    input logic                            port_req_read [TOTAL_PORTS],
    input logic                            port_req_write[TOTAL_PORTS],
    input logic [            ID_WIDTH-1:0] port_issue_id [TOTAL_PORTS],
    input logic                            port_release  [TOTAL_PORTS],
    input logic [                    31:0] port_wdata    [TOTAL_PORTS],

    // === 输出 ===
    output logic [31:0] port_rdata_out[TOTAL_PORTS],
    output logic        port_grant_out[TOTAL_PORTS]
);

    // 内部互联矩阵
    // reg_req_xxx [寄存器索引] [端口索引]
    logic        reg_req_read [NUM_PHY_REGS] [TOTAL_PORTS];
    logic        reg_req_write[NUM_PHY_REGS] [TOTAL_PORTS];
    logic        reg_grant    [NUM_PHY_REGS] [TOTAL_PORTS];
    logic [31:0] reg_data_out [NUM_PHY_REGS];

    // ============================================================
    // 1. 请求路由 (Routing: Ports -> Registers)
    // ============================================================
    always_comb begin
        // 默认清零
        for (int r = 0; r < NUM_PHY_REGS; r++) begin
            for (int p = 0; p < TOTAL_PORTS; p++) begin
                reg_req_read[r][p]  = 0;
                reg_req_write[r][p] = 0;
            end
        end

        // 遍历所有通用端口进行路由
        for (int p = 0; p < TOTAL_PORTS; p++) begin
            // 只有地址在合法范围内才路由请求
            if (port_addr[p] < NUM_PHY_REGS) begin
                reg_req_read[port_addr[p]][p]  = port_req_read[p];
                reg_req_write[port_addr[p]][p] = port_req_write[p];
            end
        end
    end

    // ============================================================
    // 2. 物理寄存器阵列实例化
    // ============================================================
    genvar r;
    generate
        for (r = 0; r < NUM_PHY_REGS; r++) begin : phy_regs

            // 为每个寄存器生成 Release 信号向量
            logic local_release[TOTAL_PORTS];

            always_comb begin
                for (int p = 0; p < TOTAL_PORTS; p++) begin
                    // 只有当该端口的目标地址是本寄存器，且 release 有效时
                    local_release[p] = port_release[p] && (port_addr[p] == r);
                end
            end

            // 实例化带锁单元
            register_with_lock #(
                .NUM_PORTS(TOTAL_PORTS),  // 每个寄存器都要处理所有端口的竞争
                .ID_WIDTH (ID_WIDTH)
            ) rw_lock (
                .clk         (clk),
                .rst_n       (rst_n),
                .req_read    (reg_req_read[r]),
                .req_write   (reg_req_write[r]),
                .req_issue_id(port_issue_id),     // 端口 ID 直接透传
                .release_lock(local_release),
                .wdata       (port_wdata),        // 写数据直接透传
                .rdata       (reg_data_out[r]),
                .grant       (reg_grant[r])
            );
        end
    endgenerate

    // ============================================================
    // 3. 输出多路复用 (Muxing: Registers -> Ports)
    // ============================================================
    always_comb begin
        for (int p = 0; p < TOTAL_PORTS; p++) begin
            // 默认输出
            port_grant_out[p] = 0;
            port_rdata_out[p] = 'x;

            if (port_addr[p] < NUM_PHY_REGS) begin
                // 从目标寄存器获取 Grant
                port_grant_out[p] = reg_grant[port_addr[p]][p];

                // 如果读授权，则从目标寄存器获取数据
                if (port_grant_out[p] && port_req_read[p]) begin
                    port_rdata_out[p] = reg_data_out[port_addr[p]];
                end
            end
        end
    end

endmodule
