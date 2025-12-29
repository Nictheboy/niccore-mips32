// =========================================================
// Global shared types
// =========================================================
// 约定：
// - 跨模块复用的类型统一放在这里
// - class 仅用于封装 typedef struct packed（便于参数化）

`ifndef STRUCTS_SVH
`define STRUCTS_SVH

// -----------------------------
// Resource Pool Lock request bundle
// -----------------------------
class rpl_req #(
    parameter int ID_WIDTH = 1
);
    typedef struct packed {
        logic                req;
        logic [ID_WIDTH-1:0] req_issue_id;
        logic                release_lock;
    } t;
endclass

// -----------------------------
// MIPS opcode enum
// -----------------------------
typedef enum logic [5:0] {
    OPC_INVALID,
    OPC_SPECIAL,
    OPC_BEQ,
    OPC_BNE,
    OPC_J,
    OPC_JAL,
    OPC_ANDI,
    OPC_ORI,
    OPC_XORI,
    OPC_ADDIU,
    OPC_SLTI,
    OPC_LUI,
    OPC_LW,
    OPC_SW,
    OPC_LBU,
    OPC_SB
} opcode_t;

// -----------------------------
// Writeback select
// -----------------------------
typedef enum logic [2:0] {
    WB_NONE,  // no GPR writeback
    WB_ALU,   // write alu result
    WB_LUI,   // write {imm16, 16'b0}
    WB_LINK,  // write PC+4
    WB_MEM    // write memory read data
} wb_sel_t;

// -----------------------------
// Control-flow kind
// -----------------------------
typedef enum logic [1:0] {
    CF_NONE,      // not a control-flow instruction
    CF_BRANCH,    // conditional branch (BEQ)
    CF_JUMP_IMM,  // jump by immediate target (J/JAL)
    CF_JUMP_REG   // jump by register (JR)
} cf_kind_t;

// -----------------------------
// Destination field kind (optional debug)
// -----------------------------
typedef enum logic [1:0] {
    DST_NONE,  // no architectural dst field
    DST_RT,    // dst is RT field (I-type writes)
    DST_RD     // dst is RD field (R-type writes)
} dst_field_t;

// -----------------------------
// Decoded instruction info
// - 字段 rs/rt/rd/funct/imm/jtarget 为原始提取
// - 其余为执行意图（读写/资源/写回/控制流）
// -----------------------------
typedef struct packed {
    opcode_t     opcode;          // 指令 opcode（枚举）
    logic [4:0]  rs;
    logic [4:0]  rt;
    logic [4:0]  rd;
    logic [5:0]  funct;
    logic [15:0] imm16;
    logic [31:0] imm16_sign_ext;
    logic [31:0] imm16_zero_ext;
    logic [25:0] jump_target;

    // 执行意图
    cf_kind_t   cf_kind;
    logic       read_rs;    // needs RS read value
    logic       read_rt;    // needs RT read value
    logic       write_gpr;  // will commit a GPR write
    logic [4:0] dst_lr;     // destination logical register (valid iff write_gpr)
    dst_field_t dst_field;  // dst 来自 rt/rd（可选调试用）

    // ALU usage (only for alu_r/ori/beq in current core)
    logic       use_alu;
    logic [5:0] alu_op;
    logic       alu_b_is_imm;
    logic       alu_imm_is_zero_ext;

    // Memory usage
    logic mem_read;
    logic mem_write;

    // Branch metadata
    logic write_ecr;  // BEQ updates ECR

    // System
    logic is_syscall;

    // Writeback source
    wb_sel_t wb_sel;
} instr_info_t;

// -----------------------------
// SIC packet (issue -> execute)
// -----------------------------
class sic_packet #(
    parameter int NUM_PHY_REGS,
    parameter int ID_WIDTH,
    parameter int NUM_ECRS
);
    localparam int PR_W  = (NUM_PHY_REGS > 1) ? $clog2(NUM_PHY_REGS) : 1;
    localparam int ECR_W = (NUM_ECRS > 1) ? $clog2(NUM_ECRS) : 1;

typedef struct packed {
    logic        valid;         // 指令有效位
    logic [31:0] pc;            // 当前指令 PC
    logic [31:0] next_pc_pred;  // 预测的下一条 PC (用于 JAL/Branch)

    // 锁与排序
    logic [ID_WIDTH-1:0] issue_id;

    // 解码信息
    instr_info_t info;

    // 寄存器重命名结果 (物理寄存器号)
        logic [PR_W-1:0] phy_rs;
        logic [PR_W-1:0] phy_rt;
        logic [PR_W-1:0] phy_rd;
        logic [PR_W-1:0] phy_dst;

    // 分支预测与 ECR
        logic          pred_taken;
        logic [ECR_W-1:0] dep_ecr_id;
        logic [ECR_W-1:0] set_ecr_id;
    } t;
