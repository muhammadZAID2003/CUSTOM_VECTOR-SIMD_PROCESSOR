// =============================================================================
//  load_unit.sv
//  Part of the RV32I core.  Compile order (Questa/Quartus):
//     vec_pkg.sv, vector_alu.sv, vector_accel.sv,
//     alu.sv, alu_decoder.sv, alu_src.sv, alu_srca.sv, imm_ext.sv,
//     branch_unit.sv, load_unit.sv, store_unit.sv, main_decoder.sv,
//     program_counter.sv, pc_target.sv, register_file.sv, result_src.sv,
//     instr_mem.sv, data_memory.sv, riscv_top.sv
// =============================================================================

module load_unit(
    input  logic [2:0]  funct3,
    input  logic [1:0]  byte_off,
    input  logic [31:0] raw,
    output logic [31:0] data
);
    logic [7:0]  b;
    logic [15:0] h;
    always_comb begin
        b = raw[8*byte_off +: 8];
        h = byte_off[1] ? raw[31:16] : raw[15:0];
        case (funct3)
            3'b000:  data = {{24{b[7]}},  b};    // lb
            3'b001:  data = {{16{h[15]}}, h};    // lh
            3'b100:  data = {24'b0, b};          // lbu
            3'b101:  data = {16'b0, h};          // lhu
            default: data = raw;                 // lw
        endcase
    end
endmodule
