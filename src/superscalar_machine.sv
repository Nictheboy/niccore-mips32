
`include "structs.svh"

(* dont_touch = "true" *)
module superscalar_machine (
    input logic clk,
    input logic rst_n
);

    // =========================================================
    // 参数定义
    // =========================================================
    localparam int NUM_SICS = 8;
    localparam int NUM_PHY_REGS = 64;
    localparam int NUM_ALUS = 8;
    localparam int NUM_ECRS = 8;
    localparam int ID_WIDTH = 16;
    localparam int TOTAL_REG_PORTS = NUM_SICS * 3;
    localparam int ECR_ADDR_W = (NUM_ECRS > 1) ? $clog2(NUM_ECRS) : 1;
    localparam int BRANCH_PREDICTOR_TABLE_SIZE = 64;
    localparam int IMEM_DEPTH = 1024;
    localparam logic [31:0] IMEM_START_BYTE_ADDR = 32'h0000_3000;
    // localparam string IMEM_INIT_FILE = "/home/nictheboy/Documents/niccore-mips32/test/add-1.txt";
    // localparam string IMEM_INIT_FILE = "/home/nictheboy/Documents/niccore-mips32/test/add-2.txt";
    // localparam string IMEM_INIT_FILE = "/home/nictheboy/Documents/niccore-mips32/test/add-4.txt";
    // localparam string IMEM_INIT_FILE = "/home/nictheboy/Documents/niccore-mips32/test/add-8.txt";
    // localparam string IMEM_INIT_FILE = "/home/nictheboy/Documents/niccore-mips32/test/lfsr.txt";
    // localparam string IMEM_INIT_FILE = "/home/nictheboy/Documents/niccore-mips32/test/pointer-chasing.txt";
    localparam string IMEM_INIT_FILE = "/home/nictheboy/Documents/niccore-mips32/test/gcd-softmul.txt";
    localparam int DMEM_DEPTH = 2048;
    localparam int DMEM_NUM_BANKS = 4;

    // =========================================================
    // 互联信号定义
    // =========================================================

    // SIC <-> Issue Controller
    logic sic_req_instr[NUM_SICS];
    sic_packet #(NUM_PHY_REGS, ID_WIDTH, NUM_ECRS)::t sic_packets[NUM_SICS];
    // SIC -> Issue：ECR 依赖反馈
    logic sic_ecr_read_en[NUM_SICS];
    // SIC -> Issue：JR PC 重定向反馈
    logic sic_pc_redirect_valid[NUM_SICS];
    logic [31:0] sic_pc_redirect_pc[NUM_SICS];
    logic [ID_WIDTH-1:0] sic_pc_redirect_issue_id[NUM_SICS];
    logic [31:0] imem_addr;
    logic [NUM_SICS-1:0][31:0] imem_data;  // Packed Array
    logic [1:0] ecr_monitor[NUM_ECRS];
    logic rollback_sig;

    ecr_reset_for_issue #(NUM_ECRS)::t issue_ecr_update;
    logic [NUM_ECRS-1:0] ecr_in_use;

    // ECR -> BP：更新（由 ECR 产生）
    bp_update_t ecr_bp_update;

    // Issue Controller -> Register File allocate (new lifecycle pulse)
    logic rf_alloc_wen[NUM_SICS];
    logic [$clog2(NUM_PHY_REGS)-1:0] rf_alloc_pr[NUM_SICS];

    // Register File (packed) <-> SIC
    reg_req #(NUM_PHY_REGS)::t rf_req[NUM_SICS];
    reg_ans_t rf_ans[NUM_SICS];
    logic [NUM_PHY_REGS-1:0] rf_pr_not_idle;
    pr_state_t rf_pr_state[NUM_PHY_REGS];

    // SIC <-> ALU (Pool Interface)
    rpl_req #(ID_WIDTH)::t alu_rpl[NUM_SICS];
    alu_req_t sic_alu_req[NUM_SICS];
    alu_ans_t sic_alu_ans[NUM_SICS];
    logic sic_alu_grant[NUM_SICS];

    // SIC <-> Memory (packed)
    rpl_req #(ID_WIDTH)::t mem_rpl[NUM_SICS];
    mem_req_t mem_req[NUM_SICS];
    logic [31:0] mem_rdata[NUM_SICS];
    logic mem_grant[NUM_SICS];

    // SIC <-> ECR File (Simplified Interface)
    // 注意：这里定义为 1D 数组，每个 SIC 只有一组读写信号
    logic [ECR_ADDR_W-1:0] sic_ecr_read_addr[NUM_SICS];
    logic [1:0] sic_ecr_read_data[NUM_SICS];  // 这是一个被驱动的 Wire
    logic sic_ecr_wen[NUM_SICS];
    logic [ECR_ADDR_W-1:0] sic_ecr_write_addr[NUM_SICS];
    logic [1:0] sic_ecr_wdata[NUM_SICS];

    // =========================================================
    // 模块实例化
    // =========================================================

    // 1. 指令内存
    instruction_memory #(
        .MEM_DEPTH(IMEM_DEPTH),
        .START_BYTE_ADDR(IMEM_START_BYTE_ADDR),
        .INIT_FILE(IMEM_INIT_FILE),
        .FETCH_WIDTH(NUM_SICS)
    ) imem (
        .reset(~rst_n),
        .clock(clk),
        .address(imem_addr),
        .instruction(imem_data)
    );

    // 2. 发射控制器
    issue_controller #(
        .NUM_SICS(NUM_SICS),
        .NUM_PHY_REGS(NUM_PHY_REGS),
        .NUM_ECRS(NUM_ECRS),
        .ID_WIDTH(ID_WIDTH),
        .BRANCH_PREDICTOR_TABLE_SIZE(BRANCH_PREDICTOR_TABLE_SIZE)
    ) issuer (
        .clk(clk),
        .rst_n(rst_n),
        .imem_addr(imem_addr),
        .imem_data(imem_data),
        .sic_req_instr(sic_req_instr),
        .sic_packet_out(sic_packets),
        .sic_pc_redirect_valid(sic_pc_redirect_valid),
        .sic_pc_redirect_pc(sic_pc_redirect_pc),
        .sic_pc_redirect_issue_id(sic_pc_redirect_issue_id),
        .rollback_trigger(rollback_sig),
        .ecr_monitor(ecr_monitor),
        .ecr_in_use(ecr_in_use),
        .ecr_update(issue_ecr_update),
        .bp_update(ecr_bp_update),
        // Register File allocate pulse
        .rf_alloc_wen(rf_alloc_wen),
        .rf_alloc_pr(rf_alloc_pr),
        // Register File usage bitmap
        .pr_not_idle(rf_pr_not_idle)
    );

    // 3. SIC 阵列
    genvar i;
    generate
        for (i = 0; i < NUM_SICS; i++) begin : sics
            single_instruction_controller #(
                .SIC_ID(i),
                .NUM_PHY_REGS(NUM_PHY_REGS),
                .NUM_ECRS(NUM_ECRS),
                .ID_WIDTH(ID_WIDTH)
            ) sic_core (
                .clk(clk),
                .rst_n(rst_n),
                .req_instr(sic_req_instr[i]),
                .packet_in(sic_packets[i]),

                // Reg (packed)
                .reg_req(rf_req[i]),
                .reg_ans(rf_ans[i]),

                // Mem Port
                .mem_rpl  (mem_rpl[i]),
                .mem_req  (mem_req[i]),
                .mem_rdata(mem_rdata[i]),
                .mem_grant(mem_grant[i]),

                // ALU Port (Updated)
                .alu_rpl  (alu_rpl[i]),
                .alu_req  (sic_alu_req[i]),
                .alu_ans  (sic_alu_ans[i]),
                .alu_grant(sic_alu_grant[i]),

                // ECR Port (Simplified)
                .ecr_read_addr(sic_ecr_read_addr[i]),
                .ecr_read_data(sic_ecr_read_data[i]),  // SIC 从这里读取，这是 Input

                .ecr_wen(sic_ecr_wen[i]),
                .ecr_write_addr(sic_ecr_write_addr[i]),
                .ecr_wdata(sic_ecr_wdata[i]),

                // BP Update
                // BP Update：已迁移到 ECR 内部（无需 SIC 直接驱动）

                // ECR Dep Feedback
                .ecr_read_en(sic_ecr_read_en[i]),

                // JR Redirect Feedback
                .pc_redirect_valid(sic_pc_redirect_valid[i]),
                .pc_redirect_pc(sic_pc_redirect_pc[i]),
                .pc_redirect_issue_id(sic_pc_redirect_issue_id[i])
            );
        end
    endgenerate

    // 4. 无锁寄存器文件（生命周期：issue alloc -> commit write -> reads）
    register_file #(
        .NUM_PHY_REGS(NUM_PHY_REGS),
        .NUM_SICS    (NUM_SICS)
    ) reg_file (
        .clk        (clk),
        .rst_n      (rst_n),
        .alloc_wen  (rf_alloc_wen),
        .alloc_pr   (rf_alloc_pr),
        .reg_req    (rf_req),
        .reg_ans    (rf_ans),
        .pr_not_idle(rf_pr_not_idle),
        .pr_state   (rf_pr_state)
    );

    // 5. 数据内存
    data_memory_with_lock #(
        .MEM_DEPTH(DMEM_DEPTH),
        .NUM_BANKS(DMEM_NUM_BANKS),
        .NUM_PORTS(NUM_SICS),
        .ID_WIDTH (ID_WIDTH)
    ) dmem (
        .clk(clk),
        .rst_n(rst_n),
        .rpl_req(mem_rpl),
        .mem_req(mem_req),
        .rdata(mem_rdata),
        .grant(mem_grant)
    );

    // 6. ALU 资源池
    alu_array_with_lock #(
        .NUM_ALUS (NUM_ALUS),
        .NUM_PORTS(NUM_SICS),
        .ID_WIDTH (ID_WIDTH)
    ) alu_pool (
        .clk(clk),
        .rst_n(rst_n),
        .sic_rpl(alu_rpl),
        .sic_alu_req(sic_alu_req),
        .sic_alu_ans(sic_alu_ans),
        .sic_grant_out(sic_alu_grant)
    );

    // 7. ECR File (简化版)
    // [修复关键]: sic_read_data 只能在这里被驱动 (Concurrent Assignment)
    // 确保代码中没有其他地方对 sic_ecr_read_data 进行赋值
    execution_condition_register_file #(
        .NUM_ECRS(NUM_ECRS),
        .NUM_SICS(NUM_SICS)
    ) ecr_file (
        .clk(clk),
        .rst_n(rst_n),
        .sic_read_en(sic_ecr_read_en),
        .sic_read_addr(sic_ecr_read_addr),
        .sic_read_data(sic_ecr_read_data),  // Output from module
        .sic_wen(sic_ecr_wen),
        .sic_write_addr(sic_ecr_write_addr),
        .sic_wdata(sic_ecr_wdata),
        .issue_update(issue_ecr_update),
        .bp_update(ecr_bp_update),
        .in_use(ecr_in_use),
        .monitor_states(ecr_monitor)
    );

endmodule
