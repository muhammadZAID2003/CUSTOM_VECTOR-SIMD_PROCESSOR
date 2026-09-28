// =============================================================================
//  imm_ext.sv
//  Part of the RV32I core.  Compile order (Questa/Quartus):
//     vec_pkg.sv, vector_alu.sv, vector_accel.sv,
//     alu.sv, alu_decoder.sv, alu_src.sv, alu_srca.sv, imm_ext.sv,
//     branch_unit.sv, load_unit.sv, store_unit.sv, main_decoder.sv,
//     program_counter.sv, pc_target.sv, register_file.sv, result_src.sv,
//     instr_mem.sv, data_memory.sv, riscv_top.sv
// =============================================================================

module imm_ext (
    input  logic [31:0] instr,
    input  logic [2:0]  imm_src,
    output logic [31:0] imm
);
    always_comb begin
        case (imm_src)
            3'b000:  imm = {{20{instr[31]}}, instr[31:20]};                                   // I
            3'b001:  imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};                      // S
            3'b010:  imm = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};      // B
            3'b011:  imm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};    // J
            3'b100:  imm = {instr[31:12], 12'b0};                                             // U
            default: imm = 32'b0;
        endcase
    end
endmodule
