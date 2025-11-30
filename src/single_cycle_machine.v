/* 
 *  Description : A complete MIPS-32 single-cycle machine, with memory.
 *  Author      : nictheboy <nictheboy@outlook.com>
 *  Create Date : 2025/11/30
 * 
 */

module single_cycle_machine (
    input reset,
    input clock
);

    // Submodule: Data Memory
    wire [31:2] data_memory_address;
    wire data_memory_write_enable;
    wire [31:0] data_memory_write_input;
    wire [31:0] data_memory_read_result;
    (* dont_touch = "true" *) data_memory data_memory_1 (
        .reset(reset),
        .clock(clock),
        .address(data_memory_address),
        .write_enable(data_memory_write_enable),
        .write_input(data_memory_write_input),
        .read_result(data_memory_read_result)
    );

    // Submodule: Instruction Memory
    wire [31:2] instruction_memory_address;
    wire [31:0] instruction_memory_instruction;
    (* dont_touch = "true" *) instruction_memory instruction_memory_1 (
        .reset(reset),
        .clock(clock),
        .address(instruction_memory_address),
        .instruction(instruction_memory_instruction)
    );

    // Submodule: CPU
    (* dont_touch = "true" *)
    single_cycle_cpu single_cycle_cpu_1 (
        .reset(reset),
        .clock(clock),
        .instruction_memory_address(instruction_memory_address),
        .instruction_memory_instruction(instruction_memory_instruction),
        .data_memory_address(data_memory_address),
        .data_memory_write_enable(data_memory_write_enable),
        .data_memory_write_input(data_memory_write_input),
        .data_memory_read_result(data_memory_read_result)
    );
endmodule
