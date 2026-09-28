module data_memory #(
    parameter int DEPTH = 256
)(
    input  logic        clk,
    // port A (CPU)
    input  logic [3:0]  a_we,
    input  logic [31:0] a_addr,
    input  logic [31:0] a_wdata,
    output logic [31:0] a_rdata,
    // port B (vector engine)
    input  logic        b_we,
    input  logic [31:0] b_addr,
    input  logic [31:0] b_wdata,
    output logic [31:0] b_rdata
);
    localparam int AW = $clog2(DEPTH);
 
    logic [3:0] b_we4;
    assign b_we4 = {4{b_we}};   // port B always writes the full word
 
    genvar i;
    generate
        for (i = 0; i < 4; i++) begin : byte_lane
            dp_byte_ram #(.DEPTH(DEPTH), .AW(AW)) u_ram (
                .clk     (clk),
                .we_a    (a_we[i]),
                .addr_a  (a_addr[AW+1:2]),
                .wdata_a (a_wdata[8*i +: 8]),
                .rdata_a (a_rdata[8*i +: 8]),
                .we_b    (b_we4[i]),
                .addr_b  (b_addr[AW+1:2]),
                .wdata_b (b_wdata[8*i +: 8]),
                .rdata_b (b_rdata[8*i +: 8])
            );
        end
    endgenerate
endmodule