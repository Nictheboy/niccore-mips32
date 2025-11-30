module mips_tb;
    reg reset, clock;
    single_cycle_machine single_cycle_machine (
        .reset(reset),
        .clock(clock)
    );

    integer k;
    initial begin
        reset = 1;
        clock = 0;
        #1;
        clock = 1;
        #1;
        clock = 0;
        #1;
        reset = 0;
        #1;
        for (k = 0; k < 100000; k = k + 1) begin
            clock = 1;
            #5;
            clock = 0;
            #5;
        end
        $display("CPU did not finish within 100000 cycles. Test failed.");
        $finish;
    end
endmodule
