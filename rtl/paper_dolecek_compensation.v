// =============================================================================
// Module: paper_dolecek_compensation
// Description: Multiplierless CIC Compensation Filter based on:
//              G. Jovanovic Dolecek & S. K. Mitra, "Simple method for compensation
//              of CIC decimation filter", IEEE Trans. Circuits Syst. II (2005).
// Taps: 3-tap linear phase FIR: H(z) = -2^-4 + (1 + 2^-3)z^-1 - 2^-4 z^-2
// Fixed Point: h = [-1, 18, -1] / 16 (Scale = 16, Shift = 4)
// Total Hardware: ONLY 2 ADDERS / SUBTRACTORS!
// =============================================================================

`timescale 1ns / 1ps

module paper_dolecek_compensation #(
    parameter IN_WIDTH  = 18,
    parameter OUT_WIDTH = 20
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       in_valid,
    input  wire signed [IN_WIDTH-1:0]   in_data,
    
    output reg                        out_valid,
    output reg  signed [OUT_WIDTH-1:0] out_data
);

    reg signed [IN_WIDTH-1:0] x1, x2;

    // Symmetric outer sum: s = x[n] + x[n-2]
    wire signed [IN_WIDTH:0] s_outer = in_data + x2;

    // Center tap: 18 * x1 = (x1 << 4) + (x1 << 1)
    wire signed [IN_WIDTH+4:0] center_term = (x1 <<< 4) + (x1 <<< 1);

    // Sum: 18*x1 - s_outer
    wire signed [IN_WIDTH+5:0] total_sum = center_term - s_outer;

    // Convergent rounding: add (1 << 3) = 8, shift right by 4
    wire signed [IN_WIDTH+5:0] sum_rounded = total_sum + 6'sd8;
    wire signed [IN_WIDTH+1:0] scaled_out  = sum_rounded >>> 4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x1        <= {IN_WIDTH{1'b0}};
            x2        <= {IN_WIDTH{1'b0}};
            out_valid <= 1'b0;
            out_data  <= {OUT_WIDTH{1'b0}};
        end else if (in_valid) begin
            x1        <= in_data;
            x2        <= x1;
            out_data  <= {{(OUT_WIDTH-(IN_WIDTH+2)){scaled_out[IN_WIDTH+1]}}, scaled_out};
            out_valid <= 1'b1;
        end else begin
            out_valid <= 1'b0;
        end
    end

endmodule
