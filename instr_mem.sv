// =============================================================================
//  instr_mem.sv
//  Part of the RV32I core.  Compile order (Questa/Quartus):
//     vec_pkg.sv, vector_alu.sv, vector_accel.sv,
//     alu.sv, alu_decoder.sv, alu_src.sv, alu_srca.sv, imm_ext.sv,
//     branch_unit.sv, load_unit.sv, store_unit.sv, main_decoder.sv,
//     program_counter.sv, pc_target.sv, register_file.sv, result_src.sv,
//     instr_mem.sv, data_memory.sv, riscv_top.sv
// =============================================================================

module instr_mem #(
    parameter int    DEPTH     = 256,
    parameter INIT_FILE = "program.hex"
)(
    input  logic        clk,
    input  logic [31:0] addr,
    output logic [31:0] instr
);
    localparam int AW = $clog2(DEPTH);

    logic [31:0] memory [0:DEPTH-1];

    initial begin
        for (int i = 0; i < DEPTH; i++) memory[i] = 32'h0000_0013;   // NOP
        $readmemh(INIT_FILE, memory);      // Quartus uses this as RAM init data
    end

    always_ff @(posedge clk)
        instr <= memory[addr[AW+1:2]];
endmodule
