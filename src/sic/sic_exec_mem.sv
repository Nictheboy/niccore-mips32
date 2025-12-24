`include "structs.svh"

module sic_exec_mem #(
    parameter int SIC_ID,
    parameter int NUM_PHY_REGS,
    parameter int ID_WIDTH
) (
    input logic clk,
    input logic rst_n,
    input sic_sub_in#(NUM_PHY_REGS, ID_WIDTH)::t in,
    output sic_sub_out#(NUM_PHY_REGS, ID_WIDTH)::t out
);

    // 本地别名：仅保留高频使用项
    sic_packet_t        packet_in;
    reg_ans_t           reg_ans;
    logic        [31:0] mem_rdata;
    logic               mem_grant;

    assign packet_in = in.pkt;
    assign reg_ans   = in.reg_ans;
    assign mem_rdata = in.mem_rdata;
    assign mem_grant = in.mem_grant;

    // 状态机
    typedef enum logic [3:0] {
        IDLE,
        WAIT_PACKET,
        REQUEST_LOCKS,
        EXECUTE_READ,
        CHECK_ECR,
        MEM_ACCESS,
        RELEASE
    } state_t;

    state_t state;
    sic_packet_t pkt;

    logic [31:0] mem_addr_hold;  // byte addr
    logic [31:0] mem_wdata_hold;

    // Abort：依赖的 ECR 为 10 时，丢弃当前指令
    logic abort_mispredict;

    // 指令资源需求（用于请求/释放资源）
    logic need_reg_read0, need_reg_read1, need_reg_write2;
    logic need_mem_read, need_mem_write;

    // REQUEST_LOCKS 阶段的 grant 聚合
    logic all_granted;
    sic_packet_t pkt_v;

    // 组合逻辑计算锁请求
    always_comb begin
        out                      = '0;

        // WAIT_PACKET 拍使用 packet_in 视图，其余拍使用已锁存的 pkt
        pkt_v                    = ((state == WAIT_PACKET) && packet_in.valid) ? packet_in : pkt;

        // 资源需求（由 decoder 给出）
        need_reg_read0           = pkt_v.info.read_rs;
        need_reg_read1           = pkt_v.info.read_rt;
        need_reg_write2          = pkt_v.info.write_gpr;
        need_mem_read            = pkt_v.info.mem_read;
        need_mem_write           = pkt_v.info.mem_write;

        // ECR read
        out.ecr_read_addr        = pkt.dep_ecr_id[$clog2(2)-1:0];
        out.ecr_read_en          = (state != IDLE) && (state != WAIT_PACKET);
        abort_mispredict         = out.ecr_read_en && (in.ecr_read_data == 2'b10);

        // req instr
        out.req_instr            = (state == IDLE) || (state == WAIT_PACKET && !packet_in.valid);

        // mem lock & request
        out.mem_rpl.req_issue_id = pkt.issue_id;
        if (state == MEM_ACCESS) begin
            out.mem_rpl.req          = (need_mem_read || need_mem_write);
            out.mem_rpl.release_lock = mem_grant;
        end
        out.mem_req.addr = mem_addr_hold[31:2];
        out.mem_req.wdata = mem_wdata_hold;
        out.mem_req.wen = (state == MEM_ACCESS) && need_mem_write && mem_grant && !abort_mispredict;

        // RF commit (LW only)
        out.reg_req = '0;
        if ((state == MEM_ACCESS) && need_mem_read && mem_grant) begin
            out.reg_req.wdata   = mem_rdata;
            out.reg_req.wcommit = need_reg_write2 && !abort_mispredict;
        end
    end

    // 聚合 grant（避免在 always_ff 内部声明 all_granted 变量）
    always_comb begin
        all_granted = 1;
        if (state == REQUEST_LOCKS) begin
            if (need_reg_read0 && !reg_ans.rs_valid) all_granted = 0;
            if (need_reg_read1 && !reg_ans.rt_valid) all_granted = 0;
        end
    end

    // 状态机逻辑
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            mem_addr_hold <= 32'b0;
            mem_wdata_hold <= 32'b0;
        end else begin
            // 若依赖 ECR 已为 Incorrect，则丢弃当前指令
            if (abort_mispredict) begin
                state <= RELEASE;
            end else
                case (state)
                    IDLE: begin
                        state <= WAIT_PACKET;
                    end

                    WAIT_PACKET: begin
                        if (packet_in.valid) begin
                            pkt   <= packet_in;
                            state <= REQUEST_LOCKS;
                        end
                    end

                    REQUEST_LOCKS: begin
                        // 等待所需资源满足
                        if (all_granted) state <= EXECUTE_READ;
                    end

                    EXECUTE_READ: begin
                        // 地址计算
                        if (need_mem_read || need_mem_write) begin
                            // 地址计算（内部加法）
                            mem_addr_hold <= reg_ans.rs_rdata + pkt.info.imm16_sign_ext;  // byte addr
                            mem_wdata_hold <= reg_ans.rt_rdata;
                        end
                        // 单周期进入下一阶段
                        state <= CHECK_ECR;
                    end

                    CHECK_ECR: begin
                        // 约定：00=Busy, 01=Correct, 10=Incorrect
                        if (in.ecr_read_data == 2'b10) begin
                            state <= RELEASE;
                        end else if (in.ecr_read_data == 2'b01) begin
                            state <= MEM_ACCESS;
                        end
                        // 00: Busy，保持等待
                    end

                    MEM_ACCESS: begin
                        // lw/sw：等待 mem grant；grant 当拍完成访存
                        if (mem_grant) begin
                            state <= RELEASE;
                        end else begin
                            state <= MEM_ACCESS;
                        end
                    end

                    RELEASE: begin
                        // 释放资源
                        state <= IDLE;
                    end
                endcase
        end
    end

endmodule


