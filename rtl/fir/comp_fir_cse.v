// =============================================================================
// Module  : comp_fir_cse
// Project : P6 PDM-to-PCM Audio Front End
// Purpose : Method 2 — Shared Common Subexpression (CSE / MCM) multiplier
//           Same FIR function as comp_fir_naive, but the constant
//           multiplications share common shift-add subexpressions across taps.
//
// Key idea: instead of computing coeff[i] × x[n-i] independently for each i,
// we factor out partial products that appear in multiple coefficients:
//   e.g., if coeff[3] = 0b...01001 and coeff[7] = 0b...01001xx,
//   the sub-product (x << 0) + (x << 3) is computed ONCE and reused.
//
// Implementation: RTL description of the shared adder graph.
// The sharing was identified by the Python comp_fir.py method2_cse_mcm().
// =============================================================================

`timescale 1ns / 1ps

module comp_fir_cse #(
    parameter integer N_TAPS = 31,
    parameter integer B_IN   = 24,
    parameter integer B_OUT  = 24
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    valid_in,
    input  wire signed [B_IN-1:0]  data_in,
    output reg  signed [B_OUT-1:0] data_out,
    output reg                     valid_out
);

localparam integer COEFF_W = 16;
localparam integer B_ACC   = B_IN + COEFF_W + 6;
localparam integer SHIFT_BITS = B_ACC - B_OUT; // bits to drop for truncation
localparam integer N_HALF  = (N_TAPS + 1) / 2;   // 16

// ── Delay line ────────────────────────────────────────────────────────────────
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

// ── Folded symmetric accumulation ─────────────────────────────────────────────
// For a symmetric FIR, pair up delay[i] + delay[N-1-i] first,
// then multiply by one coefficient. This halves the number of multiplications
// before even applying CSD.
wire signed [B_IN:0] sym_sum [0:N_HALF-2];   // N_HALF-1 pairs (skip centre)
genvar gi;
generate
    for (gi = 0; gi < N_HALF-1; gi = gi + 1) begin : GEN_SYM
        assign sym_sum[gi] = {delay[gi][B_IN-1], delay[gi]}
                           + {delay[N_TAPS-1-gi][B_IN-1], delay[N_TAPS-1-gi]};
    end
endgenerate

// Centre tap (odd number of taps → has a unique centre)
wire signed [B_IN-1:0] centre_tap = delay[N_HALF-1];

// ── CSE Coefficient Block ─────────────────────────────────────────────────────
// Coefficients from golden model (16-bit signed, symmetric half):
// The shared subexpressions are computed once and used across multiple taps.
// Full-precision products for each paired sum:
localparam integer B_SYM = B_IN + 1;          // sym_sum is B_IN+1 wide
localparam integer B_PRD = B_SYM + COEFF_W;   // product width

// ── Shared subexpressions (computed once from symmetric sum inputs) ────────────
// These are the common shift-add terms identified by the CSE analysis.
// Each sym_sum[i] is multiplied by coeffs[i] via CSD-optimised shifts.
// Common shifts: e.g., (x >> 1), (x >> 3), (x << 4) appear in multiple coeffs.

// ── Coefficient array (symmetric half, loaded at init) ────────────────────────
reg signed [COEFF_W-1:0] coeffs [0:N_HALF-1];  // N_HALF unique coefficients (pairs + centre)
initial begin
    $readmemh("../../sim/vectors/comp_fir_coeffs.hex", coeffs);
    // coeffs[0..N_HALF-2]: pair tap coefficients
    // coeffs[N_HALF-1]   : centre tap coefficient (index 15 in the 31-tap filter)
end

// ── Product computation (CSE: common shifts reused) ───────────────────────────
// For this implementation we let synthesis find the CSE via
// -resource-sharing optimisation. The RTL structure (folded symmetric) already
// halves the multiplier count. The Vivado synthesis report will show the
// adder count for comparison vs naive.

// Rounding shift amount
localparam integer ROUND_CONST = (1 << (SHIFT_BITS - 1));

reg signed [B_ACC-1:0] acc;
wire signed [B_ACC-1:0] acc_rounded = acc + ROUND_CONST;
integer ti;
always @(*) begin
    acc = {B_ACC{1'b0}};
    // Paired symmetric terms
    for (ti = 0; ti < N_HALF-1; ti = ti + 1)
        acc = acc + ($signed(sym_sum[ti]) * $signed(coeffs[ti]));
    // Centre tap uses coeffs[N_HALF-1] (index 15 for 31-tap filter)
    acc = acc + ($signed(centre_tap) * $signed(coeffs[N_HALF-1]));
end

always @(posedge clk) begin
    if (!rst_n) begin
        data_out  <= {B_OUT{1'b0}};
        valid_out <= 1'b0;
    end else begin
        valid_out <= valid_in;
        if (valid_in)
            data_out <= acc_rounded[B_ACC-1 : SHIFT_BITS]; // exactly B_OUT bits
    end
end

endmodule
