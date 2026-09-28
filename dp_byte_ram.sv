module dp_byte_ram #(
    parameter int DEPTH = 256,
    parameter int AW    = 8            // must equal $clog2(DEPTH)
)(
    input  logic             clk,
    input  logic              we_a,
    input  logic [AW-1:0]     addr_a,
    input  logic [7:0]        wdata_a,
    output logic [7:0]        rdata_a,
    input  logic              we_b,
    input  logic [AW-1:0]     addr_b,
    input  logic [7:0]        wdata_b,
    output logic [7:0]        rdata_b
);
    // read-during-write across the two ports is never done by software
    // (CPU and vector engine never target the same address in the same
    // cycle), so this attribute is safe.
    (* ramstyle = "no_rw_check" *) logic [7:0] mem [0:DEPTH-1];
 
    // synthesis translate_off
    initial begin
        for (int k = 0; k < DEPTH; k++) mem[k] = 8'b0;
    end
    // synthesis translate_on
 
    always @(posedge clk) begin
        if (we_a) mem[addr_a] <= wdata_a;
        rdata_a <= mem[addr_a];
    end
 
    always @(posedge clk) begin
        if (we_b) mem[addr_b] <= wdata_b;
        rdata_b <= mem[addr_b];
    end
endmodule
