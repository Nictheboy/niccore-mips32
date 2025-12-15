/*
 * Description :
 * 
 * 并行读写锁 (Parallel Read-Write Lock) 核心仲裁模块。
 *
 * 本模块实现了一种支持乱序执行 (Out-of-Order Execution) 的细粒度锁机制，
 * 专为超标量处理器的寄存器重命名与依赖调度设计。
 *
 * 主要功能特性：
 * 1. 基于发射序号 (Issue ID) 的仲裁：
 * 模块接收 N 个端口的请求，根据 Issue ID 的环形序列距离，
 * 自动识别并批准“最旧”的请求，确保指令按程序顺序的逻辑依赖执行。
 * 支持 ID 环绕回滚 (Rollback/Wrap-around) 判定。
 *
 * 2. 三态状态机控制：
 * 维护 FREE (自由), READING (读共享), WRITING (写独占) 三种状态。
 * - READING: 允许多个读请求同时进入，但阻塞所有比当前读更晚的写请求。
 * - WRITING: 独占访问，阻塞所有其他读写请求。
 *
 * 3. 反饥饿机制 (Anti-Starvation / The Sandwich Logic):
 * 实现了严格的“读-写-读”夹心排序逻辑。当锁处于 READING 状态时，
 * 如果队列中存在一个较旧的写请求 (Write)，则后续即使是读请求 (Read)
 * 也会被阻塞，防止写请求被源源不断的读请求饿死，破坏内存一致性。
 *
 * 4. 极速授权 (Flash Grant):
 * 采用纯组合逻辑输出 Grant 信号，支持“单周期读释放” (Flash Read)。
 * 请求方可以在同一个周期内发出请求、获得授权、读取数据并释放锁，
 * 从而消除流水线气泡，实现零周期的依赖解决。
 *
 * Author      : nictheboy <nictheboy@outlook.com>
 * Create Date : 2025/12/15
 *
 */

