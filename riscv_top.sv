// =============================================================================
//  riscv_top.sv
//  Part of the RV32I core.  Compile order (Questa/Quartus):
//     vec_pkg.sv, vector_alu.sv, vector_accel.sv,
//     alu.sv, alu_decoder.sv, alu_src.sv, alu_srca.sv, imm_ext.sv,
//     branch_unit.sv, load_unit.sv, store_unit.sv, main_decoder.sv,
//     program_counter.sv, pc_target.sv, register_file.sv, result_src.sv,
//     instr_mem.sv, data_memory.sv, riscv_top.sv
// =============================================================================

// =============================================================================
//  riscv_core.sv -- RV32I core (single-cycle, +1 stall cycle on loads)
//                   with Quartus/M9K-friendly synchronous SRAMs and the
//                   memory-mapped vector accelerator.
//
//  Compile order (Questa / Quartus):  vector_accel.sv -> riscv_core.sv
//
//  Address map:
//     0x0000_0000 ...            data RAM  (byte / half / word accesses)
//     0x4000_0000 ... 0x4000_0FFF vector accelerator (word accesses only)
//
//  WHERE THE SRAMs ARE
//    instr_mem   : 1 x M9K-style ROM/RAM, synchronous read.  Its address port
//                  is fed with PC_NEXT, so the RAM's internal address register
//                  IS the program counter -> instruction is valid in the same
//                  cycle as pc_addr, no fetch stall.
//    data_memory : true dual-port RAM (byte-enabled port A = CPU,
//                  port B = vector load/store engine), synchronous read.
//                  Loads therefore take 2 cycles (see `stall` in riscv_top).
//
//  Summary of fixes vs. the previous version
//    * LUI / AUIPC / JALR implemented (new SrcA mux, jalr target mux)
//    * All 6 branches (BEQ BNE BLT BGE BLTU BGEU) via a real comparator
//    * LB LH LBU LHU / SB SH via load_unit / store_unit + byte enables
//    * ALU default is 0 (no X), imm_ext no longer has a dangling clk port
//    * reg/mem writes are blocked while reset is high
// =============================================================================


