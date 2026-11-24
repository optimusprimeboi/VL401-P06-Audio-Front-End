// =============================================================================
// Module: pwm_audio_dac
// Description: High-Rate 1st-Order Delta-Sigma DAC for direct headphone listening
// Oversampling: 49.152 MHz / 48 kHz = 1024x OSR!
// Input: 16-bit signed PCM audio
// Output: 1-bit high frequency stream for RC lowpass / headphone output
// =============================================================================

`timescale 1ns / 1ps

module pwm_audio_dac (
    input  wire        clk,        // 49.152 MHz system clock
    input  wire        rst_n,      // Active-low reset
    input  wire signed [15:0] pcm_sample, // 16-bit signed audio
    
    output reg         audio_pwm_out      // 1-bit audio pin
);

    // Convert signed [-32768, 32767] to unsigned [0, 65535]
    wire [15:0] pcm_unsigned = pcm_sample ^ 16'h8000;

    // 17-bit Delta-Sigma Accumulator
    reg [16:0] dac_accum;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dac_accum     <= 17'd0;
            audio_pwm_out <= 1'b0;
        end else begin
            dac_accum     <= {1'b0, dac_accum[15:0]} + {1'b0, pcm_unsigned};
            audio_pwm_out <= dac_accum[16];
        end
    end

endmodule