endclass

// -----------------------------
// Data memory request bundle (to data_memory)
// -----------------------------
typedef struct packed {
    logic [31:2] addr;   // word address (same as old data_memory.address)
    logic        wen;    // write enable (same as old data_memory.write_enable)
    logic [31:0] wdata;  // write data   (same as old data_memory.write_input)
} mem_req_t;

// -----------------------------
// ALU request/answer bundle
// -----------------------------
typedef struct packed {
    logic [31:0] a;
    logic [31:0] b;
    logic [5:0]  op;
} alu_req_t;

typedef struct packed {
    logic [31:0] c;
    logic        over;
    logic        zero;
} alu_ans_t;

// -----------------------------
// Branch predictor update bundle
// -----------------------------
typedef struct packed {
    logic        en;
    logic [31:0] pc;
    logic        actual_taken;
} bp_update_t;

class ecr_reset_for_issue #(
    parameter int NUM_ECRS = 2
);
    localparam int ecr_w = (NUM_ECRS > 1) ? $clog2(NUM_ECRS) : 1;
    typedef struct packed {
        // single-cycle pulse; when 0, ignore everything else
        logic             wen;
        logic [ecr_w-1:0] addr;

        // which payloads are valid this cycle
        logic do_reset;
        logic do_bpinfo;

        // reset/write of ecr_regs[addr]
        logic [1:0] reset_data;  // 00=busy, 01=free/correct, 10=incorrect

        // branch metadata (for BP update generation)
        logic [31:0] bpinfo_pc;
        logic        bpinfo_pred_taken;
    } t;
endclass

// -----------------------------
// Register file request/answer bundle (SIC <-> register_file)
// -----------------------------
class reg_req #(
    parameter int NUM_PHY_REGS = 64
);
    localparam int ADDR_W = (NUM_PHY_REGS > 1) ? $clog2(NUM_PHY_REGS) : 1;
    typedef struct packed {
        logic [ADDR_W-1:0] rs_addr;
        logic [ADDR_W-1:0] rt_addr;
        logic              wcommit;
        logic [ADDR_W-1:0] waddr;
        logic [31:0]       wdata;
    } t;
endclass

typedef struct packed {
    logic [31:0] rs_rdata;
    logic [31:0] rt_rdata;
    logic        rs_valid;
    logic        rt_valid;
} reg_ans_t;

// -----------------------------
// Physical register state (for allocation/debug)
// -----------------------------
typedef enum logic [1:0] {
    PR_IDLE,        // no SIC is referencing this PR
    PR_WAIT_VALUE,  // referenced but value not valid yet
    PR_READING      // referenced and value valid
} pr_state_t;

// -----------------------------
// Sub-SIC bundled interfaces (internal use)
// -----------------------------
class sic_sub_in #(
    parameter int NUM_PHY_REGS,
    parameter int ID_WIDTH,
    parameter int NUM_ECRS
);
    typedef struct packed {
        sic_packet#(NUM_PHY_REGS, ID_WIDTH, NUM_ECRS)::t pkt;
        reg_ans_t    reg_ans;
        logic [31:0] mem_rdata;
        logic        mem_grant;
        alu_ans_t    alu_ans;
        logic        alu_grant;
        logic [1:0]  ecr_read_data;
    } t;
endclass

class sic_sub_out #(
    parameter int NUM_PHY_REGS,
    parameter int ID_WIDTH,
    parameter int NUM_ECRS
);
    localparam int ECR_AW = (NUM_ECRS > 1) ? $clog2(NUM_ECRS) : 1;
    typedef struct packed {
        logic req_instr;

        // RF
        $unit::reg_req#(NUM_PHY_REGS)::t reg_req;

        // MEM
        rpl_req#(ID_WIDTH)::t mem_rpl;
        mem_req_t mem_req;

        // ALU
        rpl_req#(ID_WIDTH)::t alu_rpl;
        alu_req_t             alu_req;

        // ECR
        logic                 ecr_wen;
        logic [ECR_AW-1:0] ecr_write_addr;
        logic [          1:0] ecr_wdata;

        // // JR redirect
        logic                pc_redirect_valid;
        logic [        31:0] pc_redirect_pc;
        logic [ID_WIDTH-1:0] pc_redirect_issue_id;
    } t;
endclass

`endif
