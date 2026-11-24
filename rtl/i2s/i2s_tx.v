// =============================================================================
// Module  : i2s_tx
// Project : P6 PDM-to-PCM Audio Front End
// Purpose : Standard I2S Audio Transmitter
//           Converts 16-bit parallel PCM audio into I2S serial protocol:
//           - BCLK  : Bit Clock (e.g. 48 kHz * 32 * 2 = 3.072 MHz)
//           - LRCLK : Left/Right Word Clock (48 kHz, Low = Left, High = Right)
//           - SDATA : Serial Audio Data (MSB-first, delayed by 1 BCLK from LRCLK transition)
// =============================================================================

`timescale 1ns / 1ps

module i2s_tx #(
    parameter integer DATA_W = 16
)(
    input  wire                 clk,       // Master audio clock (e.g. 12.288 MHz)
    input  wire                 rst_n,

    // PCM Input
    input  wire signed [DATA_W-1:0] pcm_l,
    input  wire signed [DATA_W-1:0] pcm_r,
    input  wire                 pcm_valid,

    // I2S Interface
    output reg                  bclk,      // 3.072 MHz (clk / 4)
    output reg                  lrclk,     // 48 kHz (bclk / 64)
    output reg                  sdata
);

// Free-running clock divider to generate continuous BCLK (12.288 MHz / 4 = 3.072 MHz)
// Kept free-running across reset so the SSM2603 DAC maintains clock lock
reg [1:0] bclk_div = 2'd0;
wire bclk_pulse = (bclk_div == 2'd3);

always @(posedge clk) begin
    bclk_div <= bclk_div + 1'b1;
    if (bclk_div == 2'd1) bclk <= 1'b1;
    if (bclk_div == 2'd3) bclk <= 1'b0;
end

// I2S Frame Counter (64 BCLK cycles per LRCLK period: 32 left + 32 right)
reg [5:0]  bit_cnt = 6'd0;
reg [31:0] shift_reg = 32'd0;

reg [DATA_W-1:0] latched_l;
reg [DATA_W-1:0] latched_r;

always @(posedge clk) begin
    if (!rst_n) begin
        latched_l <= 0;
        latched_r <= 0;
    end else if (pcm_valid) begin
        latched_l <= pcm_l;
        latched_r <= pcm_r;
    end
end

always @(posedge clk) begin
    if (bclk_pulse) begin
        bit_cnt <= bit_cnt + 1'b1;

        // Falling edge of BCLK transitions LRCLK cleanly
        if (bit_cnt == 6'd0)  lrclk     <= 1'b0; // Left channel begins
        if (bit_cnt == 6'd32) lrclk     <= 1'b1; // Right channel begins

        if (!rst_n) begin
            // Mute output to dead digital silence during reset
            sdata     <= 1'b0;
            shift_reg <= 32'd0;
        end else begin
            if (bit_cnt == 6'd0) begin
                shift_reg <= {latched_l, 16'd0}; // Pad to 32 bits
            end else if (bit_cnt == 6'd32) begin
                shift_reg <= {latched_r, 16'd0};
            end else begin
                shift_reg <= {shift_reg[30:0], 1'b0};
            end

            // In I2S standard, SDATA MSB is emitted on second BCLK after LRCLK edge
            sdata <= shift_reg[31];
        end
    end
end

endmodule
