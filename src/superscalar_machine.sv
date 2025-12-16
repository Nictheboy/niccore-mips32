(* dont_touch = "true" *)
module superscalar_machine (
    input logic clk,
    input logic rst_n
);

    // =========================================================
    // 参数定义
    // =========================================================
    localparam int NUM_SICS = 2;
    localparam int NUM_PHY_REGS = 64;
    localparam int NUM_ALUS = 4;
    localparam int NUM_ECRS = 2;  // 新增
    localparam int ID_WIDTH = 16;
    localparam int TOTAL_REG_PORTS = NUM_SICS * 3;

    // =========================================================
    // 互联信号定义
    // =========================================================

    // SIC <-> Issue Controller
    logic sic_req_instr[NUM_SICS];
    sic_packet_t sic_packets[NUM_SICS];
    // SIC -> Issue：ECR 依赖反馈
    logic sic_dep_ecr_active[NUM_SICS];
    logic [1:0] sic_dep_ecr_id[NUM_SICS];
    // SIC -> Issue：JR PC 重定向反馈
    logic sic_pc_redirect_valid[NUM_SICS];
    logic [31:0] sic_pc_redirect_pc[NUM_SICS];
    logic [ID_WIDTH-1:0] sic_pc_redirect_issue_id[NUM_SICS];
    logic [31:0] imem_addr;
    logic [NUM_SICS-1:0][31:0] imem_data;  // Packed Array
    logic [1:0] ecr_monitor[NUM_ECRS];
    logic rollback_sig;

    // Issue Controller -> ECR (Reset Port)
    logic issue_ecr_wen;
    logic [0:0] issue_ecr_waddr;
    logic [1:0] issue_ecr_wdata;  // 通常为 2'b00 (Busy)

    // SIC <-> Register Module (Flattened for Module Interface)
    logic [$clog2(NUM_PHY_REGS)-1:0] reg_addr_flat[TOTAL_REG_PORTS];
    logic reg_req_read_flat[TOTAL_REG_PORTS];
    logic reg_req_write_flat[TOTAL_REG_PORTS];
    logic reg_write_commit_flat[TOTAL_REG_PORTS];
    logic [ID_WIDTH-1:0] reg_issue_id_flat[TOTAL_REG_PORTS];
    logic reg_release_flat[TOTAL_REG_PORTS];
    logic [31:0] reg_wdata_flat[TOTAL_REG_PORTS];
    logic [31:0] reg_rdata_flat[TOTAL_REG_PORTS];
    logic reg_grant_flat[TOTAL_REG_PORTS];

    // SIC <-> ALU (Pool Interface)
    logic sic_alu_req[NUM_SICS];
    logic [ID_WIDTH-1:0] sic_alu_issue[NUM_SICS];
    logic sic_alu_rel[NUM_SICS];
    logic [31:0] sic_alu_opa[NUM_SICS];
    logic [31:0] sic_alu_opb[NUM_SICS];
    logic [5:0] sic_alu_code[NUM_SICS];
    logic [31:0] sic_alu_res[NUM_SICS];
    logic sic_alu_zero[NUM_SICS];
    logic sic_alu_over[NUM_SICS];
    logic sic_alu_grant[NUM_SICS];

    // SIC <-> Memory
    logic [31:0] mem_addr[NUM_SICS];
    logic mem_req_r[NUM_SICS];
    logic mem_req_w[NUM_SICS];
    logic [ID_WIDTH-1:0] mem_issue[NUM_SICS];
    logic mem_rel[NUM_SICS];
    logic [31:0] mem_wdata[NUM_SICS];
    logic mem_write_commit[NUM_SICS];
    logic [31:0] mem_rdata[NUM_SICS];
    logic mem_grant[NUM_SICS];

    // SIC <-> ECR File (Simplified Interface)
    // 注意：这里定义为 1D 数组，每个 SIC 只有一组读写信号
    logic [$clog2(NUM_ECRS)-1:0] sic_ecr_read_addr[NUM_SICS];
    logic [1:0] sic_ecr_read_data[NUM_SICS];  // 这是一个被驱动的 Wire
    logic sic_ecr_wen[NUM_SICS];
    logic [$clog2(NUM_ECRS)-1:0] sic_ecr_write_addr[NUM_SICS];
    logic [1:0] sic_ecr_wdata[NUM_SICS];

    // =========================================================
    // 模块实例化
    // =========================================================

    // 1. 指令内存
    instruction_memory #(
        .MEM_DEPTH(1024),
        .START_BYTE_ADDR(32'h0000_3000),
        .INIT_FILE("/home/nictheboy/Documents/niccore-mips32/test/mips1.txt"),
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
        .ID_WIDTH(ID_WIDTH),
        .BRANCH_PREDICTOR_TABLE_SIZE(64)
    ) issuer (
        .clk(clk),
        .rst_n(rst_n),
        .imem_addr(imem_addr),
        .imem_data(imem_data),
        .sic_req_instr(sic_req_instr),
        .sic_packet_out(sic_packets),
        .sic_dep_ecr_active(sic_dep_ecr_active),
        .sic_dep_ecr_id(sic_dep_ecr_id),
        .sic_pc_redirect_valid(sic_pc_redirect_valid),
        .sic_pc_redirect_pc(sic_pc_redirect_pc),
        .sic_pc_redirect_issue_id(sic_pc_redirect_issue_id),
        .ecr_states(ecr_monitor),
        .rollback_trigger(rollback_sig),
        // Issue Controller 在分配 ECR 时将其置为 Busy(00)
        .ecr_reset_wen(issue_ecr_wen),
        .ecr_reset_addr(issue_ecr_waddr),
        .ecr_reset_data(issue_ecr_wdata)
    );

    // 3. SIC 阵列
    genvar i;
    generate
        for (i = 0; i < NUM_SICS; i++) begin : sics
            // 临时 Reg 信号 (用于连接到 Flat 数组)
            logic [$clog2(NUM_PHY_REGS)-1:0] s_reg_addr        [3];
            logic                            s_reg_req_read    [3];
            logic                            s_reg_req_write   [3];
            logic                            s_reg_write_commit[3];
            logic [            ID_WIDTH-1:0] s_reg_issue_id    [3];
            logic                            s_reg_release     [3];
            logic [                    31:0] s_reg_wdata       [3];
            logic [                    31:0] s_reg_rdata       [3];
            logic                            s_reg_grant       [3];

            single_instruction_controller #(
                .SIC_ID(i),
                .NUM_PHY_REGS(NUM_PHY_REGS),
                .ID_WIDTH(ID_WIDTH)
            ) sic_core (
                .clk(clk),
                .rst_n(rst_n),
                .req_instr(sic_req_instr[i]),
                .packet_in(sic_packets[i]),

                // Reg Ports (Internal 3-port array)
                .reg_addr(s_reg_addr),
                .reg_req_read(s_reg_req_read),
                .reg_req_write(s_reg_req_write),
                .reg_write_commit(s_reg_write_commit),
                .reg_issue_id(s_reg_issue_id),
                .reg_release(s_reg_release),
                .reg_wdata(s_reg_wdata),
                .reg_rdata(s_reg_rdata),
                .reg_grant(s_reg_grant),

                // Mem Port
                .mem_addr(mem_addr[i]),
                .mem_req_read(mem_req_r[i]),
                .mem_req_write(mem_req_w[i]),
                .mem_issue_id(mem_issue[i]),
                .mem_release(mem_rel[i]),
                .mem_wdata(mem_wdata[i]),
                .mem_write_commit(mem_write_commit[i]),
                .mem_rdata(mem_rdata[i]),
                .mem_grant(mem_grant[i]),

                // ALU Port (Updated)
                .alu_req(sic_alu_req[i]),
                .alu_issue_id(sic_alu_issue[i]),
                .alu_release(sic_alu_rel[i]),
                .alu_op_a(sic_alu_opa[i]),
                .alu_op_b(sic_alu_opb[i]),
                .alu_opcode(sic_alu_code[i]),
                .alu_res(sic_alu_res[i]),
                .alu_zero(sic_alu_zero[i]),
                .alu_over(sic_alu_over[i]),
                .alu_grant(sic_alu_grant[i]),

                // ECR Port (Simplified)
                .ecr_read_addr(sic_ecr_read_addr[i]),
                .ecr_read_data(sic_ecr_read_data[i]),  // SIC 从这里读取，这是 Input

                .ecr_wen(sic_ecr_wen[i]),
                .ecr_write_addr(sic_ecr_write_addr[i]),
                .ecr_wdata(sic_ecr_wdata[i]),

                // BP Update
                .bp_update_en(),
                .bp_update_pc(),
                .bp_actual_taken(),

                // ECR Dep Feedback
                .dep_ecr_active(sic_dep_ecr_active[i]),
                .dep_ecr_id_out(sic_dep_ecr_id[i]),

                // JR Redirect Feedback
                .pc_redirect_valid(sic_pc_redirect_valid[i]),
                .pc_redirect_pc(sic_pc_redirect_pc[i]),
                .pc_redirect_issue_id(sic_pc_redirect_issue_id[i])
            );

            // 连接 Reg 信号到 Flat 数组
            always_comb begin
                for (int p = 0; p < 3; p++) begin
                    int idx = i * 3 + p;
                    reg_addr_flat[idx]         = s_reg_addr[p];
                    reg_req_read_flat[idx]     = s_reg_req_read[p];
                    reg_req_write_flat[idx]    = s_reg_req_write[p];
                    reg_write_commit_flat[idx] = s_reg_write_commit[p];
                    reg_issue_id_flat[idx]     = s_reg_issue_id[p];
                    reg_release_flat[idx]      = s_reg_release[p];
                    reg_wdata_flat[idx]        = s_reg_wdata[p];
                    s_reg_rdata[p]             = reg_rdata_flat[idx];
                    s_reg_grant[p]             = reg_grant_flat[idx];
                end
            end
        end
    endgenerate

    // 4. 全局寄存器模块
    register_module #(
        .NUM_PHY_REGS(NUM_PHY_REGS),
        .TOTAL_PORTS(TOTAL_REG_PORTS),
        .ID_WIDTH(ID_WIDTH)
    ) reg_file (
        .clk(clk),
        .rst_n(rst_n),
        .port_addr(reg_addr_flat),
        .port_req_read(reg_req_read_flat),
        .port_req_write(reg_req_write_flat),
        .port_write_commit(reg_write_commit_flat),
        .port_issue_id(reg_issue_id_flat),
        .port_release(reg_release_flat),
        .port_wdata(reg_wdata_flat),
        .port_rdata_out(reg_rdata_flat),
        .port_grant_out(reg_grant_flat)
    );

    // 5. 数据内存
    data_memory_with_lock #(
        .MEM_DEPTH(2048),
        .NUM_PORTS(NUM_SICS),
        .ID_WIDTH (ID_WIDTH)
    ) dmem (
        .clk(clk),
        .rst_n(rst_n),
        .addr(mem_addr),
        .req_read(mem_req_r),
        .req_write(mem_req_w),
        .req_issue_id(mem_issue),
        .release_lock(mem_rel),
        .write_commit(mem_write_commit),
        .wdata(mem_wdata),
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
        .sic_req(sic_alu_req),
        .sic_issue_id(sic_alu_issue),
        .sic_release(sic_alu_rel),
        .sic_op_a(sic_alu_opa),
        .sic_op_b(sic_alu_opb),
        .sic_op_code(sic_alu_code),
        .sic_res_out(sic_alu_res),
        .sic_zero_out(sic_alu_zero),
        .sic_over_out(sic_alu_over),
        .sic_grant_out(sic_alu_grant)
    );

    // 7. ECR File (简化版)
    // [修复关键]: sic_read_data 只能在这里被驱动 (Concurrent Assignment)
    // 确保代码中没有其他地方对 sic_ecr_read_data 进行赋值
    execution_condition_register_file #(
        .NUM_ECRS(NUM_ECRS),
        .NUM_SICS(NUM_SICS),
        .ID_WIDTH(ID_WIDTH)
    ) ecr_file (
        .clk(clk),
        .rst_n(rst_n),
        .sic_read_addr(sic_ecr_read_addr),
        .sic_read_data(sic_ecr_read_data),  // Output from module
        .sic_wen(sic_ecr_wen),
        .sic_write_addr(sic_ecr_write_addr),
        .sic_wdata(sic_ecr_wdata),

        // Issue Controller Reset/Busy 端口
        .issue_wen(issue_ecr_wen),
        .issue_write_addr(issue_ecr_waddr),
        .issue_wdata(issue_ecr_wdata),

        .monitor_states(ecr_monitor)
    );

endmodule
