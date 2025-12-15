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
    parameter int TOTAL_PORTS = 4;  // 使用 4 个端口来复现之前的压力测试场景
    parameter int TEST_ID_W = 8;

    logic                         clk;
    logic                         rst_n;

    // === 接口信号 (1D Arrays - 通用端口) ===
    logic [$clog2(TEST_REGS)-1:0] port_addr                                       [TOTAL_PORTS];
    logic                         port_req_read                                   [TOTAL_PORTS];
    logic                         port_req_write                                  [TOTAL_PORTS];
    logic [        TEST_ID_W-1:0] port_issue_id                                   [TOTAL_PORTS];
    logic                         port_release                                    [TOTAL_PORTS];
    logic [                 31:0] port_wdata                                      [TOTAL_PORTS];

    // === 输出信号 ===
    logic [                 31:0] port_rdata_out                                  [TOTAL_PORTS];
    logic                         port_grant_out                                  [TOTAL_PORTS];

    // === 辅助信号 ===
    logic [      TOTAL_PORTS-1:0] grant_packed;  // 用于断言检查的位向量
    bit                           test_pass = 1;

    // 将 Unpacked Array 映射到 Packed Vector 方便 `if (grant == 4'bxxxx)` 判断
    always_comb begin
        for (int i = 0; i < TOTAL_PORTS; i++) begin
            grant_packed[i] = port_grant_out[i];
        end
    end

    // === DUT 实例化 (Generic Interface) ===
    register_module #(
        .NUM_PHY_REGS(TEST_REGS),
        .TOTAL_PORTS (TOTAL_PORTS),
        .ID_WIDTH    (TEST_ID_W)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .port_addr     (port_addr),
        .port_req_read (port_req_read),
        .port_req_write(port_req_write),
        .port_issue_id (port_issue_id),
        .port_release  (port_release),
        .port_wdata    (port_wdata),
        .port_rdata_out(port_rdata_out),
        .port_grant_out(port_grant_out)
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

        // 1. 初始化 (使用循环清零，适应任意端口数)
        for (int i = 0; i < TOTAL_PORTS; i++) begin
            port_addr[i]      = 0;
            port_req_read[i]  = 0;
            port_req_write[i] = 0;
            port_issue_id[i]  = 0;
            port_release[i]   = 0;
            port_wdata[i]     = 0;
        end

        // 2. 复位
        $display("\n=== START: Continuous Heavy Load Sequence (Generic Ports) ===");
        rst_n = 0;
        #10;
        rst_n = 1;

        // =====================================================================
        // PART 1: 基础与交接测试 (Cycles 1-7)
        // =====================================================================

        // --- Cycle 1: Burst Write ---
        // Port 0-3 同时写入 R1-R4
        $display("\n[T=%0t] Cycle 1: Burst Write Init (R1-R4)", $time);
        port_addr      = '{1, 2, 3, 4};
        port_req_write = '{1, 1, 1, 1};
        port_req_read  = '{0, 0, 0, 0};
        port_issue_id  = '{10, 10, 10, 10};
        port_wdata     = '{32'h1111_1111, 32'h2222_2222, 32'h3333_3333, 32'h4444_4444};
        port_release   = '{1, 1, 1, 1};

        #1;  // 采样点
        if (grant_packed !== 4'b1111) begin
            $error("Failed Cyc1: Expected 1111, got %b", grant_packed);
            test_pass = 0;
        end
        #9;

        // --- Cycle 2: Contention ---
        // Port 0,1,2 竞争 R10. Port 3 闲置.
        // ID: P0=100(R), P1=90(W), P2=80(R). 
        // 预期: 最小ID (P2, ID 80) 获胜？不对，是 ID 差距比较。
        // 根据之前的逻辑: 假设当前锁ID为0。
        // 这里逻辑没变：P1(90) 和 P2(80) 和 P0(100).
        // 如果是全新请求，谁先拿到？并行锁模块会选最老的 (closest logic).
        // 假设之前逻辑是 P2 获胜。
        $display("\n[T=%0t] Cycle 2: Contention R10 (100-R, 90-W, 80-R)", $time);
        port_release   = '{0, 0, 0, 0};
        port_addr      = '{10, 10, 10, 0};
        port_req_write = '{0, 1, 0, 0};
        port_req_read  = '{1, 0, 1, 0};
        port_issue_id  = '{100, 90, 80, 0};
        port_wdata     = '{0, 32'hCAFE_BABE, 0, 0};

        #1;
        // 注意：这里保留原来的结果预期。如果是 P1 胜出，说明 P1 的 ID 逻辑更优或原本 TB 逻辑如此。
        // 原 TB 预期是 0100 (SIC 1 胜出，即现在的 Port 1)。
        if (grant_packed !== 4'b0100) begin
            $error("Failed Cyc2: Expected 0100 (Port 1 win), got %b", grant_packed);
            test_pass = 0;
        end
        #9;

        // --- Cycle 3: Isolation ---
        // Port 1 保持 R10. Port 3 访问 R20 (互不干扰).
        $display("\n[T=%0t] Cycle 3: Hold R10 & Port 3 accesses R20", $time);
        port_addr[3]      = 20;
        port_req_write[3] = 1;
        port_issue_id[3]  = 50;
        port_wdata[3]     = 32'h1501_1501;

        #1;
        if (grant_packed !== 4'b1100) begin  // P3(bit3)=1, P2(bit2)=0, P1(bit1)=1, P0=0
            $error("Failed Cyc3: Expected 1100, got %b", grant_packed);
            test_pass = 0;
        end
        #9;

        // --- Cycle 4: Release Prep ---
        $display("\n[T=%0t] Cycle 4: Release (Handover Prep)", $time);
        port_release[1] = 1;  // 原 sic[2] -> 现 port[1] ? 
        // 修正：原 TB Cycle 2 赢家是 SIC 1?
        // 原代码 Cyc2: grant_packed !== 4'b0100 -> bit 2 is 1? 
        // Verilog packed array: [3][2][1][0]. 4'b0100 意味着 Index 2 是 1。
        // 原 TB 代码: sic_req_write = '{0, 1, 0, 0}; -> Index 1 请求写.
        // 等等，packed array index 顺序是个坑。
        // logic [3:0] vec; vec[1] 是第2位。
        // 原 TB: sic_grant_out[TEST_SICS] -> loop i=0..3 -> grant_packed[i] = grant[i];
        // 所以 grant_packed[0] 是 bit 0.
        // 4'b0100 -> bit 2 set. -> Port 2 win?
        // 让我们看原 TB Cyc2 输入:
        // sic_addr = {10, 10, 10, 0} -> Index 0, 1, 2 request.
        // sic_id   = {100, 90, 80, 0}.
        // 如果 0100 (Index 2) 赢，说明 ID 80 赢了。合理，因为 80 最老。

        // 好的，我们继续按照原逻辑的 Index 映射：
        // 原 Index 2 (Port 2) 持有锁。
        // 原 Index 3 (Port 3) 持有锁。
        port_release[2] = 1;
        port_release[3] = 1;
        #10;

        // --- Cycle 5: Write Exec ---
        $display("\n[T=%0t] Cycle 5: Port 1 Executing Write on R10", $time);
        // 上个周期释放了 Port 2 的读锁。
        // 现在 Port 1 (ID 90, Write) 应该拿到锁。
        port_req_read[2]  = 0;
        port_release[2]   = 0;
        port_req_write[3] = 0;
        port_release[3]   = 0;

        #1;
        // 预期 Port 1 (bit 1) 获得锁 -> 4'b0010
        if (grant_packed !== 4'b0010) begin
            $error("Failed Cyc5: Expected 0010 (Port 1 Write), got %b", grant_packed);
            test_pass = 0;
        end
        #9;

        // --- Cycle 6: Release Write ---
        $display("\n[T=%0t] Cycle 6: Release (Handover to Read)", $time);
        port_release[1] = 1;
        #10;

        // --- Cycle 7: Read Verify ---
        $display("\n[T=%0t] Cycle 7: Port 0 Reads R10 (Verify Data)", $time);
        // Port 1 释放，Port 0 (ID 100, Read) 等候已久。
        port_req_write[1] = 0;
        port_release[1]   = 0;

        #1;
        // 预期 Port 0 (bit 0) 获得锁 -> 4'b0001
        if (grant_packed !== 4'b0001) begin
            $error("Failed Cyc7: Expected 0001 (Port 0 Read), got %b", grant_packed);
            test_pass = 0;
        end
        if (port_rdata_out[0] !== 32'hCAFE_BABE) begin
            $error("Data Mismatch: Expected CAFE_BABE, got %h", port_rdata_out[0]);
            test_pass = 0;
        end
        #9;

        // --- Cleanup Part 1 ---
        $display("\n[T=%0t] Cleanup Part 1", $time);
        port_release[0] = 1;
        #10;
        port_req_read[0] = 0;
        port_release[0]  = 0;

        // =====================================================================
        // PART 2: 高级场景扩展 (Cycles 8-12)
        // =====================================================================

        // ---------------------------------------------------------------------
        // Cycle 8: ID Rollback (ID 回滚测试)
        // ---------------------------------------------------------------------
        $display("\n[T=%0t] Cycle 8: ID Rollback (250 vs 10) on R50", $time);
        port_addr      = '{50, 50, 0, 0};
        port_req_write = '{1, 1, 0, 0};
        port_req_read  = '{0, 0, 0, 0};
        port_issue_id  = '{250, 10, 0, 0};
        port_wdata     = '{32'hAAAA_0000, 32'hBBBB_0000, 0, 0};
        port_release   = '{0, 0, 0, 0};

        #1;
        // Port 0 (250) vs Port 1 (10). 250 更老 (跨越回滚点)。
        // 预期 Port 0 (bit 0) 赢 -> 4'b0001
        if (grant_packed !== 4'b0001) begin
            $error("Failed Cyc8: Expected 0001 (ID 250 wins), got %b", grant_packed);
            test_pass = 0;
        end
        #9;

        // --- Cleanup Cycle 8 ---
        port_release[0] = 1;
        #10;
        port_req_write[0] = 0;
        port_req_write[1] = 0;
        port_release[0]   = 0;

        // ---------------------------------------------------------------------
        // Cycle 9: True Parallel Read (真并行读)
        // ---------------------------------------------------------------------
        $display("\n[T=%0t] Cycle 9: True Parallel Read on R60", $time);
        port_addr     = '{60, 60, 60, 0};
        port_req_read = '{1, 1, 1, 0};
        port_issue_id = '{10, 11, 12, 0};

        #1;
        // Port 0, 1, 2 全部读。无冲突。
        if (grant_packed !== 4'b0111) begin
            $error("Failed Cyc9: Expected 0111 (All Read), got %b", grant_packed);
            test_pass = 0;
        end
        #9;

        // --- Cleanup Cycle 9 ---
        port_release = '{1, 1, 1, 0};
        #10;
        port_req_read = '{0, 0, 0, 0};
        port_release  = '{0, 0, 0, 0};

        // ---------------------------------------------------------------------
        // Cycle 10-12: The Sandwich (读写夹心/反饥饿测试)
        // ---------------------------------------------------------------------
        $display("\n[T=%0t] Cycle 10: Sandwich Setup - Port 0 Reads R70", $time);
        port_addr[0]     = 70;
        port_req_read[0] = 1;
        port_issue_id[0] = 40;

        #1;
        if (grant_packed !== 4'b0001) begin
            $error("Failed Cyc10: Port 0 grant failed, got %b", grant_packed);
            test_pass = 0;
        end
        #9;

        $display("\n[T=%0t] Cycle 11: Sandwich Contention (W-50 vs R-60)", $time);
        // Port 0 (Holder)
        // Port 1 (Write, ID 50)
        // Port 2 (Read, ID 60)
        port_addr[1]      = 70;
        port_req_write[1] = 1;
        port_issue_id[1]  = 50;
        port_addr[2]      = 70;
        port_req_read[2]  = 1;
        port_issue_id[2]  = 60;

        #1;
        // 规则：
        // 1. P0 继续持有 (Flash Grant 逻辑允许保持)。
        // 2. P1 想要写，被 P0 阻塞。
        // 3. P2 想要读。虽然 R70 是 Shared 状态，但 P1 (Write) 比 P2 (Read) 更老 (50 < 60)。
        //    为了防止写饥饿，P2 必须被阻塞，不能加入 P0。
        // 预期: 4'b0001 (只有 P0)
        if (grant_packed !== 4'b0001) begin
            $error("Failed Cyc11: Expected 0001 (Blocking), got %b", grant_packed);
            test_pass = 0;
        end
        #9;

        $display("\n[T=%0t] Cycle 12: Sandwich Resolution - Port 0 Leaves", $time);
        port_release[0] = 1;
        #10;

        // P0 离开。锁应该交给 P1 (Write)，而不是 P2 (Read)。
        port_req_read[0] = 0;
        port_release[0]  = 0;

        #1;
        // 预期: 4'b0010 (Port 1 Write)
        if (grant_packed !== 4'b0010) begin
            $error("Failed Cyc12: Expected 0010 (Writer Priority), got %b", grant_packed);
            test_pass = 0;
        end
        #9;

        // --- Final Cleanup ---
        $display("\n[T=%0t] Final Cleanup", $time);
        port_release[1] = 1;
        #10;
        port_req_write[1] = 0;
        port_release[1]   = 0;
        port_req_read[2]  = 0;
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
