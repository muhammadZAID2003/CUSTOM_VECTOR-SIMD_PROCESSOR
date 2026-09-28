// =============================================================================
//  alu_srca.sv
//  Part of the RV32I core.  Compile order (Questa/Quartus):
//     vec_pkg.sv, vector_alu.sv, vector_accel.sv,
//     alu.sv, alu_decoder.sv, alu_src.sv, alu_srca.sv, imm_ext.sv,
//     branch_unit.sv, load_unit.sv, store_unit.sv, main_decoder.sv,
//     program_counter.sv, pc_target.sv, register_file.sv, result_src.sv,
//     instr_mem.sv, data_memory.sv, riscv_top.sv
// =============================================================================

module ALU_srca(
    input  logic [1:0]  sel,
    input  logic [31:0] rd1, pc,
    output logic [31:0] src_a
);
    always_comb begin
        case (sel)
            2'b01:   src_a = pc;
            2'b10:   src_a = 32'd0;
            default: src_a = rd1;
        endcase
    end
endmodule
