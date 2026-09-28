// =============================================================================
//  program_counter.sv
//  Part of the RV32I core.  Compile order (Questa/Quartus):
//     vec_pkg.sv, vector_alu.sv, vector_accel.sv,
//     alu.sv, alu_decoder.sv, alu_src.sv, alu_srca.sv, imm_ext.sv,
//     branch_unit.sv, load_unit.sv, store_unit.sv, main_decoder.sv,
//     program_counter.sv, pc_target.sv, register_file.sv, result_src.sv,
//     instr_mem.sv, data_memory.sv, riscv_top.sv
// =============================================================================

module program_counter(
    input  logic        clk, reset,
    input  logic [31:0] pc_next,
    output logic [31:0] pc_addr
);
    always_ff @(posedge clk)
        if (reset) pc_addr <= 32'b0;
        else       pc_addr <= pc_next;
endmodule
