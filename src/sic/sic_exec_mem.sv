/*
 * Description :
 *
 * Mem 子 SIC（ready-bit 风格）。
 *
 * 执行模型：
 * - 用 `busy` / `mem_wait` 两个寄存器描述“是否有在飞指令 / 是否已进入访存阶段”。
 * - 其余“阶段”不显式编码，而是用 ready 条件组合推导：
 *   - `rf_ok`：所需的源寄存器值已就绪（reg_ans.*_valid=1 时数据可用）
 *   - `ecr_ok`：依赖的 ECR 已为 01（用于约束“不可回滚副作用”，例如 store）
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
    logic        [31:0] sb_word_hold;
    logic        [ 1:0] sb_phase;

    // Abort：依赖的 ECR 为 10 时，丢弃当前指令
    logic               abort_mispredict;

    logic               rf_ok;
    logic               ecr_ok;
    logic               is_lbu;
    logic               is_sb;
    logic               is_lb;
    logic               is_lh;
    logic               is_lhu;
    logic               is_sh;
    logic        [ 1:0] byte_off;
    logic        [31:0] load_data;
    logic        [31:0] store_word;

    // 组合逻辑计算锁请求
    always_comb begin
        out = '0;

        // ready 条件（组合）
        rf_ok = (!pkt.info.read_rs || reg_ans.rs_valid) && (!pkt.info.read_rt || reg_ans.rt_valid);
        ecr_ok = (in.ecr_read_data == 2'b01);

        abort_mispredict = busy && (in.ecr_read_data == 2'b10);

        // req instr：必须把 packet_in.valid 也考虑进去，避免 issue 连发导致丢包
        out.req_instr = !busy && !packet_in.valid;

        is_lbu = (pkt.info.opcode == OPC_LBU);
        is_sb = (pkt.info.opcode == OPC_SB);
        is_lb = (pkt.info.opcode == OPC_LB);
        is_lh = (pkt.info.opcode == OPC_LH);
        is_lhu = (pkt.info.opcode == OPC_LHU);
        is_sh = (pkt.info.opcode == OPC_SH);
        byte_off = mem_addr_hold[1:0];

        load_data = mem_rdata;
        if (is_lb || is_lbu) begin
            unique case (byte_off)
                2'd0:
                load_data = is_lb ? {{24{mem_rdata[7]}}, mem_rdata[7:0]} : {24'b0, mem_rdata[7:0]};
                2'd1:
                load_data = is_lb ? {{24{mem_rdata[15]}}, mem_rdata[15:8]} :
                                          {24'b0, mem_rdata[15:8]};
                2'd2:
                load_data = is_lb ? {{24{mem_rdata[23]}}, mem_rdata[23:16]} :
                                          {24'b0, mem_rdata[23:16]};
                default:
                load_data = is_lb ? {{24{mem_rdata[31]}}, mem_rdata[31:24]} :
                                             {24'b0, mem_rdata[31:24]};
            endcase
        end else if (is_lh || is_lhu) begin
            if (!byte_off[1]) begin
                load_data = is_lh ? {{16{mem_rdata[15]}}, mem_rdata[15:0]} : {16'b0, mem_rdata[15:0]};
            end else begin
                load_data = is_lh ? {{16{mem_rdata[31]}}, mem_rdata[31:16]} : {16'b0, mem_rdata[31:16]};
            end
        end

        store_word = sb_word_hold;
        if (is_sh) begin
            if (!byte_off[1]) store_word[15:0] = mem_wdata_hold[15:0];
            else store_word[31:16] = mem_wdata_hold[15:0];
        end else begin
            unique case (byte_off)
                2'd0: store_word[7:0] = mem_wdata_hold[7:0];
                2'd1: store_word[15:8] = mem_wdata_hold[7:0];
                2'd2: store_word[23:16] = mem_wdata_hold[7:0];
                default: store_word[31:24] = mem_wdata_hold[7:0];
            endcase
        end

        // mem lock & request
        out.mem_rpl.req_issue_id = pkt.issue_id;
        out.mem_rpl.req = mem_wait && !abort_mispredict;
        out.mem_rpl.release_lock = mem_wait && (!(is_sb || is_sh) ? mem_grant : (sb_phase == 2'd2));

        out.mem_req.addr = mem_addr_hold[31:2];
        out.mem_req.wdata = (is_sb || is_sh) ? store_word : mem_wdata_hold;
        out.mem_req.wen = mem_wait && mem_grant && pkt.info.mem_write && !abort_mispredict &&
                          (!(is_sb || is_sh) || (sb_phase == 2'd1));

        // RF commit
        out.reg_req = '0;
        out.reg_req.wdata = load_data;
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
            sb_word_hold <= 32'b0;
            sb_phase <= 2'd0;
        end else begin
            if (!busy) begin
                if (packet_in.valid) begin
                    pkt <= packet_in;
                    busy <= 1'b1;
                    mem_wait <= 1'b0;
                    sb_phase <= 2'd0;
                end
            end else begin
                if (abort_mispredict) begin
                    busy <= 1'b0;
                    mem_wait <= 1'b0;
                    sb_phase <= 2'd0;
                end else if (!mem_wait) begin
                    if (rf_ok && (pkt.info.mem_read || ecr_ok)) begin
                        mem_addr_hold <= reg_ans.rs_rdata + pkt.info.imm16_sign_ext;  // byte addr
                        mem_wdata_hold <= reg_ans.rt_rdata;
                        mem_wait <= 1'b1;
                        sb_phase <= 2'd0;
                    end
                end else begin
                    if (((pkt.info.opcode == OPC_SB) || (pkt.info.opcode == OPC_SH)) && (sb_phase == 2'd2)) begin
                        busy <= 1'b0;
                        mem_wait <= 1'b0;
                        sb_phase <= 2'd0;
                    end else if (mem_grant) begin
                        if ((pkt.info.opcode == OPC_SB) || (pkt.info.opcode == OPC_SH)) begin
                            if (sb_phase == 2'd0) begin
                                sb_word_hold <= mem_rdata;
                                sb_phase <= 2'd1;
                            end else if (sb_phase == 2'd1) begin
                                sb_phase <= 2'd2;
                            end
                        end else begin
                            busy <= 1'b0;
                            mem_wait <= 1'b0;
                        end
                    end
                end
            end
        end
    end

endmodule


