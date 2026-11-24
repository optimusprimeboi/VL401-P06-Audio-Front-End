// =============================================================================
// Module: halfband_stage1
// Description: 11-Tap Multiplierless Half-Band Decimation FIR Filter (Stage 1)
// Decimation: 192 kHz -> 96 kHz (downsample by 2)
// Multiplierless CSD with Q14 Normalization (Scale = 16384, Shift = 14)
// Polyphase half-band structure: zero-coefficients skipped
// =============================================================================

`timescale 1ns / 1ps

module halfband_stage1 #(
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

    // Shift register for 11 taps (tap[0] oldest, in_data newest)
    reg signed [IN_WIDTH-1:0] tap [0:9];
    integer i;

    // Decimation phase toggle (divide by 2)
    reg dec_phase;

    // Symmetric pre-adders for non-zero taps:
    // tap[10] corresponds to in_data
    wire signed [IN_WIDTH:0] s0 = tap[0] + in_data; // h0 and h10
    wire signed [IN_WIDTH:0] s2 = tap[2] + tap[8];   // h2 and h8
    wire signed [IN_WIDTH:0] s4 = tap[4] + tap[6];   // h4 and h6
    wire signed [IN_WIDTH:0] s5 = {tap[5][IN_WIDTH-1], tap[5]}; // Center tap h5

    // Multiplierless CSD:
    // 1) h0 = 168 = (1<<7) + (1<<5) + (1<<3)
    wire signed [IN_WIDTH+8:0] prod0 = (s0 <<< 7) + (s0 <<< 5) + (s0 <<< 3);
    
    // 2) h2 = -968 = -(1<<10) + (1<<6) - (1<<3)
    wire signed [IN_WIDTH+11:0] prod2 = -(s2 <<< 10) + (s2 <<< 6) - (s2 <<< 3);
    
    // 3) h4 = 4896 = (1<<12) + (1<<10) - (1<<8) + (1<<5)
    wire signed [IN_WIDTH+13:0] prod4 = (s4 <<< 12) + (s4 <<< 10) - (s4 <<< 8) + (s4 <<< 5);
    
    // 4) Center tap h5 = 8192 (0.5 in Q14) = 1<<13
    wire signed [IN_WIDTH+14:0] prod5 = (s5 <<< 13);

    // Accumulation sum (35-bit accumulator)
    wire signed [34:0] accum = prod0 + prod2 + prod4 + prod5;

    // Convergent rounding: add (1 << 13), then shift right by 14
    wire signed [34:0] accum_rounded = accum + 35'sd8192;
    wire signed [20:0] scaled_val    = accum_rounded >>> 14;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 10; i = i + 1) begin
                tap[i] <= {IN_WIDTH{1'b0}};
            end
            dec_phase <= 1'b0;
            out_valid <= 1'b0;
            out_data  <= {OUT_WIDTH{1'b0}};
        end else if (in_valid) begin
            // Shift register
            tap[0] <= tap[1];
            tap[1] <= tap[2];
            tap[2] <= tap[3];
            tap[3] <= tap[4];
            tap[4] <= tap[5];
            tap[5] <= tap[6];
            tap[6] <= tap[7];
            tap[7] <= tap[8];
            tap[8] <= tap[9];
            tap[9] <= in_data;
            
            // Toggle decimation phase
            dec_phase <= ~dec_phase;
            
            // Output sample every 2nd input
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
