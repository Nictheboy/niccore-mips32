module superscalar_machine_tb;
    reg reset, clock;
    superscalar_machine superscalar_machine (
        .rst_n(~reset),
        .clk  (clock)
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
        for (k = 0; k < 1000000; k = k + 1) begin
            clock = 1;
            #5;
            clock = 0;
            #5;
        end
        $display("CPU did not finish within 1000000 cycles. Test failed.");
        $finish;
    end
endmodule
