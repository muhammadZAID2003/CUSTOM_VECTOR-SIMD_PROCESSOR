// =============================================================================
//  core_probe_if.sv
//  Passive white-box probe into riscv_top, used by the UVM core monitor.
//  These are internal signals (not a real external bus), connected at the
//  testbench top via continuous assigns to the DUT hierarchy -- see
//  tb_uvm_core_top.sv. The monitor never drives this interface.
// =============================================================================
interface core_probe_if (input logic clk);
    logic        reset;
    logic [31:0] pc_addr;      // PC of the instruction currently in the pipe
    logic [31:0] instr;        // that instruction's encoding
    logic        reg_write;    // reg_write_eff: a real (non-stalled) writeback
    logic [4:0]  waddr;        // destination register (instr[11:7])
    logic [31:0] wdata;        // value written back (= `result`)
    logic        stall;        // load-stall cycle in progress
    logic        vec_busy;     // vector accelerator STATUS.BUSY
    logic        vec_err;      // vector accelerator STATUS.ERR
endinterface
