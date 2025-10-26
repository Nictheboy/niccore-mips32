/*
 * Description : Testbench for program_counter
 * Author      : Gemini
 * Create Date : 2025/10/26
 *
 */

`timescale 1ns / 1ps

module program_counter_tb;

    // --- Parameters ---
    localparam CLK_PERIOD = 10;  // 10ns clock period
    // 从DUT中获取复位地址的[31:2]部分
    localparam RESET_VAL_FULL = 32'h00003000;
    localparam RESET_VAL = RESET_VAL_FULL[31:2];  // 30'h00000C00

    // --- Signals ---
    // Inputs to DUT
    reg         reset;
    reg         clock;
    reg         jump_enable;
    reg  [31:2] jump_input;

    // Output from DUT
    wire [31:2] pc_value;

    // Testbench internal
    reg  [31:2] pc_value_expected;  // 期望的PC值
    wire        correct;  // 验证通过信号

    // --- Instantiate DUT ---
    program_counter uut (
        .reset      (reset),
        .clock      (clock),
        .jump_enable(jump_enable),
        .jump_input (jump_input),
        .pc_value   (pc_value)
    );

    // --- Verification Logic ---
    // 按照您的要求：如果DUT输出与期望值匹配，correct为1
    // 注意：在时间0，pc_value为X，pc_value_expected为X，所以 'correct' 也将为X。
    // 在第一个时钟沿(复位)之后，'correct' 应该始终为 1。
    assign correct = (pc_value == pc_value_expected);

    // --- Clock Generator ---
    always #((CLK_PERIOD) / 2) clock = ~clock;

    // --- Test Sequence ---
    initial begin
        // --- Setup (Dump waves and monitor) ---
        $dumpfile("program_counter_tb.vcd");
        $dumpvars(0, program_counter_tb);

        $monitor(
            "Time=%0t | reset=%b jump_en=%b | jump_in=%h | pc_value=%h | expected=%h | correct=%b",
            $time, reset, jump_enable, jump_input, pc_value, pc_value_expected, correct);

        // --- Test Cases ---

        // 1. 初始状态 (t=0)
        clock = 0;
        reset = 1;  // 准备在第一个时钟沿复位
        jump_enable = 0;
        jump_input = 30'hX;
        pc_value_expected = 30'hX;  // DUT的 'pc_value' 寄存器初始为X

        // 2. 测试复位 (t=5ns)
        @(posedge clock);  // 时钟上升沿 @ t=5ns
        // DUT更新: reset=1 -> pc_value 变为 RESET_VAL
        pc_value_expected = RESET_VAL;  // 更新期望值以匹配DUT
        #1;  // 等待1ns (t=6ns) 确保 'correct' 信号稳定为 1

        // 3. 释放复位, 测试 PC+1 (t=15ns)
        reset = 0;  // 在下一个时钟沿之前设置输入
        @(posedge clock);  // 时钟上升沿 @ t=15ns
        // DUT更新: reset=0, jump=0 -> pc_value 变为 pc_value + 1 (0xC00 + 1)
        pc_value_expected = RESET_VAL + 1;  // 0xC01
        #1;  // t=16ns

        // 4. 测试 PC+1 (t=25ns)
        @(posedge clock);  // 时钟上升沿 @ t=25ns
        // DUT更新: reset=0, jump=0 -> pc_value 变为 pc_value + 1 (0xC01 + 1)
        pc_value_expected = RESET_VAL + 2;  // 0xC02
        #1;  // t=26ns

        // 5. 测试跳转 (t=35ns)
        jump_enable = 1;
        jump_input  = 30'h1000F00D;
        @(posedge clock);  // 时钟上升沿 @ t=35ns
        // DUT更新: reset=0, jump=1 -> pc_value 变为 jump_input
        pc_value_expected = 30'h1000F00D;
        #1;  // t=36ns

        // 6. 测试跳转后 PC+1 (t=45ns)
        jump_enable = 0;  // 禁用跳转
        @(posedge clock);  // 时钟上升沿 @ t=45ns
        // DUT更新: reset=0, jump=0 -> pc_value 变为 pc_value + 1 (0x1000F00D + 1)
        pc_value_expected = 30'h1000F00D + 1;  // 0x1000F00E
        #1;  // t=46ns

        // 7. 测试复位优先于跳转 (t=55ns)
        reset = 1;  // 启用复位
        jump_enable = 1;  // 同时启用跳转 (应被复位覆盖)
        jump_input = 30'hDEADBEEF;  // 这个值应该被忽略
        @(posedge clock);  // 时钟上升沿 @ t=55ns
        // DUT更新: reset=1 -> pc_value 变为 RESET_VAL
        pc_value_expected = RESET_VAL;  // 0xC00
        #1;  // t=56ns

        // 8. 再次测试复位后 PC+1 (t=65ns)
        reset = 0;
        jump_enable = 0;
        @(posedge clock);  // 时钟上升沿 @ t=65ns
        // DUT更新: reset=0, jump=0 -> pc_value 变为 pc_value + 1 (0xC00 + 1)
        pc_value_expected = RESET_VAL + 1;  // 0xC01
        #1;  // t=66ns

        $display("--- Testbench Finished ---");
        $finish;
    end

endmodule
