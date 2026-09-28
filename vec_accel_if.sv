// =============================================================================
//  vec_accel_if.sv
//  Bus interface for the vector accelerator's memory-mapped register set.
//  Mirrors exactly what riscv_top's periph_we/alu_result[11:0]/rd2/periph_rdata
//  wiring does -- a UVM agent using this interface exercises the accelerator
//  the same way the CPU's `sw`/`lw` instructions do.
// =============================================================================
interface vec_accel_if (input logic clk);
    logic        reset;
    logic        we;
    logic [11:0] addr;
    logic [31:0] wdata;
    logic [31:0] rdata;
endinterface
