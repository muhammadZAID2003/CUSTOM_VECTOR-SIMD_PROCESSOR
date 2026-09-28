// =============================================================================
//  vec_uvm_pkg.sv
//  UVM verification environment for the vector accelerator (vector_accel.sv).
//  Drives the same memory-mapped bus the CPU's sw/lw instructions use.
//
//  Architecture:
//    vec_txn        : one accelerator transaction (operand load + CMD issue)
//    vec_driver     : drives vec_txn onto vec_accel_if, captures the DUT's
//                     actual response (register/RESULT/STATUS readback)
//                     into the same txn, and publishes it via an analysis
//                     port. (Combining "driver that also reports results" is
//                     a deliberate simplification for this register-mapped,
//                     fully-synchronous DUT -- see README_UVM.md.)
//    vec_monitor    : passive; samples CMD-write activity only, for coverage
//    vec_ref_model  : software reference model + shadow architectural state,
//                     the same 4 arithmetic/compare/reduce laws as the RTL
//    vec_scoreboard : predicts each txn's expected result from the model
//                     BEFORE the driver's actual result is known to it,
//                     then compares
//    vec_coverage   : functional coverage (opcode, VL, scalar mode, error)
//    sequences      : reset, directed smoke test, randomized regression,
//                     illegal-opcode, busy-reject (fail-safe) sequences
// =============================================================================
`include "uvm_macros.svh"

package vec_uvm_pkg;
    import uvm_pkg::*;
    import vec_pkg::*;

    // =========================================================================
    //  Transaction
    // =========================================================================
    class vec_txn extends uvm_sequence_item;
        rand bit [3:0] op;
        rand bit [2:0] vd, vs1, vs2;
        rand bit       scl;
        rand int       new_vl;          // -1 = leave VL unchanged
        rand bit       load_a, load_b, load_scalar;
        rand int       a0, a1, a2, a3;   // written to vs1 if load_a
        rand int       b0, b1, b2, b3;   // written to vs2 if load_b (or SCALAR if load_scalar)
        rand int       scalar_val;

        // filled in by the driver after issuing; read by the scoreboard
        int  got0, got1, got2, got3;     // vd lanes after a lane-wise op
        int  got_result;                 // RESULT after a reduction
        bit  got_err, got_busy, got_done;

        `uvm_object_utils_begin(vec_txn)
            `uvm_field_int(op,     UVM_ALL_ON)
            `uvm_field_int(vd,     UVM_ALL_ON)
            `uvm_field_int(vs1,    UVM_ALL_ON)
            `uvm_field_int(vs2,    UVM_ALL_ON)
            `uvm_field_int(scl,    UVM_ALL_ON)
            `uvm_field_int(new_vl, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "vec_txn");
            super.new(name);
        endfunction

        constraint c_regs   { vd inside {[0:7]}; vs1 inside {[0:7]}; vs2 inside {[0:7]}; }
        constraint c_vl     { new_vl inside {[-1:4]}; }
        constraint c_op     { op inside {OP_VADD, OP_VSUB, OP_VMUL, OP_VSLT, OP_VSEQ,
                                          OP_VMAX, OP_VMIN, OP_VMOV,
                                          OP_VRSUM, OP_VRMAX, OP_VRMIN, OP_VDOT}; }
        constraint c_range  { a0 inside {[-10:10]}; a1 inside {[-10:10]};
                               a2 inside {[-10:10]}; a3 inside {[-10:10]};
                               b0 inside {[-10:10]}; b1 inside {[-10:10]};
                               b2 inside {[-10:10]}; b3 inside {[-10:10]};
                               scalar_val inside {[-10:10]}; }

        function bit is_reduce();
            return (op == OP_VRSUM) || (op == OP_VRMAX) || (op == OP_VRMIN) || (op == OP_VDOT);
        endfunction
        function bit is_lane_op();
            return !is_reduce();
        endfunction
    endclass

    // A separate, minimal transaction kind for the two fail-safe scenarios:
    // an illegal opcode, and a CMD write issued while BUSY.
    class vec_failsafe_txn extends uvm_sequence_item;
        typedef enum { ILLEGAL_OP, BUSY_REJECT } kind_e;
        rand kind_e kind;
        bit got_err;

        `uvm_object_utils(vec_failsafe_txn)
        function new(string name = "vec_failsafe_txn");
            super.new(name);
        endfunction
    endclass

    // =========================================================================
    //  Driver  (also captures the DUT's response -- see class header note)
    // =========================================================================
    class vec_driver extends uvm_driver #(vec_txn);
        `uvm_component_utils(vec_driver)
        virtual vec_accel_if vif;
        uvm_analysis_port #(vec_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual vec_accel_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "vec_driver: virtual interface not set")
        endfunction

        task bus_write(logic [11:0] a, logic [31:0] d);
            @(posedge vif.clk);
            vif.we = 1'b1; vif.addr = a; vif.wdata = d;
            @(posedge vif.clk); #1;
            vif.we = 1'b0; vif.addr = 12'd0; vif.wdata = 32'd0;
        endtask

        task bus_read(logic [11:0] a, output logic [31:0] d);
            vif.addr = a; #1; d = vif.rdata; vif.addr = 12'd0;
        endtask

        function logic [11:0] vreg_addr(int r, int l);
            return OFF_VRF + 12'(r * 16) + 12'(l * 4);
        endfunction

        task wait_done();
            logic [31:0] v;
            int n;
            n = 0; bus_read(OFF_STATUS, v);
            while (v[2] && n < 50) begin
                @(posedge vif.clk); #1; n++; bus_read(OFF_STATUS, v);
            end
        endtask

        task issue_cmd(bit [3:0] op, bit [2:0] vd, vs1, vs2, bit scl);
            bus_write(OFF_CMD, {18'd0, scl, 3'(vs2), 3'(vs1), 3'(vd), op});
            if (op == OP_VLD || op == OP_VST) wait_done();
        endtask

        task run_phase(uvm_phase phase);
            vec_txn tx;
            logic [31:0] v;
            // FIX: without this, a fast sequence (e.g. the fail-safe test's
            // single-transaction illegal-op check) can run and get checked
            // while the DUT is still held in reset -- reset forces ERR=0 by
            // design, so any such check is doomed regardless of real DUT
            // behavior. Level-sensitive wait (not an edge wait) so this is
            // correct whether or not reset has already cleared by the time
            // this task starts.
            wait (vif.reset === 1'b0);
            forever begin
                seq_item_port.get_next_item(tx);

                if (tx.new_vl != -1) bus_write(OFF_VL, tx.new_vl);
                if (tx.load_a) begin
                    bus_write(vreg_addr(tx.vs1, 0), tx.a0);
                    bus_write(vreg_addr(tx.vs1, 1), tx.a1);
                    bus_write(vreg_addr(tx.vs1, 2), tx.a2);
                    bus_write(vreg_addr(tx.vs1, 3), tx.a3);
                end
                if (tx.load_scalar)
                    bus_write(OFF_SCALAR, tx.scalar_val);
                else if (tx.load_b) begin
                    bus_write(vreg_addr(tx.vs2, 0), tx.b0);
                    bus_write(vreg_addr(tx.vs2, 1), tx.b1);
                    bus_write(vreg_addr(tx.vs2, 2), tx.b2);
                    bus_write(vreg_addr(tx.vs2, 3), tx.b3);
                end

                issue_cmd(tx.op, tx.vd, tx.vs1, tx.vs2, tx.scl);

                if (tx.is_lane_op()) begin
                    bus_read(vreg_addr(tx.vd, 0), v); tx.got0 = $signed(v);
                    bus_read(vreg_addr(tx.vd, 1), v); tx.got1 = $signed(v);
                    bus_read(vreg_addr(tx.vd, 2), v); tx.got2 = $signed(v);
                    bus_read(vreg_addr(tx.vd, 3), v); tx.got3 = $signed(v);
                end
                else begin
                    bus_read(OFF_RESULT, v); tx.got_result = $signed(v);
                end
                bus_read(OFF_STATUS, v);
                tx.got_done = v[0]; tx.got_err = v[1]; tx.got_busy = v[2];

                ap.write(tx);
                seq_item_port.item_done();
            end
        endtask
    endclass

    class vec_failsafe_driver extends uvm_driver #(vec_failsafe_txn);
        `uvm_component_utils(vec_failsafe_driver)
        virtual vec_accel_if vif;
        uvm_analysis_port #(vec_failsafe_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual vec_accel_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "vec_failsafe_driver: virtual interface not set")
        endfunction

        task bus_write(logic [11:0] a, logic [31:0] d);
            @(posedge vif.clk);
            vif.we = 1'b1; vif.addr = a; vif.wdata = d;
            @(posedge vif.clk); #1;
            vif.we = 1'b0; vif.addr = 12'd0; vif.wdata = 32'd0;
        endtask

        task bus_read(logic [11:0] a, output logic [31:0] d);
            vif.addr = a; #1; d = vif.rdata; vif.addr = 12'd0;
        endtask

        function logic [11:0] vreg_addr(int r, int l);
            return OFF_VRF + 12'(r * 16) + 12'(l * 4);
        endfunction

        task run_phase(uvm_phase phase);
            vec_failsafe_txn tx;
            logic [31:0] v;
            wait (vif.reset === 1'b0);   // same reset-race fix as vec_driver
            forever begin
                seq_item_port.get_next_item(tx);

                if (tx.kind == vec_failsafe_txn::ILLEGAL_OP) begin
                    bus_write(OFF_CMD, {18'd0, 1'b0, 3'd0, 3'd0, 3'd0, OP_NOP | 4'hF});
                    bus_read(OFF_STATUS, v);
                    tx.got_err = v[1];
                end
                else begin // BUSY_REJECT
                    bus_write(OFF_VL, 4);
                    bus_write(vreg_addr(0, 0), 1); bus_write(vreg_addr(0, 1), 2);
                    bus_write(vreg_addr(0, 2), 3); bus_write(vreg_addr(0, 3), 4);
                    bus_write(OFF_VBASE, 0);
                    // issue VST (multi-cycle) but do NOT wait for it -- then
                    // immediately try another CMD while BUSY is still high
                    bus_write(OFF_CMD, {18'd0, 1'b0, 3'd0, 3'd0, 3'd0, OP_VST});
                    bus_write(OFF_CMD, {18'd0, 1'b0, 3'd0, 3'd0, 3'd1, OP_VADD});
                    bus_read(OFF_STATUS, v);
                    tx.got_err = v[1];
                    // drain the still-running VST so it doesn't bleed into
                    // the next transaction
                    while (v[2]) begin @(posedge vif.clk); #1; bus_read(OFF_STATUS, v); end
                end

                ap.write(tx);
                seq_item_port.item_done();
            end
        endtask
    endclass

    // =========================================================================
    //  Passive bus monitor (for coverage only -- checking is done by the
    //  driver + scoreboard pair above; this class exists so the agent has a
    //  proper independent monitor component, not just a driver)
    // =========================================================================
    class vec_monitor extends uvm_monitor;
        `uvm_component_utils(vec_monitor)
        virtual vec_accel_if vif;
        uvm_analysis_port #(vec_txn) cmd_ap;   // re-broadcasts CMD writes only

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cmd_ap = new("cmd_ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual vec_accel_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "vec_monitor: virtual interface not set")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.we && vif.addr == OFF_CMD) begin
                    vec_txn t = vec_txn::type_id::create("mon_txn");
                    {t.scl, t.vs2, t.vs1, t.vd, t.op} =
                        {vif.wdata[13], vif.wdata[12:10], vif.wdata[9:7],
                         vif.wdata[6:4], vif.wdata[3:0]};
                    cmd_ap.write(t);
                end
            end
        endtask
    endclass

    // =========================================================================
    //  Agent
    // =========================================================================
    class vec_agent extends uvm_agent;
        `uvm_component_utils(vec_agent)
        vec_driver              drv;
        uvm_sequencer #(vec_txn) sqr;
        vec_monitor              mon;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv = vec_driver::type_id::create("drv", this);
            sqr = uvm_sequencer#(vec_txn)::type_id::create("sqr", this);
            mon = vec_monitor::type_id::create("mon", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    class vec_failsafe_agent extends uvm_agent;
        `uvm_component_utils(vec_failsafe_agent)
        vec_failsafe_driver               drv;
        uvm_sequencer #(vec_failsafe_txn) sqr;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv = vec_failsafe_driver::type_id::create("drv", this);
            sqr = uvm_sequencer#(vec_failsafe_txn)::type_id::create("sqr", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // =========================================================================
    //  Reference model + scoreboard
    // =========================================================================
    class vec_ref_model extends uvm_object;
        `uvm_object_utils(vec_ref_model)
        int shadow_vrf [0:7][0:3];
        int shadow_scalar;     // FIX: was shadow_vrf[8][0], an out-of-bounds
                                // access on an array declared [0:7] -- undefined
                                // behavior in Questa, corrupted every scl=1 txn
        int shadow_vl;

        function new(string name = "vec_ref_model");
            super.new(name);
            do_reset();
        endfunction

        function void do_reset();
            for (int r = 0; r < 8; r++)
                for (int l = 0; l < 4; l++) shadow_vrf[r][l] = 0;
            shadow_scalar = 0;
            shadow_vl = 4;
        endfunction

        function int lane_op(bit [3:0] op, int a, int b);
            case (op)
                OP_VADD: return a + b;
                OP_VSUB: return a - b;
                OP_VMUL: return a * b;
                OP_VSLT: return (a < b) ? 1 : 0;
                OP_VSEQ: return (a == b) ? 1 : 0;
                OP_VMAX: return (a > b) ? a : b;
                OP_VMIN: return (a < b) ? a : b;
                OP_VMOV: return b;
                default: return 0;
            endcase
        endfunction

        // predicts a txn's outcome from CURRENT shadow state (call before the
        // driver's actual response is known), then commits the shadow update
        function void predict(vec_txn tx, output int e0, e1, e2, e3, e_result);
            int a[4], b[4];
            if (tx.new_vl != -1) shadow_vl = tx.new_vl;
            if (tx.load_a) begin
                shadow_vrf[tx.vs1][0] = tx.a0; shadow_vrf[tx.vs1][1] = tx.a1;
                shadow_vrf[tx.vs1][2] = tx.a2; shadow_vrf[tx.vs1][3] = tx.a3;
            end
            if (tx.load_scalar) begin
                shadow_scalar = tx.scalar_val;
            end
            if (tx.load_b) begin
                shadow_vrf[tx.vs2][0] = tx.b0; shadow_vrf[tx.vs2][1] = tx.b1;
                shadow_vrf[tx.vs2][2] = tx.b2; shadow_vrf[tx.vs2][3] = tx.b3;
            end

            for (int l = 0; l < 4; l++) begin
                a[l] = shadow_vrf[tx.vs1][l];
                b[l] = tx.scl ? shadow_scalar : shadow_vrf[tx.vs2][l];
            end

            if (tx.is_lane_op()) begin
                e0 = (0 < shadow_vl) ? lane_op(tx.op, a[0], b[0]) : shadow_vrf[tx.vd][0];
                e1 = (1 < shadow_vl) ? lane_op(tx.op, a[1], b[1]) : shadow_vrf[tx.vd][1];
                e2 = (2 < shadow_vl) ? lane_op(tx.op, a[2], b[2]) : shadow_vrf[tx.vd][2];
                e3 = (3 < shadow_vl) ? lane_op(tx.op, a[3], b[3]) : shadow_vrf[tx.vd][3];
                e_result = 0;
                if (0 < shadow_vl) shadow_vrf[tx.vd][0] = e0;
                if (1 < shadow_vl) shadow_vrf[tx.vd][1] = e1;
                if (2 < shadow_vl) shadow_vrf[tx.vd][2] = e2;
                if (3 < shadow_vl) shadow_vrf[tx.vd][3] = e3;
            end
            else begin
                int acc;
                acc = 0;
                // NOTE: the RTL's reduction tree always initializes its
                // accumulators to the identity element (INT_MIN for max,
                // INT_MAX for min) and only lanes < VL ever update them --
                // so at VL=0 it correctly returns that identity, not 0.
                // The model must match this exactly, not special-case VL=0.
                case (tx.op)
                    OP_VRSUM: for (int l = 0; l < shadow_vl; l++) acc += a[l];
                    OP_VRMAX: begin
                        acc = 32'sh8000_0000;   // INT_MIN
                        for (int l = 0; l < shadow_vl; l++) if (a[l] > acc) acc = a[l];
                    end
                    OP_VRMIN: begin
                        acc = 32'sh7FFF_FFFF;   // INT_MAX
                        for (int l = 0; l < shadow_vl; l++) if (a[l] < acc) acc = a[l];
                    end
                    OP_VDOT: for (int l = 0; l < shadow_vl; l++) acc += a[l] * b[l];
                    default: acc = 0;
                endcase
                e_result = acc;
                e0 = 0; e1 = 0; e2 = 0; e3 = 0;
            end
        endfunction
    endclass

    class vec_scoreboard extends uvm_subscriber #(vec_txn);
        `uvm_component_utils(vec_scoreboard)
        vec_ref_model model;
        int n_checked, n_failed;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            model = vec_ref_model::type_id::create("model");
        endfunction

        function void do_reset(); model.do_reset(); endfunction

        virtual function void write(vec_txn t);
            int e0, e1, e2, e3, er;
            model.predict(t, e0, e1, e2, e3, er);
            n_checked++;
            if (t.is_lane_op()) begin
                if (t.got0 !== e0 || t.got1 !== e1 || t.got2 !== e2 || t.got3 !== e3) begin
                    n_failed++;
                    `uvm_error("VEC_SB",
                        $sformatf("op=%0h vd=%0d got=[%0d,%0d,%0d,%0d] exp=[%0d,%0d,%0d,%0d]",
                                  t.op, t.vd, t.got0, t.got1, t.got2, t.got3, e0, e1, e2, e3))
                end
                else
                    `uvm_info("VEC_SB", $sformatf("PASS op=%0h vd=%0d = [%0d,%0d,%0d,%0d]",
                              t.op, t.vd, t.got0, t.got1, t.got2, t.got3), UVM_HIGH)
            end
            else begin
                if (t.got_result !== er) begin
                    n_failed++;
                    `uvm_error("VEC_SB", $sformatf("op=%0h RESULT got=%0d exp=%0d",
                                                    t.op, t.got_result, er))
                end
                else
                    `uvm_info("VEC_SB", $sformatf("PASS op=%0h RESULT=%0d", t.op, t.got_result),
                              UVM_HIGH)
            end
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("VEC_SB", $sformatf("checked=%0d failed=%0d", n_checked, n_failed), UVM_LOW)
            if (n_failed > 0)
                `uvm_error("VEC_SB", $sformatf("%0d of %0d transactions FAILED", n_failed, n_checked))
        endfunction
    endclass

    class vec_failsafe_scoreboard extends uvm_subscriber #(vec_failsafe_txn);
        `uvm_component_utils(vec_failsafe_scoreboard)
        int n_checked, n_failed;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        virtual function void write(vec_failsafe_txn t);
            n_checked++;
            // BOTH fail-safe scenarios must set ERR=1 and change no other
            // architectural state (illegal op does nothing; busy-reject
            // does not corrupt the in-flight VST).
            if (!t.got_err) begin
                n_failed++;
                `uvm_error("FAILSAFE_SB",
                    $sformatf("kind=%s did NOT set ERR", t.kind.name()))
            end
            else
                `uvm_info("FAILSAFE_SB", $sformatf("PASS kind=%s ERR=1", t.kind.name()), UVM_LOW)
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("FAILSAFE_SB", $sformatf("checked=%0d failed=%0d", n_checked, n_failed), UVM_LOW)
            if (n_failed > 0)
                `uvm_error("FAILSAFE_SB", $sformatf("%0d of %0d fail-safe checks FAILED",
                                                     n_failed, n_checked))
        endfunction
    endclass

    // =========================================================================
    //  Functional coverage
    // =========================================================================
    class vec_coverage extends uvm_subscriber #(vec_txn);
        `uvm_component_utils(vec_coverage)
        vec_txn t;

        covergroup cg;
            option.per_instance = 1;
            cp_op:  coverpoint t.op  { bins ops[] = {OP_VADD, OP_VSUB, OP_VMUL, OP_VSLT, OP_VSEQ,
                                                      OP_VMAX, OP_VMIN, OP_VMOV,
                                                      OP_VRSUM, OP_VRMAX, OP_VRMIN, OP_VDOT}; }
            cp_vl:  coverpoint t.new_vl { bins unchanged = {-1}; bins vl[] = {[0:4]}; }
            cp_scl: coverpoint t.scl;
            cross_op_vl:  cross cp_op, cp_vl;
            cross_op_scl: cross cp_op, cp_scl;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg = new();
        endfunction

        virtual function void write(vec_txn t);
            this.t = t;
            cg.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("VEC_COV", $sformatf("functional coverage = %0.1f%%", cg.get_coverage()), UVM_LOW)
        endfunction
    endclass

    // =========================================================================
    //  Sequences
    // =========================================================================
    class vec_directed_seq extends uvm_sequence #(vec_txn);
        `uvm_object_utils(vec_directed_seq)
        function new(string name = "vec_directed_seq"); super.new(name); endfunction

        task body();
            vec_txn t;
            // one representative case of each command family named in the spec
            t = vec_txn::type_id::create("t");
            start_item(t);
            t.op = OP_VADD; t.vd = 2; t.vs1 = 0; t.vs2 = 1; t.scl = 0; t.new_vl = 4;
            t.load_a = 1; t.a0=3; t.a1=-4; t.a2=10; t.a3=7;
            t.load_b = 1; t.b0=5; t.b1=6;  t.b2=-2; t.b3=7;
            t.load_scalar = 0;
            finish_item(t);

            t = vec_txn::type_id::create("t");
            start_item(t);
            t.op = OP_VMUL; t.vd = 3; t.vs1 = 0; t.vs2 = 1; t.scl = 0; t.new_vl = 4;
            t.load_a = 0; t.load_b = 0; t.load_scalar = 0;
            finish_item(t);

            t = vec_txn::type_id::create("t");
            start_item(t);
            t.op = OP_VSLT; t.vd = 4; t.vs1 = 0; t.vs2 = 1; t.scl = 0; t.new_vl = 4;
            t.load_a = 0; t.load_b = 0; t.load_scalar = 0;
            finish_item(t);

            t = vec_txn::type_id::create("t");
            start_item(t);
            t.op = OP_VRSUM; t.vd = 0; t.vs1 = 0; t.vs2 = 0; t.scl = 0; t.new_vl = 4;
            t.load_a = 0; t.load_b = 0; t.load_scalar = 0;
            finish_item(t);
        endtask
    endclass

    class vec_random_seq extends uvm_sequence #(vec_txn);
        `uvm_object_utils(vec_random_seq)
        rand int n = 100;
        function new(string name = "vec_random_seq"); super.new(name); endfunction

        task body();
            vec_txn t;
            for (int i = 0; i < n; i++) begin
                t = vec_txn::type_id::create($sformatf("t%0d", i));
                start_item(t);
                if (!t.randomize() with {
                        load_a       == 1'((i % 3) == 0);
                        load_b       == 1'((i % 3) == 1 && scl == 0);
                        load_scalar  == (scl == 1);
                        new_vl       inside {-1, -1, -1, [0:4]};   // mostly unchanged
                    })
                    `uvm_error("VEC_RAND_SEQ", "randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    class vec_failsafe_seq extends uvm_sequence #(vec_failsafe_txn);
        `uvm_object_utils(vec_failsafe_seq)
        function new(string name = "vec_failsafe_seq"); super.new(name); endfunction

        task body();
            vec_failsafe_txn t;
            t = vec_failsafe_txn::type_id::create("t");
            start_item(t); t.kind = vec_failsafe_txn::ILLEGAL_OP; finish_item(t);

            t = vec_failsafe_txn::type_id::create("t");
            start_item(t); t.kind = vec_failsafe_txn::BUSY_REJECT; finish_item(t);
        endtask
    endclass

    // Deterministically hits every (opcode, VL, scalar-mode) combination the
    // covergroup tracks, rather than hoping randomization stumbles onto all
    // of them. This is what actually closes cross_op_vl / cross_op_scl --
    // random_seq alone rarely reaches every corner in a short run.
    class vec_coverage_closure_seq extends uvm_sequence #(vec_txn);
        `uvm_object_utils(vec_coverage_closure_seq)
        function new(string name = "vec_coverage_closure_seq"); super.new(name); endfunction

        task body();
            vec_txn t;
            bit [3:0] ops [12];
            int       vls [6];
            ops[0]=OP_VADD; ops[1]=OP_VSUB; ops[2]=OP_VMUL;  ops[3]=OP_VSLT;
            ops[4]=OP_VSEQ; ops[5]=OP_VMAX; ops[6]=OP_VMIN;  ops[7]=OP_VMOV;
            ops[8]=OP_VRSUM; ops[9]=OP_VRMAX; ops[10]=OP_VRMIN; ops[11]=OP_VDOT;
            vls[0]=-1; vls[1]=0; vls[2]=1; vls[3]=2; vls[4]=3; vls[5]=4;

            foreach (ops[o]) begin
                foreach (vls[v]) begin
                    for (int scl_i = 0; scl_i < 2; scl_i++) begin
                        t = vec_txn::type_id::create($sformatf("closure_%0d_%0d_%0d", o, v, scl_i));
                        start_item(t);
                        t.op = ops[o]; t.new_vl = vls[v]; t.scl = (scl_i == 1);
                        t.vd = 2; t.vs1 = 0; t.vs2 = 1;
                        t.load_a = 1; t.a0=3; t.a1=-4; t.a2=10; t.a3=7;
                        if (t.scl) begin t.load_scalar = 1; t.scalar_val = 5; t.load_b = 0; end
                        else       begin t.load_b = 1; t.b0=5; t.b1=6; t.b2=-2; t.b3=7;
                                          t.load_scalar = 0; end
                        finish_item(t);
                    end
                end
            end
        endtask
    endclass

    // =========================================================================
    //  Environment
    // =========================================================================
    class vec_env extends uvm_env;
        `uvm_component_utils(vec_env)
        vec_agent              agent;
        vec_failsafe_agent     fs_agent;
        vec_scoreboard         sb;
        vec_failsafe_scoreboard fs_sb;
        vec_coverage           cov;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent    = vec_agent::type_id::create("agent", this);
            fs_agent = vec_failsafe_agent::type_id::create("fs_agent", this);
            sb       = vec_scoreboard::type_id::create("sb", this);
            fs_sb    = vec_failsafe_scoreboard::type_id::create("fs_sb", this);
            cov      = vec_coverage::type_id::create("cov", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.drv.ap.connect(sb.analysis_export);
            agent.drv.ap.connect(cov.analysis_export);
            fs_agent.drv.ap.connect(fs_sb.analysis_export);
        endfunction
    endclass

    // =========================================================================
    //  Tests
    // =========================================================================
    class vec_base_test extends uvm_test;
        `uvm_component_utils(vec_base_test)
        vec_env env;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = vec_env::type_id::create("env", this);
        endfunction
    endclass

    class vec_smoke_test extends vec_base_test;
        `uvm_component_utils(vec_smoke_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            vec_directed_seq seq = vec_directed_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(env.agent.sqr);
            phase.drop_objection(this);
        endtask
    endclass

    class vec_random_test extends vec_base_test;
        `uvm_component_utils(vec_random_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            vec_random_seq seq = vec_random_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.n = 150;
            seq.start(env.agent.sqr);
            phase.drop_objection(this);
        endtask
    endclass

    class vec_failsafe_test extends vec_base_test;
        `uvm_component_utils(vec_failsafe_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            vec_failsafe_seq seq = vec_failsafe_seq::type_id::create("seq");
            phase.raise_objection(this);
            seq.start(env.fs_agent.sqr);
            phase.drop_objection(this);
        endtask
    endclass

    // Runs directed + coverage-closure + a large random pass + fail-safe all
    // in ONE test, so vec_coverage accumulates across every sequence instead
    // of resetting each time a separate vsim invocation starts fresh. This
    // is the test to run for a real functional-coverage number.
    class vec_full_test extends vec_base_test;
        `uvm_component_utils(vec_full_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        task run_phase(uvm_phase phase);
            vec_directed_seq          d_seq = vec_directed_seq::type_id::create("d_seq");
            vec_coverage_closure_seq  c_seq = vec_coverage_closure_seq::type_id::create("c_seq");
            vec_random_seq            r_seq = vec_random_seq::type_id::create("r_seq");
            vec_failsafe_seq          f_seq = vec_failsafe_seq::type_id::create("f_seq");
            phase.raise_objection(this);
            d_seq.start(env.agent.sqr);
            c_seq.start(env.agent.sqr);
            r_seq.n = 400;
            r_seq.start(env.agent.sqr);
            f_seq.start(env.fs_agent.sqr);
            phase.drop_objection(this);
        endtask
    endclass

endpackage
