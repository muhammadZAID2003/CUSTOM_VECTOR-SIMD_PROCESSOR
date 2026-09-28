// =============================================================================
//  alu.sv
//  Part of the RV32I core.  Compile order (Questa/Quartus):
//     vec_pkg.sv, vector_alu.sv, vector_accel.sv,
//     alu.sv, alu_decoder.sv, alu_src.sv, alu_srca.sv, imm_ext.sv,
//     branch_unit.sv, load_unit.sv, store_unit.sv, main_decoder.sv,
//     program_counter.sv, pc_target.sv, register_file.sv, result_src.sv,
//     instr_mem.sv, data_memory.sv, riscv_top.sv
// =============================================================================

module alu(
    input  logic [3:0]  alu_control,
    input  logic [31:0] src1, src2,
    output logic [31:0] alu_result
);
    logic signed [31:0] src1_s, src2_s;
    assign src1_s = src1;
    assign src2_s = src2;

    always_comb begin
        case (alu_control)
            4'b0000: alu_result = src1 + src2;                 // add
            4'b0001: alu_result = src1 - src2;                 // sub
            4'b0010: alu_result = src1 & src2;                 // and
            4'b0011: alu_result = src1 | src2;                 // or
            4'b0100: alu_result = src1 ^ src2;                 // xor
            4'b0101: alu_result = {31'b0, (src1_s < src2_s)};  // slt
            4'b0110: alu_result = {31'b0, (src1 < src2)};      // sltu
            4'b0111: alu_result = src1 << src2[4:0];           // sll
            4'b1000: alu_result = src1 >> src2[4:0];           // srl
            4'b1001: alu_result = src1_s >>> src2[4:0];        // sra
            default: alu_result = 32'd0;
        endcase
    end
endmodule
