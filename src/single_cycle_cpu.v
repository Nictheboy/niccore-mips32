/* 
 *  Description : A MIPS-32 single-cycle CPU, without memory.
 *  Author      : nictheboy <nictheboy@outlook.com>
 *  Create Date : 2025/11/30
 * 
 */

module single_cycle_cpu (
    input reset,
    input clock,

    // Peer Module: Instruction Memory
    output [31:2] instruction_memory_address,  // from PC register
    input [31:0] instruction_memory_instruction,  // to instruction decoder

    // Peer Module: Data Memory
    output [31:2] data_memory_address,
    output data_memory_write_enable,
    output [31:0] data_memory_write_input,
    input [31:0] data_memory_read_result
);

    // Submodule: PC register
    wire program_counter_jump_enable;
    wire [31:2] program_counter_jump_input;
    (* dont_touch = "true" *) program_counter program_counter_1 (
        .reset(reset),
        .clock(clock),
        .jump_enable(program_counter_jump_enable),
        .jump_input(program_counter_jump_input),
        .pc_value(instruction_memory_address)  // to output
    );

    // Submodule: register File
    wire [4:0] register_file_rs;
    wire [4:0] register_file_rt;
    wire [4:0] register_file_rd;
    wire [31:0] register_file_write_data;
    wire register_file_write_enable;
    wire [31:0] register_file_rs_data;
    wire [31:0] register_file_rt_data;
    (* dont_touch = "true" *) register_file register_file_1 (
        .reset(reset),
        .clock(clock),
        .rs(register_file_rs),
        .rt(register_file_rt),
        .rd(register_file_rd),
        .write_data(register_file_write_data),
        .write_enable(register_file_write_enable),
        .rs_data(register_file_rs_data),
        .rt_data(register_file_rt_data)
    );

    // Submodule: ALU
    wire [31:0] alu_a;
    wire [31:0] alu_b;
    wire [5:0] alu_op;
    wire [31:0] alu_c;
    wire alu_over;
    (* dont_touch = "true" *) alu alu_1 (
        .A(alu_a),
        .B(alu_b),
        .Op(alu_op),
        .C(alu_c),
        .Over(alu_over)
    );

    // Submodule: Data Path Controller
    (* dont_touch = "true" *)
    single_cycle_datapath_controller single_cycle_datapath_controller_1 (
        .instruction(instruction_memory_instruction),
        .register_file_rs(register_file_rs),
        .register_file_rt(register_file_rt),
        .register_file_rs_data(register_file_rs_data),
        .register_file_rt_data(register_file_rt_data),
        .register_file_write_enable(register_file_write_enable),
        .register_file_rd(register_file_rd),
        .register_file_write_data(register_file_write_data),
        .alu_a(alu_a),
        .alu_b(alu_b),
        .alu_op(alu_op),
        .alu_c(alu_c),
        .data_memory_address(data_memory_address),
        .data_memory_read_result(data_memory_read_result),
        .data_memory_write_enable(data_memory_write_enable),
        .data_memory_write_input(data_memory_write_input),
        .program_counter_value(instruction_memory_address),
        .program_counter_jump_enable(program_counter_jump_enable),
        .program_counter_jump_input(program_counter_jump_input)
    );
endmodule
