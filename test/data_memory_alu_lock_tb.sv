`timescale 1ns / 1ps

module data_memory_alu_lock_tb;

    parameter int TB_PORTS = 4;
    parameter int TB_ID_W = 8;

    logic clk, rst_n;

    // === Memory 信号 ===
    logic [31:0] mem_addr    [TB_PORTS];
    logic        mem_req_r   [TB_PORTS];
    logic        mem_req_w   [TB_PORTS];
    logic [ 7:0] mem_id      [TB_PORTS];
    logic        mem_rel     [TB_PORTS];
    logic [31:0] mem_wdata   [TB_PORTS];
    logic [31:0] mem_rdata   [TB_PORTS];
    logic        mem_grant   [TB_PORTS];

    // === ALU Array 信号 ===
    logic [ 0:0] alu_id      [TB_PORTS];  // 假设 2 个 ALU (1 bit ID)
    logic        alu_req     [TB_PORTS];
    logic [ 7:0] alu_issue_id[TB_PORTS];
    logic        alu_rel     [TB_PORTS];
    logic [31:0] alu_op_a    [TB_PORTS];
    logic [31:0] alu_op_b    [TB_PORTS];
    logic [ 5:0] alu_code    [TB_PORTS];
    logic [31:0] alu_res     [TB_PORTS];
    logic        alu_grant   [TB_PORTS];

    // === 实例化 DUT ===

    // 1. Data Memory
    data_memory_with_lock #(
        .MEM_DEPTH(128),
        .NUM_PORTS(TB_PORTS),
        .ID_WIDTH (TB_ID_W)
    ) dut_mem (
        .clk(clk),
        .rst_n(rst_n),
        .addr(mem_addr),
        .req_read(mem_req_r),
        .req_write(mem_req_w),
        .req_issue_id(mem_id),
        .release_lock(mem_rel),
        .wdata(mem_wdata),
        .rdata(mem_rdata),
        .grant(mem_grant)
    );

    // 2. ALU Array
    alu_array_with_lock #(
        .NUM_ALUS (2),
        .NUM_PORTS(TB_PORTS),
        .ID_WIDTH (TB_ID_W)
    ) dut_alu (
        .clk(clk),
        .rst_n(rst_n),
        .sic_alu_id(alu_id),
        .sic_req(alu_req),
        .sic_issue_id(alu_issue_id),
        .sic_release(alu_rel),
        .sic_op_a(alu_op_a),
        .sic_op_b(alu_op_b),
        .sic_op_code(alu_code),
        .sic_res_out(alu_res),
        .sic_grant_out(alu_grant)
    );

    // 时钟
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // 初始化帮助函数
    task init_sigs();
        for (int i = 0; i < TB_PORTS; i++) begin
            mem_addr[i] = 0;
            mem_req_r[i] = 0;
            mem_req_w[i] = 0;
            mem_id[i] = 0;
            mem_rel[i] = 0;
            mem_wdata[i] = 0;

            alu_id[i] = 0;
            alu_req[i] = 0;
            alu_issue_id[i] = 0;
            alu_rel[i] = 0;
            alu_op_a[i] = 0;
            alu_op_b[i] = 0;
            alu_code[i] = 0;
        end
    endtask

    logic [3:0] grant_vec_mem;
    logic [3:0] grant_vec_alu;
    always_comb begin
        for (int i = 0; i < 4; i++) begin
            grant_vec_mem[i] = mem_grant[i];
            grant_vec_alu[i] = alu_grant[i];
        end
    end

    initial begin
        $timeformat(-9, 0, " ns", 10);
        init_sigs();
        rst_n = 0;
        #10 rst_n = 1;

        $display("=== TEST START ===");

        // --------------------------------------------------------
        // TEST 1: Memory Global Lock
        // SIC 0 (Write Addr 0x4, ID 100) vs SIC 1 (Write Addr 0x8, ID 50)
        // 即使地址不同，由于是全局锁，ID 50 应先获胜。
        // --------------------------------------------------------
        $display("[T=%0t] Memory Contention: SIC0(ID100) vs SIC1(ID50)", $time);
        mem_addr[0] = 32'h4;
        mem_req_w[0] = 1;
        mem_id[0] = 100;
        mem_wdata[0] = 32'hDEAD;
        mem_addr[1] = 32'h8;
        mem_req_w[1] = 1;
        mem_id[1] = 50;
        mem_wdata[1] = 32'hBEEF;

        #1;
        if (grant_vec_mem !== 4'b0010)
            $error("Mem Fail 1: Expected SIC1 win, got %b", grant_vec_mem);
        else $display("Mem Pass 1: SIC1 won lock.");

        #9;
        // 释放 SIC 1
        mem_rel[1] = 1;
        #10;
        mem_rel[1]   = 0;
        mem_req_w[1] = 0;

        #1;
        if (grant_vec_mem !== 4'b0001)
            $error("Mem Fail 2: Expected SIC0 win, got %b", grant_vec_mem);
        else $display("Mem Pass 2: SIC0 won lock.");

        // 写入并释放 SIC 0
        mem_rel[0] = 1;
        #10;
        init_sigs();  // Reset inputs

        // 验证写入结果 (Read)
        mem_addr[0] = 32'h8;
        mem_req_r[0] = 1;
        mem_id[0] = 10;
        #1;
        // 等待一个周期 (读是组合的，但 Grant 产生可能需要时间稳定，但在 Flash Grant 下是即时的)
        #5;
        if (mem_rdata[0] !== 32'hBEEF)
            $error("Mem Fail 3: Read mismatch. Exp BEEF, got %h", mem_rdata[0]);
        else $display("Mem Pass 3: Read verification success.");

        #5;
        init_sigs();

        // --------------------------------------------------------
        // TEST 2: ALU Array Mutex
        // SIC 0 req ALU 0 (ID 20)
        // SIC 1 req ALU 0 (ID 10) -> Should win
        // SIC 2 req ALU 1 (ID 30) -> Should win parallelly
        // --------------------------------------------------------
        $display("\n[T=%0t] ALU Array Test", $time);

        // Setup
        alu_id[0] = 0;
        alu_req[0] = 1;
        alu_issue_id[0] = 20;
        alu_op_a[0] = 1;
        alu_op_b[0] = 1;
        alu_code[0] = 6'h20;  // 1+1

        alu_id[1] = 0;
        alu_req[1] = 1;
        alu_issue_id[1] = 10;
        alu_op_a[1] = 2;
        alu_op_b[1] = 2;
        alu_code[1] = 6'h20;  // 2+2

        alu_id[2] = 1;
        alu_req[2] = 1;
        alu_issue_id[2] = 30;  // ALU 1 is free
        alu_op_a[2] = 10;
        alu_op_b[2] = 5;
        alu_code[2] = 6'h22;  // 10-5

        #1;
        // 预期: SIC 1 赢得 ALU 0, SIC 2 赢得 ALU 1. SIC 0 等待。
        // Grant Vec: 4'b0110 (SIC2=1, SIC1=1, SIC0=0)
        if (grant_vec_alu !== 4'b0110) $error("ALU Fail 1: Expected 0110, got %b", grant_vec_alu);
        else $display("ALU Pass 1: Correct Arbitration (Priority & Parallelism).");

        // 检查结果
        // SIC 1 Result should be 4
        // SIC 2 Result should be 5
        if (alu_res[1] !== 4) $error("ALU Calc Fail: SIC1 Res %d != 4", alu_res[1]);
        if (alu_res[2] !== 5) $error("ALU Calc Fail: SIC2 Res %d != 5", alu_res[2]);

        #9;
        // 释放 SIC 1 (ALU 0 Holder)
        alu_rel[1] = 1;
        #10;
        alu_rel[1] = 0;
        alu_req[1] = 0;

        #1;
        // 现在 SIC 0 应该获得 ALU 0
        if (grant_vec_alu[0] !== 1) $error("ALU Fail 2: SIC 0 did not get lock");
        if (alu_res[0] !== 2) $error("ALU Calc Fail: SIC0 Res %d != 2", alu_res[0]);
        else $display("ALU Pass 2: Handover success.");

        $display("=== ALL TESTS COMPLETED ===");
        $finish;
    end

endmodule
