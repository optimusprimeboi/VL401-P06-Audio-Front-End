// =============================================================================
// Module  : hb_filter_folded
// Project : P6 PDM-to-PCM Audio Front End
// Purpose : Half-Band FIR — Folded (Shared MAC) Architecture
//           N_TAPS = 31, symmetric half-band filter.
//           Every odd offset from center is zero.
//           Only 9 unique non-zero coefficients (8 symmetric pairs + 1 center tap).
//
// Operation:
//   - Receives data_in on valid_in strobe.
//   - Decimates by 2: computes an output every 2 valid_in strobes.
//   - Sequencer computes 9 MAC steps sequentially across system clock cycles.
//   - Uses only ONE multiplier (area-efficient).
// =============================================================================

`timescale 1ns / 1ps

module hb_filter_folded #(
    parameter integer N_TAPS   = 31,
    parameter integer B_IN     = 24,
    parameter integer B_OUT    = 24,
    parameter integer COEFF_W  = 16,
    parameter integer N_UNIQUE = 9,
    parameter         COEFF_FILE = "../../sim/vectors/hb1_coeffs_folded.hex"
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    valid_in,
    input  wire signed [B_IN-1:0]  data_in,
    output reg  signed [B_OUT-1:0] data_out,
    output reg                     valid_out
);

// ── Folded Coefficients ROM (9 unique values) ────────────────────────────────
reg signed [COEFF_W-1:0] coeff_rom [0:N_UNIQUE-1];
initial begin
    $readmemh(COEFF_FILE, coeff_rom);
end

// ── Shift register for input samples ──────────────────────────────────────────
reg signed [B_IN-1:0] delay [0:N_TAPS-1];
reg                   dec_phase;
integer di;

always @(posedge clk) begin
    if (!rst_n) begin
        for (di = 0; di < N_TAPS; di = di + 1)
            delay[di] <= {B_IN{1'b0}};
        dec_phase <= 1'b0;
    end else if (valid_in) begin
        delay[0] <= data_in;
        for (di = 1; di < N_TAPS; di = di + 1)
            delay[di] <= delay[di-1];
        dec_phase <= ~dec_phase;
    end
end

// ── Tap indices for symmetric pairs ───────────────────────────────────────────
// Non-zero tap indices for 31-tap halfband:
// 0, 2, 4, 6, 8, 10, 12, 14, 15, 16, 18, 20, 22, 24, 26, 28, 30
reg [4:0] tap_a [0:N_UNIQUE-1];
reg [4:0] tap_b [0:N_UNIQUE-1];
initial begin
    tap_a[0] = 5'd0;  tap_b[0] = 5'd30;
    tap_a[1] = 5'd2;  tap_b[1] = 5'd28;
    tap_a[2] = 5'd4;  tap_b[2] = 5'd26;
    tap_a[3] = 5'd6;  tap_b[3] = 5'd24;
    tap_a[4] = 5'd8;  tap_b[4] = 5'd22;
    tap_a[5] = 5'd10; tap_b[5] = 5'd20;
    tap_a[6] = 5'd12; tap_b[6] = 5'd18;
    tap_a[7] = 5'd14; tap_b[7] = 5'd16;
    tap_a[8] = 5'd15; tap_b[8] = 5'd15; // Center tap
end

// ── Sequencer FSM ─────────────────────────────────────────────────────────────
localparam ST_IDLE = 2'd0;
localparam ST_CALC = 2'd1;
localparam ST_DONE = 2'd2;

localparam integer B_ACC = B_IN + COEFF_W + 6; // Headroom for accumulation

reg [1:0]                 state;
reg [3:0]                 step;
reg signed [B_ACC-1:0]    acc;

// Multiplier operands
wire is_center = (step == 4'd8);
wire signed [B_IN:0] sym_operand = is_center ? 
    {delay[tap_a[step]][B_IN-1], delay[tap_a[step]]} :
    ({delay[tap_a[step]][B_IN-1], delay[tap_a[step]]} + {delay[tap_b[step]][B_IN-1], delay[tap_b[step]]});

wire signed [COEFF_W-1:0] coeff_operand = coeff_rom[step];
wire signed [B_ACC-1:0]   mult_product  = $signed(sym_operand) * $signed(coeff_operand);

// Rounding and saturation constant (scale by 32767 ≈ 2^15)
localparam integer SHIFT = COEFF_W - 1; // 15
wire signed [B_ACC-1:0] rounded_acc = acc + (1 << (SHIFT - 1));
wire signed [B_ACC-1:0] shifted_acc = rounded_acc >>> SHIFT;

always @(posedge clk) begin
    if (!rst_n) begin
        state     <= ST_IDLE;
        step      <= 4'd0;
        acc       <= {B_ACC{1'b0}};
        data_out  <= {B_OUT{1'b0}};
        valid_out <= 1'b0;
    end else begin
        valid_out <= 1'b0;
        case (state)
            ST_IDLE: begin
                // Trigger calculation on decimation phase strobe (every 2nd valid_in)
                if (valid_in && (dec_phase == 1'b0)) begin
                    acc   <= mult_product;
                    step  <= 4'd1;
                    state <= ST_CALC;
                end
            end

            ST_CALC: begin
                acc <= acc + mult_product;
                if (step == N_UNIQUE - 1) begin
                    state <= ST_DONE;
                end else begin
                    step <= step + 1'b1;
                end
            end

            ST_DONE: begin
                // Saturate to signed B_OUT bits
                if (shifted_acc > $signed({1'b0, {(B_OUT-1){1'b1}}}))
                    data_out <= {1'b0, {(B_OUT-1){1'b1}}};
                else if (shifted_acc < $signed({1'b1, {(B_OUT-1){1'b0}}}))
                    data_out <= {1'b1, {(B_OUT-1){1'b0}}};
                else
                    data_out <= shifted_acc[B_OUT-1:0];

                valid_out <= 1'b1;
                step      <= 4'd0;
                state     <= ST_IDLE;
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
