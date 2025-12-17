/*
 * Description :
 *
 * 最简化物理寄存器文件（无锁版）。
 *
 * 设计要点：
 * - 物理寄存器按“生命周期”使用：allocate/reset -> (commit 写一次) -> 读若干次 -> 回收
 * - 不使用 Issue ID/锁；用 valid 位阻止在写回前读取到旧数据
 * - 写入只能发生一次：若对 valid==1 的寄存器再次写入，直接断言失败（便于调试）
 *
 * 接口说明：
 * - 每个 SIC 提供 2 个读端口（rs/rt）以及 1 个写端口（dst commit）
 * - Issue Controller 提供 alloc 端口：在分配新 phy_dst 时将其 valid 清 0（并可将 data 置 X）
 */

module register_file #(
    parameter int NUM_PHY_REGS = 64,
    parameter int NUM_SICS     = 2
) (
    input logic clk,
    input logic rst_n,

    // === Allocate / Reset lifecycle (from Issue Controller) ===
    input logic                             alloc_wen [NUM_SICS],
    input logic [$clog2(NUM_PHY_REGS)-1:0]  alloc_pr  [NUM_SICS],

    // === Read ports (from SIC) ===
    input  logic [$clog2(NUM_PHY_REGS)-1:0] rs_addr   [NUM_SICS],
    input  logic [$clog2(NUM_PHY_REGS)-1:0] rt_addr   [NUM_SICS],
    output logic [31:0]                     rs_rdata  [NUM_SICS],
    output logic [31:0]                     rt_rdata  [NUM_SICS],
    output logic                            rs_valid  [NUM_SICS],
    output logic                            rt_valid  [NUM_SICS],

    // === Write ports (from SIC) ===
    input logic                             wcommit   [NUM_SICS],
    input logic [$clog2(NUM_PHY_REGS)-1:0]  waddr     [NUM_SICS],
    input logic [31:0]                      wdata     [NUM_SICS]
);

    logic [31:0] regs [NUM_PHY_REGS];
    logic        vld  [NUM_PHY_REGS];

    // 组合读：直接输出数据；由 valid 提供“是否可用”
    always_comb begin
        for (int s = 0; s < NUM_SICS; s++) begin
            rs_rdata[s] = regs[rs_addr[s]];
            rt_rdata[s] = regs[rt_addr[s]];
            rs_valid[s] = vld[rs_addr[s]];
            rt_valid[s] = vld[rt_addr[s]];
        end
    end

    // 生命周期控制：allocate -> valid=0；commit 写回 -> valid=1
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 复位：0..31 作为架构初值映射，置为 valid=1 且值为 0
            for (int p = 0; p < NUM_PHY_REGS; p++) begin
                regs[p] <= 32'b0;
                vld[p]  <= (p < 32);
            end
        end else begin
            // 1) allocate：开启新生命周期（清 valid，data 置 X 便于调试）
            for (int s = 0; s < NUM_SICS; s++) begin
                if (alloc_wen[s]) begin
                    vld[alloc_pr[s]]  <= 1'b0;
                    regs[alloc_pr[s]] <= 32'hxxxx_xxxx;
                end
            end

            // 2) commit 写回：只允许写一次
            for (int s = 0; s < NUM_SICS; s++) begin
                if (wcommit[s]) begin
`ifndef SYNTHESIS
                    // 禁止写物理 0..31（保留初值映射），以及禁止二次写
                    assert (waddr[s] >= 32)
                        else $fatal(1, "RF: illegal write to reserved pr=%0d", waddr[s]);
                    assert (vld[waddr[s]] == 1'b0)
                        else $fatal(1, "RF: double-write to pr=%0d", waddr[s]);
`endif
                    regs[waddr[s]] <= wdata[s];
                    vld[waddr[s]]  <= 1'b1;
                end
            end
        end
    end

endmodule


