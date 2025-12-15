/*
 * Description :
 * Parametric Instruction Memory (Read-Only)
 * Supports configurable fetch width and SystemVerilog parameters.
 * Author      : nictheboy <nictheboy@outlook.com>
 * Modified    : 2025/12/15 (Updated to SystemVerilog)
 */

module instruction_memory #(
    // 内存深度 (指令数量)
    parameter int MEM_DEPTH,
    // 起始字节地址 (必须是4的倍数)
    parameter logic [31:0] START_BYTE_ADDR,
    // 初始化文件路径
    parameter string INIT_FILE,
    // 一次获取的指令数量 (Superscalar width)
    parameter int FETCH_WIDTH
) (
    input  logic                         reset,
    input  logic                         clock,
    // 输入改为完整的32位地址，内部忽略低2位进行字对齐
    input  logic [           31:0]       address,
    // 输出: 打包的二维数组 [指令索引][31:0]
    // 例如: FETCH_WIDTH=2, instruction[0]是当前地址指令, instruction[1]是下一条
    output logic [FETCH_WIDTH-1:0][31:0] instruction
);

    // 计算内部字索引的起始偏移量
    localparam logic [29:0] START_WORD_ADDR = START_BYTE_ADDR[31:2];

    // 内存定义
    logic [31:0] mem_array[0:MEM_DEPTH-1];

    // 加载内存初始化文件
    initial begin
        // 注意: SystemVerilog允许在readmem中使用parameter
        $readmemh(INIT_FILE, mem_array);
    end

    // 组合逻辑读取 (异步读取)
    // 如果需要同步读取(BRAM block ram)，请将此逻辑放入 always_ff @(posedge clock)
    always_comb begin
        // 计算当前输入地址对应的 0-based 内存索引
        // (当前字地址 - 起始字地址)
        logic [29:0] base_index;
        base_index = address[31:2] - START_WORD_ADDR;

        // 遍历输出每一个指令槽位
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            // 边界检查：
            // 1. 输入地址必须大于等于起始地址
            // 2. 计算出的索引 + 偏移 i 必须在内存深度范围内
            if (address >= START_BYTE_ADDR && (base_index + i) < MEM_DEPTH) begin
                instruction[i] = mem_array[base_index+i];
            end else begin
                // 地址无效或越界，输出 X
                instruction[i] = 32'bx;
            end
        end
    end

    // 原有的时钟块保留，但目前不做任何事 (因为是纯组合逻辑读取)
    // 如果将来改为同步 RAM，逻辑应移到这里
    always_ff @(posedge clock) begin
        if (reset) begin
            // 可选: 复位逻辑
        end
    end

endmodule
