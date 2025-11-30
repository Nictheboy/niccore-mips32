/* 
 *  Description : A component that manages all the datapath
 *                in a single-cycle MIPS CPU.
 *  Author      : nictheboy <nictheboy@outlook.com>
 *  Create Date : 2025/11/30
 * 
 */

module single_cycle_datapath_controller (
    input [31:0] instruction,

    // Peer Module: Register File
    output reg [4:0] register_file_rs,  // for read
    output reg [4:0] register_file_rt,
    input [31:0] register_file_rs_data,
    input [31:0] register_file_rt_data,
    output reg register_file_write_enable,  // for write
    output reg [4:0] register_file_rd,
    output reg [31:0] register_file_write_data,

    // Peer Module: ALU
    output reg [31:0] alu_a,
    output reg [31:0] alu_b,
    output reg [5:0] alu_op,
    input [31:0] alu_c,

    // Peer Module: Data Memory
    output reg [31:2] data_memory_address,  // for read & write
    input [31:0] data_memory_read_result,  // for read
    output reg data_memory_write_enable,  // for write
    output reg [31:0] data_memory_write_input,

    // Peer Module: Program Counter
    input [31:2] program_counter_value,  // for read
    output reg program_counter_jump_enable,  // for write
    output reg [31:2] program_counter_jump_input
);
    // Submodule: Instruction Decoder
    wire instruction_decoder_op_alu_r;
    wire instruction_decoder_op_ori;
    wire instruction_decoder_op_lui;
    wire instruction_decoder_op_lw;
    wire instruction_decoder_op_sw;
    wire instruction_decoder_op_beq;
    wire instruction_decoder_op_j;
    wire instruction_decoder_op_jal;
    wire instruction_decoder_op_jr;
    wire instruction_decoder_op_syscall;
    wire [4:0] instruction_decoder_rs;
    wire [4:0] instruction_decoder_rt;
    wire [4:0] instruction_decoder_rd;
    wire [5:0] instruction_decoder_funct;
    wire [15:0] instruction_decoder_imm16;
    wire [31:0] instruction_decoder_imm16_sign_ext;
    wire [31:0] instruction_decoder_imm16_zero_ext;
    wire [25:0] instruction_decoder_jump_target;
    instruction_decoder instruction_decoder_1 (
        .instr(instruction),  // from input
        .op_alu_r(instruction_decoder_op_alu_r),
        .op_ori(instruction_decoder_op_ori),
        .op_lui(instruction_decoder_op_lui),
        .op_lw(instruction_decoder_op_lw),
        .op_sw(instruction_decoder_op_sw),
        .op_beq(instruction_decoder_op_beq),
        .op_j(instruction_decoder_op_j),
        .op_jal(instruction_decoder_op_jal),
        .op_jr(instruction_decoder_op_jr),
        .op_syscall(instruction_decoder_op_syscall),
        .rs(instruction_decoder_rs),
        .rt(instruction_decoder_rt),
        .rd(instruction_decoder_rd),
        .funct(instruction_decoder_funct),
        .imm16(instruction_decoder_imm16),
        .imm16_sign_ext(instruction_decoder_imm16_sign_ext),
        .imm16_zero_ext(instruction_decoder_imm16_zero_ext),
        .jump_target(instruction_decoder_jump_target)
    );

    always @(*) begin
        // --------------------------------------------------------------------
        // Step 1: 设置所有信号的默认值
        // --------------------------------------------------------------------
        register_file_rs = 5'bx;
        register_file_rt = 5'bx;
        register_file_rd = 5'bx;
        register_file_write_enable = 1'b0;
        register_file_write_data = 32'bx;

        alu_a = 32'bx;
        alu_b = 32'bx;
        alu_op = 6'bx;

        data_memory_address = 30'bx;
        data_memory_write_input = 32'bx;
        data_memory_write_enable = 1'b0;

        program_counter_jump_input = 30'bx;
        program_counter_jump_enable = 1'b0;

        // --------------------------------------------------------------------
        // Step 2: 按指令覆盖逻辑 (Override by Instruction)
        // --------------------------------------------------------------------

        // ============================
        // Group 1: ALU Operations
        // ============================

        // === ALU R-Type (addu, subu) ===
        if (instruction_decoder_op_alu_r) begin
            register_file_rs = instruction_decoder_rs;
            register_file_rt = instruction_decoder_rt;
            register_file_rd = instruction_decoder_rd;
            register_file_write_enable = 1'b1;

            alu_a = register_file_rs_data;
            alu_b = register_file_rt_data;
            alu_op = instruction_decoder_funct;  // 这里的 funct 直接对应 ALU 操作码

            register_file_write_data = alu_c;
        end else

        // === ORI (I-Type Logic) ===
        if (instruction_decoder_op_ori) begin
            register_file_rs           = instruction_decoder_rs;
            register_file_rt           = 5'bx;
            register_file_rd           = instruction_decoder_rt;
            register_file_write_enable = 1'b1;

            alu_a                      = register_file_rs_data;
            alu_b                      = instruction_decoder_imm16_zero_ext;
            alu_op                     = 6'd37;  // OR

            register_file_write_data   = alu_c;
        end else

        // === LUI (I-Type Load Upper) ===
        if (instruction_decoder_op_lui) begin
            register_file_rs           = 5'bx;
            register_file_rt           = 5'bx;
            register_file_rd           = instruction_decoder_rt;
            register_file_write_enable = 1'b1;

            alu_a                      = 32'bx;
            alu_b                      = 32'bx;
            alu_op                     = 6'bx;

            register_file_write_data   = {instruction_decoder_imm16, 16'b0};
        end else

        // ============================
        // Group 2: Memory Operations
        // ============================

        // === LW (Load Word) ===
        if (instruction_decoder_op_lw) begin
            register_file_rs           = instruction_decoder_rs;
            register_file_rt           = 5'bx;
            register_file_rd           = instruction_decoder_rt;
            register_file_write_enable = 1'b1;

            alu_a                      = register_file_rs_data;
            alu_b                      = instruction_decoder_imm16_sign_ext;
            alu_op                     = 6'd32;  // ADD

            data_memory_address        = alu_c[31:2];
            register_file_write_data   = data_memory_read_result;
        end else

        // === SW (Store Word) ===
        if (instruction_decoder_op_sw) begin
            register_file_rs         = instruction_decoder_rs;
            register_file_rt         = instruction_decoder_rt;

            alu_a                    = register_file_rs_data;
            alu_b                    = instruction_decoder_imm16_sign_ext;
            alu_op                   = 6'd32;  // ADD

            data_memory_address      = alu_c[31:2];
            data_memory_write_enable = 1'b1;
            data_memory_write_input  = register_file_rt_data;
        end else

        // ============================
        // Group 3: Branch & Jumps
        // ============================

        // === BEQ (Branch if Equal) ===
        if (instruction_decoder_op_beq) begin
            register_file_rs = instruction_decoder_rs;
            register_file_rt = instruction_decoder_rt;

            alu_a            = register_file_rs_data;
            alu_b            = register_file_rt_data;
            alu_op           = 6'd34;  // SUB

            if (alu_c == 32'b0) begin
                program_counter_jump_enable = 1'b1;
                program_counter_jump_input  = (program_counter_value + 1'b1) + instruction_decoder_imm16_sign_ext[29:0];
            end
        end else

        // === J (Jump) ===
        if (instruction_decoder_op_j) begin
            register_file_rs = 5'bx;
            register_file_rt = 5'bx;
            register_file_rd = 5'bx;
            register_file_write_enable = 1'b0;  // J 不写寄存器

            alu_a = 32'bx;
            alu_b = 32'bx;
            alu_op = 6'bx;

            program_counter_jump_enable = 1'b1;
            // Target: {PC+1[31:28], instr_index}
            program_counter_jump_input = {
                (program_counter_value + 1'b1) & 30'h3C000000, instruction_decoder_jump_target
            };
        end else

        // === JAL (Jump and Link) ===
        if (instruction_decoder_op_jal) begin
            register_file_rs = 5'bx;
            register_file_rt = 5'bx;
            register_file_rd = 5'd31;  // $ra
            register_file_write_enable = 1'b1;

            register_file_write_data = {(program_counter_value + 1'b1), 2'b00};

            alu_a = 32'bx;
            alu_b = 32'bx;
            alu_op = 6'bx;

            program_counter_jump_enable = 1'b1;
            program_counter_jump_input = {
                (program_counter_value + 1'b1) & 30'h3C000000, instruction_decoder_jump_target
            };
        end else

        // === JR (Jump Register) ===
        if (instruction_decoder_op_jr) begin
            register_file_rs            = instruction_decoder_rs;

            alu_a                       = 32'bx;
            alu_b                       = 32'bx;
            alu_op                      = 6'bx;

            program_counter_jump_enable = 1'b1;
            program_counter_jump_input  = register_file_rs_data[31:2];
        end else

        // ============================
        // Group 4: System
        // ============================

        // === Syscall ===
        if (instruction_decoder_op_syscall) begin
            $display("Syscall detected. Finishing simulation.");
            $finish;
        end else

        // === Error Handling ===
        begin
            register_file_write_enable  = 1'bx;
            data_memory_write_enable    = 1'bx;
            program_counter_jump_enable = 1'bx;
        end
    end
endmodule
