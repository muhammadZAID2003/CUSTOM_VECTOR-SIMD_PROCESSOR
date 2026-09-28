// =============================================================================
//  tb_vector_accel.sv -- directed, self-checking testbench for vector_accel
//
//  The testbench plays the role of the CPU: it performs bus writes/reads to
//  the accelerator's register map (exactly what the core's sw/lw do) and
//  checks every result.  A real data_memory instance backs VLD/VST.
//
//  Compile order: vector_accel.sv, riscv_core.sv (for data_memory), this file.
// =============================================================================
`timescale 1ns/1ps

module tb_vector_accel;
    import vec_pkg::*;

    logic                clk = 0, reset = 1;
    logic                we = 0;
    logic [11:0]         addr = 12'd0;
    logic [31:0]         wdata = 32'd0, rdata;
    logic [31:0]         vmem_addr, vmem_wdata, vmem_rdata;
    logic                vmem_we;

    vector_accel dut (
        .clk(clk), .reset(reset), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata),
        .vmem_addr(vmem_addr), .vmem_we(vmem_we),
        .vmem_wdata(vmem_wdata), .vmem_rdata(vmem_rdata));

    // synchronous-read dual-port SRAM model; port A (CPU) is unused here
    data_memory #(.DEPTH(64)) ram (
        .clk(clk),
        .a_we(4'b0), .a_addr(32'd0), .a_wdata(32'd0), .a_rdata(),
        .b_we(vmem_we), .b_addr(vmem_addr), .b_wdata(vmem_wdata), .b_rdata(vmem_rdata));

    always #5 clk = ~clk;

    int errors = 0;
    int checks = 0;
    int n_cmds = 0;                       // commands issued since reset

    // ram now stores each 32-bit word as 4 separate byte-lane RAMs
    // (ram.byte_lane[i].mem); these helpers preload/check it by word index.
    function automatic logic [31:0] rd_ram(input int word_idx);
        rd_ram = { ram.byte_lane[3].u_ram.mem[word_idx], ram.byte_lane[2].u_ram.mem[word_idx],
                   ram.byte_lane[1].u_ram.mem[word_idx], ram.byte_lane[0].u_ram.mem[word_idx] };
    endfunction

    task automatic wr_ram(input int word_idx, input logic [31:0] val);
        begin
            ram.byte_lane[0].u_ram.mem[word_idx] = val[7:0];
            ram.byte_lane[1].u_ram.mem[word_idx] = val[15:8];
            ram.byte_lane[2].u_ram.mem[word_idx] = val[23:16];
            ram.byte_lane[3].u_ram.mem[word_idx] = val[31:24];
        end
    endtask

    // ------------------------------------------------------------------ bus
    // Signals change 1 ns after a clock edge and are sampled by the next edge.
    task automatic bus_write(input logic [11:0] a, input logic [31:0] d);
        begin
            we = 1'b1; addr = a; wdata = d;
            @(posedge clk); #1;
            we = 1'b0; addr = 12'd0; wdata = 32'd0;
        end
    endtask

    task automatic bus_read(input logic [11:0] a, output logic [31:0] d);
        begin
            addr = a; #1; d = rdata; addr = 12'd0;
        end
    endtask

    function automatic logic [11:0] vreg_addr(input int r, input int l);
        return OFF_VRF + 12'(r * 16) + 12'(l * 4);
    endfunction

    // -------------------------------------------------------------- helpers
    task automatic expect32(input logic [31:0] got, input logic [31:0] exp, input string what);
        begin
            checks++;
            if (got !== exp) begin
                errors++;
                $display("FAIL  %-28s got %0d (0x%08h)  expected %0d (0x%08h)",
                         what, $signed(got), got, $signed(exp), exp);
            end
            else
                $display("PASS  %-28s = %0d", what, $signed(got));
        end
    endtask

    task automatic set_vec(input int r, input int l0, input int l1, input int l2, input int l3);
        begin
            bus_write(vreg_addr(r, 0), l0);
            bus_write(vreg_addr(r, 1), l1);
            bus_write(vreg_addr(r, 2), l2);
            bus_write(vreg_addr(r, 3), l3);
        end
    endtask

    task automatic check_vec(input int r, input int e0, input int e1, input int e2, input int e3,
                             input string name);
        int e [4];
        logic [31:0] v;
        begin
            e[0] = e0; e[1] = e1; e[2] = e2; e[3] = e3;
            for (int l = 0; l < 4; l++) begin
                bus_read(vreg_addr(r, l), v);
                expect32(v, e[l], $sformatf("%s V%0d[%0d]", name, r, l));
            end
        end
    endtask

    // issue_nb : write CMD and return immediately (used to observe BUSY)
    task automatic issue_nb(input logic [3:0] op, input int vd, input int vs1, input int vs2,
                            input logic scl);
        begin
            bus_write(OFF_CMD, {18'd0, scl, 3'(vs2), 3'(vs1), 3'(vd), op});
            n_cmds++;
        end
    endtask

    // wait until STATUS.BUSY==0 (with a timeout so a hung FSM fails the test)
    task automatic wait_done(input string what);
        logic [31:0] v;
        int n;
        begin
            n = 0; bus_read(OFF_STATUS, v);
            while (v[2] && n < 50) begin
                @(posedge clk); #1; n++; bus_read(OFF_STATUS, v);
            end
            checks++;
            if (v[2]) begin errors++; $display("FAIL  %s never finished (BUSY stuck)", what); end
        end
    endtask

    // issue : like the CPU driver code -- VLD/VST are followed by a DONE poll
    task automatic issue(input logic [3:0] op, input int vd, input int vs1, input int vs2,
                         input logic scl);
        begin
            issue_nb(op, vd, vs1, vs2, scl);
            if (op == OP_VLD || op == OP_VST) wait_done("VLD/VST");
        end
    endtask

    task automatic check_result(input int e, input string name);
        logic [31:0] v;
        begin
            bus_read(OFF_RESULT, v);
            expect32(v, e, {"RESULT after ", name});
        end
    endtask

    task automatic check_status(input logic [31:0] mask, input logic [31:0] e, input string name);
        logic [31:0] v;
        begin
            bus_read(OFF_STATUS, v);
            expect32(v & mask, e, {"STATUS ", name});
        end
    endtask

    // =========================================================================
    //  REFERENCE MODEL
    //  Independent of the RTL: computes what vector_accel SHOULD produce for
    //  a lane-wise op, a reduction op, and whether an opcode is illegal.
    //  A shadow copy of the vector register file and RESULT register is kept
    //  in the testbench (shadow_vrf / shadow_result) and updated by these
    //  same functions, so randomized sequences can be checked automatically
    //  instead of relying on hand-picked expected constants.
    // =========================================================================
    function automatic logic signed [31:0] ref_lane_op(input logic [3:0] op,
                                                        input logic signed [31:0] a,
                                                        input logic signed [31:0] b);
        case (op)
            OP_VADD: ref_lane_op = a + b;
            OP_VSUB: ref_lane_op = a - b;
            OP_VMUL: ref_lane_op = a * b;
            OP_VSLT: ref_lane_op = (a < b) ? 32'sd1 : 32'sd0;
            OP_VSEQ: ref_lane_op = (a == b) ? 32'sd1 : 32'sd0;
            OP_VMAX: ref_lane_op = (a > b) ? a : b;
            OP_VMIN: ref_lane_op = (a < b) ? a : b;
            OP_VMOV: ref_lane_op = b;               // VD <- VS2 (or SCALAR if scl)
            default: ref_lane_op = 32'sd0;
        endcase
    endfunction

    // a0..a3 / b0..b3 replace unpacked-array ports (not all simulators
    // handle fixed-size array function ports the same way).
    function automatic logic signed [31:0] ref_reduce_op(
            input logic [3:0] op, input int vl,
            input logic signed [31:0] a0, input logic signed [31:0] a1,
            input logic signed [31:0] a2, input logic signed [31:0] a3,
            input logic signed [31:0] b0, input logic signed [31:0] b1,
            input logic signed [31:0] b2, input logic signed [31:0] b3);
        logic signed [31:0] a [4], b [4];
        logic signed [31:0] acc;
        begin
            a[0]=a0; a[1]=a1; a[2]=a2; a[3]=a3;
            b[0]=b0; b[1]=b1; b[2]=b2; b[3]=b3;
            acc = 32'sd0;
            case (op)
                OP_VRSUM: begin
                    for (int l = 0; l < vl; l++) acc += a[l];
                end
                OP_VRMAX: begin
                    // The RTL's reduction tree initializes its accumulator
                    // to the identity element (INT_MIN) and only lanes < vl
                    // ever update it, so at vl=0 it correctly returns
                    // INT_MIN, not 0 (verified directly against
                    // vector_alu.sv; same fix as vec_uvm_pkg.sv).
                    acc = 32'sh8000_0000;
                    for (int l = 0; l < vl; l++) if (a[l] > acc) acc = a[l];
                end
                OP_VRMIN: begin
                    acc = 32'sh7FFF_FFFF;   // identity element for min
                    for (int l = 0; l < vl; l++) if (a[l] < acc) acc = a[l];
                end
                OP_VDOT: begin
                    for (int l = 0; l < vl; l++) acc += a[l] * b[l];
                end
                default: acc = 32'sd0;
            endcase
            ref_reduce_op = acc;
        end
    endfunction

    function automatic bit ref_is_reduce(input logic [3:0] op);
        ref_is_reduce = (op == OP_VRSUM) || (op == OP_VRMAX) ||
                        (op == OP_VRMIN) || (op == OP_VDOT);
    endfunction

    function automatic bit ref_is_lane_op(input logic [3:0] op);
        ref_is_lane_op = (op == OP_VADD) || (op == OP_VSUB) || (op == OP_VMUL) ||
                         (op == OP_VSLT) || (op == OP_VSEQ) || (op == OP_VMAX) ||
                         (op == OP_VMIN) || (op == OP_VMOV);
    endfunction

    function automatic bit ref_is_illegal(input logic [3:0] op);
        ref_is_illegal = (op == 4'hF);
    endfunction

    // ---- shadow state: mirrors what the DUT's architectural state should be
    int          shadow_vrf [0:NVREG-1][0:3];
    int          shadow_scalar;
    int          shadow_vl;
    int          shadow_result;

    task automatic shadow_reset();
        begin
            for (int r = 0; r < NVREG; r++)
                for (int l = 0; l < 4; l++) shadow_vrf[r][l] = 0;
            shadow_scalar = 0;
            shadow_vl     = LANES;
            shadow_result = 0;
        end
    endtask

    // Issue a lane-wise or reduction op, check the DUT against the reference
    // model, and update the shadow state to match. Any mismatch is reported
    // through expect32/check_vec/check_result like every other check.
    task automatic ref_issue_and_check(input logic [3:0] op, input int vd, input int vs1,
                                       input int vs2, input logic scl, input string tag);
        int a0, a1, a2, a3, b0, b1, b2, b3;
        int exp0, exp1, exp2, exp3;
        begin
            a0 = shadow_vrf[vs1][0]; a1 = shadow_vrf[vs1][1];
            a2 = shadow_vrf[vs1][2]; a3 = shadow_vrf[vs1][3];
            b0 = scl ? shadow_scalar : shadow_vrf[vs2][0];
            b1 = scl ? shadow_scalar : shadow_vrf[vs2][1];
            b2 = scl ? shadow_scalar : shadow_vrf[vs2][2];
            b3 = scl ? shadow_scalar : shadow_vrf[vs2][3];

            issue(op, vd, vs1, vs2, scl);

            if (ref_is_lane_op(op)) begin
                exp0 = (0 < shadow_vl) ? ref_lane_op(op, a0, b0) : shadow_vrf[vd][0];
                exp1 = (1 < shadow_vl) ? ref_lane_op(op, a1, b1) : shadow_vrf[vd][1];
                exp2 = (2 < shadow_vl) ? ref_lane_op(op, a2, b2) : shadow_vrf[vd][2];
                exp3 = (3 < shadow_vl) ? ref_lane_op(op, a3, b3) : shadow_vrf[vd][3];
                check_vec(vd, exp0, exp1, exp2, exp3, tag);
                if (0 < shadow_vl) shadow_vrf[vd][0] = exp0;
                if (1 < shadow_vl) shadow_vrf[vd][1] = exp1;
                if (2 < shadow_vl) shadow_vrf[vd][2] = exp2;
                if (3 < shadow_vl) shadow_vrf[vd][3] = exp3;
            end
            else if (ref_is_reduce(op)) begin
                shadow_result = ref_reduce_op(op, shadow_vl, a0, a1, a2, a3, b0, b1, b2, b3);
                check_result(shadow_result, tag);
            end
        end
    endtask

    // ----------------------------------------------------------------- test
    logic [31:0] t;

    initial begin
        $dumpfile("tb_vector_accel.vcd");
        $dumpvars(0, tb_vector_accel);

        // ---------------------------------------------------------- reset
        repeat (3) @(posedge clk);
        #1 reset = 1'b0;
        $display("\n=== 0. reset state ===");
        check_status(32'hFFFF_FFFF, 32'h0000_0001, "DONE=1, ERR=0, cnt=0");
        bus_read(OFF_VL, t);    expect32(t, 4, "VL resets to LANES");
        check_vec(3, 0, 0, 0, 0, "reset");

        // ------------------------------------------------ operands V0, V1
        set_vec(0,  3, -4, 10, 7);
        set_vec(1,  5,  6, -2, 7);
        check_vec(0, 3, -4, 10, 7, "load");
        check_vec(1, 5,  6, -2, 7, "load");

        // -------------------------------------------- 1. lane-wise vector ops
        $display("\n=== 1. lane-wise vector ops ===");
        issue(OP_VADD, 2, 0, 1, 0);  check_vec(2,  8,   2,   8, 14, "VADD");
        issue(OP_VSUB, 3, 0, 1, 0);  check_vec(3, -2, -10,  12,  0, "VSUB");
        issue(OP_VMUL, 4, 0, 1, 0);  check_vec(4, 15, -24, -20, 49, "VMUL");
        issue(OP_VSLT, 5, 0, 1, 0);  check_vec(5,  1,   1,   0,  0, "VSLT");
        issue(OP_VSEQ, 6, 0, 1, 0);  check_vec(6,  0,   0,   0,  1, "VSEQ");
        issue(OP_VMAX, 7, 0, 1, 0);  check_vec(7,  5,   6,  10,  7, "VMAX");
        issue(OP_VMIN, 2, 0, 1, 0);  check_vec(2,  3,  -4,  -2,  7, "VMIN");
        check_vec(0, 3, -4, 10, 7, "sources intact");
        check_vec(1, 5,  6, -2, 7, "sources intact");
        check_status(32'h0000_000F, 32'h0000_0001, "after vector op (RES_VALID=0)");

        // ------------------------------------------------ 2. reductions
        $display("\n=== 2. reductions ===");
        issue(OP_VRSUM, 0, 0, 0, 0);  check_result(16,  "VRSUM V0");
        check_status(32'h0000_000F, 32'h0000_0009, "after reduction (RES_VALID=1)");
        issue(OP_VRMAX, 0, 0, 0, 0);  check_result(10,  "VRMAX V0");
        issue(OP_VRMIN, 0, 0, 0, 0);  check_result(-4,  "VRMIN V0");
        issue(OP_VDOT,  0, 0, 1, 0);  check_result(20,  "VDOT V0.V1");

        // ------------------------------------------ 3. vector-scalar (SCL=1)
        $display("\n=== 3. scalar operand / broadcast ===");
        bus_write(OFF_SCALAR, 100);
        bus_read(OFF_SCALAR, t);       expect32(t, 100, "SCALAR readback");
        issue(OP_VADD, 2, 0, 0, 1);   check_vec(2, 103,  96, 110, 107, "VADD.S");
        bus_write(OFF_SCALAR, 3);
        issue(OP_VMUL, 3, 0, 0, 1);   check_vec(3,   9, -12,  30,  21, "VMUL.S");
        bus_write(OFF_SCALAR, 5);
        issue(OP_VSLT, 4, 0, 0, 1);   check_vec(4,   1,   1,   0,   0, "VSLT.S");
        bus_write(OFF_SCALAR, 42);
        issue(OP_VMOV, 5, 0, 0, 1);   check_vec(5,  42,  42,  42,  42, "VSPLAT");
        issue(OP_VMOV, 6, 0, 1, 0);   check_vec(6,   5,   6,  -2,   7, "VMOV");
        bus_write(OFF_SCALAR, 3);
        issue(OP_VDOT, 0, 0, 0, 1);   check_result(48, "VDOT V0.3");

        // ----------------------- 4. corner cases: signed compare, wrap-around
        $display("\n=== 4. corner cases ===");
        set_vec(0, 32'h7FFF_FFFF, -1, 32'h8000_0000, 32'h0001_0000);
        set_vec(1, 1,              1, -1,            32'h0001_0000);
        issue(OP_VADD, 2, 0, 1, 0);
        check_vec(2, 32'h8000_0000, 0, 32'h7FFF_FFFF, 32'h0002_0000, "VADD wrap");
        issue(OP_VMUL, 3, 0, 1, 0);
        check_vec(3, 32'h7FFF_FFFF, -1, 32'h8000_0000, 0, "VMUL low32");
        issue(OP_VSLT, 4, 0, 1, 0);
        check_vec(4, 0, 1, 1, 0, "VSLT signed");
        issue(OP_VMAX, 5, 0, 1, 0);
        check_vec(5, 32'h7FFF_FFFF, 1, -1, 32'h0001_0000, "VMAX signed");
        issue(OP_VMIN, 6, 0, 1, 0);
        check_vec(6, 1, -1, 32'h8000_0000, 32'h0001_0000, "VMIN signed");
        issue(OP_VRMAX, 0, 0, 0, 0);  check_result(32'h7FFF_FFFF, "VRMAX extremes");
        issue(OP_VRMIN, 0, 0, 0, 0);  check_result(32'h8000_0000, "VRMIN extremes");

        // restore operands for the remaining tests
        set_vec(0, 3, -4, 10, 7);
        set_vec(1, 5,  6, -2, 7);

        // ------------------------------------------ 5. vector length masking
        $display("\n=== 5. vector length (VL) ===");
        set_vec(2, 32'hDEAD_BEEF, 32'hDEAD_BEEF, 32'hDEAD_BEEF, 32'hDEAD_BEEF);
        bus_write(OFF_VL, 2);
        bus_read(OFF_VL, t);           expect32(t, 2, "VL readback");
        issue(OP_VADD, 2, 0, 1, 0);
        check_vec(2, 8, 2, 32'hDEAD_BEEF, 32'hDEAD_BEEF, "VADD vl=2 (lanes 2,3 kept)");
        issue(OP_VRSUM, 0, 0, 0, 0);  check_result(-1, "VRSUM vl=2");
        issue(OP_VRMAX, 0, 0, 0, 0);  check_result(3,  "VRMAX vl=2");
        issue(OP_VRMIN, 0, 0, 0, 0);  check_result(-4, "VRMIN vl=2");
        issue(OP_VDOT,  0, 0, 1, 0);  check_result(-9, "VDOT vl=2");
        bus_write(OFF_VL, 0);
        issue(OP_VRSUM, 0, 0, 0, 0);  check_result(0,  "VRSUM vl=0");
        bus_write(OFF_VL, 9);
        bus_read(OFF_VL, t);           expect32(t, 4, "VL clamps to LANES");

        // ------------------------------------------------- 6. load / store
        $display("\n=== 6. vector load/store unit ===");
        wr_ram(8, 11);  wr_ram(9, 22);
        wr_ram(10, 33); wr_ram(11, 44);

        bus_write(OFF_VBASE, 32'h20);                       // word 8
        issue(OP_VLD, 1, 0, 0, 0);
        check_vec(1, 11, 22, 33, 44, "VLD @0x20");

        bus_write(OFF_VBASE, 32'h30);                       // word 12
        issue(OP_VST, 0, 0, 0, 0);                          // stores V0
        expect32(rd_ram(12),  3, "VST ram[12]");
        expect32(rd_ram(13), -4, "VST ram[13]");
        expect32(rd_ram(14), 10, "VST ram[14]");
        expect32(rd_ram(15),  7, "VST ram[15]");
        expect32(rd_ram(11), 44, "ram[11] untouched");

        bus_write(OFF_VBASE, 32'h24);                       // word 9, not 4-aligned
        issue(OP_VLD, 3, 0, 0, 0);
        check_vec(3, 22, 33, 44, 3, "VLD unaligned @0x24");

        bus_write(OFF_VL, 3);
        set_vec(4, 1, 2, 3, 32'h77);
        bus_write(OFF_VBASE, 32'h20);
        issue(OP_VLD, 4, 0, 0, 0);
        check_vec(4, 11, 22, 33, 32'h77, "VLD vl=3 (lane 3 kept)");

        bus_write(OFF_VBASE, 32'h40);                       // word 16
        issue(OP_VST, 0, 1, 0, 0);                          // stores V1 = 11,22,33,44
        expect32(rd_ram(16), 11, "VST vl=3 ram[16]");
        expect32(rd_ram(17), 22, "VST vl=3 ram[17]");
        expect32(rd_ram(18), 33, "VST vl=3 ram[18]");
        expect32(rd_ram(19),  0, "VST vl=3 ram[19] not written");
        bus_write(OFF_VL, 4);

        // ------------------------------------ 6b. BUSY / DONE handshake
        $display("\n=== 6b. BUSY / DONE handshake ===");
        bus_write(OFF_VBASE, 32'h20);
        issue_nb(OP_VLD, 5, 0, 0, 0);                        // VL=4 -> ~5 cycles
        check_status(32'h0000_0007, 32'h0000_0004, "BUSY=1 DONE=0 right after VLD");
        bus_write(OFF_CMD, {18'd0, 1'b0, 3'd0, 3'd0, 3'd6, OP_VADD});   // VADD V6 while busy (rejected, not counted)
        check_status(32'h0000_0002, 32'h0000_0002, "CMD while BUSY -> ERR");
        wait_done("VLD V5");
        check_status(32'h0000_0007, 32'h0000_0003, "BUSY=0 DONE=1 (ERR still set)");
        check_vec(5, 11, 22, 33, 44, "VLD V5 after busy");
        check_vec(6, 1, -1, 32'h8000_0000, 32'h0001_0000, "rejected VADD left V6 intact");
        bus_write(OFF_VL, 0);                                // VL=0 : VLD/VST finish instantly
        issue(OP_VLD, 5, 0, 0, 0);
        check_status(32'h0000_0007, 32'h0000_0001, "VLD with VL=0 never goes BUSY");
        check_vec(5, 11, 22, 33, 44, "VL=0 VLD writes nothing");
        bus_write(OFF_VL, 4);

        // ------------------------------------ 7. illegal op, NOP, read-only
        $display("\n=== 7. status / error handling ===");
        bus_read(OFF_RESULT, t);                            // remember RESULT
        issue(4'hF, 2, 0, 1, 0);
        check_status(32'h0000_0003, 32'h0000_0003, "illegal op -> ERR=1");
        check_vec(2, 8, 2, 32'hDEAD_BEEF, 32'hDEAD_BEEF, "illegal op leaves V2");
        check_result(t, "illegal op leaves RESULT");
        issue(OP_NOP, 0, 0, 0, 0);
        check_status(32'h0000_0003, 32'h0000_0001, "NOP clears ERR");
        check_result(t, "NOP leaves RESULT");

        bus_write(OFF_RESULT, 32'hFFFF_FFFF);               // read-only registers
        bus_write(OFF_STATUS, 32'hFFFF_FFFF);
        check_result(t, "RESULT is read-only");
        check_status(32'h0000_0007, 32'h0000_0001, "STATUS is read-only, BUSY=0");

        bus_read(OFF_STATUS, t);
        expect32(t[31:16], n_cmds, "command counter");

        // ------------------------------------------------------ 8. reset
        $display("\n=== 8. reset clears state ===");
        @(negedge clk); reset = 1'b1; @(posedge clk); #1 reset = 1'b0;
        n_cmds = 0;
        check_vec(0, 0, 0, 0, 0, "after reset");
        bus_read(OFF_VL, t);    expect32(t, 4, "VL after reset");
        check_status(32'hFFFF_FFFF, 32'h0000_0001, "after reset");

        // ------------------------------------------------ 9. reference model
        // Randomized regression: every lane/reduce op is checked against the
        // reference model (ref_lane_op / ref_reduce_op) instead of a
        // hand-picked constant, across random operands, registers, VL, and
        // scalar/vector mode. A fixed seed keeps failures reproducible.
        $display("\n=== 9. reference-model randomized regression ===");
        begin
            int seed = 32'hC0FF_EE01;
            int op_hits [0:15];         // indexed by opcode 0..15
            logic [3:0] rand_ops [8];
            logic [3:0] op;
            int         vd, vs1, vs2, vl_pick;
            logic       scl;
            int         v0, v1, v2, v3;

            for (int k = 0; k < 16; k++) op_hits[k] = 0;

            rand_ops[0] = OP_VADD; rand_ops[1] = OP_VSUB; rand_ops[2] = OP_VMUL;
            rand_ops[3] = OP_VSLT; rand_ops[4] = OP_VSEQ; rand_ops[5] = OP_VMAX;
            rand_ops[6] = OP_VMIN; rand_ops[7] = OP_VMOV;

            shadow_reset();

            for (int i = 0; i < 150; i++) begin
                // occasionally change VL (0..4) so length coverage stays randomized
                if ($urandom(seed) % 4 == 0) begin
                    vl_pick = $urandom(seed) % (LANES + 1);
                    bus_write(OFF_VL, vl_pick);
                    shadow_vl = vl_pick;
                end

                vd  = $urandom(seed) % NVREG;
                vs1 = $urandom(seed) % NVREG;
                vs2 = $urandom(seed) % NVREG;      // may alias vs1 or vd -- intentional
                scl = $urandom(seed) % 5 == 0;     // ~20% scalar-broadcast mode
                op  = rand_ops[$urandom(seed) % 8];

                // refresh source operands with small random values sometimes,
                // so the model exercises more than one fixed data pattern
                if ($urandom(seed) % 3 == 0) begin
                    v0 = $urandom(seed) % 21 - 10; v1 = $urandom(seed) % 21 - 10;
                    v2 = $urandom(seed) % 21 - 10; v3 = $urandom(seed) % 21 - 10;
                    set_vec(vs1, v0, v1, v2, v3);
                    shadow_vrf[vs1][0] = v0; shadow_vrf[vs1][1] = v1;
                    shadow_vrf[vs1][2] = v2; shadow_vrf[vs1][3] = v3;
                end
                if (scl) begin
                    v0 = $urandom(seed) % 21 - 10;
                    bus_write(OFF_SCALAR, v0);
                    shadow_scalar = v0;
                end
                else if ($urandom(seed) % 3 == 0) begin
                    v0 = $urandom(seed) % 21 - 10; v1 = $urandom(seed) % 21 - 10;
                    v2 = $urandom(seed) % 21 - 10; v3 = $urandom(seed) % 21 - 10;
                    set_vec(vs2, v0, v1, v2, v3);
                    shadow_vrf[vs2][0] = v0; shadow_vrf[vs2][1] = v1;
                    shadow_vrf[vs2][2] = v2; shadow_vrf[vs2][3] = v3;
                end

                ref_issue_and_check(op, vd, vs1, vs2, scl,
                    $sformatf("rand[%0d] op=%0h vd=%0d vs1=%0d vs2=%0d scl=%0b vl=%0d",
                              i, op, vd, vs1, vs2, scl, shadow_vl));
                op_hits[op] = op_hits[op] + 1;
            end

            // reduction ops get their own short randomized pass: RESULT is a
            // single scalar, so aliasing vd doesn't apply the same way.
            for (int i = 0; i < 40; i++) begin
                logic [3:0] red_ops [4];
                red_ops[0] = OP_VRSUM; red_ops[1] = OP_VRMAX;
                red_ops[2] = OP_VRMIN; red_ops[3] = OP_VDOT;

                vl_pick = $urandom(seed) % (LANES + 1);
                bus_write(OFF_VL, vl_pick); shadow_vl = vl_pick;

                vs1 = $urandom(seed) % NVREG;
                vs2 = $urandom(seed) % NVREG;
                op  = red_ops[$urandom(seed) % 4];

                v0 = $urandom(seed) % 21 - 10; v1 = $urandom(seed) % 21 - 10;
                v2 = $urandom(seed) % 21 - 10; v3 = $urandom(seed) % 21 - 10;
                set_vec(vs1, v0, v1, v2, v3);
                shadow_vrf[vs1][0] = v0; shadow_vrf[vs1][1] = v1;
                shadow_vrf[vs1][2] = v2; shadow_vrf[vs1][3] = v3;
                if (op == OP_VDOT) begin
                    v0 = $urandom(seed) % 21 - 10; v1 = $urandom(seed) % 21 - 10;
                    v2 = $urandom(seed) % 21 - 10; v3 = $urandom(seed) % 21 - 10;
                    set_vec(vs2, v0, v1, v2, v3);
                    shadow_vrf[vs2][0] = v0; shadow_vrf[vs2][1] = v1;
                    shadow_vrf[vs2][2] = v2; shadow_vrf[vs2][3] = v3;
                end

                ref_issue_and_check(op, 0 /*unused for reduce*/, vs1, vs2, 1'b0,
                    $sformatf("rand-reduce[%0d] op=%0h vs1=%0d vs2=%0d vl=%0d",
                              i, op, vs1, vs2, shadow_vl));
                op_hits[op] = op_hits[op] + 1;
            end

            // command coverage: every op named in the spec must have been
            // exercised at least once by the randomized loops above.
            begin
                logic [3:0] must_hit [12];
                must_hit[0]=OP_VADD; must_hit[1]=OP_VSUB; must_hit[2]=OP_VMUL;
                must_hit[3]=OP_VSLT; must_hit[4]=OP_VSEQ; must_hit[5]=OP_VMAX;
                must_hit[6]=OP_VMIN; must_hit[7]=OP_VMOV;  must_hit[8]=OP_VRSUM;
                must_hit[9]=OP_VRMAX; must_hit[10]=OP_VRMIN; must_hit[11]=OP_VDOT;
                for (int k = 0; k < 12; k++) begin
                    checks++;
                    if (op_hits[must_hit[k]] == 0) begin
                        errors++;
                        $display("FAIL  op 0x%0h never hit by randomized regression", must_hit[k]);
                    end
                end
                $display("PASS  command coverage: all 12 arithmetic/compare/reduce ops hit");
            end
        end

        // ----------------------------------------------------------- done
        $display("\n----------------------------------------");
        if (errors == 0) $display("ALL TESTS PASSED (%0d checks)", checks);
        else             $display("%0d of %0d CHECKS FAILED", errors, checks);
        $finish;
    end

    initial begin
        #500000;
        $display("TIMEOUT");
        $finish;
    end
endmodule