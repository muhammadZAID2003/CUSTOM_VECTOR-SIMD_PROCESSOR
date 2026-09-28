// =============================================================================
//  result_src.sv
//  Part of the RV32I core.  Compile order (Questa/Quartus):
//     vec_pkg.sv, vector_alu.sv, vector_accel.sv,
//     alu.sv, alu_decoder.sv, alu_src.sv, alu_srca.sv, imm_ext.sv,
//     branch_unit.sv, load_unit.sv, store_unit.sv, main_decoder.sv,
//     program_counter.sv, pc_target.sv, register_file.sv, result_src.sv,
//     instr_mem.sv, data_memory.sv, riscv_top.sv
// =============================================================================

module RESULT_src (
    input  logic [1:0]  result_src,
    input  logic [31:0] alu_result,
    input  logic [31:0] read_data,
    input  logic [31:0] pc_plus4,
    output logic [31:0] result
);
    always_comb begin
        case (result_src)
            2'b01:   result = read_data;
            2'b10:   result = pc_plus4;
            default: result = alu_result;
        endcase
    end
endmodule
