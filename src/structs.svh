// =========================================================
// Global shared types (struct/enum/class typedefs)
// =========================================================
// 约定：
// - 所有需要跨模块复用的“全局结构体/类型定义”集中放在这里
// - 不使用 `type`（关键字）作为成员/typedef 名称；统一使用 `t`

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
// MIPS opcode enum (for decode/debug)
// -----------------------------
typedef enum logic [5:0] {
    OPC_INVALID,
    OPC_SPECIAL,
    OPC_BEQ,
    OPC_J,
    OPC_JAL,
    OPC_ORI,
    OPC_LUI,
    OPC_LW,
    OPC_SW
} opcode_t;

// -----------------------------
// Decoded instruction info
// -----------------------------
typedef struct packed {
    opcode_t     opcode;          // 指令 opcode（枚举）
    logic        is_branch;       // 是否为分支指令（当前仅 BEQ）
    // 字段有效性（用于发射端重命名/调试）
    logic        rs_valid;
    logic        rt_valid;
    logic        rd_valid;
    logic [4:0]  rs;
    logic [4:0]  rt;
    logic [4:0]  rd;
    logic [5:0]  funct;
    logic [15:0] imm16;
    logic [31:0] imm16_sign_ext;
    logic [31:0] imm16_zero_ext;
    logic [25:0] jump_target;
} instr_info_t;

// -----------------------------
// SIC packet (issue -> execute)
// -----------------------------
typedef struct packed {
    logic        valid;         // 指令有效位
    logic [31:0] pc;            // 当前指令 PC
    logic [31:0] next_pc_pred;  // 预测的下一条 PC (用于 JAL/Branch)

    // 锁与排序
    logic [15:0] issue_id;  // 发射序号 (假设 16位宽)

    // 解码信息
    instr_info_t info;

    // 寄存器重命名结果 (物理寄存器号)
    // 说明：
    // - phy_rs/phy_rt/phy_rd：对应“逻辑字段 rs/rt/rd”的物理映射（仅用于执行/调试）
    // - phy_dst：本指令真正要写回的目的物理寄存器（SIC 写端口使用它）
    logic [5:0] phy_rs;   // rs 字段映射；无意义则为 'x
    logic [5:0] phy_rt;   // rt 字段映射；无意义则为 'x
    logic [5:0] phy_rd;   // rd 字段映射；无意义则为 'x
    logic [5:0] phy_dst;  // 目的寄存器映射；无写回则为 'x

    // 分支预测与 ECR
    logic       pred_taken;  // 预测跳转方向
    logic [1:0] dep_ecr_id;  // 依赖的 ECR 号
    logic [1:0] set_ecr_id;  // 本指令需要设置的 ECR 号
} sic_packet_t;

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

`endif
