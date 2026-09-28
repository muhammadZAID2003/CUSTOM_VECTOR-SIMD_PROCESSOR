// =============================================================================
//  tb_uvm_core_top.sv
//  Instantiates riscv_top and taps internal signals into core_probe_if for
//  the UVM core environment in core_uvm_pkg.sv. The program is loaded into
//  instr_mem statically via $readmemh (same mechanism as tb_rv32i_core.sv);
//  the UVM test only controls reset and waits for the program to finish.
//
//  Run (Questa example):
//    vlib work
//    vlog -sv -f uvm/filelist_uvm.f
//    vsim -c work.tb_uvm_core_top +UVM_TESTNAME=core_test -do "run -all"
//  (rv32i_test.hex must be in the run directory)
// =============================================================================
`include "uvm_macros.svh"

module tb_uvm_core_top;
    import uvm_pkg::*;
    import core_uvm_pkg::*;

    logic clk = 0;
    always #5 clk = ~clk;

    core_probe_if probe (.clk(clk));
    initial probe.reset = 1'b1;

    logic reset;
    assign reset = probe.reset;

    riscv_top #(.IMEM_FILE("rv32i_test.hex")) dut (.clk(clk), .reset(reset));

    // white-box taps into the DUT hierarchy -- see core_probe_if.sv
    assign probe.pc_addr   = dut.pc_addr;
    assign probe.instr     = dut.instr;
    assign probe.reg_write = dut.reg_write_eff;
    assign probe.waddr     = dut.instr[11:7];
    assign probe.wdata     = dut.result;
    assign probe.stall     = dut.stall;
    assign probe.vec_busy  = dut.vec_acc.busy_q;
    assign probe.vec_err   = dut.vec_acc.err_q;

    initial begin
        uvm_config_db#(virtual core_probe_if)::set(null, "*", "vif", probe);
        run_test();
    end

    initial begin
        #100000;
        $display("TIMEOUT: tb_uvm_core_top did not finish in time");
        $fatal;
    end
endmodule
