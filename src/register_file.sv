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

`include "structs.svh"

module register_file #(
    parameter int NUM_PHY_REGS,
    parameter int NUM_SICS
) (
    input logic clk,
    input logic rst_n,

    // === Allocate / Reset lifecycle (from Issue Controller) ===
    input logic                            alloc_wen[NUM_SICS],
    input logic [$clog2(NUM_PHY_REGS)-1:0] alloc_pr [NUM_SICS],

    // === SIC interface (packed) ===
    input  reg_req#(NUM_PHY_REGS)::t reg_req[NUM_SICS],
    output reg_ans_t                 reg_ans[NUM_SICS],

    // === Physical register usage/state (for allocator / debug) ===
    output logic      [NUM_PHY_REGS-1:0] pr_not_idle,
    output pr_state_t                    pr_state   [NUM_PHY_REGS]
);

    logic [            31:0] regs   [NUM_PHY_REGS];
    logic                    vld    [NUM_PHY_REGS];

    // In-use bitmap: any SIC referencing a PR via rs/rt/waddr marks it in-use.
    logic [NUM_PHY_REGS-1:0] in_use;

`ifndef SYNTHESIS
    // Enable debug assertions only after reset has been released and at least one clk edge occurred.
    logic sim_checks_en;
`endif

    // 组合读：直接输出数据；由 valid 提供“是否可用”
    always_comb begin
        for (int s = 0; s < NUM_SICS; s++) begin
`ifndef SYNTHESIS
            // Simulation-time safety checks: any X/Z in register indices is a hard error.
            if (sim_checks_en && $isunknown(reg_req[s].rs_addr))
                $fatal(1, "RF: rs_addr contains X/Z (sic=%0d, rs_addr=%b)", s, reg_req[s].rs_addr);
            if (sim_checks_en && $isunknown(reg_req[s].rt_addr))
                $fatal(1, "RF: rt_addr contains X/Z (sic=%0d, rt_addr=%b)", s, reg_req[s].rt_addr);
            if (sim_checks_en && $isunknown(reg_req[s].waddr))
                $fatal(1, "RF: waddr contains X/Z (sic=%0d, waddr=%b)", s, reg_req[s].waddr);
`endif
            // PR0 behaves like MIPS $0: always reads as 0 and always valid.
            if (reg_req[s].rs_addr == '0) begin
                reg_ans[s].rs_rdata = 32'b0;
                reg_ans[s].rs_valid = 1'b1;
            end else begin
                reg_ans[s].rs_rdata = regs[reg_req[s].rs_addr];
                reg_ans[s].rs_valid = vld[reg_req[s].rs_addr];
            end

            if (reg_req[s].rt_addr == '0) begin
                reg_ans[s].rt_rdata = 32'b0;
                reg_ans[s].rt_valid = 1'b1;
            end else begin
                reg_ans[s].rt_rdata = regs[reg_req[s].rt_addr];
                reg_ans[s].rt_valid = vld[reg_req[s].rt_addr];
            end
        end
    end

    // PR usage / state derivation (purely combinational; no per-PR FSM)
    always_comb begin
        in_use = '0;

        for (int s = 0; s < NUM_SICS; s++) begin
`ifndef SYNTHESIS
            // Same check here because we use indices to set bits in a packed array.
            if (sim_checks_en && $isunknown(reg_req[s].rs_addr))
                $fatal(
                    1,
                    "RF: rs_addr contains X/Z while deriving in_use (sic=%0d, rs_addr=%b)",
                    s,
                    reg_req[s].rs_addr
                );
            if (sim_checks_en && $isunknown(reg_req[s].rt_addr))
                $fatal(
                    1,
                    "RF: rt_addr contains X/Z while deriving in_use (sic=%0d, rt_addr=%b)",
                    s,
                    reg_req[s].rt_addr
                );
            if (sim_checks_en && $isunknown(reg_req[s].waddr))
                $fatal(
                    1,
                    "RF: waddr contains X/Z while deriving in_use (sic=%0d, waddr=%b)",
                    s,
                    reg_req[s].waddr
                );
