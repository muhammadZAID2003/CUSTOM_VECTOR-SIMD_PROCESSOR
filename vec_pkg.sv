// =============================================================================
//  vec_pkg.sv
//  Part of the vector accelerator.  Compile order (Questa/Quartus):
//     vec_pkg.sv, vector_alu.sv, vector_accel.sv, then the RV32I core files.
// =============================================================================

// =============================================================================
//  vector_accel.sv  --  4-lane, 32-bit vector accelerator (SRAM-friendly)
//
//  Contents (compile this file BEFORE the core and testbenches):
//    vec_pkg       : constants (lane count, opcodes, register offsets)
//    vector_alu    : purely combinational lane-wise ALU + reduction tree
//    vector_accel  : command/status regs + vector register file + a small
//                    load/store FSM.  Memory-mapped on the CPU data bus.
//
//  TIMING MODEL (CHANGED)
//    * Arithmetic / compare / reduce / VMOV / NOP : still single-cycle.
//      The result is visible to the instruction after the `sw` to CMD.
//    * VLD / VST : multi-cycle.  The data RAM is a synchronous-read SRAM with
//      one 32-bit port for this unit, so the FSM moves ONE lane per cycle.
//        VST : VL cycles.   VLD : VL + 1 cycles (1 cycle SRAM read latency).
//      STATUS.BUSY = 1 (DONE = 0) until the transfer finishes.
//    * A CMD write while BUSY is REJECTED: ERR is set, nothing else changes.
//    * Vector-register-window writes while BUSY are ignored.
//    * VL / VBASE are snapshotted when a VLD/VST starts.
//
//  Register map (byte offsets from the accelerator base, 0x4000_0000):
//    0x000  CMD     W  writing this word issues a command (R: last command)
//    0x004  STATUS  R  [0]DONE [1]ERR [2]BUSY [3]RES_VALID [31:16]cmd count
//    0x008  RESULT  R  scalar result of the last reduction / dot product
//    0x00C  SCALAR  RW scalar operand, broadcast to all lanes when CMD.SCL = 1
//    0x010  VL      RW active lane count 0..4 (values >4 clamp to 4, reset = 4)
//    0x014  VBASE   RW byte address in data RAM used by VLD / VST
//    0x100..0x17F   RW vector register window: 0x100 + reg*0x10 + lane*4
//                      (8 vector registers V0..V7, 4 lanes each)
//
//  CMD word format:
//    [3:0]   OP     [6:4] VD    [9:7] VS1    [12:10] VS2    [13] SCL
//    SCL = 1 : second operand is the SCALAR register broadcast to all lanes.
//
//  Opcodes:
//    0 NOP    1 VADD   2 VSUB   3 VMUL   (lane-wise, wraps at 32 bits)
//    4 VSLT   5 VSEQ                     (lane-wise compare -> 1 / 0, signed)
//    6 VMAX   7 VMIN                     (lane-wise signed max / min)
//    8 VRSUM  9 VRMAX  A VRMIN           (reduce VS1 -> RESULT)
//    B VDOT                              (sum(VS1[i]*VS2[i]) -> RESULT)
//    C VLD    D VST                      (VD <- RAM[VBASE..], RAM[VBASE..] <- VS1)
//    E VMOV                              (VD <- VS2, or splat SCALAR if SCL=1)
//    F illegal -> STATUS.ERR = 1, no other state changes
//
//  Only lanes 0..VL-1 are written, stored, or included in a reduction.
// =============================================================================

package vec_pkg;
    localparam int LANES = 4;
    localparam int NVREG = 8;
    localparam int VLW   = $clog2(LANES + 1);   // bits needed to hold 0..LANES

    localparam logic [3:0] OP_NOP   = 4'h0;
    localparam logic [3:0] OP_VADD  = 4'h1;
    localparam logic [3:0] OP_VSUB  = 4'h2;
    localparam logic [3:0] OP_VMUL  = 4'h3;
    localparam logic [3:0] OP_VSLT  = 4'h4;
    localparam logic [3:0] OP_VSEQ  = 4'h5;
    localparam logic [3:0] OP_VMAX  = 4'h6;
    localparam logic [3:0] OP_VMIN  = 4'h7;
    localparam logic [3:0] OP_VRSUM = 4'h8;
    localparam logic [3:0] OP_VRMAX = 4'h9;
    localparam logic [3:0] OP_VRMIN = 4'hA;
    localparam logic [3:0] OP_VDOT  = 4'hB;
    localparam logic [3:0] OP_VLD   = 4'hC;
    localparam logic [3:0] OP_VST   = 4'hD;
    localparam logic [3:0] OP_VMOV  = 4'hE;

    localparam logic [11:0] OFF_CMD    = 12'h000;
    localparam logic [11:0] OFF_STATUS = 12'h004;
    localparam logic [11:0] OFF_RESULT = 12'h008;
    localparam logic [11:0] OFF_SCALAR = 12'h00C;
    localparam logic [11:0] OFF_VL     = 12'h010;
    localparam logic [11:0] OFF_VBASE  = 12'h014;
    localparam logic [11:0] OFF_VRF    = 12'h100;   // window base
endpackage
