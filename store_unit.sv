// =============================================================================
//  store_unit.sv
//  Part of the RV32I core.  Compile order (Questa/Quartus):
//     vec_pkg.sv, vector_alu.sv, vector_accel.sv,
//     alu.sv, alu_decoder.sv, alu_src.sv, alu_srca.sv, imm_ext.sv,
//     branch_unit.sv, load_unit.sv, store_unit.sv, main_decoder.sv,
//     program_counter.sv, pc_target.sv, register_file.sv, result_src.sv,
//     instr_mem.sv, data_memory.sv, riscv_top.sv
// =============================================================================

module store_unit(
    input  logic [2:0]  funct3,
    input  logic [1:0]  byte_off,
    input  logic [31:0] rs2,
    output logic [31:0] wdata,
    output logic [3:0]  be
);
    always_comb begin
        case (funct3[1:0])
            2'b00: begin wdata = {4{rs2[7:0]}};  be = 4'b0001 << byte_off;        end // sb
            2'b01: begin wdata = {2{rs2[15:0]}}; be = byte_off[1] ? 4'b1100 : 4'b0011; end // sh
            default: begin wdata = rs2;          be = 4'b1111;                    end // sw
        endcase
    end
endmodule
