/*
 * Instruction decoder
 *
 * Supported instructions:
 * - R-Type: addu, subu, jr, syscall
 * - I-Type: andi, ori, xori, addiu, slti, lw, sw, beq, bne, lui
 * - J-Type: j, jal
 */

`include "structs.svh"

function automatic opcode_t opcode_enum(input logic [5:0] raw, input logic [4:0] rt_field);
    opcode_t r;
    begin
        r = OPC_INVALID;
        unique case (raw)
            6'h00: r = OPC_SPECIAL;
            6'h04: r = OPC_BEQ;
            6'h05: r = OPC_BNE;
            6'h06: r = OPC_BLEZ;
            6'h07: r = OPC_BGTZ;
            6'h01: r = (rt_field == 5'd0) ? OPC_BLTZ : (rt_field == 5'd1) ? OPC_BGEZ : OPC_INVALID;
            6'h02: r = OPC_J;
            6'h03: r = OPC_JAL;
            6'h0c: r = OPC_ANDI;
            6'h0d: r = OPC_ORI;
            6'h0e: r = OPC_XORI;
            6'h08: r = OPC_ADDI;
            6'h09: r = OPC_ADDIU;
            6'h0a: r = OPC_SLTI;
            6'h0b: r = OPC_SLTIU;
            6'h0f: r = OPC_LUI;
            6'h20: r = OPC_LB;
            6'h21: r = OPC_LH;
            6'h23: r = OPC_LW;
            6'h2b: r = OPC_SW;
            6'h24: r = OPC_LBU;
            6'h25: r = OPC_LHU;
            6'h28: r = OPC_SB;
            6'h29: r = OPC_SH;
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
    assign opc = opcode_enum(opcode_raw, instr[20:16]);

    wire is_r_type = (opc == OPC_SPECIAL);

    // =========================================================
    // 指令判定逻辑 (Internal Wires)
    // =========================================================

    // R-Type 具体功能判定
    wire is_addu = is_r_type && (func_code == 6'h21);
    wire is_subu = is_r_type && (func_code == 6'h23);
    wire is_add = is_r_type && (func_code == 6'h20);
    wire is_sub = is_r_type && (func_code == 6'h22);
    wire is_and = is_r_type && (func_code == 6'h24);
    wire is_or = is_r_type && (func_code == 6'h25);
    wire is_xor = is_r_type && (func_code == 6'h26);
    wire is_nor = is_r_type && (func_code == 6'h27);
    wire is_sll = is_r_type && (func_code == 6'h00);
    wire is_srl = is_r_type && (func_code == 6'h02);
    wire is_sra = is_r_type && (func_code == 6'h03);
    wire is_sllv = is_r_type && (func_code == 6'h04);
    wire is_srlv = is_r_type && (func_code == 6'h06);
    wire is_srav = is_r_type && (func_code == 6'h07);
    wire is_slt = is_r_type && (func_code == 6'h2a);
    wire is_sltu = is_r_type && (func_code == 6'h2b);
    wire is_jr = is_r_type && (func_code == 6'h08);
    wire is_jalr = is_r_type && (func_code == 6'h09);
    wire is_syscall = is_r_type && (func_code == 6'h0c);
    wire is_mult = is_r_type && (func_code == 6'h18);
    wire is_multu = is_r_type && (func_code == 6'h19);
    wire is_div = is_r_type && (func_code == 6'h1a);
    wire is_divu = is_r_type && (func_code == 6'h1b);
    wire is_mfhi = is_r_type && (func_code == 6'h10);
    wire is_mthi = is_r_type && (func_code == 6'h11);
    wire is_mflo = is_r_type && (func_code == 6'h12);
    wire is_mtlo = is_r_type && (func_code == 6'h13);

    // I/J-Type 判定
    wire is_andi = (opc == OPC_ANDI);
    wire is_ori = (opc == OPC_ORI);
    wire is_xori = (opc == OPC_XORI);
    wire is_addi = (opc == OPC_ADDI);
    wire is_addiu = (opc == OPC_ADDIU);
    wire is_slti = (opc == OPC_SLTI);
    wire is_sltiu = (opc == OPC_SLTIU);
    wire is_lui = (opc == OPC_LUI);
    wire is_lb = (opc == OPC_LB);
    wire is_lh = (opc == OPC_LH);
    wire is_lw = (opc == OPC_LW);
    wire is_sw = (opc == OPC_SW);
    wire is_lbu = (opc == OPC_LBU);
    wire is_lhu = (opc == OPC_LHU);
    wire is_sb = (opc == OPC_SB);
    wire is_sh = (opc == OPC_SH);
    wire is_beq = (opc == OPC_BEQ);
    wire is_bne = (opc == OPC_BNE);
    wire is_blez = (opc == OPC_BLEZ);
    wire is_bgtz = (opc == OPC_BGTZ);
    wire is_bgez = (opc == OPC_BGEZ);
    wire is_bltz = (opc == OPC_BLTZ);
    wire is_j = (opc == OPC_J);
    wire is_jal = (opc == OPC_JAL);

    wire is_alu_r = is_addu | is_subu | is_add | is_sub | is_and | is_or | is_xor | is_nor |
                    is_sll | is_srl | is_sra | is_sllv | is_srlv | is_srav | is_slt | is_sltu;
    wire is_alu_i = is_andi | is_ori | is_xori | is_addi | is_addiu | is_slti | is_sltiu;
    wire is_muldiv = is_mult | is_multu | is_div | is_divu | is_mfhi | is_mthi | is_mflo | is_mtlo;

    // 写回选择
    wb_sel_t wb_sel_int;

    // 目的逻辑寄存器号（用于重命名/执行）
    wire write_gpr_int = is_alu_r | is_alu_i | is_lui | is_lb | is_lbu | is_lh | is_lhu | is_lw |
                         is_jal | is_jalr | is_mfhi | is_mflo;
    wire [4:0] dst_lr_int =
        is_alu_r ? instr[15:11] :
        is_mfhi  ? instr[15:11] :
        is_mflo  ? instr[15:11] :
        is_jal   ? 5'd31 :
        is_jalr  ? instr[15:11] :
        (is_alu_i | is_lui | is_lb | is_lbu | is_lh | is_lhu | is_lw) ? instr[20:16] :
        5'd0;

    // 目的字段类型（调试用）
    dst_field_t dst_field_int;
    always_comb begin
        dst_field_int = DST_NONE;
        if (is_alu_r || is_mfhi || is_mflo) dst_field_int = DST_RD;
        else if (is_alu_i || is_lui || is_lb || is_lbu || is_lh || is_lhu || is_lw)
            dst_field_int = DST_RT;
    end

    // 源寄存器读取需求
    wire is_shift_imm = is_sll | is_srl | is_sra;
    wire is_shift_var = is_sllv | is_srlv | is_srav;
    wire read_rs_int = (is_alu_r && !is_shift_imm && !is_shift_var) | is_shift_var | is_jr | is_jalr |
                       is_alu_i | is_lb | is_lbu | is_lh | is_lhu | is_lw | is_sw | is_sb | is_sh |
                       is_mult | is_multu | is_div | is_divu | is_mthi | is_mtlo |
                       is_beq | is_bne | is_blez | is_bgtz | is_bgez | is_bltz;
    wire read_rt_int = (is_alu_r && !is_shift_imm) | is_shift_imm | is_shift_var |
                       is_sw | is_sb | is_sh |
                       is_beq | is_bne | is_mult | is_multu | is_div | is_divu;

    // 资源/执行意图
    wire use_alu_int = is_alu_r | is_alu_i | is_beq | is_bne;
    wire mem_read_int = is_lb | is_lbu | is_lh | is_lhu | is_lw;
    wire mem_write_int = is_sw | is_sb | is_sh;
    wire write_ecr_int = is_beq | is_bne | is_blez | is_bgtz | is_bgez | is_bltz;

    // ALU 控制（use_alu_int=1 时有效）
    wire [5:0] alu_op_int = is_alu_r ? func_code : is_andi ? 6'h24 :  // AND
    is_ori ? 6'h25 :  // OR
    is_xori ? 6'h26 :  // XOR
    (is_addi | is_addiu) ? 6'h21 :
    is_slti ? 6'h2a :
    is_sltiu ? 6'h2b :
    (is_beq | is_bne) ? 6'h22 :  // SUB (check zero)
    6'h00;
    wire alu_b_is_imm_int = is_alu_i;
    wire alu_imm_is_zero_ext_int = is_andi | is_ori | is_xori;

    // 写回来源
    always_comb begin
        wb_sel_int = WB_NONE;
        if (mem_read_int) wb_sel_int = WB_MEM;
        else if (is_lui) wb_sel_int = WB_LUI;
        else if (is_jal || is_jalr) wb_sel_int = WB_LINK;
        else if (is_alu_r || is_alu_i || is_mfhi || is_mflo) wb_sel_int = WB_ALU;
    end

    // 控制流类型
    cf_kind_t cf_kind_int;
    always_comb begin
        cf_kind_int = CF_NONE;
        if (is_beq || is_bne || is_blez || is_bgtz || is_bgez || is_bltz) cf_kind_int = CF_BRANCH;
        else if (is_j || is_jal) cf_kind_int = CF_JUMP_IMM;
        else if (is_jr || is_jalr) cf_kind_int = CF_JUMP_REG;
    end


    // ---------------------------------------------------------
    // 输出
    // ---------------------------------------------------------

    assign info.opcode = opc;
    assign info.rs = is_syscall ? 5'd2 : instr[25:21];
    assign info.rt = is_syscall ? 5'd4 : instr[20:16];
    assign info.rd = instr[15:11];
    assign info.funct = instr[5:0];
    assign info.imm16 = instr[15:0];
    assign info.imm16_sign_ext = {{16{instr[15]}}, instr[15:0]};
    assign info.imm16_zero_ext = {16'b0, instr[15:0]};
    assign info.jump_target = instr[25:0];

    assign info.cf_kind = cf_kind_int;
    assign info.read_rs = read_rs_int | is_syscall;
    assign info.read_rt = read_rt_int | is_syscall;
    assign info.write_gpr = write_gpr_int;
    assign info.dst_lr = write_gpr_int ? dst_lr_int : 5'd0;
    assign info.dst_field = dst_field_int;

    assign info.use_alu = use_alu_int;
    assign info.alu_op = alu_op_int;
    assign info.alu_b_is_imm = alu_b_is_imm_int;
    assign info.alu_imm_is_zero_ext = alu_imm_is_zero_ext_int;

    assign info.mem_read = mem_read_int;
    assign info.mem_write = mem_write_int;
    assign info.use_muldiv = is_muldiv;
    assign info.muldiv_op           = is_mfhi  ? 3'd0 :
                                      is_mflo  ? 3'd1 :
                                      is_mthi  ? 3'd2 :
                                      is_mtlo  ? 3'd3 :
                                      is_mult  ? 3'd4 :
                                      is_multu ? 3'd5 :
                                      is_div   ? 3'd6 :
                                      is_divu  ? 3'd7 : 3'd0;
    assign info.muldiv_start = is_mult | is_multu | is_div | is_divu;
    assign info.write_ecr = write_ecr_int;

    assign info.is_syscall = is_syscall;
    assign info.wb_sel = wb_sel_int;

endmodule
