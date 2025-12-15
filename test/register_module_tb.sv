/*
 * Description :
 *
 * 寄存器堆模块系统级验证平台 (SystemVerilog Testbench)。
 * 
 * 本测试文件采用连续时间序列 (Continuous Time-Sequence) 的方式，
 * 在无中间复位的高负载环境下，对寄存器堆进行全方位的压力测试。
 * 
 * 测试覆盖场景 (Test Coverage)：
 * 1. 吞吐量测试：验证 N 个端口同时进行 Flash Write 的全速带宽。
 * 2. 冲突仲裁 (Contention)：验证多个端口竞争同一寄存器时，
 * 逻辑是否能正确根据 Issue ID 选出唯一的获胜者。
 * 3. 资源隔离 (Isolation)：验证对寄存器 A 的长时间占用不影响
 * 对寄存器 B 的并发访问。
 * 4. 无缝交接 (Handover)：验证锁从“持有者释放”到“新请求获准”
 * 之间是否存在流水线气泡或逻辑死锁。
 * 5. 读写夹心 (The Sandwich)：验证在 READING 状态下，较旧的写请求
 * 能否正确阻塞较新的读请求，防止写饥饿。
 * 6. 序号回滚 (Rollback)：验证 ID 环绕边界 (如 250 vs 10) 的
 * 比较逻辑正确性。
 * 7. 真并行读 (True Parallel Read)：验证无冲突下的多端口并发读取。
 * 
 * 技术特点：
 * - 使用 Unpacked Array 到 Packed Vector 的映射进行断言检查。
 * - 包含自检逻辑，自动统计错误计数并输出最终测试报告。
 * 
 * Author      : nictheboy <nictheboy@outlook.com>
 * Create Date : 2025/12/15
 * 
 */

