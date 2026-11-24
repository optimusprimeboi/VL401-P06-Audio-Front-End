// =============================================================================
// Module  : pwm_audio
// Project : P6 PDM-to-PCM Audio Front End
// Purpose : Delta-Sigma / High-Speed PWM Audio DAC
//           Converts signed 16-bit PCM samples into a 1-bit high-frequency PWM
//           waveform that directly drives an RC lowpass filter or headphones.
// =============================================================================

`timescale 1ns / 1ps

module pwm_audio #(
    parameter integer DATA_W = 16
)(
    input  wire                 clk,      // System clock (e.g. 125 MHz or 12.288 MHz)
    input  wire                 rst_n,
    input  wire signed [DATA_W-1:0] pcm_in,
    output reg                  pwm_out
);

// Map signed [-32768, 32767] to unsigned [0, 65535]
wire [15:0] unsigned_pcm = pcm_in + 16'h8000;

// 1st-order Delta-Sigma PWM Accumulator
reg [16:0] sigma_delta_acc;

always @(posedge clk) begin
    if (!rst_n) begin
        sigma_delta_acc <= 17'd0;
        pwm_out         <= 1'b0;
    end else begin
        sigma_delta_acc <= sigma_delta_acc[15:0] + unsigned_pcm;
        pwm_out         <= sigma_delta_acc[16];
    end
end

endmodule
