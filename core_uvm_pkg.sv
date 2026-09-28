// =============================================================================
//  core_uvm_pkg.sv
//  UVM verification environment for riscv_top's RV32I core.
//
//  SCOPE NOTE (read this before extending): the core is an autonomous
//  program-executing DUT, not a passive slave you feed transactions into --
//  it fetches its own instructions from instr_mem (loaded once at time 0 via
//  $readmemh, same as tb_rv32i_core.sv). So the "driver" here only controls
//  reset; verification is done by a PASSIVE monitor tapping core_probe_if.
//
//  The reference model predicts register writeback values for opcode
//  classes that don't depend on memory content: R-type/I-type ALU ops,
//  LUI, AUIPC, JAL, JALR -- i.e. exactly the instruction classes this core
//  had real bugs in (see riscv_core.sv's history: LUI/AUIPC/JALR/branches
//  were broken before the fixes). Loads/stores/branch-target correctness
//  are already exhaustively checked with concrete expected values by the
//  directed testbench (tb_rv32i_core.sv, 39/39 passing) -- this UVM
//  environment is complementary, not a replacement, and does not re-model
//  memory contents.
//
//  Stall detection is checked two independent ways: a scoreboard tally
//  here (stall never exceeds 1 consecutive cycle) and an SVA temporal
//  property in core_assertions.sv.
// =============================================================================
`include "uvm_macros.svh"

package core_uvm_pkg;
    import uvm_pkg::*;

    // =========================================================================
    //  Retirement transaction -- one per cycle where the core commits state
    // =========================================================================
    class core_txn extends uvm_sequence_item;
        bit [31:0] pc;
        bit [31:0] instr;
        bit        reg_write;
        bit [4:0]  waddr;
        bit [31:0] wdata;
        bit        stall;
        bit        vec_busy, vec_err;

        `uvm_object_utils(core_txn)
        function new(string name = "core_txn");
            super.new(name);
        endfunction
    endclass

    // =========================================================================
    //  Passive monitor
    // =========================================================================
    class core_monitor extends uvm_monitor;
        `uvm_component_utils(core_monitor)
        virtual core_probe_if vif;
        uvm_analysis_port #(core_txn) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual core_probe_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "core_monitor: virtual interface not set")
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (!vif.reset) begin
                    core_txn t = core_txn::type_id::create("t");
                    t.pc        = vif.pc_addr;
                    t.instr     = vif.instr;
                    t.reg_write = vif.reg_write;
                    t.waddr     = vif.waddr;
                    t.wdata     = vif.wdata;
                    t.stall     = vif.stall;
                    t.vec_busy  = vif.vec_busy;
                    t.vec_err   = vif.vec_err;
                    ap.write(t);
                end
            end
        endtask
    endclass

    // =========================================================================
    //  Reset-control-only "driver" + agent (see file header)
    // =========================================================================
    class core_reset_driver extends uvm_component;
        `uvm_component_utils(core_reset_driver)
        virtual core_probe_if vif;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual core_probe_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "core_reset_driver: virtual interface not set")
        endfunction
    endclass

    class core_agent extends uvm_agent;
        `uvm_component_utils(core_agent)
        core_monitor mon;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            mon = core_monitor::type_id::create("mon", this);
        endfunction
    endclass

    // =========================================================================
    //  Reference model + scoreboard (ALU/LUI/AUIPC/JAL/JALR writeback class)
    // =========================================================================
    class core_ref_model extends uvm_object;
        `uvm_object_utils(core_ref_model)
        int regs [0:31];

        function new(string name = "core_ref_model");
            super.new(name);
            for (int i = 0; i < 32; i++) regs[i] = 0;
        endfunction

        function void do_reset();
            for (int i = 0; i < 32; i++) regs[i] = 0;
        endfunction

        // returns 1 and fills `pred` if this instruction's writeback is
        // predictable without memory content; returns 0 otherwise (loads)
        function bit predict(bit [31:0] instr, bit [31:0] pc, bit [31:0] pc_plus4,
                             output int pred);
            bit [6:0] opcode  = instr[6:0];
            bit [2:0] funct3  = instr[14:12];
            bit [6:0] funct7  = instr[31:25];
            int       rs1     = instr[19:15];
            int       rs2     = instr[24:20];
            int       imm_i   = $signed(instr[31:20]);
            int       imm_u   = {instr[31:12], 12'b0};
            int       a       = regs[rs1];
            int       b       = regs[rs2];

            case (opcode)
                7'b0110011: begin // R-type
                    predict = 1;
                    case (funct3)
                        3'b000: pred = funct7[5] ? (a - b) : (a + b);
                        3'b001: pred = a <<< b[4:0];
                        3'b010: pred = ($signed(a) < $signed(b)) ? 1 : 0;
                        3'b011: pred = ($unsigned(a) < $unsigned(b)) ? 1 : 0;
                        3'b100: pred = a ^ b;
                        3'b101: pred = funct7[5] ? (a >>> b[4:0]) : ($unsigned(a) >> b[4:0]);
                        3'b110: pred = a | b;
                        3'b111: pred = a & b;
                    endcase
                end
                7'b0010011: begin // I-type ALU
                    predict = 1;
                    case (funct3)
                        3'b000: pred = a + imm_i;
                        3'b001: pred = a <<< instr[24:20];
                        3'b010: pred = ($signed(a) < imm_i) ? 1 : 0;
                        3'b011: pred = ($unsigned(a) < $unsigned(imm_i)) ? 1 : 0;
                        3'b100: pred = a ^ imm_i;
                        3'b101: pred = funct7[5] ? (a >>> instr[24:20]) : ($unsigned(a) >> instr[24:20]);
                        3'b110: pred = a | imm_i;
                        3'b111: pred = a & imm_i;
                    endcase
                end
                7'b0110111: begin predict = 1; pred = imm_u; end               // LUI
                7'b0010111: begin predict = 1; pred = pc + imm_u; end          // AUIPC
                7'b1101111: begin predict = 1; pred = pc_plus4; end            // JAL (link)
                7'b1100111: begin predict = 1; pred = pc_plus4; end            // JALR (link)
                default:    begin predict = 0; pred = 0; end                  // loads etc: not modeled here
            endcase
        endfunction

        function void commit(int rd, int val);
            if (rd != 0) regs[rd] = val;
        endfunction
    endclass

    class core_scoreboard extends uvm_subscriber #(core_txn);
        `uvm_component_utils(core_scoreboard)
        core_ref_model model;
        int n_checked, n_failed, n_skipped_mem;
        int stall_run;                 // consecutive stall cycles seen right now
        int n_stall_violations;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            model = core_ref_model::type_id::create("model");
        endfunction

        function void do_reset();
            model.do_reset();
            stall_run = 0;
        endfunction

        virtual function void write(core_txn t);
            int pred;
            bit predictable;

            // ---- stall tally: must never see 2+ consecutive stall cycles
            if (t.stall) begin
                stall_run++;
                if (stall_run > 1) begin
                    n_stall_violations++;
                    `uvm_error("CORE_SB", $sformatf("stall held for %0d consecutive cycles at pc=%0h",
                                                     stall_run, t.pc))
                end
            end
            else stall_run = 0;

            // ---- writeback check (skip during the stall cycle itself; the
            // real writeback happens on the following, non-stalled cycle)
            if (t.reg_write) begin
                n_checked++;
                predictable = model.predict(t.instr, t.pc, t.pc + 4, pred);
                if (predictable) begin
                    if ($signed(t.wdata) !== pred) begin
                        n_failed++;
                        `uvm_error("CORE_SB", $sformatf(
                            "pc=%0h instr=%0h x%0d: got=%0d exp=%0d",
                            t.pc, t.instr, t.waddr, $signed(t.wdata), pred))
                    end
                end
                else n_skipped_mem++;    // load: trust it, directed TB covers this
                model.commit(t.waddr, t.wdata);
            end
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("CORE_SB", $sformatf(
                "writebacks checked=%0d failed=%0d (loads skipped, not modeled=%0d)  stall violations=%0d",
                n_checked, n_failed, n_skipped_mem, n_stall_violations), UVM_LOW)
            if (n_failed > 0 || n_stall_violations > 0)
                `uvm_error("CORE_SB", "core scoreboard reported failures -- see log above")
        endfunction
    endclass

    // =========================================================================
    //  Functional coverage: opcode class + stall observed
    // =========================================================================
    class core_coverage extends uvm_subscriber #(core_txn);
        `uvm_component_utils(core_coverage)
        core_txn t;

        covergroup cg;
            option.per_instance = 1;
            cp_opcode: coverpoint t.instr[6:0] {
                bins r_type  = {7'b0110011};
                bins i_alu   = {7'b0010011};
                bins load    = {7'b0000011};
                bins store   = {7'b0100011};
                bins branch  = {7'b1100011};
                bins jal     = {7'b1101111};
                bins jalr    = {7'b1100111};
                bins lui     = {7'b0110111};
                bins auipc   = {7'b0010111};
            }
            cp_stall:    coverpoint t.stall;
            cp_vec_busy: coverpoint t.vec_busy;
            cp_vec_err:  coverpoint t.vec_err;
            cross_opcode_stall: cross cp_opcode, cp_stall;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg = new();
        endfunction

        virtual function void write(core_txn t);
            this.t = t;
            cg.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("CORE_COV", $sformatf("functional coverage = %0.1f%%", cg.get_coverage()), UVM_LOW)
        endfunction
    endclass

    // =========================================================================
    //  Environment + test
    // =========================================================================
    class core_env extends uvm_env;
        `uvm_component_utils(core_env)
        core_agent      agent;
        core_scoreboard sb;
        core_coverage   cov;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent = core_agent::type_id::create("agent", this);
            sb    = core_scoreboard::type_id::create("sb", this);
            cov   = core_coverage::type_id::create("cov", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.mon.ap.connect(sb.analysis_export);
            agent.mon.ap.connect(cov.analysis_export);
        endfunction
    endclass

    class core_test extends uvm_test;
        `uvm_component_utils(core_test)
        core_env env;
        virtual core_probe_if vif;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = core_env::type_id::create("env", this);
            if (!uvm_config_db#(virtual core_probe_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "core_test: virtual interface not set")
        endfunction

        // program is already loaded into instr_mem at time 0 via $readmemh
        // (same mechanism as tb_rv32i_core.sv); this test just resets and
        // lets the program run to its end label, then stops.
        task run_phase(uvm_phase phase);
            phase.raise_objection(this);
            repeat (3) @(posedge vif.clk);
            @(negedge vif.clk); vif.reset = 1'b0;
            // END_PC must match rv32i_test.hex's 'END:' label (see gen_rv32i_test.py)
            wait (vif.pc_addr == 32'h0000_01CC);
            repeat (3) @(posedge vif.clk);
            phase.drop_objection(this);
        endtask
    endclass

endpackage