`endif
            if (reg_req[s].rs_addr != '0) in_use[reg_req[s].rs_addr] = 1'b1;
            if (reg_req[s].rt_addr != '0) in_use[reg_req[s].rt_addr] = 1'b1;
            if (reg_req[s].waddr != '0) in_use[reg_req[s].waddr] = 1'b1;
        end

        // PR0 is special ($0/unused marker): do not treat it as in-use for allocation purposes.
        in_use[0]   = 1'b0;
        pr_not_idle = in_use;

        for (int p = 0; p < NUM_PHY_REGS; p++) begin
            if (!in_use[p]) pr_state[p] = PR_IDLE;
            else if (!vld[p]) pr_state[p] = PR_WAIT_VALUE;
            else pr_state[p] = PR_READING;
        end
        // Force PR0 to IDLE: we use 0 as "no register referenced".
        pr_state[0] = PR_IDLE;
    end

    // 生命周期控制：allocate -> valid=0；commit 写回 -> valid=1
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
`ifndef SYNTHESIS
            sim_checks_en <= 1'b0;
`endif
            // 复位：0..31 作为架构初值映射，置为 valid=1 且值为 0
            for (int p = 0; p < NUM_PHY_REGS; p++) begin
                regs[p] <= 32'b0;
                vld[p]  <= (p < 32);
            end
        end else begin
`ifndef SYNTHESIS
            sim_checks_en <= 1'b1;
`endif
            // 1) allocate：开启新生命周期（清 valid，data 置 X 便于调试）
            for (int s = 0; s < NUM_SICS; s++) begin
                if (alloc_wen[s]) begin
`ifndef SYNTHESIS
                    if (sim_checks_en && $isunknown(alloc_pr[s]))
                        $fatal(
                            1, "RF: alloc_pr contains X/Z (sic=%0d, alloc_pr=%b)", s, alloc_pr[s]
                        );
`endif
                    // Never allocate/reset PR0 ($0). It is always valid and always 0.
                    if (alloc_pr[s] != '0) begin
                        vld[alloc_pr[s]]  <= 1'b0;
                        regs[alloc_pr[s]] <= 32'hxxxx_xxxx;
                    end
                end
            end

            // 2) commit 写回：只允许写一次
            for (int s = 0; s < NUM_SICS; s++) begin
                if (reg_req[s].wcommit) begin
`ifndef SYNTHESIS
                    // Simulation-time safety checks: any X/Z in write address/data is a hard error.
                    if (sim_checks_en && $isunknown(reg_req[s].waddr))
                        $fatal(
                            1,
                            "RF: write address contains X/Z (sic=%0d, waddr=%b)",
                            s,
                            reg_req[s].waddr
                        );
                    if (reg_req[s].waddr != '0) begin
                        if (sim_checks_en && $isunknown(reg_req[s].wdata))
                            $fatal(
                                1,
                                "RF: write data contains X/Z (sic=%0d, pr=%0d, wdata=%h)",
                                s,
                                reg_req[s].waddr,
                                reg_req[s].wdata
                            );
                    end

                    // PR0: MIPS $0 semantics - writes are ignored (allowed any number of times).
                    // PR1..31: still reserved (illegal to write).
                    if (reg_req[s].waddr != '0) begin
                        assert (reg_req[s].waddr >= 32)
                        else $fatal(1, "RF: illegal write to reserved pr=%0d", reg_req[s].waddr);
                        assert (vld[reg_req[s].waddr] == 1'b0)
                        else $fatal(1, "RF: double-write to pr=%0d", reg_req[s].waddr);
                    end
`endif
                    // Ignore writes to PR0; normal writeback otherwise.
                    if (reg_req[s].waddr != '0) begin
                        regs[reg_req[s].waddr] <= reg_req[s].wdata;
                        vld[reg_req[s].waddr]  <= 1'b1;
                    end
                end
            end
        end
    end

endmodule
