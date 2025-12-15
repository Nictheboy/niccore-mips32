/*
 * Description :
 *
 * 编译用顶层封装模块 (Synthesis Top Wrapper)。
 * 
 * 本模块用于验证 RegisterModule 的综合可行性。它将 RegisterModule
 * 的多维数组接口 (Unpacked Arrays) 转换为标准的扁平化向量接口 (Packed Vectors)，
 * 以满足 FPGA/ASIC 综合工具对顶层 I/O 的要求。
 * 
 * 主要功能：
 * 1. 参数具象化：实例化 64 个物理寄存器、4 个 SIC端口、8 位 ID 宽度的具体配置。
 * 2. 接口打包/解包：利用 SystemVerilog 的流操作符或循环，实现
 * Flat Vector <-> Unpacked Array 的双向转换。
 * 
 * Author      : nictheboy <nictheboy@outlook.com>
 * Create Date : 2025/12/15
 * 
 */

module top_module #(
    // 在这里定义具体的综合规模
    parameter int SYN_PHY_REGS = 64,
    parameter int SYN_SICS     = 4,
    parameter int SYN_ID_W     = 8
) (
    input logic clk,
    input logic rst_n,

    // === 扁平化输入接口 (Flat Inputs) ===
    // 地址宽计算: $clog2(64) = 6 bit. 总宽 = 4 * 6 = 24 bit
    input logic [SYN_SICS * $clog2(SYN_PHY_REGS) - 1 : 0] flat_sic_addr,

    // 控制信号直接是位宽为 NUM_SICS 的向量
    input logic [SYN_SICS - 1 : 0] flat_sic_req_read,
    input logic [SYN_SICS - 1 : 0] flat_sic_req_write,

    // ID 宽计算: 4 * 8 = 32 bit
    input logic [SYN_SICS * SYN_ID_W - 1 : 0] flat_sic_issue_id,

    input logic [SYN_SICS - 1 : 0] flat_sic_release,

    // 数据宽计算: 4 * 32 = 128 bit
    input logic [SYN_SICS * 32 - 1 : 0] flat_sic_wdata,

    // === 扁平化输出接口 (Flat Outputs) ===
    output logic [SYN_SICS * 32 - 1 : 0] flat_sic_rdata_out,
    output logic [     SYN_SICS - 1 : 0] flat_sic_grant_out
);

    // =========================================================================
    // 内部多维数组声明 (Unpacked Arrays)
    // =========================================================================
    localparam int ADDR_W = $clog2(SYN_PHY_REGS);

    logic [ADDR_W - 1 : 0] sic_addr     [SYN_SICS];
    logic                  sic_req_read [SYN_SICS];
    logic                  sic_req_write[SYN_SICS];
    logic [SYN_ID_W - 1:0] sic_issue_id [SYN_SICS];
    logic                  sic_release  [SYN_SICS];
    logic [          31:0] sic_wdata    [SYN_SICS];

    logic [          31:0] sic_rdata_out[SYN_SICS];
    logic                  sic_grant_out[SYN_SICS];

    // =========================================================================
    // 1. 输入解包 (Unpack: Flat -> Array)
    // =========================================================================
    always_comb begin
        for (int i = 0; i < SYN_SICS; i++) begin
            // 使用索引切片语法 [Base +: Width]
            sic_addr[i]      = flat_sic_addr[i*ADDR_W+:ADDR_W];
            sic_req_read[i]  = flat_sic_req_read[i];
            sic_req_write[i] = flat_sic_req_write[i];
            sic_issue_id[i]  = flat_sic_issue_id[i*SYN_ID_W+:SYN_ID_W];
            sic_release[i]   = flat_sic_release[i];
            sic_wdata[i]     = flat_sic_wdata[i*32+:32];
        end
    end

    // =========================================================================
    // 2. 核心模块实例化
    // =========================================================================
    register_module #(
        .NUM_PHY_REGS(SYN_PHY_REGS),
        .NUM_SICS    (SYN_SICS),
        .ID_WIDTH    (SYN_ID_W)
    ) u_core (
        .clk          (clk),
        .rst_n        (rst_n),
        .sic_addr     (sic_addr),
        .sic_req_read (sic_req_read),
        .sic_req_write(sic_req_write),
        .sic_issue_id (sic_issue_id),
        .sic_release  (sic_release),
        .sic_wdata    (sic_wdata),
        .sic_rdata_out(sic_rdata_out),
        .sic_grant_out(sic_grant_out)
    );

    // =========================================================================
    // 3. 输出打包 (Pack: Array -> Flat)
    // =========================================================================
    always_comb begin
        for (int i = 0; i < SYN_SICS; i++) begin
            flat_sic_rdata_out[i*32+:32] = sic_rdata_out[i];
            flat_sic_grant_out[i]        = sic_grant_out[i];
        end
    end

endmodule
