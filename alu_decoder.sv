// =============================================================================
//  alu_decoder.sv
//  Part of the RV32I core.  Compile order (Questa/Quartus):
//     vec_pkg.sv, vector_alu.sv, vector_accel.sv,
//     alu.sv, alu_decoder.sv, alu_src.sv, alu_srca.sv, imm_ext.sv,
//     branch_unit.sv, load_unit.sv, store_unit.sv, main_decoder.sv,
//     program_counter.sv, pc_target.sv, register_file.sv, result_src.sv,
//     instr_mem.sv, data_memory.sv, riscv_top.sv
// =============================================================================

module alu_decoder(
    input  logic [6:0] opcode,
    input  logic [2:0] funct3,
    input  logic [6:0] funct7,
    input  logic [1:0] alu_op,
    output logic [3:0] alu_control
);
    always_comb begin
        alu_control = 4'b0000;
        case (alu_op)
            2'b00: alu_control = 4'b0000;
            2'b01: alu_control = 4'b0001;
            default: begin
                case (funct3)
                    // funct7[5] only matters for SUB when the instruction is
                    // R-type (opcode[5]=1); for ADDI those bits are immediate.
                    3'b000: alu_control = (opcode[5] && funct7[5]) ? 4'b0001 : 4'b0000;
                    3'b001: alu_control = 4'b0111;                              // sll(i)
                    3'b010: alu_control = 4'b0101;                              // slt(i)
                    3'b011: alu_control = 4'b0110;                              // sltu(i)
                    3'b100: alu_control = 4'b0100;                              // xor(i)
                    3'b101: alu_control = funct7[5] ? 4'b1001 : 4'b1000;        // sra / srl
                    3'b110: alu_control = 4'b0011;                              // or(i)
                    3'b111: alu_control = 4'b0010;                              // and(i)
                    default: alu_control = 4'b0000;
                endcase
            end
        endcase
    end
endmodule
