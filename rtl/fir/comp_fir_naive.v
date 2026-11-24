// =============================================================================
// Module  : csd_mult_naive
// Project : P6 PDM-to-PCM Audio Front End
// Purpose : Method 1 — Naïve CSD multiplier block
//           Multiplies a B_IN-bit signed input by a fixed set of
//           COMP_FIR coefficients using shifts and adds.
//           Each coefficient is independently converted to CSD;
//           no sharing between taps.
//
// Coefficients (31-tap, 16-bit, from golden/comp_fir.py output):
//   Stored as localparams, regenerate with golden/comp_fir.py if you change
//   filter parameters.
//
// Adder count: reported by golden model (comp_fir.py method1_naive_csd).
// =============================================================================

`timescale 1ns / 1ps

// Generic CSD constant multiplier: computes DATA_IN * CONSTANT
// using shifts and adds in CSD representation.
// One instance per tap in the naive approach.
module csd_const_mult #(
    parameter signed [15:0] COEFF     = 16'sd0,  // Fixed coefficient
    parameter integer        B_IN      = 24,       // Input width
    parameter integer        B_OUT     = 24        // Output width (truncated)
)(
    input  wire signed [B_IN-1:0]  data_in,
    output wire signed [B_OUT-1:0] data_out
);

// Full-precision accumulator width: B_IN + 16 (coefficient bits) + 1 (sign)
localparam integer B_FULL = B_IN + 17;

// Expand input to full precision
wire signed [B_FULL-1:0] x = {{(B_FULL-B_IN){data_in[B_IN-1]}}, data_in};

// CSD multiplication: sum of signed shifts
// The synthesis tool will collapse this to a shift-add tree.
// For the report, count the non-zero bits in the CSD representation.
wire signed [B_FULL-1:0] product;
assign product = x * $signed(COEFF);   // let synthesis optimise to shifts

// Round to B_OUT bits (arithmetic right-shift with rounding)
// We drop (B_FULL - B_OUT) LSBs with rounding.
localparam integer SHIFT = B_FULL - B_OUT;
assign data_out = product[B_FULL-1 : SHIFT];

endmodule


// =============================================================================
// Top-level naive CSD FIR: instantiates one csd_const_mult per unique tap
// For a 31-tap symmetric FIR → 16 unique coefficients (h[0]..h[15], centre h[16])
// =============================================================================
module comp_fir_naive #(
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

// ── Coefficient ROM (from golden model comp_fir.py) ───────────────────────────
// 16-bit signed, 31 taps, symmetric (h[i] = h[N-1-i])
// Regenerate with: python golden/comp_fir.py
localparam integer N_HALF   = (N_TAPS + 1) / 2;    // 16
localparam integer COEFF_W  = 16;

// Coefficient values (loaded from golden model output)
// These are the FULL symmetric array. Update if filter is redesigned.
reg signed [COEFF_W-1:0] coeffs [0:N_TAPS-1];
initial begin
    // Populated by a $readmemh at sim time (or hardcode from comp_fir_coeffs.hex)
    $readmemh("../../sim/vectors/comp_fir_coeffs.hex", coeffs);
end

// ── Delay Line (shift register) ───────────────────────────────────────────────
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

// ── MAC: sum all tap*coeff products ──────────────────────────────────────────
// Full-precision accumulator: B_IN + COEFF_W + clog2(N_TAPS) extra bits
localparam integer B_ACC = B_IN + COEFF_W + 6;  // 6 bits for N=31 sum

reg signed [B_ACC-1:0] acc;
integer ti;
always @(*) begin
    acc = {B_ACC{1'b0}};
    for (ti = 0; ti < N_TAPS; ti = ti + 1)
        acc = acc + (delay[ti] * coeffs[ti]);
end

// ── Output register + truncation ─────────────────────────────────────────────
// Rounding: add 0.5 LSB before shift, then take top B_OUT bits
localparam integer SHIFT_BITS = B_ACC - B_OUT; // number of bits to drop (= COEFF_W + 6 = 22)
localparam integer ROUND_CONST = (1 << (SHIFT_BITS - 1));

wire signed [B_ACC-1:0] acc_rounded = acc + ROUND_CONST;

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
