// =============================================================================
//  register_file.sv
//  Part of the RV32I core.  Compile order (Questa/Quartus):
//     vec_pkg.sv, vector_alu.sv, vector_accel.sv,
//     alu.sv, alu_decoder.sv, alu_src.sv, alu_srca.sv, imm_ext.sv,
//     branch_unit.sv, load_unit.sv, store_unit.sv, main_decoder.sv,
//     program_counter.sv, pc_target.sv, register_file.sv, result_src.sv,
//     instr_mem.sv, data_memory.sv, riscv_top.sv
// =============================================================================

module register_file (
    input  logic        clk,
    input  logic        reg_write,
    input  logic [4:0]  a1, a2, a3,
    input  logic [31:0] wd3,
    output logic [31:0] rd1, rd2
);
    logic [31:0] regs [0:31];

    assign rd1 = (a1 == 5'b0) ? 32'b0 : regs[a1];
    assign rd2 = (a2 == 5'b0) ? 32'b0 : regs[a2];

    always @(posedge clk)
        if (reg_write && a3 != 5'b0) regs[a3] <= wd3;

    initial for (int i = 0; i < 32; i++) regs[i] = 32'b0;
endmodule
