// =============================================================================
// Module: i2s_transmitter
// Description: Standard Audio I2S Master Transmitter (Pmod I2S Compatible)
// Format: 16-bit audio in 32-bit frame per channel (64 BCLK cycles per LRCLK)
// Clocking: BCLK = 3.072 MHz, LRCLK = 48 kHz
// =============================================================================

`timescale 1ns / 1ps

module i2s_transmitter (
    input  wire        clk,          // System clock (49.152 MHz)
    input  wire        rst_n,        // Active-low reset
    input  wire        sample_valid, // 48 kHz sample strobe
    input  wire [15:0] pcm_sample,   // 16-bit audio sample
    
    output reg         i2s_bclk,     // 3.072 MHz bit clock
    output reg         i2s_lrclk,    // 48 kHz word clock (0 = Left, 1 = Right)
    output reg         i2s_sdata     // Serial audio data
);

    // Clock divider: 49.152 MHz / 8 = 6.144 MHz -> toggle every 8 system clocks = 3.072 MHz
    reg [2:0] bclk_div;
    wire bclk_rising  = (bclk_div == 3'd7) && (i2s_bclk == 1'b0);
    wire bclk_falling = (bclk_div == 3'd7) && (i2s_bclk == 1'b1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bclk_div <= 3'd0;
            i2s_bclk <= 1'b0;
        end else begin
            bclk_div <= bclk_div + 3'd1;
            if (bclk_div == 3'd7) begin
                i2s_bclk <= ~i2s_bclk;
            end
        end
    end

    // 64-bit frame counter (32 bits left channel, 32 bits right channel)
    reg [5:0]  bit_cnt;
    reg [31:0] shift_reg_left;
    reg [31:0] shift_reg_right;
    reg [15:0] sample_hold;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_hold <= 16'd0;
        end else if (sample_valid) begin
            sample_hold <= pcm_sample;
        end
    end

    // Frame Sequencing on BCLK falling edge
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt         <= 6'd0;
            i2s_lrclk       <= 1'b0;
            i2s_sdata       <= 1'b0;
            shift_reg_left  <= 32'd0;
            shift_reg_right <= 32'd0;
        end else if (bclk_falling) begin
            bit_cnt <= bit_cnt + 6'd1;
            
            if (bit_cnt == 6'd63) begin
                // Transition to Left channel: LRCLK = 0
                i2s_lrclk      <= 1'b0;
                shift_reg_left <= {sample_hold, 16'd0}; // MSB aligned
            end else if (bit_cnt == 6'd31) begin
                // Transition to Right channel: LRCLK = 1
                i2s_lrclk       <= 1'b1;
                shift_reg_right <= {sample_hold, 16'd0}; // Duplicate mono to right
            end
            
            // I2S Standard: Data is delayed by 1 BCLK cycle after LRCLK edge
            if (bit_cnt == 6'd0 || bit_cnt == 6'd32) begin
                // 1 BCLK cycle delay slot
                i2s_sdata <= 1'b0;
            end else if (bit_cnt < 6'd32) begin
                // Left slot: bits 1 to 31
                i2s_sdata      <= shift_reg_left[31];
                shift_reg_left <= {shift_reg_left[30:0], 1'b0};
            end else begin
                // Right slot: bits 33 to 63
                i2s_sdata       <= shift_reg_right[31];
                shift_reg_right <= {shift_reg_right[30:0], 1'b0};
            end
        end
    end

endmodule
