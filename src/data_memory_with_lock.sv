/*
 * Description :
 *
 * 数据内存顶层包装 (Data Memory Wrapper).
 *
 * 性能优化：
 * - 将单端口内存扩展为按地址分 Bank 的多实例内存（NUM_BANKS 个）。
 * - 不同 Bank 的访问可并行；同一 Bank 内仍通过 resource_pool_lock 按 issue_id 仲裁。
 *
 * 语义注意：
 * - 不同 Bank 的访问可能在同一周期完成（等价于某种顺序的并发完成）。
 * - 若未来引入 MMIO/强序依赖，需考虑是否仍需要全局串行化。
 *
 * Author      : nictheboy
 * Date        : 2025/12/16
 *
 */

`include "structs.svh"

module data_memory_with_lock #(
    parameter int MEM_DEPTH,
    parameter int NUM_PORTS,
    parameter int ID_WIDTH,
    parameter int NUM_BANKS = 1
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

    localparam int VALID_W = (MEM_DEPTH > 1) ? $clog2(MEM_DEPTH) : 1;
    localparam int BANK_W = (NUM_BANKS > 1) ? $clog2(NUM_BANKS) : 1;
    localparam int MEM_DEPTH_PER_BANK = (NUM_BANKS > 0) ? (MEM_DEPTH / NUM_BANKS) : MEM_DEPTH;
    localparam int VALID_W_BANK = (MEM_DEPTH_PER_BANK > 1) ? $clog2(MEM_DEPTH_PER_BANK) : 1;

`ifndef SYNTHESIS
    initial begin
        if (NUM_BANKS <= 0) $fatal(1, "NUM_BANKS must be >= 1");
        if ((MEM_DEPTH % NUM_BANKS) != 0)
            $fatal(1, "MEM_DEPTH (%0d) must be divisible by NUM_BANKS (%0d)", MEM_DEPTH, NUM_BANKS);
    end
`endif

    // ============================================================
    // 1. Bank 选择：使用与 data_memory 相同的有效地址提取方式
    // global_idx = mem_req.addr[VALID_W+1:2]   (与 data_memory 内部 valid_address 一致)
    // bank = global_idx[BANK_W-1:0]
    // local_idx = global_idx[VALID_W-1:BANK_W] (深度为 MEM_DEPTH/NUM_BANKS)
    // ============================================================
    logic [NUM_PORTS-1:0][VALID_W-1:0] global_idx;
    logic [NUM_PORTS-1:0][BANK_W-1:0] bank_sel;
    logic [NUM_PORTS-1:0][VALID_W_BANK-1:0] local_idx;

    always_comb begin
        for (int p = 0; p < NUM_PORTS; p++) begin
            // 只有在 req=1 时该地址才有意义；否则强制为 0 以避免 X 传播
            logic [31:2] addr_s;
            addr_s = rpl_req[p].req ? mem_req[p].addr : '0;
            global_idx[p] = addr_s[VALID_W+1:2];
            bank_sel[p] = (NUM_BANKS > 1) ? global_idx[p][BANK_W-1:0] : '0;
            local_idx[p]  = (NUM_BANKS > 1) ? global_idx[p][VALID_W-1:BANK_W] : global_idx[p][VALID_W_BANK-1:0];
        end
    end

    // ============================================================
    // 2. 每个 Bank 一个锁 + 一个单端口 memory
    // ============================================================
    $unit::rpl_req #(ID_WIDTH)::t rpl_bank[NUM_BANKS][NUM_PORTS];
    logic grant_bank[NUM_BANKS][NUM_PORTS];
    logic [0:0] alloc_id_bank[NUM_BANKS][NUM_PORTS];
    logic pool_busy_bank[NUM_BANKS];

    mem_req_t mem_req_in[NUM_BANKS];
    logic [31:0] mem_rdata_out[NUM_BANKS];

    genvar b;
    generate
        for (b = 0; b < NUM_BANKS; b++) begin : banks
            // 只把目标 bank 的请求送入该 bank 的锁
            always_comb begin
                for (int p = 0; p < NUM_PORTS; p++) begin
                    rpl_bank[b][p] = '0;
                    if (rpl_req[p].req && (bank_sel[p] == BANK_W'(b))) begin
                        rpl_bank[b][p] = rpl_req[p];
                    end
                end
            end

            resource_pool_lock #(
                .NUM_RESOURCES(1),
                .NUM_PORTS    (NUM_PORTS),
                .ID_WIDTH     (ID_WIDTH)
            ) bank_lock (
                .clk      (clk),
                .rst_n    (rst_n),
                .rpl_in   (rpl_bank[b]),
                .grant    (grant_bank[b]),
                .alloc_id (alloc_id_bank[b]),
                .pool_busy(pool_busy_bank[b])
            );

            // 选择获得该 bank grant 的端口作为该 bank 的输入
            always_comb begin
                mem_req_in[b] = '0;
                for (int p = 0; p < NUM_PORTS; p++) begin
                    if (grant_bank[b][p]) begin
                        mem_req_in[b].wen   = mem_req[p].wen;
                        mem_req_in[b].wdata = mem_req[p].wdata;
                        // bank-local 地址：把 local_idx 放到 addr 的低位（对应 data_memory 内部的 valid_address）
                        mem_req_in[b].addr  = {{(30 - VALID_W_BANK) {1'b0}}, local_idx[p]};
                    end
                end
            end

            data_memory #(
                .MEM_DEPTH(MEM_DEPTH_PER_BANK)
            ) mem_core (
                .reset      (~rst_n),
                .clock      (clk),
                .mem_req    (mem_req_in[b]),
                .read_result(mem_rdata_out[b])
            );
        end
    endgenerate

    // ============================================================
    // 3. 输出分发 (Demux: Banks -> SIC)
    // ============================================================
    always_comb begin
        for (int p = 0; p < NUM_PORTS; p++) begin
            grant[p] = 1'b0;
            rdata[p] = 32'b0;
            for (int k = 0; k < NUM_BANKS; k++) begin
                if (grant_bank[k][p]) begin
                    grant[p] = 1'b1;
                    if (!mem_req[p].wen) begin
                        rdata[p] = mem_rdata_out[k];
                    end
                end
            end
        end
    end

endmodule
