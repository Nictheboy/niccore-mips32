
`include "structs.svh"

module single_instruction_controller #(
    parameter int SIC_ID,
    parameter int NUM_PHY_REGS,
    parameter int NUM_ECRS,
    parameter int ID_WIDTH
) (
    input logic clk,
    input logic rst_n,

    // 与 Issue Controller 交互
    output logic                                            req_instr,
    input  sic_packet#(NUM_PHY_REGS, ID_WIDTH, NUM_ECRS)::t packet_in,

    // 与 Register File 交互（打包接口）
    output reg_req#(NUM_PHY_REGS)::t reg_req,
    input  reg_ans_t                 reg_ans,

    // 与 Memory 交互（打包接口）
    output rpl_req#(ID_WIDTH)::t        mem_rpl,
    output mem_req_t                    mem_req,
    input  logic                 [31:0] mem_rdata,
    input  logic                        mem_grant,

    // 与 ALU 交互
    output rpl_req#(ID_WIDTH)::t alu_rpl,
    output alu_req_t             alu_req,
    input  alu_ans_t             alu_ans,
    input  logic                 alu_grant,

    // 与 ECR 交互 (简化接口)
    // 读接口：直接输出地址，组合逻辑读取
    output logic                                               ecr_read_en,
    output logic [((NUM_ECRS > 1) ? $clog2(NUM_ECRS) : 1)-1:0] ecr_read_addr,
    input  logic [                                        1:0] ecr_read_data,
    // 写接口：写使能和地址数据
    output logic                                               ecr_wen,
    output logic [((NUM_ECRS > 1) ? $clog2(NUM_ECRS) : 1)-1:0] ecr_write_addr,
    output logic [                                        1:0] ecr_wdata,

    // === JR：提交后 PC 重定向反馈 ===
    output logic                pc_redirect_valid,
    output logic [        31:0] pc_redirect_pc,
    output logic [ID_WIDTH-1:0] pc_redirect_issue_id
);

    typedef sic_packet#(NUM_PHY_REGS, ID_WIDTH, NUM_ECRS)::t sic_packet_t;
    localparam int ECR_AW = (NUM_ECRS > 1) ? $clog2(NUM_ECRS) : 1;

    // 选择子 SIC：接收 packet 的当拍用组合选择，后续用寄存选择保持稳定
    typedef enum logic [2:0] {
        SEL_ALU,
        SEL_MEM,
        SEL_IMM,
        SEL_JR,
        SEL_SYSCALL
    } sel_t;
    sel_t sel_r, sel_now;

    logic kind_mem, kind_alu, kind_syscall, kind_jr, kind_imm;
    assign kind_mem = packet_in.valid && (packet_in.info.mem_read || packet_in.info.mem_write);
    assign kind_alu = packet_in.valid && !kind_mem && (packet_in.info.use_alu || packet_in.info.write_ecr);
    assign kind_syscall = packet_in.valid && !kind_mem && !kind_alu && packet_in.info.is_syscall;
    assign kind_jr = packet_in.valid && !kind_mem && !kind_alu && !kind_syscall &&
                     (packet_in.info.cf_kind == CF_JUMP_REG);
    assign kind_imm = packet_in.valid && !kind_mem && !kind_alu && !kind_syscall && !kind_jr;
    always_comb begin
        if (packet_in.valid) begin
            if (kind_mem) sel_now = SEL_MEM;
            else if (kind_alu) sel_now = SEL_ALU;
            else if (kind_syscall) sel_now = SEL_SYSCALL;
            else if (kind_jr) sel_now = SEL_JR;
            else sel_now = SEL_IMM;
        end else begin
            sel_now = sel_r;
        end
    end

    // gated packets
    sic_packet_t pkt_alu, pkt_mem, pkt_imm, pkt_jr, pkt_syscall;
    always_comb begin
        pkt_alu = packet_in;
        pkt_mem = packet_in;
        pkt_imm = packet_in;
        pkt_jr = packet_in;
        pkt_syscall = packet_in;
        pkt_alu.valid = packet_in.valid && (sel_now == SEL_ALU);
        pkt_mem.valid = packet_in.valid && (sel_now == SEL_MEM);
        pkt_imm.valid = packet_in.valid && (sel_now == SEL_IMM);
        pkt_jr.valid = packet_in.valid && (sel_now == SEL_JR);
        pkt_syscall.valid = packet_in.valid && (sel_now == SEL_SYSCALL);
    end

    // 子 SIC bundle
    sic_sub_in #(NUM_PHY_REGS, ID_WIDTH, NUM_ECRS)::t in_alu, in_mem, in_imm, in_jr, in_syscall;
    sic_sub_out #(NUM_PHY_REGS, ID_WIDTH, NUM_ECRS)::t
        out_alu, out_mem, out_imm, out_jr, out_syscall;
    sic_sub_out #(NUM_PHY_REGS, ID_WIDTH, NUM_ECRS)::t out_sel;

    // 保存最近一次接收到的 packet（用于 PR 占用声明在后续周期持续有效）
    sic_packet_t pkt_hold;
    logic holding_exec;

    always_comb begin
        in_alu = '0;
        in_mem = '0;
        in_imm = '0;
        in_jr = '0;
        in_syscall = '0;

        in_alu.pkt = pkt_alu;
        in_mem.pkt = pkt_mem;
        in_imm.pkt = pkt_imm;
        in_jr.pkt = pkt_jr;
        in_syscall.pkt = pkt_syscall;

        in_alu.reg_ans = reg_ans;
        in_mem.reg_ans = reg_ans;
        in_imm.reg_ans = reg_ans;
        in_jr.reg_ans = reg_ans;
        in_syscall.reg_ans = reg_ans;

        in_alu.mem_rdata = mem_rdata;
        in_mem.mem_rdata = mem_rdata;
        in_imm.mem_rdata = mem_rdata;
        in_jr.mem_rdata = mem_rdata;
        in_syscall.mem_rdata = mem_rdata;

        in_alu.mem_grant = mem_grant;
        in_mem.mem_grant = mem_grant;
        in_imm.mem_grant = mem_grant;
        in_jr.mem_grant = mem_grant;
        in_syscall.mem_grant = mem_grant;

        in_alu.alu_ans = alu_ans;
        in_mem.alu_ans = alu_ans;
        in_imm.alu_ans = alu_ans;
        in_jr.alu_ans = alu_ans;
        in_syscall.alu_ans = alu_ans;

        in_alu.alu_grant = alu_grant;
        in_mem.alu_grant = alu_grant;
        in_imm.alu_grant = alu_grant;
        in_jr.alu_grant = alu_grant;
        in_syscall.alu_grant = alu_grant;

        in_alu.ecr_read_data = ecr_read_data;
        in_mem.ecr_read_data = ecr_read_data;
        in_imm.ecr_read_data = ecr_read_data;
        in_jr.ecr_read_data = ecr_read_data;
        in_syscall.ecr_read_data = ecr_read_data;
    end

    sic_exec_alu #(
        .SIC_ID(SIC_ID),
        .NUM_PHY_REGS(NUM_PHY_REGS),
        .NUM_ECRS(NUM_ECRS),
        .ID_WIDTH(ID_WIDTH)
    ) u_alu (
        .clk(clk),
        .rst_n(rst_n),
        .in(in_alu),
        .out(out_alu)
    );

    sic_exec_mem #(
        .SIC_ID(SIC_ID),
        .NUM_PHY_REGS(NUM_PHY_REGS),
        .NUM_ECRS(NUM_ECRS),
        .ID_WIDTH(ID_WIDTH)
    ) u_mem (
        .clk(clk),
        .rst_n(rst_n),
        .in(in_mem),
        .out(out_mem)
    );

    sic_exec_imm #(
        .SIC_ID(SIC_ID),
        .NUM_PHY_REGS(NUM_PHY_REGS),
        .NUM_ECRS(NUM_ECRS),
        .ID_WIDTH(ID_WIDTH)
    ) u_imm (
        .clk(clk),
        .rst_n(rst_n),
        .in(in_imm),
        .out(out_imm)
    );

    sic_exec_jr #(
        .SIC_ID(SIC_ID),
        .NUM_PHY_REGS(NUM_PHY_REGS),
        .NUM_ECRS(NUM_ECRS),
        .ID_WIDTH(ID_WIDTH)
    ) u_jr (
        .clk(clk),
        .rst_n(rst_n),
        .in(in_jr),
        .out(out_jr)
    );

    sic_exec_syscall #(
        .SIC_ID(SIC_ID),
        .NUM_PHY_REGS(NUM_PHY_REGS),
        .NUM_ECRS(NUM_ECRS),
        .ID_WIDTH(ID_WIDTH)
    ) u_syscall (
        .clk(clk),
        .rst_n(rst_n),
        .in(in_syscall),
        .out(out_syscall)
    );

    // 顶层 req_instr：仅当所有子 SIC 均在等待指令时才请求
    assign req_instr = out_alu.req_instr & out_mem.req_instr & out_imm.req_instr & out_jr.req_instr &
                       out_syscall.req_instr;

    // 选择输出 bundle（当拍优先使用 sel_now）
    always_comb begin
        unique case (sel_now)
            SEL_ALU: out_sel = out_alu;
            SEL_MEM: out_sel = out_mem;
            SEL_JR: out_sel = out_jr;
            SEL_SYSCALL: out_sel = out_syscall;
            default: out_sel = out_imm;
        endcase
    end

    // PR 占用声明：以 packet_in.valid 的当拍为最高优先，其余周期使用 pkt_hold
    sic_packet_t pkt_adv;
    logic holding_adv;
    always_comb begin
        pkt_adv = packet_in.valid ? packet_in : pkt_hold;
        holding_adv = packet_in.valid ? 1'b1 : ~out_sel.req_instr;
    end

    // 输出 mux：当拍优先使用 sel_now，避免丢 PR 广告
    always_comb begin
        // default
        mem_rpl = out_sel.mem_rpl;
        mem_req = out_sel.mem_req;
        alu_rpl = out_sel.alu_rpl;
        alu_req = out_sel.alu_req;
        ecr_read_en = packet_in.valid | holding_exec;
        ecr_read_addr = packet_in.valid ? packet_in.dep_ecr_id[ECR_AW-1:0] :
                        holding_exec    ? pkt_hold.dep_ecr_id[ECR_AW-1:0] : '0;
        ecr_wen = out_sel.ecr_wen;
        ecr_write_addr = out_sel.ecr_write_addr;
        ecr_wdata = out_sel.ecr_wdata;
        pc_redirect_valid = out_sel.pc_redirect_valid;
        pc_redirect_pc = out_sel.pc_redirect_pc;
        pc_redirect_issue_id = out_sel.pc_redirect_issue_id;

        // RF：地址/占用由顶层统一声明，wcommit/wdata 由子 SIC 决定
        reg_req = '0;
        reg_req.rs_addr = (holding_adv && pkt_adv.info.read_rs) ? pkt_adv.phy_rs : '0;
        reg_req.rt_addr = (holding_adv && pkt_adv.info.read_rt) ? pkt_adv.phy_rt : '0;
        reg_req.waddr = (holding_adv && pkt_adv.info.write_gpr) ? pkt_adv.phy_dst : '0;
        reg_req.wdata = out_sel.reg_req.wdata;
        reg_req.wcommit = out_sel.reg_req.wcommit;
    end

    // 选择寄存：指令进入执行后保持 sel，不依赖 packet_in
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sel_r <= SEL_IMM;
            pkt_hold <= '0;
            holding_exec <= 1'b0;
        end else begin
            if (packet_in.valid) begin
                sel_r <= sel_now;
                pkt_hold <= packet_in;
                holding_exec <= 1'b1;
            end else if (req_instr) begin
                // 全部子 SIC 均在请求指令 => 当前无在飞指令
                sel_r <= SEL_IMM;
                holding_exec <= 1'b0;
            end
        end
    end

endmodule