`timescale 1ns / 1ps

module register_module_tb;

    // === 参数定义 ===
    parameter int TEST_REGS = 64;
    parameter int TEST_SICS = 4;
    parameter int TEST_ID_W = 8;

    logic                         clk;
    logic                         rst_n;

    // === 接口信号 (多维数组 - Unpacked Arrays) ===
    logic [$clog2(TEST_REGS)-1:0] sic_addr                             [TEST_SICS];
    logic                         sic_req_read                         [TEST_SICS];
    logic                         sic_req_write                        [TEST_SICS];
    logic [        TEST_ID_W-1:0] sic_issue_id                         [TEST_SICS];
    logic                         sic_release                          [TEST_SICS];
    logic [                 31:0] sic_wdata                            [TEST_SICS];

    logic [                 31:0] sic_rdata_out                        [TEST_SICS];
    logic                         sic_grant_out                        [TEST_SICS];

    // === 辅助信号 ===
    logic [        TEST_SICS-1:0] grant_packed;
    bit                           test_pass = 1;  // 测试状态标志

    // 将 Unpacked Array 映射到 Packed Vector
    always_comb begin
        for (int i = 0; i < TEST_SICS; i++) begin
            grant_packed[i] = sic_grant_out[i];
        end
    end

    // === DUT 实例化 ===
    register_module #(
        .NUM_PHY_REGS(TEST_REGS),
        .NUM_SICS    (TEST_SICS),
        .ID_WIDTH    (TEST_ID_W)
    ) dut (
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

    // === 时钟生成 ===
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // === 主测试流程 ===
    initial begin
        // 显示设置
        $timeformat(-9, 0, " ns", 10);

        // 1. 初始化
        sic_addr      = '{0, 0, 0, 0};
        sic_req_read  = '{0, 0, 0, 0};
        sic_req_write = '{0, 0, 0, 0};
        sic_issue_id  = '{0, 0, 0, 0};
        sic_release   = '{0, 0, 0, 0};
        sic_wdata     = '{0, 0, 0, 0};

        // 2. 复位
        $display("\n=== START: Continuous Heavy Load Sequence ===");
        rst_n = 0;
        #10;
        rst_n = 1;

        // =====================================================================
        // PART 1: 基础与交接测试 (Cycles 1-7)
        // =====================================================================

        // --- Cycle 1: Burst Write ---
        $display("\n[T=%0t] Cycle 1: Burst Write Init (R1-R4)", $time);
        sic_addr      = '{1, 2, 3, 4};
        sic_req_write = '{1, 1, 1, 1};
        sic_req_read  = '{0, 0, 0, 0};
        sic_issue_id  = '{10, 10, 10, 10};
        sic_wdata     = '{32'h1111_1111, 32'h2222_2222, 32'h3333_3333, 32'h4444_4444};
        sic_release   = '{1, 1, 1, 1};

        #1;
        if (grant_packed !== 4'b1111) begin
            $error("Failed Cyc1: Expected 1111, got %b", grant_packed);
            test_pass = 0;
        end
        #9;

        // --- Cycle 2: Contention ---
        $display("\n[T=%0t] Cycle 2: Contention R10 (100-R, 90-W, 80-R)", $time);
        sic_release   = '{0, 0, 0, 0};
        sic_addr      = '{10, 10, 10, 0};
        sic_req_write = '{0, 1, 0, 0};
        sic_req_read  = '{1, 0, 1, 0};
        sic_issue_id  = '{100, 90, 80, 0};
        sic_wdata     = '{0, 32'hCAFE_BABE, 0, 0};

        #1;
        if (grant_packed !== 4'b0100) begin
            $error("Failed Cyc2: Expected 0100 (SIC2 win), got %b", grant_packed);
            test_pass = 0;
        end
        #9;

        // --- Cycle 3: Isolation ---
        $display("\n[T=%0t] Cycle 3: Hold R10 & SIC 3 accesses R20", $time);
        sic_addr[3]      = 20;
        sic_req_write[3] = 1;
        sic_issue_id[3]  = 50;
        sic_wdata[3]     = 32'h1501_1501;

        #1;
        if (grant_packed !== 4'b1100) begin
            $error("Failed Cyc3: Expected 1100, got %b", grant_packed);
            test_pass = 0;
        end
        #9;

        // --- Cycle 4: Release Prep ---
        $display("\n[T=%0t] Cycle 4: Release (Handover Prep)", $time);
        sic_release[2] = 1;
        sic_release[3] = 1;
        #10;

        // --- Cycle 5: Write Exec ---
        $display("\n[T=%0t] Cycle 5: SIC 1 Executing Write on R10", $time);
        sic_req_read[2]  = 0;
        sic_release[2]   = 0;
        sic_req_write[3] = 0;
        sic_release[3]   = 0;

        #1;
        if (grant_packed !== 4'b0010) begin
            $error("Failed Cyc5: Expected 0010 (SIC1 Write), got %b", grant_packed);
            test_pass = 0;
        end
        #9;

        // --- Cycle 6: Release Write ---
        $display("\n[T=%0t] Cycle 6: Release (Handover to Read)", $time);
        sic_release[1] = 1;
        #10;

        // --- Cycle 7: Read Verify ---
        $display("\n[T=%0t] Cycle 7: SIC 0 Reads R10 (Verify Data)", $time);
        sic_req_write[1] = 0;
        sic_release[1]   = 0;

        #1;
        if (grant_packed !== 4'b0001) begin
            $error("Failed Cyc7: Expected 0001 (SIC0 Read), got %b", grant_packed);
            test_pass = 0;
        end
        if (sic_rdata_out[0] !== 32'hCAFE_BABE) begin
            $error("Data Mismatch: Expected CAFE_BABE, got %h", sic_rdata_out[0]);
            test_pass = 0;
        end
        #9;

        // --- Cleanup Part 1 ---
        $display("\n[T=%0t] Cleanup Part 1", $time);
        sic_release[0] = 1;
        #10;
        sic_req_read[0] = 0;
        sic_release[0]  = 0;

        // =====================================================================
        // PART 2: 高级场景扩展 (Cycles 8-12)
        // =====================================================================

        // ---------------------------------------------------------------------
        // Cycle 8: ID Rollback (ID 回滚测试)
        // 场景: Target R50. SIC 0 (Write, ID 250) vs SIC 1 (Write, ID 10)
        // 预期: 250 - 10 = 240 (在8位中视为负距离)，所以 250 更老，250 胜出。
        // ---------------------------------------------------------------------
        $display("\n[T=%0t] Cycle 8: ID Rollback (250 vs 10) on R50", $time);
        sic_addr      = '{50, 50, 0, 0};
        sic_req_write = '{1, 1, 0, 0};
        sic_req_read  = '{0, 0, 0, 0};
        sic_issue_id  = '{250, 10, 0, 0};
        sic_wdata     = '{32'hAAAA_0000, 32'hBBBB_0000, 0, 0};
        sic_release   = '{0, 0, 0, 0};

        #1;
        if (grant_packed !== 4'b0001) begin
            $error("Failed Cyc8: Expected 0001 (ID 250 wins), got %b", grant_packed);
            test_pass = 0;
        end
        #9;

        // --- Cleanup Cycle 8 ---
        sic_release[0] = 1;
        #10;
        sic_req_write[0] = 0;
        sic_req_write[1] = 0;  // SIC 1 还没拿到锁就撤销，模拟超时或Flush
        sic_release[0]   = 0;

        // ---------------------------------------------------------------------
        // Cycle 9: True Parallel Read (真并行读)
        // 场景: Target R60. SIC 0, 1, 2 全部申请 Read。
        // 预期: 所有人同时获得 Grant。
        // ---------------------------------------------------------------------
        $display("\n[T=%0t] Cycle 9: True Parallel Read on R60", $time);
        sic_addr     = '{60, 60, 60, 0};
        sic_req_read = '{1, 1, 1, 0};
        sic_issue_id = '{10, 11, 12, 0};

        #1;
        if (grant_packed !== 4'b0111) begin
            $error("Failed Cyc9: Expected 0111 (All Read), got %b", grant_packed);
            test_pass = 0;
        end
        #9;

        // --- Cleanup Cycle 9 ---
        sic_release = '{1, 1, 1, 0};
        #10;
        sic_req_read = '{0, 0, 0, 0};
        sic_release  = '{0, 0, 0, 0};

        // ---------------------------------------------------------------------
        // Cycle 10-12: The Sandwich (读写夹心/反饥饿测试)
        // 场景: R70.
        // Step 1 (Cycle 10): SIC 0 获得读锁。
        // Step 2 (Cycle 11): SIC 1 请求写(ID 50), SIC 2 请求读(ID 60).
        //        虽然 R70 是 Reading 状态，且 SIC 2 是 Read，但 SIC 1 更老。
        //        预期: SIC 0 继续持有，SIC 1 等待，SIC 2 必须被阻塞(不能插队)！
        // ---------------------------------------------------------------------
        $display("\n[T=%0t] Cycle 10: Sandwich Setup - SIC 0 Reads R70", $time);
        sic_addr[0]     = 70;
        sic_req_read[0] = 1;
        sic_issue_id[0] = 40;

        #1;
        if (grant_packed !== 4'b0001) begin
            $error("Failed Cyc10: SIC 0 grant failed, got %b", grant_packed);
            test_pass = 0;
        end
        #9;

        $display("\n[T=%0t] Cycle 11: Sandwich Contention (W-50 vs R-60)", $time);
        // SIC 0 保持
        sic_addr[1]      = 70;
        sic_req_write[1] = 1;
        sic_issue_id[1]  = 50;
        sic_addr[2]      = 70;
        sic_req_read[2]  = 1;
        sic_issue_id[2]  = 60;

        #1;
        // 预期: 只有 SIC 0 有 Grant (因为它是 Holder)。
        // SIC 1 被 SIC 0 阻塞。
        // SIC 2 被 SIC 1 阻塞 (关键点)。
        if (grant_packed !== 4'b0001) begin
            $error("Failed Cyc11: Expected 0001 (Blocking), got %b", grant_packed);
            test_pass = 0;
        end
        #9;

        $display("\n[T=%0t] Cycle 12: Sandwich Resolution - SIC 0 Leaves", $time);
        sic_release[0] = 1;
        #10;

        // 下个周期，锁应该交给 SIC 1 (Write)
        sic_req_read[0] = 0;
        sic_release[0]  = 0;

        #1;
        if (grant_packed !== 4'b0010) begin
            $error("Failed Cyc12: Expected 0010 (Writer Priority), got %b", grant_packed);
            test_pass = 0;
        end
        #9;

        // --- Final Cleanup ---
        $display("\n[T=%0t] Final Cleanup", $time);
        sic_release[1] = 1;  // Release Writer
        #10;
        sic_req_write[1] = 0;
        sic_release[1]   = 0;
        // SIC 2 gets grant now? Yes, but we stop here.
        sic_req_read[2]  = 0;  // SIC 2 timeouts
        #10;


        // =====================================================================
        // 最终结果判定
        // =====================================================================
        if (test_pass) begin
            $display("\n");
            $display("###########################################################");
            $display("##                                                       ##");
            $display("##             ALL TESTS PASSED SUCCESSFULLY             ##");
            $display("##                                                       ##");
            $display("###########################################################");
            $display("\n");
        end else begin
            $display("\n");
            $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
            $display("!!             TEST FAILED - CHECK ERROR LOG             !!");
            $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
            $display("\n");
        end

        $finish;
    end

endmodule
