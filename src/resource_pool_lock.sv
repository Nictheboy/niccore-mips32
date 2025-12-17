/*
 * Description :
 * 资源池锁 (Resource Pool Lock) - 修复版
 * * 修复内容：
 * 1. 增加了 RES_ID_WIDTH 和 PORT_IDX_WIDTH 本地参数。
 * 2. 处理了当 NUM_RESOURCES=1 或 NUM_PORTS=1 时，$clog2 计算结果为 0 导致产生 [-1:0] 非法位宽的问题。
 * 现在当数量为 1 时，强制位宽为 1。
 */
module resource_pool_lock #(
    parameter int NUM_RESOURCES,
    parameter int NUM_PORTS,
    parameter int ID_WIDTH,
    // Vivado 兼容：端口列表里不能引用在模块体内才声明的 localparam
    // 所以把安全位宽计算提升为参数（可依赖前面的参数）
    parameter int RES_ID_WIDTH   = (NUM_RESOURCES > 1) ? $clog2(NUM_RESOURCES) : 1,
    parameter int PORT_IDX_WIDTH = (NUM_PORTS > 1) ? $clog2(NUM_PORTS) : 1
) (
    input logic clk,
    input logic rst_n,

    input logic                req         [NUM_PORTS],
    input logic [ID_WIDTH-1:0] req_issue_id[NUM_PORTS],
    input logic                release_lock[NUM_PORTS],

    // 输出
    output logic                    grant    [NUM_PORTS],
    output logic [RES_ID_WIDTH-1:0] alloc_id [NUM_PORTS],
    output logic                    pool_busy
);

    // 资源持有者状态表
    typedef struct packed {
        logic valid;
        logic [PORT_IDX_WIDTH-1:0] port_idx;
    } res_owner_t;

    res_owner_t                     owners        [NUM_RESOURCES];
    res_owner_t                     next_owners   [NUM_RESOURCES];

    // 临时变量：必须是 Packed Array 才能使用 & 缩减运算
    logic       [    NUM_PORTS-1:0] port_serviced;
    logic       [NUM_RESOURCES-1:0] res_allocated;

    // =========================================================================
    // 辅助函数: 序号比较
    // =========================================================================
    function automatic logic is_seq_smaller(input logic [ID_WIDTH-1:0] a, b);
        logic [ID_WIDTH-1:0] diff;
        diff = a - b;
        return diff[ID_WIDTH-1];
    endfunction

    // =========================================================================
    // 仲裁与分配组合逻辑
    // =========================================================================
    always_comb begin
        // 1. 初始化
        for (int p = 0; p < NUM_PORTS; p++) begin
            grant[p] = 0;
            alloc_id[p] = 0;
            port_serviced[p] = 0;
        end

        for (int r = 0; r < NUM_RESOURCES; r++) begin
            next_owners[r]   = owners[r];
            res_allocated[r] = owners[r].valid;

            if (owners[r].valid) begin
                if (release_lock[owners[r].port_idx]) begin
                    res_allocated[r] = 0;
                    next_owners[r].valid = 0;
                end else begin
                    grant[owners[r].port_idx] = 1;
                    // 【修复点 4】：使用安全位宽截断
                    alloc_id[owners[r].port_idx] = r[RES_ID_WIDTH-1:0];
                    port_serviced[owners[r].port_idx] = 1;
                end
            end
        end

        // 2. 贪心分配循环
        for (int i = 0; i < NUM_RESOURCES; i++) begin

            logic [ID_WIDTH-1:0] best_id;
            int                  best_port;
            logic                found_candidate;
            int                  target_res;

            best_id = '0;
            best_port = -1;
            found_candidate = 0;
            target_res = -1;

            // A. 寻找一个空闲资源
            for (int r = 0; r < NUM_RESOURCES; r++) begin
                if (res_allocated[r] == 0) begin
                    target_res = r;
                    break;
                end
            end

            if (target_res != -1) begin
                // B. 寻找未被服务的、Issue ID 最小的请求者
                for (int p = 0; p < NUM_PORTS; p++) begin
                    if (req[p] && !port_serviced[p]) begin
                        if (!found_candidate) begin
                            best_id = req_issue_id[p];
                            best_port = p;
                            found_candidate = 1;
                        end else begin
                            if (is_seq_smaller(req_issue_id[p], best_id)) begin
                                best_id   = req_issue_id[p];
                                best_port = p;
                            end
                        end
                    end
                end

                // C. 匹配
                if (found_candidate) begin
                    grant[best_port] = 1;
                    // 【修复点 5】：使用安全位宽截断
                    alloc_id[best_port] = target_res[RES_ID_WIDTH-1:0];

                    port_serviced[best_port] = 1;
                    res_allocated[target_res] = 1;

                    if (!release_lock[best_port]) begin
                        next_owners[target_res].valid = 1;
                        // 【修复点 6】：使用安全位宽截断
                        next_owners[target_res].port_idx = best_port[PORT_IDX_WIDTH-1:0];
                    end else begin
                        next_owners[target_res].valid = 0;
                    end
                end
            end
        end
    end

    assign pool_busy = &res_allocated;

    // 状态更新
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int r = 0; r < NUM_RESOURCES; r++) begin
                owners[r].valid <= 0;
                owners[r].port_idx <= 0;
            end
        end else begin
            owners <= next_owners;
        end
    end

endmodule
