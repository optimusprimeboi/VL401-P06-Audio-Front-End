// =============================================================================
// Module: cic_decimator
// Description: Cascaded Integrator-Comb (CIC) Decimation Filter
// Parameters: R = 16 (Decimation), N = 4 (Stages), M = 1 (Differential delay)
// Input:  3.072 MHz 1-bit PDM stream (bipolar -1 / +1)
// Output: 192 kHz 18-bit signed PCM with valid strobe
// Arithmetic: Modulo 2^18 wrap-around arithmetic per Hogenauer theorem
// =============================================================================

`timescale 1ns / 1ps

module cic_decimator #(
    parameter R = 16,        // Decimation ratio
    parameter N = 4,         // Filter order (stages)
    parameter WIDTH = 18     // Bit-width: 2 + N*log2(R) = 2 + 16 = 18 bits
)(
    input  wire                   clk,          // System clock
    input  wire                   rst_n,        // Active-low asynchronous reset
    input  wire                   pdm_clk_en,   // PDM sample strobe (3.072 MHz)
    input  wire                   pdm_in,       // 1-bit PDM input (0 -> -1, 1 -> +1)
    
    output reg  signed [WIDTH-1:0] cic_out,     // Decimated output (18-bit signed)
    output reg                    cic_valid     // Output strobe at 192 kHz
);

    // -------------------------------------------------------------
    // Input Mapping: 0 -> -1, 1 -> +1 (Two's complement 18-bit)
    // -------------------------------------------------------------
    wire signed [WIDTH-1:0] x_in = pdm_in ? {{(WIDTH-1){1'b0}}, 1'b1} : {WIDTH{1'b1}};

    // -------------------------------------------------------------
    // Integrator Section: 4 cascaded integrators running at 3.072 MHz
    // -------------------------------------------------------------
    reg signed [WIDTH-1:0] itg [0:N-1];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < N; i = i + 1) begin
                itg[i] <= {WIDTH{1'b0}};
            end
        end else if (pdm_clk_en) begin
            itg[0] <= itg[0] + x_in;
            itg[1] <= itg[1] + itg[0];
            itg[2] <= itg[2] + itg[1];
            itg[3] <= itg[3] + itg[2];
        end
    end

    // -------------------------------------------------------------
    // Decimation Counter: Decimate by R = 16
    // -------------------------------------------------------------
    reg [3:0] dec_cnt;
    wire dec_strobe = (dec_cnt == 4'd15) && pdm_clk_en;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dec_cnt <= 4'd0;
        end else if (pdm_clk_en) begin
            dec_cnt <= dec_cnt + 4'd1;
        end
    end

    // -------------------------------------------------------------
    // Comb Section: 4 cascaded differentiators running at 192 kHz
    // H_c(z) = (1 - z^-1)^4
    // -------------------------------------------------------------
    reg signed [WIDTH-1:0] comb_delay0;
    reg signed [WIDTH-1:0] comb_delay1;
    reg signed [WIDTH-1:0] comb_delay2;
    reg signed [WIDTH-1:0] comb_delay3;

    wire signed [WIDTH-1:0] diff0 = itg[3] - comb_delay0;
    wire signed [WIDTH-1:0] diff1 = diff0  - comb_delay1;
    wire signed [WIDTH-1:0] diff2 = diff1  - comb_delay2;
    wire signed [WIDTH-1:0] diff3 = diff2  - comb_delay3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            comb_delay0 <= {WIDTH{1'b0}};
            comb_delay1 <= {WIDTH{1'b0}};
            comb_delay2 <= {WIDTH{1'b0}};
            comb_delay3 <= {WIDTH{1'b0}};
            cic_out     <= {WIDTH{1'b0}};
            cic_valid   <= 1'b0;
        end else if (dec_strobe) begin
            comb_delay0 <= itg[3];
            comb_delay1 <= diff0;
            comb_delay2 <= diff1;
            comb_delay3 <= diff2;
            cic_out     <= diff3;
            cic_valid   <= 1'b1;
        end else begin
            cic_valid   <= 1'b0;
        end
    end

endmodule
