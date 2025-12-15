/*
 * Description :
 *
 * 基于发射序号的互斥锁 (Mutex Lock with Issue ID Arbitration).
 *
 * 这是一个简化版的仲裁器，用于不需要区分读/写的独占资源 (如 ALU、除法器)。
 *
 * 特性：
 * 1. 独占性：同一时间只允许一个端口获得 Grant。
 * 2. 顺序性：基于 Issue ID 选择最旧的请求者。
 * 3. 三态：FREE, LOCKED.
 *
 * Author      : nictheboy
 * Create Date : 2025/12/15
 *
 */

module mutex_lock #(
    parameter int NUM_PORTS,
    parameter int ID_WIDTH
) (
    input logic clk,
    input logic rst_n,

    input logic                req         [NUM_PORTS],
    input logic [ID_WIDTH-1:0] req_issue_id[NUM_PORTS],
    input logic                release_lock[NUM_PORTS],

    output logic grant[NUM_PORTS],
    output logic busy
);

    // 状态定义
    typedef enum logic {
        STATE_FREE,
        STATE_LOCKED
    } state_t;

    state_t state;
    logic   holders[NUM_PORTS]; // 虽然是 Mutex，但为了逻辑一致性保持数组，尽管只会有一个是1

    logic next_grant[NUM_PORTS];
    logic next_holders[NUM_PORTS];

    // 仲裁变量
    logic [ID_WIDTH-1:0] best_id;
    int best_idx;
    logic found_candidate;

    // Flash Grant 输出
    always_comb begin
        for (int i = 0; i < NUM_PORTS; i++) begin
            grant[i] = next_grant[i] | holders[i];
        end
    end
    assign busy = (state != STATE_FREE);

    // 序号比较函数 (复用自 parallel_rw_lock 的逻辑)
    function automatic logic is_seq_smaller(input logic [ID_WIDTH-1:0] a, b);
        logic [ID_WIDTH-1:0] diff;
        diff = a - b;
        return diff[ID_WIDTH-1];
    endfunction

    // 仲裁逻辑
    always_comb begin
        for (int i = 0; i < NUM_PORTS; i++) next_grant[i] = 0;

        found_candidate = 0;
        best_id         = '0;
        best_idx        = -1;

        // 1. 寻找最佳候选人 (最小 Issue ID)
        for (int i = 0; i < NUM_PORTS; i++) begin
            if (req[i] && !holders[i]) begin
                if (!found_candidate) begin
                    best_id         = req_issue_id[i];
                    best_idx        = i;
                    found_candidate = 1;
                end else begin
                    if (is_seq_smaller(req_issue_id[i], best_id)) begin
                        best_id  = req_issue_id[i];
                        best_idx = i;
                    end
                end
            end
        end

        // 2. 决策
        case (state)
            STATE_LOCKED: begin
                // 已锁定，不产生新 Grant
            end
            STATE_FREE: begin
                if (found_candidate) begin
                    next_grant[best_idx] = 1;
                end
            end
        endcase
    end

    // 状态更新
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_FREE;
            for (int i = 0; i < NUM_PORTS; i++) holders[i] <= 0;
        end else begin
            logic any_holder = 0;

            for (int i = 0; i < NUM_PORTS; i++) begin
                next_holders[i] = (holders[i] | next_grant[i]) & ~release_lock[i];
                if (next_holders[i]) any_holder = 1;
            end

            holders <= next_holders;

            if (any_holder) state <= STATE_LOCKED;
            else state <= STATE_FREE;
        end
    end

endmodule
