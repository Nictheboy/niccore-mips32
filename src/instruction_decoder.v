/* 
 *  Description : Instruction decoder.
                  Only support the following instructions:
                  - R-Type: addu, subu, jr, syscall
                  - I-Type: ori, lw, sw, beq, lui
                  - J-Type: j, jal
 *  Author      : nictheboy <nictheboy@outlook.com>
 *  Create Date : 2025/11/30
 * 
 */

module instruction_decoder (
    input wire [31:0] instr,
    output wire op_alu_r,
    output wire op_ori,
    output wire op_lui,
    output wire op_lw,
    output wire op_sw,
    output wire op_beq,
    output wire op_j,
    output wire op_jal,
    output wire op_jr,
    output wire op_syscall,
    output wire [4:0] rs,
    output wire [4:0] rt,
    output wire [4:0] rd,
    output wire [5:0] funct,
    output wire [15:0] imm16,
    output wire [31:0] imm16_sign_ext,
    output wire [31:0] imm16_zero_ext,
    output wire [25:0] jump_target
);

    // =========================================================
    // 基础解码
    // =========================================================
    wire [5:0] opcode = instr[31:26];
    wire [5:0] func_code = instr[5:0];
    wire       is_r_type = (opcode == 6'b000000);

    // =========================================================
    // 指令判定逻辑
    // =========================================================

    // R-Type 具体功能判定
    wire       is_addu = is_r_type && (func_code == 6'h21);
    wire       is_subu = is_r_type && (func_code == 6'h23);
    wire       is_jr = is_r_type && (func_code == 6'h08);
    wire       is_syscall = is_r_type && (func_code == 6'h0c);

    // 标志赋值
    assign op_alu_r   = is_addu | is_subu;  // 合并 R-Type 算术指令
    assign op_jr      = is_jr;
    assign op_syscall = is_syscall;

    // I-Type / J-Type 判定
    assign op_ori     = (opcode == 6'h0d);
    assign op_lui     = (opcode == 6'h0f);
    assign op_lw      = (opcode == 6'h23);
    assign op_sw      = (opcode == 6'h2b);
    assign op_beq     = (opcode == 6'h04);
    assign op_j       = (opcode == 6'h02);  // Opcode for J
    assign op_jal     = (opcode == 6'h03);

    // =========================================================
    // 字段有效性掩码 (Validity Masks)
    // =========================================================

    // RS: op_alu_r, jr, ori, lw, sw, beq
    wire rs_valid = op_alu_r | op_jr | op_ori | op_lw | op_sw | op_beq;

    // RT: op_alu_r, ori, lw, sw, beq, lui (as destination)
    wire rt_valid = op_alu_r | op_ori | op_lw | op_sw | op_beq | op_lui;

    // RD: op_alu_r only
    wire rd_valid = op_alu_r;

    // Funct: R-Type only
    wire funct_valid = is_r_type;

    // Imm16: I-Type
    wire imm_valid = op_ori | op_lw | op_sw | op_beq | op_lui;

    // Sign Ext: lw, sw, beq
    wire sext_valid = op_lw | op_sw | op_beq;

    // Zero Ext: ori
    wire zext_valid = op_ori;

    // Jump Target: j, jal
    wire jtarget_valid = op_j | op_jal;

    // =========================================================
    // 输出赋值 (无效时输出 X)
    // =========================================================
    assign rs    = rs_valid ? instr[25:21] : 5'bx;
    assign rt    = rt_valid ? instr[20:16] : 5'bx;
    assign rd    = rd_valid ? instr[15:11] : 5'bx;
    assign funct = funct_valid ? instr[5:0] : 6'bx;
    assign imm16 = imm_valid ? instr[15:0] : 16'bx;

    assign imm16_sign_ext = sext_valid ? {{16{instr[15]}}, instr[15:0]} : 32'bx;
    assign imm16_zero_ext = zext_valid ? {16'b0, instr[15:0]} : 32'bx;

    assign jump_target = jtarget_valid ? instr[25:0] : 26'bx;

endmodule
