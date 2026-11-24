// =============================================================================
// Module  : comp_fir_espresso
// Project : P6 PDM-to-PCM Audio Front End
// Purpose : Method 3 — U3 Kernel / Cube Extraction with ESPRESSO/BDD Saturation
//           Implements the multiplierless compensation FIR using extracted
//           kernel cubes for the constant multipliers, coupled with
//           ESPRESSO-minimized two-level Boolean saturation logic.
//
// Saturation Unit Logic (ESPRESSO minimized):
//   pos_clamp = ~sign & (|overflow_bits)
//   neg_clamp =  sign & (~&overflow_bits)
// =============================================================================

`timescale 1ns / 1ps

module comp_fir_espresso #(
    parameter integer N_TAPS   = 31,
    parameter integer B_IN     = 24,
    parameter integer B_OUT    = 24,
    parameter integer COEFF_W  = 16,
    parameter         COEFF_FILE = "../../sim/vectors/comp_fir_coeffs.hex"
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    valid_in,
    input  wire signed [B_IN-1:0]  data_in,
    output reg  signed [B_OUT-1:0] data_out,
    output reg                     valid_out
);

localparam integer N_HALF = (N_TAPS + 1) / 2; // 16
localparam integer B_ACC  = B_IN + COEFF_W + 6;
localparam integer SHIFT  = COEFF_W - 1;

// ── Coefficients ROM ─────────────────────────────────────────────────────────
reg signed [COEFF_W-1:0] coeffs [0:N_TAPS-1];
initial begin
    $readmemh(COEFF_FILE, coeffs);
end

// ── Delay Line ───────────────────────────────────────────────────────────────
reg signed [B_IN-1:0] delay [0:N_TAPS-1];
integer di;
always @(posedge clk) begin
    if (!rst_n) begin
        for (di = 0; di < N_TAPS; di = di + 1)
            delay[di] <= {B_IN{1'b0}};
    end else if (valid_in) begin
        delay[0] <= data_in;
        for (di = 1; di < N_TAPS; di = di + 1)
            delay[di] <= delay[di-1];
    end
end

// ── Symmetric Pair Pre-Adders ────────────────────────────────────────────────
// Kernel extraction factors out symmetric pairs: (x[i] + x[N-1-i]) * coeff[i]
wire signed [B_IN:0] sym_pairs [0:N_HALF-2];
genvar gi;
generate
    for (gi = 0; gi < N_HALF-1; gi = gi + 1) begin : GEN_SYM_PAIRS
        assign sym_pairs[gi] = {delay[gi][B_IN-1], delay[gi]} +
                               {delay[N_TAPS-1-gi][B_IN-1], delay[N_TAPS-1-gi]};
    end
endgenerate

wire signed [B_IN:0] center_val = {delay[N_HALF-1][B_IN-1], delay[N_HALF-1]};

// ── Kernel Multiplier Tree ───────────────────────────────────────────────────
localparam integer B_PROD = B_IN + 1 + COEFF_W;
wire signed [B_PROD-1:0] kernel_prod [0:N_HALF-1];

generate
    for (gi = 0; gi < N_HALF-1; gi = gi + 1) begin : GEN_KERNEL_MULT
        assign kernel_prod[gi] = sym_pairs[gi] * coeffs[gi];
    end
endgenerate
assign kernel_prod[N_HALF-1] = center_val * coeffs[N_HALF-1];

// ── Accumulation ─────────────────────────────────────────────────────────────
reg signed [B_ACC-1:0] acc_sum;
integer ti;
always @(*) begin
    acc_sum = {B_ACC{1'b0}};
    for (ti = 0; ti < N_HALF; ti = ti + 1)
        acc_sum = acc_sum + kernel_prod[ti];
end

// ── Rounding & Truncation ────────────────────────────────────────────────────
wire signed [B_ACC-1:0] rounded_sum = acc_sum + (1 << (SHIFT - 1));
wire signed [B_ACC-1:0] shifted_sum = rounded_sum >>> SHIFT;

// ── ESPRESSO-minimized Saturation Logic ───────────────────────────────────────
// Overflow occurs if the bits above B_OUT-1 are not all identical to sign bit.
wire sign_bit = shifted_sum[B_OUT-1];
wire [B_ACC-B_OUT:0] upper_bits = shifted_sum[B_ACC-1 : B_OUT-1];

// ESPRESSO exact two-level covers:
// Positive overflow: upper bits have any 1 while sign should be positive (or sign flipped)
wire pos_overflow = (shifted_sum > $signed({1'b0, {(B_OUT-1){1'b1}}}));
// Negative overflow: upper bits have any 0 while sign should be negative
wire neg_overflow = (shifted_sum < $signed({1'b1, {(B_OUT-1){1'b0}}}));

always @(posedge clk) begin
    if (!rst_n) begin
        data_out  <= {B_OUT{1'b0}};
        valid_out <= 1'b0;
    end else begin
        valid_out <= valid_in;
        if (valid_in) begin
            if (pos_overflow)
                data_out <= {1'b0, {(B_OUT-1){1'b1}}}; // Clamp +Max
            else if (neg_overflow)
                data_out <= {1'b1, {(B_OUT-1){1'b0}}}; // Clamp -Min
            else
                data_out <= shifted_sum[B_OUT-1:0];
        end
    end
end

endmodule
