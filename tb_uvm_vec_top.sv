// =============================================================================
//  tb_uvm_vec_top.sv
//  Instantiates vector_accel standalone (bus-driven, same interface the CPU
//  uses) and hands control to the UVM environment in vec_uvm_pkg.sv.
//  Reset is generated here at the top, before run_test() starts, so every
//  UVM test begins with a known-good, already-reset DUT.
//
//  Run (Questa example):
//    vlib work
//    vlog -sv -f uvm/filelist_uvm.f
//    vsim -c work.tb_uvm_vec_top +UVM_TESTNAME=vec_random_test -do "run -all"
// =============================================================================
`include "uvm_macros.svh"

module tb_uvm_vec_top;
    import uvm_pkg::*;
    import vec_pkg::*;
    import vec_uvm_pkg::*;

    logic clk = 0;
    always #5 clk = ~clk;

    vec_accel_if vif (.clk(clk));

    initial begin
        vif.reset = 1'b1;
        vif.we    = 1'b0;
        vif.addr  = 12'd0;
        vif.wdata = 32'd0;
        repeat (3) @(posedge clk);
        @(negedge clk); vif.reset = 1'b0;
    end

    vector_accel dut (
        .clk        (clk),
        .reset      (vif.reset),
        .we         (vif.we),
        .addr       (vif.addr),
        .wdata      (vif.wdata),
        .rdata      (vif.rdata),
        .vmem_addr  (),
        .vmem_we    (),
        .vmem_wdata (),
        .vmem_rdata (32'd0)   // busy-reject / illegal-op tests don't need real memory
    );

    initial begin
        uvm_config_db#(virtual vec_accel_if)::set(null, "*", "vif", vif);
        run_test();
    end

    initial begin
        #200000;
        $display("TIMEOUT: tb_uvm_vec_top did not finish in time");
        $fatal;
    end
endmodule
