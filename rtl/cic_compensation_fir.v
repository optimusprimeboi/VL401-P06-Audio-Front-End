// =============================================================================
// Module: cic_compensation_fir
// Description: 9-Tap Multiplierless Linear-Phase CIC Compensation FIR Filter
// Sample Rate: 192 kHz
// Exploits filter symmetry (Type I linear phase) and CSD shift-and-add arithmetic
// Normalization: Q12 (Scale = 4096, Shift = 12) with rounding
// =============================================================================

`timescale 1ns / 1ps

module cic_compensation_fir #(
    parameter IN_WIDTH  = 18,
    parameter OUT_WIDTH = 20
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     in_valid,
    input  wire signed [IN_WIDTH-1:0] in_data,
    
    output reg                      out_valid,
    output reg  signed [OUT_WIDTH-1:0] out_data
);

    // Shift register for 9 taps (z^-0 to z^-8)
    reg signed [IN_WIDTH-1:0] tap [0:8];
    integer i;

    // Symmetric pre-adders (IN_WIDTH + 1 bits to prevent overflow)
    wire signed [IN_WIDTH:0] s0 = tap[0] + in_data; // tap[8] is tap[7] from prev shift, tap[0] is oldest
    wire signed [IN_WIDTH:0] s1 = tap[1] + tap[7];
    wire signed [IN_WIDTH:0] s2 = tap[2] + tap[6];
    wire signed [IN_WIDTH:0] s3 = tap[3] + tap[5];
    wire signed [IN_WIDTH:0] s4 = {tap[4][IN_WIDTH-1], tap[4]}; // Center tap

    // Multiplierless CSD Multiplication for each symmetric pair:
    // 1) h0 = -5 = -(1<<2) - (1<<0)
    wire signed [IN_WIDTH+5:0] prod0 = -((s0 <<< 2) + s0);
    
    // 2) h1 = +1
    wire signed [IN_WIDTH+5:0] prod1 = s1;
    
    // 3) h2 = -47 = -(1<<6) + (1<<4) + 1
    wire signed [IN_WIDTH+9:0] prod2 = -((s2 <<< 6) - (s2 <<< 4) - s2);
    
    // 4) h3 = +505 = (1<<9) - (1<<3) + 1
    wire signed [IN_WIDTH+12:0] prod3 = (s3 <<< 9) - (s3 <<< 3) + s3;
    
    // 5) h4 = +3188 = (1<<12) - (1<<10) + (1<<7) - (1<<4) + (1<<2)
    wire signed [IN_WIDTH+15:0] prod4 = (s4 <<< 12) - (s4 <<< 10) + (s4 <<< 7) - (s4 <<< 4) + (s4 <<< 2);

    // Accumulation sum (34-bit signed accumulator)
    wire signed [33:0] accum = prod0 + prod1 + prod2 + prod3 + prod4;

    // Convergent / Round-half-up: add (1 << 11), then shift right by 12
    wire signed [33:0] accum_rounded = accum + 34'sd2048;
    wire signed [21:0] scaled_val    = accum_rounded >>> 12;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 9; i = i + 1) begin
                tap[i] <= {IN_WIDTH{1'b0}};
            end
            out_valid <= 1'b0;
            out_data  <= {OUT_WIDTH{1'b0}};
        end else if (in_valid) begin
            // Shift register update
            tap[0] <= tap[1];
            tap[1] <= tap[2];
            tap[2] <= tap[3];
            tap[3] <= tap[4];
            tap[4] <= tap[5];
            tap[5] <= tap[6];
            tap[6] <= tap[7];
            tap[7] <= in_data;
            
            // Output registered
            out_valid <= 1'b1;
            out_data  <= scaled_val[OUT_WIDTH-1:0];
        end else begin
            out_valid <= 1'b0;
        end
    end

endmodule
