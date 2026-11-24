// =============================================================================
// Module: halfband_fir_folded
// Description: Hand-HLS Folded Half-Band Decimation FIR Filter (Stage 2)
// Architecture: Time-Multiplexed / Shared Single ALU with Polyphase Sequencer FSM
// Decimation: 96 kHz -> 48 kHz (downsample by 2)
// Clocking: Runs on high-speed FPGA master clock (e.g. 12 - 100 MHz)
// Area Advantage: Extreme resource sharing, single accumulator, minimal LUT footprint
// =============================================================================

`timescale 1ns / 1ps

module halfband_fir_folded #(
    parameter IN_WIDTH  = 20,
    parameter OUT_WIDTH = 20
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       in_valid,
    input  wire signed [IN_WIDTH-1:0]   in_data,
    
    output reg                        out_valid,
    output reg  signed [OUT_WIDTH-1:0] out_data,
    output reg                        busy
);

    // Tap storage: 23 taps (circular buffer or shift register)
    reg signed [IN_WIDTH-1:0] tap [0:21];
    integer i;

    // Decimation toggle
    reg dec_phase;

    // FSM State Encoding
    localparam S_IDLE    = 4'd0,
               S_PAIR0   = 4'd1, // Taps 0 & 22 (c0 = -191)
               S_PAIR2   = 4'd2, // Taps 2 & 20 (c2 = 280)
               S_PAIR4   = 4'd3, // Taps 4 & 18 (c4 = -488)
               S_PAIR6   = 4'd4, // Taps 6 & 16 (c6 = 832)
               S_PAIR8   = 4'd5, // Taps 8 & 14 (c8 = -1664)
               S_PAIR10  = 4'd6, // Taps 10 & 12 (c10 = 5327)
               S_CENTER  = 4'd7, // Tap 11 (c11 = 8192)
               S_FINISH  = 4'd8;

    reg [3:0] state;
    reg signed [35:0] accum;

    // Time-shared ALU inputs
    reg signed [IN_WIDTH:0] alu_in_s;
    reg signed [35:0]       alu_prod;

    // Reusable Subexpression / Multiplierless Kernels for the time-shared ALU
    wire signed [IN_WIDTH+3:0] alu_3x = (alu_in_s <<< 2) - alu_in_s;
    wire signed [IN_WIDTH+3:0] alu_5x = (alu_in_s <<< 2) + alu_in_s;

    // Combinational product generation based on active state
    always @(*) begin
        case (state)
            S_PAIR0: begin
                // c0 = -191 = -((3 << 6) - 1)
                alu_prod = -36'sd1 * (((alu_3x <<< 6) - alu_in_s));
            end
            S_PAIR2: begin
                // c2 = 280 = (32 + 3) << 3
                alu_prod = ((alu_in_s <<< 5) + alu_3x) <<< 3;
            end
            S_PAIR4: begin
                // c4 = -488 = -(64 - 3) << 3
                alu_prod = -36'sd1 * (((alu_in_s <<< 6) - alu_3x) <<< 3);
            end
            S_PAIR6: begin
                // c6 = 832 = 13 << 6 = ((3 << 2) + 1) << 6
                alu_prod = ((alu_3x <<< 2) + alu_in_s) <<< 6;
            end
            S_PAIR8: begin
                // c8 = -1664 = -(13 << 7)
                alu_prod = -36'sd1 * ((((alu_3x <<< 2) + alu_in_s) <<< 7));
            end
            S_PAIR10: begin
                // c10 = 5327 = (5 << 10) + (13 << 4) - 1
                alu_prod = (alu_5x <<< 10) + (((alu_3x <<< 2) + alu_in_s) <<< 4) - alu_in_s;
            end
            S_CENTER: begin
                // c11 = 8192 = 1 << 13
                alu_prod = (alu_in_s <<< 13);
            end
            default: begin
                alu_prod = 36'sd0;
            end
        endcase
    end

    // Sequencer and Datapath Controller FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 22; i = i + 1) begin
                tap[i] <= {IN_WIDTH{1'b0}};
            end
            dec_phase <= 1'b0;
            state     <= S_IDLE;
            accum     <= 36'sd0;
            alu_in_s  <= {(IN_WIDTH+1){1'b0}};
            out_valid <= 1'b0;
            out_data  <= {OUT_WIDTH{1'b0}};
            busy      <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    out_valid <= 1'b0;
                    if (in_valid) begin
                        // Shift in sample
                        for (i = 0; i < 21; i = i + 1) begin
                            tap[i] <= tap[i+1];
                        end
                        tap[21] <= in_data;
                        
                        dec_phase <= ~dec_phase;
                        if (dec_phase == 1'b1) begin
                            // Start folded evaluation
                            busy     <= 1'b1;
                            accum    <= 36'sd0;
                            // Setup first symmetric pair (0 & in_data)
                            alu_in_s <= tap[0] + in_data;
                            state    <= S_PAIR0;
                        end
                    end
                end
                
                S_PAIR0: begin
                    accum    <= accum + alu_prod;
                    alu_in_s <= tap[2] + tap[20];
                    state    <= S_PAIR2;
                end
                
                S_PAIR2: begin
                    accum    <= accum + alu_prod;
                    alu_in_s <= tap[4] + tap[18];
                    state    <= S_PAIR4;
                end
                
                S_PAIR4: begin
                    accum    <= accum + alu_prod;
                    alu_in_s <= tap[6] + tap[16];
                    state    <= S_PAIR6;
                end
                
                S_PAIR6: begin
                    accum    <= accum + alu_prod;
                    alu_in_s <= tap[8] + tap[14];
                    state    <= S_PAIR8;
                end
                
                S_PAIR8: begin
                    accum    <= accum + alu_prod;
                    alu_in_s <= tap[10] + tap[12];
                    state    <= S_PAIR10;
                end
                
                S_PAIR10: begin
                    accum    <= accum + alu_prod;
                    alu_in_s <= {tap[11][IN_WIDTH-1], tap[11]};
                    state    <= S_CENTER;
                end
                
                S_CENTER: begin
                    accum <= accum + alu_prod;
                    state <= S_FINISH;
                end
                
                S_FINISH: begin
                    // Convergent rounding: add 8192, shift right 14
                    out_data  <= (accum + 36'sd8192) >>> 14;
                    out_valid <= 1'b1;
                    busy      <= 1'b0;
                    state     <= S_IDLE;
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
