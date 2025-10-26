/*
 * Description : Testbench for data_memory.
 * Verifies write and read operations, reset, and invalid addressing.
 * Author      : Gemini (based on user request)
 * Create Date : 2025/10/26
 *
 */

`timescale 1ns / 1ps

module data_memory_tb;

    // --- Clock Generation ---
    localparam CLK_PERIOD = 10;  // 10ns clock period
    reg clock;
    initial begin
        clock = 0;
        forever #(CLK_PERIOD / 2) clock = ~clock;
    end

    // --- TB Signals ---
    reg         reset;
    reg  [31:0] address;  // DUT Input
    reg         write_enable;  // DUT Input
    reg  [31:0] write_input;  // DUT Input
    wire [31:0] read_result;  // DUT Output

    // --- Verification Logic ---
    reg  [31:0] read_result_expected;
    wire        correct;

    // 'correct' will be 1 if the read_result matches the expected result.
    // Using '===' to correctly compare 'x' states, since the DUT
    // outputs 'x' during writes and for invalid addresses.
    assign correct = (read_result === read_result_expected);

    // --- Instantiate the Design Under Test (DUT) ---
    data_memory uut (
        .reset(reset),
        .clock(clock),
        .address(address[31:2]),
        .write_enable(write_enable),
        .write_input(write_input),
        .read_result(read_result)
    );


    // --- Stimulus and Checking Block ---
    initial begin
        // $display("Time\tClock\tReset\tAddress\tWE\tWriteIn\t\tReadOut\t\tExpected\tCorrect");
        // $monitor("%dns\t%b\t%b\t%h\t%b\t%h\t%h\t%h\t%b",
        //          $time, clock, reset, address, write_enable, write_input, read_result, read_result_expected, correct);

        // 1. Initialize all inputs and apply reset
        @(negedge clock);
        reset = 1;
        address = 30'h0;
        write_enable = 0;
        write_input = 32'h0;

        @(posedge clock);
        read_result_expected = 32'hxxxxxxxx;  // DUT outputs 'x' during reset

        // Hold reset for one more cycle
        @(negedge clock);
        @(posedge clock);
        read_result_expected = 32'hxxxxxxxx;  // Still in reset

        // 2. De-assert reset and perform a read from address 0x08
        //    (valid_address 2). Should be 0 from reset.
        @(negedge clock);
        reset = 0;
        address = 30'h08;  // valid_address = address[11:2] = 2
        write_enable = 0;

        @(posedge clock);
        read_result_expected = 32'h00000000;  // Expect 0 after reset

        // 3. Write 0xAAAAAAAA to address 0x10 (valid_address 4)
        @(negedge clock);
        address = 30'h10;  // valid_address = 4
        write_enable = 1;
        write_input = 32'hAAAAAAAA;

        @(posedge clock);
        read_result_expected = 32'hxxxxxxxx;  // Expect 'x' during write

        // 4. Read back from address 0x10 (valid_address 4)
        @(negedge clock);
        address = 30'h10;
        write_enable = 0;
        // write_input remains 32'hAAAAAAAA, but doesn't matter

        @(posedge clock);
        read_result_expected = 32'hAAAAAAAA;  // Expect data we just wrote

        // 5. Write 0x12345678 to address 0xFFC (valid_address 1023)
        //    This is the maximum valid address (UNIT_COUNT - 1)
        @(negedge clock);
        address = 30'hFFC;  // valid_address = 0x3FF = 1023
        write_enable = 1;
        write_input = 32'h12345678;

        @(posedge clock);
        read_result_expected = 32'hxxxxxxxx;  // Expect 'x' during write

        // 6. Read back from address 0xFFC (valid_address 1023)
        @(negedge clock);
        address = 30'hFFC;
        write_enable = 0;

        @(posedge clock);
        read_result_expected = 32'h12345678;

        // 7. Read back from address 0x10 (valid_address 4) to check persistence
        @(negedge clock);
        address = 30'h10;
        write_enable = 0;

        @(posedge clock);
        read_result_expected = 32'hAAAAAAAA;

        // 8. Test invalid address (read).
        //    'address_is_valid' is false if address[31:12] are not all 0.
        //    Let's use address 0x1000.
        @(negedge clock);
        address = 30'h1000;  // address[12] = 1, so invalid
        write_enable = 0;

        @(posedge clock);
        read_result_expected = 32'hxxxxxxxx;  // Expect 'x' for invalid address

        // 9. Test invalid address (write).
        //    Write to 0x1008 (invalid), then read 0x0008 (valid) to
        //    ensure the write did not go to valid_address 2.
        @(negedge clock);
        address = 30'h1008;  // invalid, but valid_address would be 2
        write_enable = 1;
        write_input = 32'hDEADBEEF;

        @(posedge clock);
        read_result_expected = 32'hxxxxxxxx;  // Expect 'x' for invalid address

        // 10. Read from address 0x08 (valid_address 2).
        //     We expect 0 (from reset), not 0xDEADBEEF.
        @(negedge clock);
        address = 30'h08;
        write_enable = 0;

        @(posedge clock);
        read_result_expected = 32'h00000000;  // Should still be 0

        // 11. End simulation
        @(negedge clock);
        @(posedge clock);
        $display("Test finished. Observe the 'correct' signal in your waveform viewer.");
        $stop;
    end

endmodule
