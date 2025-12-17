/*
 * Description :
 *
 * Instruction decoder with Packed Structs.
 * 
 * Only support the following instructions:
 * - R-Type: addu, subu, jr, syscall
 * - I-Type: ori, lw, sw, beq, lui
 * - J-Type: j, jal
 *
 * Author      : nictheboy <nictheboy@outlook.com>
 * Refactored  : 2025/12/15 (Packed into structs)
 */

`include "structs.svh"

function automatic opcode_t opcode_enum(input logic [5:0] raw);
    opcode_t r;
    begin
        r = OPC_INVALID;
        unique case (raw)
            6'h00:   r = OPC_SPECIAL;
            6'h04:   r = OPC_BEQ;
            6'h02:   r = OPC_J;
            6'h03:   r = OPC_JAL;
            6'h0d:   r = OPC_ORI;
            6'h0f:   r = OPC_LUI;
            6'h23:   r = OPC_LW;
            6'h2b:   r = OPC_SW;
            default: r = OPC_INVALID;
        endcase
        return r;
    end
endfunction

// =========================================================
// 模块定义
// =========================================================

module instruction_decoder (
    input  wire         [31:0] instr,
    output instr_info_t        info    // 包含 opcode/分支标志/寄存器索引/立即数
);

    // =========================================================
    // 基础解码
    // =========================================================
    wire [5:0] opcode_raw = instr[31:26];
    wire [5:0] func_code = instr[5:0];
    wire       is_r_type = (opcode_raw == 6'b000000);

    // =========================================================
    // 指令判定逻辑 (Internal Wires)
    // =========================================================

    // R-Type 具体功能判定
    wire       is_addu = is_r_type && (func_code == 6'h21);
    wire       is_subu = is_r_type && (func_code == 6'h23);
    wire       is_jr = is_r_type && (func_code == 6'h08);
    wire       is_syscall = is_r_type && (func_code == 6'h0c);

    // I/J-Type 判定
    wire       is_ori = (opcode_raw == 6'h0d);
    wire       is_lui = (opcode_raw == 6'h0f);
    wire       is_lw = (opcode_raw == 6'h23);
    wire       is_sw = (opcode_raw == 6'h2b);
    wire       is_beq = (opcode_raw == 6'h04);
    wire       is_j = (opcode_raw == 6'h02);
    wire       is_jal = (opcode_raw == 6'h03);

    wire       is_alu_r = is_addu | is_subu;


    // =========================================================
    // 字段有效性掩码 (Validity Masks)
    // =========================================================

    // RS: alu_r, jr, ori, lw, sw, beq
    wire       rs_valid_int = is_alu_r | is_jr | is_ori | is_lw | is_sw | is_beq;

    // RT: alu_r, ori, lw, sw, beq, lui (as destination)
    wire       rt_valid_int = is_alu_r | is_ori | is_lw | is_sw | is_beq | is_lui;

    // RD: op_alu_r only
    wire       rd_valid_int = is_alu_r;

    // Funct: R-Type only
    wire       funct_valid = is_r_type;

    // Imm16: I-Type
    wire       imm_valid = is_ori | is_lw | is_sw | is_beq | is_lui;

    // Sign Ext: lw, sw, beq
    wire       sext_valid = is_lw | is_sw | is_beq;

    // Zero Ext: ori
    wire       zext_valid = is_ori;

    // Jump Target: j, jal
    wire       jtarget_valid = is_j | is_jal;

    // =========================================================
    // 结构体输出赋值: 解码信息 (Decoded Info)
    // =========================================================

    assign info.opcode = opcode_enum(opcode_raw);
    assign info.is_branch = is_beq;
    assign info.rs_valid = rs_valid_int;
    assign info.rt_valid = rt_valid_int;
    assign info.rd_valid = rd_valid_int;

    assign info.rs    = rs_valid_int    ? instr[25:21] : 5'bx;
    assign info.rt    = rt_valid_int    ? instr[20:16] : 5'bx;
    assign info.rd    = rd_valid_int    ? instr[15:11] : 5'bx;
    assign info.funct = funct_valid ? instr[5:0]   : 6'bx;
    assign info.imm16 = imm_valid   ? instr[15:0]  : 16'bx;

    assign info.imm16_sign_ext = sext_valid ? {{16{instr[15]}}, instr[15:0]} : 32'bx;
    assign info.imm16_zero_ext = zext_valid ? {16'b0, instr[15:0]} : 32'bx;

    assign info.jump_target    = jtarget_valid ? instr[25:0] : 26'bx;

endmodule
