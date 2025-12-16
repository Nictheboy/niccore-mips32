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

// 1. 操作标志位结构体 (Control Flags)
typedef struct packed {
    logic alu_r;    // R-Type 算术 (addu, subu)
    logic ori;
    logic lui;
    logic lw;
    logic sw;
    logic beq;
    logic j;
    logic jal;
    logic jr;
    logic syscall;
} op_flags_t;

// 2. 解码信息结构体 (Decoded Fields & Immediates)
typedef struct packed {
    logic [4:0]  rs;
    logic [4:0]  rt;
    logic [4:0]  rd;
    logic [5:0]  funct;
    logic [15:0] imm16;
    logic [31:0] imm16_sign_ext;
    logic [31:0] imm16_zero_ext;
    logic [25:0] jump_target;
} decoded_info_t;

// =========================================================
// 模块定义
// =========================================================

module instruction_decoder (
    input  wire           [31:0] instr,
    output op_flags_t            op,        // 包含所有操作类型标志
    output decoded_info_t        info,      // 包含所有寄存器索引和立即数
    // === 额外输出：字段是否“有意义”（用于发射端重命名/调试）===
    output logic                 rs_valid,
    output logic                 rt_valid,
    output logic                 rd_valid
);

    // =========================================================
    // 基础解码
    // =========================================================
    wire [5:0] opcode = instr[31:26];
    wire [5:0] func_code = instr[5:0];
    wire       is_r_type = (opcode == 6'b000000);

    // =========================================================
    // 指令判定逻辑 (Internal Wires)
    // =========================================================

    // R-Type 具体功能判定
    wire       is_addu = is_r_type && (func_code == 6'h21);
    wire       is_subu = is_r_type && (func_code == 6'h23);
    wire       is_jr = is_r_type && (func_code == 6'h08);
    wire       is_syscall = is_r_type && (func_code == 6'h0c);

    // =========================================================
    // 结构体输出赋值: 操作标志 (Op Flags)
    // =========================================================
    assign op.alu_r   = is_addu | is_subu;
    assign op.jr      = is_jr;
    assign op.syscall = is_syscall;
    assign op.ori     = (opcode == 6'h0d);
    assign op.lui     = (opcode == 6'h0f);
    assign op_lw_int  = (opcode == 6'h23);  // 暂存用于内部判断
    assign op.lw      = op_lw_int;
    assign op_sw_int  = (opcode == 6'h2b);  // 暂存用于内部判断
    assign op.sw      = op_sw_int;
    assign op_beq_int = (opcode == 6'h04);  // 暂存用于内部判断
    assign op.beq     = op_beq_int;
    assign op_j_int   = (opcode == 6'h02);  // 暂存用于内部判断
    assign op.j       = op_j_int;
    assign op_jal_int = (opcode == 6'h03);  // 暂存用于内部判断
    assign op.jal     = op_jal_int;

    // 为了内部逻辑方便，定义一些局部 wire 对应结构体成员
    // (因为直接读取 output 端口在某些 Verilog 标准下受限，或者为了代码清晰)
    wire op_alu_r = op.alu_r;
    wire op_ori = op.ori;
    wire op_lui = op.lui;
    // 上面用了 intermediate wire 赋值给 op.xx，这里可以直接复用
    wire op_lw = op_lw_int;
    wire op_sw = op_sw_int;
    wire op_beq = op_beq_int;
    wire op_j = op_j_int;
    wire op_jal = op_jal_int;


    // =========================================================
    // 字段有效性掩码 (Validity Masks)
    // =========================================================

    // RS: op_alu_r, jr, ori, lw, sw, beq
    wire rs_valid_int = op_alu_r | op.jr | op_ori | op_lw | op_sw | op_beq;

    // RT: op_alu_r, ori, lw, sw, beq, lui (as destination)
    wire rt_valid_int = op_alu_r | op_ori | op_lw | op_sw | op_beq | op_lui;

    // RD: op_alu_r only
    wire rd_valid_int = op_alu_r;

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
    // 结构体输出赋值: 解码信息 (Decoded Info)
    // =========================================================

    assign info.rs    = rs_valid_int    ? instr[25:21] : 5'bx;
    assign info.rt    = rt_valid_int    ? instr[20:16] : 5'bx;
    assign info.rd    = rd_valid_int    ? instr[15:11] : 5'bx;
    assign info.funct = funct_valid ? instr[5:0]   : 6'bx;
    assign info.imm16 = imm_valid   ? instr[15:0]  : 16'bx;

    assign info.imm16_sign_ext = sext_valid ? {{16{instr[15]}}, instr[15:0]} : 32'bx;
    assign info.imm16_zero_ext = zext_valid ? {16'b0, instr[15:0]} : 32'bx;

    assign info.jump_target    = jtarget_valid ? instr[25:0] : 26'bx;

    // 输出字段有效性
    assign rs_valid = rs_valid_int;
    assign rt_valid = rt_valid_int;
    assign rd_valid = rd_valid_int;

endmodule
