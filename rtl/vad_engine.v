// =============================================================================
// Module: vad_engine
// Description: Real-time Audio RMS Energy Computer and Voice Activity Detector
// Window: 256 samples (5.33 ms at 48 kHz)
// Features: Windowed energy accumulation, dual-threshold detection, hangover FSM
// =============================================================================

`timescale 1ns / 1ps

module vad_engine #(
    parameter WINDOW_SIZE = 256,
    parameter LOG2_WIN    = 8
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   sample_valid,
    input  wire signed [15:0]     pcm_sample,
    input  wire        [15:0]     vad_threshold,
    input  wire        [3:0]      hangover_val,
    
    output reg         [15:0]     rms_energy,
    output reg                    vad_active
);

    // Squared sample calculation (absolute value or square)
    wire signed [31:0] sample_sq = pcm_sample * pcm_sample; // 31-bit positive
    wire [15:0] sample_power = sample_sq[30:15]; // Scale to 16-bit

    reg [LOG2_WIN-1:0] win_cnt;
    reg [23:0]         energy_accum;
    reg [3:0]          hangover_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win_cnt      <= {LOG2_WIN{1'b0}};
            energy_accum <= 24'd0;
            rms_energy   <= 16'd0;
            vad_active   <= 1'b0;
            hangover_cnt <= 4'd0;
        end else if (sample_valid) begin
            if (win_cnt == WINDOW_SIZE - 1) begin
                // End of 256-sample window
                win_cnt      <= {LOG2_WIN{1'b0}};
                rms_energy   <= energy_accum[23:LOG2_WIN]; // Mean square energy
                energy_accum <= {8'd0, sample_power};
                
                // VAD decision with hangover
                if (energy_accum[23:LOG2_WIN] >= vad_threshold) begin
                    vad_active   <= 1'b1;
                    hangover_cnt <= hangover_val; // Reset hangover timer
                end else if (hangover_cnt > 0) begin
                    vad_active   <= 1'b1;
                    hangover_cnt <= hangover_cnt - 1'b1;
                end else begin
                    vad_active   <= 1'b0;
                end
            end else begin
                win_cnt      <= win_cnt + 1'b1;
                energy_accum <= energy_accum + sample_power;
            end
        end
    end

endmodule
