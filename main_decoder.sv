// =============================================================================
//  main_decoder.sv
//  Part of the RV32I core.  Compile order (Questa/Quartus):
//     vec_pkg.sv, vector_alu.sv, vector_accel.sv,
//     alu.sv, alu_decoder.sv, alu_src.sv, alu_srca.sv, imm_ext.sv,
//     branch_unit.sv, load_unit.sv, store_unit.sv, main_decoder.sv,
//     program_counter.sv, pc_target.sv, register_file.sv, result_src.sv,
//     instr_mem.sv, data_memory.sv, riscv_top.sv
// =============================================================================

module main_decoder(
    input  logic [6:0] opcode,
    output logic       reg_write,
    output logic [2:0] imm_src,
    output logic       alu_src,
    output logic [1:0] alu_src_a,
    output logic       mem_write,
    output logic [1:0] result_src,
    output logic       branch,
    output logic       jal,
    output logic       jalr,
    output logic [1:0] alu_op
);
    always_comb begin
        reg_write = 1'b0; imm_src = 3'b000; alu_src = 1'b0; alu_src_a = 2'b00;
        mem_write = 1'b0; result_src = 2'b00; branch = 1'b0;
        jal = 1'b0; jalr = 1'b0; alu_op = 2'b00;

        case (opcode)
            7'b0110011: begin reg_write = 1; alu_op = 2'b10; end                            // R
            7'b0010011: begin reg_write = 1; alu_src = 1; alu_op = 2'b10; end               // I-ALU
            7'b0000011: begin reg_write = 1; alu_src = 1; result_src = 2'b01; end           // load
            7'b0100011: begin imm_src = 3'b001; alu_src = 1; mem_write = 1; end             // store
            7'b1100011: begin imm_src = 3'b010; branch = 1; end                             // branch
            7'b1101111: begin reg_write = 1; imm_src = 3'b011; result_src = 2'b10; jal = 1; end   // JAL
            7'b1100111: begin reg_write = 1; alu_src = 1; result_src = 2'b10; jalr = 1; end       // JALR
            7'b0110111: begin reg_write = 1; imm_src = 3'b100; alu_src = 1; alu_src_a = 2'b10; end // LUI
            7'b0010111: begin reg_write = 1; imm_src = 3'b100; alu_src = 1; alu_src_a = 2'b01; end // AUIPC
            default: ;   // FENCE / SYSTEM / illegal: behave as NOP
        endcase
    end
endmodule
