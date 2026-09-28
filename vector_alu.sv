// =============================================================================
//  vector_alu.sv
//  Part of the vector accelerator.  Compile order (Questa/Quartus):
//     vec_pkg.sv, vector_alu.sv, vector_accel.sv, then the RV32I core files.
// =============================================================================

module vector_alu
    import vec_pkg::*;
(
    input  logic [3:0]          op,
    input  logic [VLW-1:0]      vl,        // number of active lanes
    input  logic [LANES*32-1:0] a,         // VS1 lanes (lane i = a[i*32 +: 32])
    input  logic [LANES*32-1:0] b,         // VS2 lanes, or broadcast scalar
    output logic [LANES*32-1:0] vec_out,   // lane-wise result
    output logic [31:0]         red_out,   // reduction / dot-product result
    output logic                vec_wr,    // op writes a vector register
    output logic                red_wr,    // op writes RESULT
    output logic                illegal    // undefined opcode
);

    logic signed [31:0] ai, bi, r;
    logic signed [31:0] sum, dot, mx, mn;

    // ---- data path ---------------------------------------------------------
    always_comb begin
        vec_out = '0;
        sum = 32'sd0;
        dot = 32'sd0;
        mx  = 32'sh8000_0000;      // INT_MIN : identity for max
        mn  = 32'sh7FFF_FFFF;      // INT_MAX : identity for min

        for (int i = 0; i < LANES; i++) begin
            ai = a[i*32 +: 32];
            bi = b[i*32 +: 32];

            case (op)
                OP_VADD: r = ai + bi;
                OP_VSUB: r = ai - bi;
                OP_VMUL: r = ai * bi;                       // low 32 bits
                OP_VSLT: r = (ai <  bi) ? 32'sd1 : 32'sd0;  // signed compare
                OP_VSEQ: r = (ai == bi) ? 32'sd1 : 32'sd0;
                OP_VMAX: r = (ai >  bi) ? ai : bi;
                OP_VMIN: r = (ai <  bi) ? ai : bi;
                OP_VMOV: r = bi;
                default: r = 32'sd0;
            endcase
            vec_out[i*32 +: 32] = r;

            // reductions only see active lanes
            if (i < vl) begin
                sum = sum + ai;
                dot = dot + ai * bi;
                if (ai > mx) mx = ai;
                if (ai < mn) mn = ai;
            end
        end

        case (op)
            OP_VRSUM: red_out = sum;
            OP_VRMAX: red_out = mx;
            OP_VRMIN: red_out = mn;
            OP_VDOT : red_out = dot;
            default : red_out = 32'd0;
        endcase
    end

    // ---- opcode classification --------------------------------------------
    always_comb begin
        vec_wr  = 1'b0;
        red_wr  = 1'b0;
        illegal = 1'b0;
        case (op)
            OP_NOP, OP_VLD, OP_VST:                       ;   // handled by accel
            OP_VADD, OP_VSUB, OP_VMUL, OP_VSLT,
            OP_VSEQ, OP_VMAX, OP_VMIN, OP_VMOV:           vec_wr  = 1'b1;
            OP_VRSUM, OP_VRMAX, OP_VRMIN, OP_VDOT:        red_wr  = 1'b1;
            default:                                      illegal = 1'b1;
        endcase
    end
endmodule
