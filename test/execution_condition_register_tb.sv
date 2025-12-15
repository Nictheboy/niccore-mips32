/*
 * Description : ECR 单元测试
 */
module execution_condition_register_tb;
    parameter int PORTS = 2;
    parameter int ID_W = 8;

    logic clk, rst_n;
    logic req_read[PORTS], req_write[PORTS], release_lock[PORTS];
    logic [ID_W-1:0] req_issue_id[PORTS];
    logic [1:0] wdata[PORTS];
    logic [1:0] rdata;
    logic grant[PORTS];

    execution_condition_register #(
        .NUM_PORTS(PORTS),
        .ID_WIDTH (ID_W)
    ) dut (
        .*
    );

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst_n = 0;
        req_read = '{0, 0};
        req_write = '{0, 0};
        release_lock = '{0, 0};
        #10 rst_n = 1;

        // 1. 端口0 (ID 10) 写入状态 2'b10 (Incorrect)
        // 模拟分支指令计算完毕更新状态
        $display("T=%0t: Port 0 Request Write Incorrect (ID 10)", $time);
        req_write[0] = 1;
        req_issue_id[0] = 10;
        wdata[0] = 2'b10;

        #1;  // Wait Flash Grant
        if (grant[0]) $display("  -> Grant Received");

        #9;  // Clock edge writes data
        req_write[0] = 0;
        release_lock[0] = 1;
        #10 release_lock[0] = 0;

        // 2. 端口1 (ID 15) 读取状态
        // 模拟后续指令检查依赖
        $display("T=%0t: Port 1 Request Read (ID 15)", $time);
        req_read[1] = 1;
        req_issue_id[1] = 15;

        #1;
        if (grant[1] && rdata == 2'b10) $display("  -> Read Success: State is Incorrect");
        else $error("  -> Read Failed or Wrong Data");

        #9;
        req_read[1] = 0;
        release_lock[1] = 1;
        #10;

        $finish;
    end
endmodule
