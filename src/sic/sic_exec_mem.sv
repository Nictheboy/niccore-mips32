/*
 * Description :
 *
 * Mem 子 SIC（ready-bit 风格）。
 *
 * 执行模型：
 * - 用 `busy` / `mem_wait` 两个寄存器描述“是否有在飞指令 / 是否已进入访存阶段”。
 * - 其余“阶段”不显式编码，而是用 ready 条件组合推导：
 *   - `rf_ok`：所需的源寄存器值已就绪（reg_ans.*_valid=1 时数据可用）
 *   - `ecr_ok`：不依赖 ECR，或依赖的 ECR 已为 01
 *   - `abort_mispredict`：依赖的 ECR 为 10，则丢弃当前指令
 *
 * 时序要点：
 * - Issue->SIC 的 `packet_in` 是寄存输出；SIC 在同一时钟沿无法立即 latch 新 packet。
 *   因此 `req_instr` 必须在 `packet_in.valid==1` 的整个周期保持为 0，避免 issue 连发导致丢包。
 * - `mem_rpl.release_lock` 与 `mem_grant` 同拍拉高，完成访存当拍释放资源。
 */

`include "structs.svh"

module sic_exec_mem #(
    parameter int SIC_ID,
    parameter int NUM_PHY_REGS,
    parameter int NUM_ECRS,
    parameter int ID_WIDTH
) (
    input logic clk,
    input logic rst_n,
    input sic_sub_in#(NUM_PHY_REGS, ID_WIDTH, NUM_ECRS)::t in,
    output sic_sub_out#(NUM_PHY_REGS, ID_WIDTH, NUM_ECRS)::t out
);

    // 本地别名：仅保留高频使用项
    localparam int ECR_W = (NUM_ECRS > 1) ? $clog2(NUM_ECRS) : 1;
    typedef sic_packet#(NUM_PHY_REGS, ID_WIDTH, NUM_ECRS)::t sic_packet_t;

    sic_packet_t        packet_in;
    reg_ans_t           reg_ans;
    logic        [31:0] mem_rdata;
    logic               mem_grant;

    assign packet_in = in.pkt;
    assign reg_ans   = in.reg_ans;
    assign mem_rdata = in.mem_rdata;
    assign mem_grant = in.mem_grant;

    // “ready-bit”风格：用少量寄存器描述执行进度
    logic               busy;  // 已锁存 pkt，指令在飞
    logic               mem_wait;  // 已进入访存阶段，等待 mem_grant
    sic_packet_t        pkt;

    logic        [31:0] mem_addr_hold;  // byte addr
    logic        [31:0] mem_wdata_hold;

    // Abort：依赖的 ECR 为 10 时，丢弃当前指令
    logic               abort_mispredict;

    logic               rf_ok;
    logic               ecr_ok;

    // 组合逻辑计算锁请求
    always_comb begin
        out = '0;

        // ready 条件（组合）
        rf_ok = (!pkt.info.read_rs || reg_ans.rs_valid) && (!pkt.info.read_rt || reg_ans.rt_valid);
        ecr_ok = (in.ecr_read_data == 2'b01);

        abort_mispredict = busy && (in.ecr_read_data == 2'b10);

        // req instr：必须把 packet_in.valid 也考虑进去，避免 issue 连发导致丢包
        out.req_instr = !busy && !packet_in.valid;

        // mem lock & request
        out.mem_rpl.req_issue_id = pkt.issue_id;
        out.mem_rpl.req = mem_wait && !abort_mispredict;
        out.mem_rpl.release_lock = mem_wait && mem_grant;

        out.mem_req.addr = mem_addr_hold[31:2];
        out.mem_req.wdata = mem_wdata_hold;
        out.mem_req.wen = mem_wait && mem_grant && pkt.info.mem_write && !abort_mispredict;

        // RF commit (LW only)
        out.reg_req = '0;
        out.reg_req.wdata = mem_rdata;
        out.reg_req.wcommit = mem_wait && mem_grant && pkt.info.mem_read && pkt.info.write_gpr &&
                              !abort_mispredict;
    end

    // 状态机逻辑
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            mem_wait <= 1'b0;
            pkt <= '0;
            mem_addr_hold <= 32'b0;
            mem_wdata_hold <= 32'b0;
        end else begin
            if (!busy) begin
                if (packet_in.valid) begin
                    pkt <= packet_in;
                    busy <= 1'b1;
                    mem_wait <= 1'b0;
                end
            end else begin
                if (abort_mispredict) begin
                    busy <= 1'b0;
                    mem_wait <= 1'b0;
                end else if (!mem_wait) begin
                    if (rf_ok && ecr_ok) begin
                        mem_addr_hold <= reg_ans.rs_rdata + pkt.info.imm16_sign_ext;  // byte addr
                        mem_wdata_hold <= reg_ans.rt_rdata;
                        mem_wait <= 1'b1;
                    end
                end else begin
                    if (mem_grant) begin
                        busy <= 1'b0;
                        mem_wait <= 1'b0;
                    end
                end
            end
        end
    end

endmodule


