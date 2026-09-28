// =============================================================================
//  vector_accel.sv
//  Part of the vector accelerator.  Compile order (Questa/Quartus):
//     vec_pkg.sv, vector_alu.sv, vector_accel.sv, then the RV32I core files.
// =============================================================================

module vector_accel
    import vec_pkg::*;
(
    input  logic                clk,
    input  logic                reset,

    // ---- CPU-side peripheral bus (word accesses) ---------------------------
    input  logic                we,          // store to accelerator region
    input  logic [11:0]         addr,        // byte offset inside the region
    input  logic [31:0]         wdata,
    output logic [31:0]         rdata,       // combinational read

    // ---- one-word port to data RAM (used by VLD / VST) ---------------------
    output logic [31:0]         vmem_addr,   // byte address of the current lane
    output logic                vmem_we,
    output logic [31:0]         vmem_wdata,
    input  logic [31:0]         vmem_rdata   // SYNCHRONOUS: valid 1 cycle after vmem_addr
);
    localparam int LW = $clog2(LANES);

    // ---- architectural state ----------------------------------------------
    logic [31:0]     vrf [0:NVREG-1][0:LANES-1];     // vector register file
    logic [31:0]     cmd_q, result_q, scalar_q, vbase_q;
    logic [15:0]     cnt_q;
    logic [VLW-1:0]  vl_q;
    logic            err_q, resv_q;

    // ---- load/store FSM state ---------------------------------------------
    logic            busy_q, is_st_q, cap_v_q;
    logic [2:0]      ls_vd_q, ls_vs1_q;
    logic [VLW-1:0]  len_q, idx_q;                   // idx_q counts 0..len_q
    logic [LW-1:0]   cap_idx_q;
    logic [31:0]     base_q;
    logic            issuing;

    assign issuing = busy_q && (idx_q < len_q);

    assign vmem_addr  = base_q + {{(30-VLW){1'b0}}, idx_q, 2'b00};
    assign vmem_we    = issuing && is_st_q;
    assign vmem_wdata = issuing ? vrf[ls_vs1_q][idx_q[LW-1:0]] : 32'd0;

    // ---- command decode ----------------------------------------------------
    logic       cmd_fire;
    logic [3:0] c_op;
    logic [2:0] c_vd, c_vs1, c_vs2;
    logic       c_scl;

    assign cmd_fire = we && (addr == OFF_CMD);
    assign c_op     = wdata[3:0];
    assign c_vd     = wdata[6:4];
    assign c_vs1    = wdata[9:7];
    assign c_vs2    = wdata[12:10];
    assign c_scl    = wdata[13];

    // ---- operand fetch (2 read ports + scalar broadcast) ------------------
    logic [LANES*32-1:0] a_vec, b_vec, alu_vec;
    logic [31:0]         alu_red;
    logic                vec_wr, red_wr, illegal;
    logic [LANES-1:0]    lane_en;

    always_comb begin
        for (int l = 0; l < LANES; l++) begin
            a_vec[l*32 +: 32] = vrf[c_vs1][l];
            b_vec[l*32 +: 32] = c_scl ? scalar_q : vrf[c_vs2][l];
            lane_en[l]        = (l < vl_q);
        end
    end

    vector_alu valu (
        .op(c_op), .vl(vl_q), .a(a_vec), .b(b_vec),
        .vec_out(alu_vec), .red_out(alu_red),
        .vec_wr(vec_wr), .red_wr(red_wr), .illegal(illegal)
    );

    // ---- sequential --------------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset) begin
            for (int r = 0; r < NVREG; r++)
                for (int l = 0; l < LANES; l++)
                    vrf[r][l] <= 32'd0;
            cmd_q     <= 32'd0;
            result_q  <= 32'd0;
            scalar_q  <= 32'd0;
            vbase_q   <= 32'd0;
            cnt_q     <= 16'd0;
            vl_q      <= VLW'(LANES);
            err_q     <= 1'b0;
            resv_q    <= 1'b0;
            busy_q    <= 1'b0;
            is_st_q   <= 1'b0;
            cap_v_q   <= 1'b0;
            ls_vd_q   <= '0;
            ls_vs1_q  <= '0;
            len_q     <= '0;
            idx_q     <= '0;
            cap_idx_q <= '0;
            base_q    <= 32'd0;
        end
        else begin
            // ------------- load/store engine (runs while BUSY) -------------
            if (busy_q) begin
                if (issuing) begin
                    idx_q <= idx_q + VLW'(1);
                    if (is_st_q) begin
                        if (idx_q + VLW'(1) == len_q) busy_q <= 1'b0;   // last store issued
                    end
                    else begin
                        cap_v_q   <= 1'b1;                              // data arrives next cycle
                        cap_idx_q <= idx_q[LW-1:0];
                    end
                end
                else begin                                              // VLD drain cycle
                    cap_v_q <= 1'b0;
                    busy_q  <= 1'b0;
                end
                if (cap_v_q)
                    vrf[ls_vd_q][cap_idx_q] <= vmem_rdata;
            end

            // ------------- CPU bus writes -------------------------------------
            if (we) begin
                if (addr == OFF_CMD) begin
                    if (busy_q) begin
                        err_q <= 1'b1;                      // rejected: engine still running
                    end
                    else begin
                        cmd_q  <= wdata;
                        cnt_q  <= cnt_q + 16'd1;
                        err_q  <= illegal;
                        resv_q <= red_wr;
                        if (red_wr)
                            result_q <= alu_red;
                        if (vec_wr) begin
                            for (int l = 0; l < LANES; l++)
                                if (lane_en[l])
                                    vrf[c_vd][l] <= alu_vec[l*32 +: 32];
                        end
                        if ((c_op == OP_VLD || c_op == OP_VST) && vl_q != '0) begin
                            busy_q    <= 1'b1;
                            is_st_q   <= (c_op == OP_VST);
                            ls_vd_q   <= c_vd;
                            ls_vs1_q  <= c_vs1;
                            len_q     <= vl_q;
                            idx_q     <= '0;
                            base_q    <= vbase_q;
                            cap_v_q   <= 1'b0;
                        end
                    end
                end
                else if (addr == OFF_SCALAR) scalar_q <= wdata;
                else if (addr == OFF_VL)     vl_q     <= (wdata > 32'(LANES)) ? VLW'(LANES)
                                                                              : wdata[VLW-1:0];
                else if (addr == OFF_VBASE)  vbase_q  <= wdata;
                else if (addr[11:7] == 5'b0_0010 && !busy_q)   // 0x100..0x17F register window
                    vrf[addr[6:4]][addr[3:2]] <= wdata;
            end
        end
    end

    // ---- combinational read mux -------------------------------------------
    always_comb begin
        rdata = 32'd0;
        if (addr[11:7] == 5'b0_0010) begin
            rdata = vrf[addr[6:4]][addr[3:2]];
        end
        else begin
            case (addr)
                OFF_CMD    : rdata = cmd_q;
                OFF_STATUS : rdata = {cnt_q, 12'd0, resv_q, busy_q, err_q, ~busy_q};
                OFF_RESULT : rdata = result_q;
                OFF_SCALAR : rdata = scalar_q;
                OFF_VL     : rdata = {{(32-VLW){1'b0}}, vl_q};
                OFF_VBASE  : rdata = vbase_q;
                default    : rdata = 32'd0;
            endcase
        end
    end
endmodule
