// =============================================================================
//  vec_accel_assertions.sv
//  SVA properties bound directly into vector_accel, checking the fail-safe
//  behaviors named in the spec independently of the UVM scoreboard (belt
//  and suspenders: a bug that fools one checking method is unlikely to also
//  fool the other). Ports below are connected by NAME via `.*` to
//  vector_accel's own internal signals -- no extra wiring needed anywhere.
// =============================================================================
module vec_accel_sva (
    input logic       clk,
    input logic       reset,
    input logic       cmd_fire,
    input logic        busy_q,
    input logic        err_q,
    input logic        illegal,
    input logic [3:0]  c_op
);
    // A CMD write while BUSY must be rejected: ERR set, nothing else changes.
    property p_busy_reject;
        @(posedge clk) disable iff (reset)
        (cmd_fire && busy_q) |=> err_q;
    endproperty
    a_busy_reject: assert property (p_busy_reject)
        else $error("[FAILSAFE] CMD written while BUSY did not set ERR");

    // Opcode 0xF (illegal) issued while idle must set ERR.
    property p_illegal_sets_err;
        @(posedge clk) disable iff (reset)
        (cmd_fire && !busy_q && illegal) |=> err_q;
    endproperty
    a_illegal_sets_err: assert property (p_illegal_sets_err)
        else $error("[FAILSAFE] illegal opcode did not set ERR");

    // The load/store FSM must never hang: BUSY clears within a bounded
    // number of cycles of going high (VL<=4, so VLD/VST take at most 5).
    // NOTE: the ##[1:20] ranged-delay form below is standard IEEE1800 SVA,
    // fully supported by Questa/VCS, but not by Verilator's SVA subset
    // (used here only for a lint pass) -- this property could not be
    // lint-checked in this sandbox for that reason.
    property p_busy_eventually_clears;
        @(posedge clk) disable iff (reset)
        $rose(busy_q) |-> ##[1:20] !busy_q;
    endproperty
    a_busy_bounded: assert property (p_busy_eventually_clears)
        else $error("[FAILSAFE] BUSY stuck high -- load/store engine hung");

    // Reset must clear BUSY and ERR.
    property p_reset_clears;
        @(posedge clk) reset |=> (!busy_q && !err_q);
    endproperty
    a_reset_clears: assert property (p_reset_clears)
        else $error("reset did not clear BUSY/ERR");
endmodule

bind vector_accel vec_accel_sva u_vec_accel_sva (.*);