module riscv_top #(
    parameter int    IMEM_DEPTH = 256,                 // words
    parameter int    DMEM_DEPTH = 256,                 // words
    parameter IMEM_FILE  = "program.hex"
)(
    input  logic clk,
    input  logic reset
);
    import vec_pkg::*;

    logic [31:0] pc_addr, pc_target_addr, pc_next, pc_next_raw, pc_plus4, result;
    logic [31:0] instr, src_a, src_b, imm_ext_w, alu_result, read_data, load_data;
    logic        pc_src, reg_write, alu_src, mem_write, branch, jal, jalr, br_taken;
    logic [1:0]  result_src, alu_op, alu_src_a;
    logic [2:0]  imm_src;
    logic [3:0]  alu_control;
    logic [31:0] rd1, rd2;

    // ---- load stall: sync-read RAM needs one extra cycle -------------------
    logic is_load, stall, ld_phase_q;
    assign is_load = (instr[6:0] == 7'b0000011);
    assign stall   = is_load & ~ld_phase_q;           // cycle 1 of a load
    always_ff @(posedge clk)
        if (reset) ld_phase_q <= 1'b0;
        else       ld_phase_q <= stall;

    // ---- data-bus decode ---------------------------------------------------
    logic                is_periph;
    logic [3:0]          ram_be, st_be;
    logic [31:0]         st_wdata, ram_rdata, periph_rdata;
    logic                periph_we, reg_write_eff;
    logic [31:0]         vmem_addr, vmem_wdata, vmem_rdata;
    logic                vmem_we;

    assign is_periph     = (alu_result[31:12] == 20'h40000);
    assign ram_be        = (mem_write & ~is_periph & ~reset) ? st_be : 4'b0000;
    assign periph_we     = mem_write & is_periph & ~reset & (instr[14:12] == 3'b010); // sw only
    assign read_data     = is_periph ? periph_rdata : ram_rdata;
    assign reg_write_eff = reg_write & ~stall & ~reset;

    // ---- next PC -----------------------------------------------------------
    assign pc_plus4    = pc_addr + 32'd4;
    assign pc_src      = jal | (branch & br_taken);
    assign pc_next_raw = jalr   ? {alu_result[31:1], 1'b0} :
                         pc_src ? pc_target_addr           : pc_plus4;
    assign pc_next     = stall ? pc_addr : pc_next_raw;

    program_counter pc(.clk(clk), .reset(reset), .pc_next(pc_next), .pc_addr(pc_addr));

    // The SRAM's address register plays the role of the PC register.
    instr_mem #(.DEPTH(IMEM_DEPTH), .INIT_FILE(IMEM_FILE)) im(
                    .clk(clk),
                    .addr(reset ? 32'b0 : pc_next),
                    .instr(instr));

    pc_target pc_t(.imm_ext(imm_ext_w), .pc_addr(pc_addr), .pc_target_addr(pc_target_addr));

    register_file reg_file(
                    .clk(clk), .reg_write(reg_write_eff), .wd3(result),
                    .a1(instr[19:15]), .a2(instr[24:20]), .a3(instr[11:7]),
                    .rd1(rd1), .rd2(rd2));

    ALU_srca alu_mux_a(.sel(alu_src_a), .rd1(rd1), .pc(pc_addr), .src_a(src_a));
    ALU_src  alu_mux  (.alu_src(alu_src), .imm_ext(imm_ext_w), .rd2(rd2), .src_b(src_b));

    alu alu_res(.alu_control(alu_control), .src1(src_a), .src2(src_b), .alu_result(alu_result));

    branch_unit br_unit(.funct3(instr[14:12]), .a(rd1), .b(rd2), .taken(br_taken));

    // ---- data memory (SRAM) ------------------------------------------------
    store_unit st_unit(.funct3(instr[14:12]), .byte_off(alu_result[1:0]),
                       .rs2(rd2), .wdata(st_wdata), .be(st_be));

    data_memory #(.DEPTH(DMEM_DEPTH)) data_mem(
                    .clk(clk),
                    .a_we(ram_be), .a_addr(alu_result), .a_wdata(st_wdata), .a_rdata(ram_rdata),
                    .b_we(vmem_we), .b_addr(vmem_addr), .b_wdata(vmem_wdata), .b_rdata(vmem_rdata));

    load_unit ld_unit(.funct3(instr[14:12]), .byte_off(alu_result[1:0]),
                      .raw(read_data), .data(load_data));

    // ---- vector accelerator -----------------------------------------------
    vector_accel vec_acc(
                    .clk(clk), .reset(reset),
                    .we(periph_we), .addr(alu_result[11:0]), .wdata(rd2), .rdata(periph_rdata),
                    .vmem_addr(vmem_addr), .vmem_we(vmem_we),
                    .vmem_wdata(vmem_wdata), .vmem_rdata(vmem_rdata));

    RESULT_src res_src(.result_src(result_src), .alu_result(alu_result),
                       .read_data(load_data), .pc_plus4(pc_plus4), .result(result));

    imm_ext immed_ext(.instr(instr), .imm_src(imm_src), .imm(imm_ext_w));

    main_decoder main_dec(
                    .opcode(instr[6:0]), .reg_write(reg_write), .imm_src(imm_src),
                    .alu_src(alu_src), .alu_src_a(alu_src_a), .mem_write(mem_write),
                    .result_src(result_src), .branch(branch), .jal(jal), .jalr(jalr),
                    .alu_op(alu_op));

    alu_decoder alu_dec(
                    .opcode(instr[6:0]), .funct3(instr[14:12]), .funct7(instr[31:25]),
                    .alu_op(alu_op), .alu_control(alu_control));
endmodule
