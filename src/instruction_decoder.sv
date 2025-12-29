/*
 * Instruction decoder
 *
 * Supported instructions:
 * - R-Type: addu, subu, jr, syscall
 * - I-Type: andi, ori, xori, addiu, slti, lw, sw, beq, bne, lui
 * - J-Type: j, jal
 */

`include "structs.svh"

function automatic opcode_t opcode_enum(input logic [5:0] raw);
    opcode_t r;
    begin
        r = OPC_INVALID;
        unique case (raw)
            6'h00:   r = OPC_SPECIAL;
            6'h04:   r = OPC_BEQ;
            6'h05:   r = OPC_BNE;
            6'h02:   r = OPC_J;
            6'h03:   r = OPC_JAL;
            6'h0c:   r = OPC_ANDI;
            6'h0d:   r = OPC_ORI;
            6'h0e:   r = OPC_XORI;
            6'h09:   r = OPC_ADDIU;
            6'h0a:   r = OPC_SLTI;
            6'h0f:   r = OPC_LUI;
            6'h23:   r = OPC_LW;
            6'h2b:   r = OPC_SW;
            6'h24:   r = OPC_LBU;
            6'h28:   r = OPC_SB;
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

    // ---------------------------------------------------------
    // 基础字段
    // ---------------------------------------------------------
    wire [5:0] opcode_raw = instr[31:26];
    wire [5:0] func_code = instr[5:0];

    // opcode 解码：未知 opcode 统一归为 OPC_INVALID
    opcode_t opc;
    assign opc = opcode_enum(opcode_raw);

    wire is_r_type = (opc == OPC_SPECIAL);

    // =========================================================
    // 指令判定逻辑 (Internal Wires)
    // =========================================================

    // R-Type 具体功能判定
    wire is_addu = is_r_type && (func_code == 6'h21);
    wire is_subu = is_r_type && (func_code == 6'h23);
    wire is_or = is_r_type && (func_code == 6'h25);
    wire is_xor = is_r_type && (func_code == 6'h26);
    wire is_sll = is_r_type && (func_code == 6'h00);
    wire is_srl = is_r_type && (func_code == 6'h02);
    wire is_sltu = is_r_type && (func_code == 6'h2b);
    wire is_jr = is_r_type && (func_code == 6'h08);
    wire is_syscall = is_r_type && (func_code == 6'h0c);

    // I/J-Type 判定
    wire is_andi = (opc == OPC_ANDI);
    wire is_ori = (opc == OPC_ORI);
    wire is_xori = (opc == OPC_XORI);
    wire is_addiu = (opc == OPC_ADDIU);
    wire is_slti = (opc == OPC_SLTI);
    wire is_lui = (opc == OPC_LUI);
    wire is_lw = (opc == OPC_LW);
    wire is_sw = (opc == OPC_SW);
    wire is_lbu = (opc == OPC_LBU);
    wire is_sb = (opc == OPC_SB);
    wire is_beq = (opc == OPC_BEQ);
    wire is_bne = (opc == OPC_BNE);
    wire is_j = (opc == OPC_J);
    wire is_jal = (opc == OPC_JAL);

    wire is_alu_r = is_addu | is_subu | is_or | is_xor | is_sll | is_srl | is_sltu;
    wire is_alu_i = is_andi | is_ori | is_xori | is_addiu | is_slti;

    // 写回选择
    wb_sel_t wb_sel_int;

    // 目的逻辑寄存器号（用于重命名/执行）
    wire write_gpr_int = is_alu_r | is_alu_i | is_lui | is_lw | is_lbu | is_jal;
    wire [4:0] dst_lr_int =
        is_alu_r ? instr[15:11] :
        is_jal   ? 5'd31 :
        (is_alu_i | is_lui | is_lw | is_lbu) ? instr[20:16] :
        5'd0;

    // 目的字段类型（调试用）
    dst_field_t dst_field_int;
    always_comb begin
        dst_field_int = DST_NONE;
        if (is_alu_r) dst_field_int = DST_RD;
        else if (is_alu_i || is_lui || is_lw || is_lbu) dst_field_int = DST_RT;
    end

    // 源寄存器读取需求
    wire read_rs_int = (is_alu_r && !(is_sll | is_srl)) | is_jr | is_alu_i | is_lw | is_sw | is_lbu | is_sb |
                       is_beq | is_bne;
    wire read_rt_int = is_alu_r | is_sw | is_sb | is_beq | is_bne;

    // 资源/执行意图
    wire use_alu_int = is_alu_r | is_alu_i | is_beq | is_bne;
    wire mem_read_int = is_lw | is_lbu;
    wire mem_write_int = is_sw | is_sb;
    wire write_ecr_int = is_beq | is_bne;

    // ALU 控制（use_alu_int=1 时有效）
    wire [5:0] alu_op_int = is_alu_r ? func_code : is_andi ? 6'h24 :  // AND
    is_ori ? 6'h25 :  // OR
    is_xori ? 6'h26 :  // XOR
    is_addiu ? 6'h21 :  // ADDU (ignore overflow)
    is_slti ? 6'h2a :  // SLT (signed)
    (is_beq | is_bne) ? 6'h22 :  // SUB (check zero)
    6'h00;
    wire alu_b_is_imm_int = is_alu_i;
    wire alu_imm_is_zero_ext_int = is_andi | is_ori | is_xori;

    // 写回来源
    always_comb begin
        wb_sel_int = WB_NONE;
        if (is_lw || is_lbu) wb_sel_int = WB_MEM;
        else if (is_lui) wb_sel_int = WB_LUI;
        else if (is_jal) wb_sel_int = WB_LINK;
        else if (is_alu_r || is_alu_i) wb_sel_int = WB_ALU;
    end

    // 控制流类型
    cf_kind_t cf_kind_int;
    always_comb begin
        cf_kind_int = CF_NONE;
        if (is_beq || is_bne) cf_kind_int = CF_BRANCH;
        else if (is_j || is_jal) cf_kind_int = CF_JUMP_IMM;
        else if (is_jr) cf_kind_int = CF_JUMP_REG;
    end


    // ---------------------------------------------------------
    // 输出
    // ---------------------------------------------------------

    assign info.opcode              = opc;
    assign info.rs                  = is_syscall ? 5'd2 : instr[25:21];
    assign info.rt                  = is_syscall ? 5'd4 : instr[20:16];
    assign info.rd                  = instr[15:11];
    assign info.funct               = instr[5:0];
    assign info.imm16               = instr[15:0];
    assign info.imm16_sign_ext      = {{16{instr[15]}}, instr[15:0]};
    assign info.imm16_zero_ext      = {16'b0, instr[15:0]};
    assign info.jump_target         = instr[25:0];

    assign info.cf_kind             = cf_kind_int;
    assign info.read_rs             = read_rs_int | is_syscall;
    assign info.read_rt             = read_rt_int | is_syscall;
    assign info.write_gpr           = write_gpr_int;
    assign info.dst_lr              = write_gpr_int ? dst_lr_int : 5'd0;
    assign info.dst_field           = dst_field_int;

    assign info.use_alu             = use_alu_int;
    assign info.alu_op              = alu_op_int;
    assign info.alu_b_is_imm        = alu_b_is_imm_int;
    assign info.alu_imm_is_zero_ext = alu_imm_is_zero_ext_int;

    assign info.mem_read            = mem_read_int;
    assign info.mem_write           = mem_write_int;
    assign info.write_ecr           = write_ecr_int;

    assign info.is_syscall          = is_syscall;
    assign info.wb_sel              = wb_sel_int;

endmodule
