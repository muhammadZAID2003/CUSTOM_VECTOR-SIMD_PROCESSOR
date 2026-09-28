// =============================================================================
//  branch_unit.sv
//  Part of the RV32I core.  Compile order (Questa/Quartus):
//     vec_pkg.sv, vector_alu.sv, vector_accel.sv,
//     alu.sv, alu_decoder.sv, alu_src.sv, alu_srca.sv, imm_ext.sv,
//     branch_unit.sv, load_unit.sv, store_unit.sv, main_decoder.sv,
//     program_counter.sv, pc_target.sv, register_file.sv, result_src.sv,
//     instr_mem.sv, data_memory.sv, riscv_top.sv
// =============================================================================

module branch_unit(
    input  logic [2:0]  funct3,
    input  logic [31:0] a, b,
    output logic        taken
);
    logic eq, lt, ltu;
    assign eq  = (a == b);
    assign lt  = ($signed(a) < $signed(b));
    assign ltu = (a < b);
    always_comb begin
        case (funct3)
            3'b000:  taken =  eq;    // beq
            3'b001:  taken = ~eq;    // bne
            3'b100:  taken =  lt;    // blt
            3'b101:  taken = ~lt;    // bge
            3'b110:  taken =  ltu;   // bltu
            3'b111:  taken = ~ltu;   // bgeu
            default: taken = 1'b0;
        endcase
    end
endmodule