module parallel_rw_lock #(
    parameter int NUM_PORTS,
    parameter int ID_WIDTH
) (
    input logic clk,
    input logic rst_n,

    input logic                req_read    [NUM_PORTS],
    input logic                req_write   [NUM_PORTS],
    input logic [ID_WIDTH-1:0] req_issue_id[NUM_PORTS],
    input logic                release_lock[NUM_PORTS],

    // Grant 必须是确定性的 0/1，不能是 X
    output logic grant    [NUM_PORTS],
    output logic lock_busy
);

    // 状态定义
    typedef enum logic [1:0] {
        STATE_FREE,
        STATE_READING,
        STATE_WRITING
    } state_t;

    state_t                current_state;
    logic                  holders         [NUM_PORTS];

    // 组合逻辑信号
    logic                  next_grant      [NUM_PORTS];
    logic                  next_holders    [NUM_PORTS];

    // 仲裁中间变量
    logic   [ID_WIDTH-1:0] best_id;
    int                    best_idx;
    logic                  best_is_write;
    logic                  found_candidate;
    logic                  conflict;

    // 直接输出组合逻辑结果 (Flash Grant)
    always_comb begin
        for (int i = 0; i < NUM_PORTS; i++) begin
            grant[i] = next_grant[i] | holders[i];
        end
    end
    assign lock_busy = (current_state != STATE_FREE);

    // =========================================================================
    // 辅助函数: 序号比较 (处理回滚)
    // =========================================================================
    function automatic logic is_seq_smaller(input logic [ID_WIDTH-1:0] a,
                                            input logic [ID_WIDTH-1:0] b);
        logic [ID_WIDTH-1:0] diff;
        diff = a - b;
        // 检查最高位 (MSB)。如果为 1，说明 diff 是负数，即 a < b (在环形空间内)
        return diff[ID_WIDTH-1];
    endfunction

    // =========================================================================
    // 仲裁逻辑
    // =========================================================================
    always_comb begin
        // 初始化
        for (int i = 0; i < NUM_PORTS; i++) next_grant[i] = 0;

        found_candidate = 0;
        best_id         = '0;
        best_idx        = -1;
        best_is_write   = 0;

        // 1. 寻找 Winner (ID 最小的请求)
        for (int i = 0; i < NUM_PORTS; i++) begin
            if ((req_read[i] || req_write[i]) && !holders[i]) begin
                if (!found_candidate) begin
                    best_id         = req_issue_id[i];
                    best_idx        = i;
                    best_is_write   = req_write[i];
                    found_candidate = 1;
                end else begin
                    // 如果 current < best
                    if (is_seq_smaller(req_issue_id[i], best_id)) begin
                        best_id       = req_issue_id[i];
                        best_idx      = i;
                        best_is_write = req_write[i];
                    end
                end
            end
        end

        // 2. 授权决策
        if (found_candidate) begin
            case (current_state)
                STATE_WRITING: begin
                    // 写状态阻塞所有新请求
                    for (int i = 0; i < NUM_PORTS; i++) next_grant[i] = 0;
                end

                STATE_READING: begin
                    if (best_is_write) begin
                        // 最小的是写请求 -> 被当前的读锁阻塞，且阻塞后续所有读
                        // (next_grant 保持全 0)
                    end else begin
                        // 最小的是读请求 -> 允许进入
                        // 并且扫描其他所有读请求，只要没有被更早的写请求挡住，都允许进入
                        for (int i = 0; i < NUM_PORTS; i++) begin
                            if (req_read[i] && !holders[i]) begin
                                conflict = 0;
                                // 检查是否存在比当前读(i)更早的写请求(j)
                                for (int j = 0; j < NUM_PORTS; j++) begin
                                    if (req_write[j] && !holders[j]) begin
                                        if (is_seq_smaller(req_issue_id[j], req_issue_id[i])) begin
                                            conflict = 1;
                                        end
                                    end
                                end
                                if (!conflict) next_grant[i] = 1;
                            end
                        end
                    end
                end

                STATE_FREE: begin
                    if (best_is_write) begin
                        // 赢家是写 -> 独占
                        next_grant[best_idx] = 1;
                    end else begin
                        // 赢家是读 -> 开启并行读
                        // 批准所有“没有被更早的写请求阻挡”的读请求
                        for (int i = 0; i < NUM_PORTS; i++) begin
                            if (req_read[i]) begin
                                conflict = 0;
                                for (int j = 0; j < NUM_PORTS; j++) begin
                                    if (req_write[j]) begin
                                        if (is_seq_smaller(req_issue_id[j], req_issue_id[i])) begin
                                            conflict = 1;
                                        end
                                    end
                                end
                                if (!conflict) next_grant[i] = 1;
                            end
                        end
                    end
                end

                default: begin
                end
            endcase
        end
    end

    // =========================================================================
    // 状态更新
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state <= STATE_FREE;
            for (int i = 0; i < NUM_PORTS; i++) holders[i] <= 0;
        end else begin
            logic any_holder;
            logic is_write_entering;

            any_holder = 0;
            is_write_entering = 0;

            for (int i = 0; i < NUM_PORTS; i++) begin
                // 下一时刻持有者 = (当前持有 | 新获准) & ~释放
                next_holders[i] = (holders[i] | next_grant[i]) & ~release_lock[i];

                if (next_holders[i]) any_holder = 1;

                // 检测从 FREE -> WRITING 的转换条件
                if (next_grant[i] && req_write[i]) is_write_entering = 1;
            end

            holders <= next_holders;

            // 状态机跳转
            if (!any_holder) begin
                current_state <= STATE_FREE;
            end else begin
                case (current_state)
                    STATE_FREE: begin
                        if (is_write_entering) current_state <= STATE_WRITING;
                        else current_state <= STATE_READING;
                    end
                    // 保持原状态直到变空
                    default: current_state <= current_state;
                endcase
            end
        end
    end

endmodule
