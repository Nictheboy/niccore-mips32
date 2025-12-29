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
    parameter int NUM_ECRS,
    parameter int NUM_SICS,
    parameter int ID_WIDTH
) (
    input logic clk,
    input logic rst_n,

    // === SIC 接口 ===
    // 读接口：SIC 只需给出它想读哪个 ECR 的 ID (通常是 dep_ecr_id)
    input  logic                        sic_read_en  [NUM_SICS],
    input  logic [$clog2(NUM_ECRS)-1:0] sic_read_addr[NUM_SICS],
    output logic [                 1:0] sic_read_data[NUM_SICS],

    // 写接口：SIC 给出它想写哪个 ECR (set_ecr_id) 和数据
    // 注意：这里我们移除了 explicit lock request，改为 Write Enable
    input logic                        sic_wen       [NUM_SICS],
    input logic [$clog2(NUM_ECRS)-1:0] sic_write_addr[NUM_SICS],
    input logic [                 1:0] sic_wdata     [NUM_SICS],

    // === Issue Controller 更新接口（打包）===
    input ecr_reset_for_issue#(NUM_ECRS)::t issue_update,
    input logic [$clog2(NUM_ECRS)-1:0] issue_active_ecr_id,

    // ECR -> BP：由 ECR 内部在分支结果确定时产生更新（单周期脉冲）
    output bp_update_t bp_update,

    // ECR -> Issue：汇总状态（allocator + rollback + in_use）
    output ecr_status_for_issue#(NUM_ECRS)::t status_for_issue,

    // 监控接口
    output logic [1:0] monitor_states[NUM_ECRS]
);

    // ECR 寄存器堆 (00=Busy/Undefined, 01=Correct/Free, 10=Incorrect)
    // 复位值为 01
    logic [1:0] ecr_regs[NUM_ECRS];

    // 分配指针：用于 round-robin 选择下一个 ECR，避免 reset 后总是分配 0
    localparam int ECR_W = (NUM_ECRS > 1) ? $clog2(NUM_ECRS) : 1;
    logic [ECR_W-1:0] alloc_ptr;

    // 分支元数据：由 issue_controller 在分配 ECR 时写入
    logic [     31:0] ecr_branch_pc        [NUM_ECRS];
    logic             ecr_branch_pred_taken[NUM_ECRS];
    logic [     31:0] ecr_alt_pc           [NUM_ECRS];

    // 读逻辑 (异步广播)
    always_comb begin
        logic [NUM_ECRS-1:0] in_use_local;
        in_use_local = '0;

        status_for_issue = '0;

        for (int i = 0; i < NUM_SICS; i++) begin
            // 直接索引读取。如果地址越界(虽不应发生)，给个默认值
            if (sic_read_addr[i] < NUM_ECRS) begin
                sic_read_data[i] = ecr_regs[sic_read_addr[i]];
            end else begin
                sic_read_data[i] = 2'b01;  // Default Safe
            end

            // 统计 in_use：只有 read_en=1 时才认为该 SIC 正在依赖该地址
            if (sic_read_en[i] && (sic_read_addr[i] < NUM_ECRS)) begin
                in_use_local[sic_read_addr[i]] = 1'b1;
            end
        end

        status_for_issue.in_use = in_use_local;

        // allocator：round-robin 从 alloc_ptr 开始扫描，避免 reset 后总是分配 0
        for (int off = 0; off < NUM_ECRS; off++) begin
            int k;
            k = (alloc_ptr + off) % NUM_ECRS;
            if (!status_for_issue.alloc_avail) begin
                if ((k[$clog2(
                        NUM_ECRS
                    )-1:0] != issue_active_ecr_id) && (ecr_regs[k] == 2'b01) &&
                        !in_use_local[k]) begin
                    status_for_issue.alloc_avail = 1'b1;
                    status_for_issue.alloc_id    = k[$clog2(NUM_ECRS)-1:0];
                end
            end
        end

        // rollback：若任一 ECR 为 10，则请求回滚（固定优先级：编号小者优先）
        for (int k = 0; k < NUM_ECRS; k++) begin
            if (!status_for_issue.rollback_valid) begin
                if (ecr_regs[k] == 2'b10) begin
                    status_for_issue.rollback_valid     = 1'b1;
                    status_for_issue.rollback_id        = k[$clog2(NUM_ECRS)-1:0];
                    status_for_issue.rollback_target_pc = ecr_alt_pc[k];
                end
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
                ecr_branch_pc[k] <= 32'b0;
                ecr_branch_pred_taken[k] <= 1'b0;
                ecr_alt_pc[k] <= 32'b0;
            end
            // 对 NUM_ECRS=2：reset 后优先分配 1，符合“初始依赖 ecr0，第一条分支写 ecr1”的预期
            if (NUM_ECRS > 1) alloc_ptr <= ECR_W'(1);
            else alloc_ptr <= '0;
            bp_update <= '0;
        end else begin
            // 默认不更新 BP（脉冲）
            bp_update.en <= 1'b0;

            // 记录分支元数据：由 issue_update 提供
            if (issue_update.wen && (issue_update.addr < NUM_ECRS)) begin
                if (issue_update.do_bpinfo) begin
                    ecr_branch_pc[issue_update.addr] <= issue_update.bpinfo_pc;
                    ecr_branch_pred_taken[issue_update.addr] <= issue_update.bpinfo_pred_taken;
                end
                if (issue_update.do_altpc) begin
                    ecr_alt_pc[issue_update.addr] <= issue_update.altpc_pc;
                end
            end

            // 当 issue 分配新分支（reset_data=00）时，推进 alloc_ptr 到下一个位置
            if (issue_update.wen && issue_update.do_reset &&
                (issue_update.addr < NUM_ECRS) && (issue_update.reset_data == 2'b00)) begin
                if (NUM_ECRS > 1)
                    alloc_ptr <= (issue_update.addr == (NUM_ECRS-1)) ? '0
                                                                                   : (issue_update.addr + 1);
                else alloc_ptr <= '0;
            end

            // 对每个 ECR，检查是否有写请求
            for (int k = 0; k < NUM_ECRS; k++) begin
                logic written;
                written = 0;

                // 优先处理 Issue Controller 的写请求（置忙操作）
                if (issue_update.wen && issue_update.do_reset &&
                    (issue_update.addr == k) && (issue_update.addr < NUM_ECRS)) begin
                    ecr_regs[k] <= issue_update.reset_data;
                    written = 1;
                end

                // 如果没有 Issue Controller 写，处理 SIC 的写请求（优先级编码）
                if (!written) begin
                    for (int i = 0; i < NUM_SICS; i++) begin
                        if (sic_wen[i] && sic_write_addr[i] == k && sic_write_addr[i] < NUM_ECRS) begin
                            ecr_regs[k] <= sic_wdata[i];
                            written = 1;

                            // 当 ECR 被分支指令写成 01/10 时，ECR 内部生成一次 BP 更新
                            // 约定：01=Correct -> actual_taken = pred_taken；10=Incorrect -> actual_taken = !pred_taken
                            if (sic_wdata[i] == 2'b01 || sic_wdata[i] == 2'b10) begin
                                bp_update.en <= 1'b1;
                                bp_update.pc <= ecr_branch_pc[k];
                                bp_update.actual_taken <= (sic_wdata[i] == 2'b01) ? ecr_branch_pred_taken[k]
                                                                                 : ~ecr_branch_pred_taken[k];
                            end
                            break;  // 优先级编码：第一个匹配的 SIC 写入
                        end
                    end
                end
            end
        end
    end

endmodule

