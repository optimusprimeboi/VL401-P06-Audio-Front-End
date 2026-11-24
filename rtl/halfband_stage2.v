// =============================================================================
// Module: halfband_stage2
// Description: 23-Tap Half-Band Decimation FIR Filter (Stage 2 - Parallel Architecture)
// Decimation: 96 kHz -> 48 kHz (downsample by 2)
// Uses Graph-Based U3 Kernel Multiplier Block for optimal area/adder count
// Normalization: Q14 (Scale = 16384, Shift = 14) with convergent rounding
// =============================================================================

`timescale 1ns / 1ps

module halfband_stage2 #(
    parameter IN_WIDTH  = 20,
    parameter OUT_WIDTH = 20
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       in_valid,
    input  wire signed [IN_WIDTH-1:0]   in_data,
    
    output reg                        out_valid,
    output reg  signed [OUT_WIDTH-1:0] out_data
);

    // Shift register for 23 taps (tap[0] oldest, in_data newest)
    reg signed [IN_WIDTH-1:0] tap [0:21];
    integer i;

    // Decimation phase toggle
    reg dec_phase;

    // Symmetric pre-adders for non-zero taps:
    wire signed [IN_WIDTH:0] s0  = tap[0]  + in_data; // h0 and h22
    wire signed [IN_WIDTH:0] s2  = tap[2]  + tap[20]; // h2 and h20
    wire signed [IN_WIDTH:0] s4  = tap[4]  + tap[18]; // h4 and h18
    wire signed [IN_WIDTH:0] s6  = tap[6]  + tap[16]; // h6 and h16
    wire signed [IN_WIDTH:0] s8  = tap[8]  + tap[14]; // h8 and h14
    wire signed [IN_WIDTH:0] s10 = tap[10] + tap[12]; // h10 and h12
    wire signed [IN_WIDTH:0] s11 = {tap[11][IN_WIDTH-1], tap[11]}; // Center tap h11

    // -------------------------------------------------------------
    // Multiplier Block: Graph-Based U3 Kernel Multiplier Block
    // Computes products for symmetric sums using optimal addition chains
    // -------------------------------------------------------------
    // Tap 0 & 22: c0 = -191
    // (s0 * 3 << 6) - s0 = 191 * s0
    wire signed [IN_WIDTH+3:0] s0_3x = (s0 <<< 2) - s0;
    wire signed [IN_WIDTH+10:0] prod0 = -((s0_3x <<< 6) - s0);

    // Tap 2 & 20: c2 = 280 = 35 << 3 = (32 + 3) << 3
    wire signed [IN_WIDTH+3:0] s2_3x = (s2 <<< 2) - s2;
    wire signed [IN_WIDTH+7:0] s2_35x = (s2 <<< 5) + s2_3x;
    wire signed [IN_WIDTH+11:0] prod2 = (s2_35x <<< 3);

    // Tap 4 & 18: c4 = -488 = -(61 << 3) = -((64 - 3) << 3)
    wire signed [IN_WIDTH+3:0] s4_3x = (s4 <<< 2) - s4;
    wire signed [IN_WIDTH+7:0] s4_61x = (s4 <<< 6) - s4_3x;
    wire signed [IN_WIDTH+11:0] prod4 = -(s4_61x <<< 3);

    // Tap 6 & 16: c6 = 832 = 13 << 6
    wire signed [IN_WIDTH+3:0] s6_3x = (s6 <<< 2) - s6;
    wire signed [IN_WIDTH+5:0] s6_13x = (s6_3x <<< 2) + s6;
    wire signed [IN_WIDTH+12:0] prod6 = (s6_13x <<< 6);

    // Tap 8 & 14: c8 = -1664 = -(13 << 7)
    wire signed [IN_WIDTH+3:0] s8_3x = (s8 <<< 2) - s8;
    wire signed [IN_WIDTH+5:0] s8_13x = (s8_3x <<< 2) + s8;
    wire signed [IN_WIDTH+13:0] prod8 = -(s8_13x <<< 7);

    // Tap 10 & 12: c10 = 5327 = (5 << 10) + (13 << 4) - 1
    wire signed [IN_WIDTH+3:0] s10_5x  = (s10 <<< 2) + s10;
    wire signed [IN_WIDTH+3:0] s10_3x  = (s10 <<< 2) - s10;
    wire signed [IN_WIDTH+5:0] s10_13x = (s10_3x <<< 2) + s10;
    wire signed [IN_WIDTH+14:0] s10_comb = (s10_5x <<< 10) + (s10_13x <<< 4);
    wire signed [IN_WIDTH+14:0] prod10 = s10_comb - s10;

    // Center Tap 11: c11 = 8192 (0.5 in Q14)
    wire signed [IN_WIDTH+14:0] prod11 = (s11 <<< 13);

    // Total Accumulator (36-bit signed)
    wire signed [35:0] accum = prod0 + prod2 + prod4 + prod6 + prod8 + prod10 + prod11;

    // Convergent Rounding: add (1 << 13), then shift right by 14
    wire signed [35:0] accum_rounded = accum + 36'sd8192;
    wire signed [21:0] scaled_val    = accum_rounded >>> 14;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 22; i = i + 1) begin
                tap[i] <= {IN_WIDTH{1'b0}};
            end
            dec_phase <= 1'b0;
            out_valid <= 1'b0;
            out_data  <= {OUT_WIDTH{1'b0}};
        end else if (in_valid) begin
            // Shift register
            for (i = 0; i < 21; i = i + 1) begin
                tap[i] <= tap[i+1];
            end
            tap[21] <= in_data;
            
            // Decimate by 2
            dec_phase <= ~dec_phase;
            if (dec_phase == 1'b1) begin
                out_valid <= 1'b1;
                out_data  <= scaled_val[OUT_WIDTH-1:0];
            end else begin
                out_valid <= 1'b0;
            end
        end else begin
            out_valid <= 1'b0;
        end
    end

endmodule
