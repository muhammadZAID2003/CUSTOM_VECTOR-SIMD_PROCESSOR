// =============================================================================
//  core_assertions.sv
//  SVA properties bound directly into riscv_top: stall detection and reset
//  safety, checked independently of the UVM core scoreboard's stall tally.
// =============================================================================
module core_sva (
    input logic        clk,
    input logic        reset,
    input logic        stall,
    input logic        reg_write_eff,
    input logic [31:0] pc_addr,
    input logic [31:0] pc_next
);
    // A load's stall cycle never runs longer than 1 cycle.
    property p_stall_one_cycle;
        @(posedge clk) disable iff (reset) stall |=> !stall;
    endproperty
    a_stall_one_cycle: assert property (p_stall_one_cycle)
        else $error("[STALL] held for more than 1 consecutive cycle");

    // The PC must not advance while a stall is in progress.
    property p_pc_frozen_during_stall;
        @(posedge clk) disable iff (reset) stall |-> (pc_next == pc_addr);
    endproperty
    a_pc_frozen: assert property (p_pc_frozen_during_stall)
        else $error("[STALL] PC advanced during a stall cycle");

    // No architectural register write while reset is asserted.
    property p_no_write_during_reset;
        @(posedge clk) reset |-> !reg_write_eff;
    endproperty
    a_no_write_reset: assert property (p_no_write_during_reset)
        else $error("[FAILSAFE] register write occurred while reset was asserted");
endmodule

bind riscv_top core_sva u_core_sva (.*);
