/*
 * Description : Simplified ECR Module.
 * 
 * 功能：
 * 1. 维护 NUM_ECRS 个 2-bit 状态寄存器。
 * 2. 读操作：无锁，纯组合逻辑广播。任何 SIC 可以随时读取任何 ECR。
 * 3. 写操作：基于 Issue ID 授权。每个 ECR 记录它被分配给哪条指令 (owner_issue_id)。
 *    只有当写请求的 Issue ID 与记录的 owner_issue_id 匹配时，才允许写入。
 *    (注：为了简化，这里假设发射控制器保证了 Issue ID 的分配正确性，或者简单地允许最新指令覆盖)
 * 
 * 更简单的实现：由于 SIC 严格按顺序执行分支，且发射控制器保证了 set_ecr_id 的分配，
 * 我们可以不做复杂的 ID 检查，直接允许写入。因为根据设计，只有那条特定的分支指令会被分配
 * 写该 ECR 的任务。
 * 
 * Author      : nictheboy
 * Create Date : 2025/12/15
 */

module execution_condition_register_file #(
    parameter int NUM_ECRS = 2,
    parameter int NUM_SICS = 2,
    parameter int ID_WIDTH = 16
) (
    input logic clk,
    input logic rst_n,

    // === SIC 接口 ===
    // 读接口：SIC 只需给出它想读哪个 ECR 的 ID (通常是 dep_ecr_id)
    input  logic [$clog2(NUM_ECRS)-1:0] sic_read_addr[NUM_SICS],
    output logic [                 1:0] sic_read_data[NUM_SICS],

    // 写接口：SIC 给出它想写哪个 ECR (set_ecr_id) 和数据
    // 注意：这里我们移除了 explicit lock request，改为 Write Enable
    input logic                        sic_wen       [NUM_SICS],
    input logic [$clog2(NUM_ECRS)-1:0] sic_write_addr[NUM_SICS],
    input logic [                 1:0] sic_wdata     [NUM_SICS],

    // === Issue Controller 写接口 ===
    // Issue Controller 在分配 ECR 时将其置为 Busy (00)
    input logic                        issue_wen,
    input logic [$clog2(NUM_ECRS)-1:0] issue_write_addr,
    input logic [                 1:0] issue_wdata,

    // 监控接口
    output logic [1:0] monitor_states[NUM_ECRS]
);

    // ECR 寄存器堆 (00=Busy/Undefined, 01=Correct/Free, 10=Incorrect)
    // 复位值为 01
    logic [1:0] ecr_regs[NUM_ECRS];

    // 读逻辑 (异步广播)
    always_comb begin
        for (int i = 0; i < NUM_SICS; i++) begin
            // 直接索引读取。如果地址越界(虽不应发生)，给个默认值
            if (sic_read_addr[i] < NUM_ECRS) begin
                sic_read_data[i] = ecr_regs[sic_read_addr[i]];
            end else begin
                sic_read_data[i] = 2'b01;  // Default Safe
            end
        end

        for (int k = 0; k < NUM_ECRS; k++) begin
            monitor_states[k] = ecr_regs[k];
        end
    end

    // 写逻辑 (同步)
    // 处理多端口写入：Issue Controller 和 SIC 可能同时写入不同的 ECR
    // 如果多个写请求针对同一个 ECR，Issue Controller 优先级更高，SIC 之间使用优先级编码
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int k = 0; k < NUM_ECRS; k++) begin
                ecr_regs[k] <= 2'b01;  // Reset to Correct/Free
            end
        end else begin
            // 对每个 ECR，检查是否有写请求
            for (int k = 0; k < NUM_ECRS; k++) begin
                logic written;
                written = 0;

                // 优先处理 Issue Controller 的写请求（置忙操作）
                if (issue_wen && issue_write_addr == k && issue_write_addr < NUM_ECRS) begin
                    ecr_regs[k] <= issue_wdata;
                    written = 1;
                end

                // 如果没有 Issue Controller 写，处理 SIC 的写请求（优先级编码）
                if (!written) begin
                    for (int i = 0; i < NUM_SICS; i++) begin
                        if (sic_wen[i] && sic_write_addr[i] == k && sic_write_addr[i] < NUM_ECRS) begin
                            ecr_regs[k] <= sic_wdata[i];
                            written = 1;
                            break;  // 优先级编码：第一个匹配的 SIC 写入
                        end
                    end
                end
            end
        end
    end

endmodule

