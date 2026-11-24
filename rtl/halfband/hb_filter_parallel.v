// =============================================================================
// Module  : hb_filter_parallel
// Project : P6 PDM-to-PCM Audio Front End
// Purpose : Half-Band FIR — Parallel Architecture
//           N_TAPS = 31, symmetric half-band filter.
//           Exploits structural zeros (even taps = 0 except center) and symmetry.
//           All 9 multiplications (8 symmetric pairs + center tap) are evaluated
//           in parallel in a single pipeline stage for maximum throughput.
//
// Contrast with Folded design:
//   - Parallel: Uses 9 parallel multipliers, 1 clock latency, high Fmax/throughput.
//   - Folded  : Uses 1 shared multiplier, 9 clock cycles per output, minimal area.
// =============================================================================

`timescale 1ns / 1ps

module hb_filter_parallel #(
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

// ── Coefficient ROM (9 unique values) ────────────────────────────────────────
reg signed [COEFF_W-1:0] coeff_rom [0:N_UNIQUE-1];
initial begin
    $readmemh(COEFF_FILE, coeff_rom);
end

// ── Delay Line ───────────────────────────────────────────────────────────────
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

// ── Symmetric Pair Adders (combinational) ────────────────────────────────────
wire signed [B_IN:0] sym_sum [0:7];
assign sym_sum[0] = {delay[0][B_IN-1],  delay[0]}  + {delay[30][B_IN-1], delay[30]};
assign sym_sum[1] = {delay[2][B_IN-1],  delay[2]}  + {delay[28][B_IN-1], delay[28]};
assign sym_sum[2] = {delay[4][B_IN-1],  delay[4]}  + {delay[26][B_IN-1], delay[26]};
assign sym_sum[3] = {delay[6][B_IN-1],  delay[6]}  + {delay[24][B_IN-1], delay[24]};
assign sym_sum[4] = {delay[8][B_IN-1],  delay[8]}  + {delay[22][B_IN-1], delay[22]};
assign sym_sum[5] = {delay[10][B_IN-1], delay[10]} + {delay[20][B_IN-1], delay[20]};
assign sym_sum[6] = {delay[12][B_IN-1], delay[12]} + {delay[18][B_IN-1], delay[18]};
assign sym_sum[7] = {delay[14][B_IN-1], delay[14]} + {delay[16][B_IN-1], delay[16]};

wire signed [B_IN:0] center_val = {delay[15][B_IN-1], delay[15]};

// ── Multipliers (9 parallel instances) ───────────────────────────────────────
localparam integer B_PROD = B_IN + 1 + COEFF_W;
wire signed [B_PROD-1:0] prod [0:8];

genvar gi;
generate
    for (gi = 0; gi < 8; gi = gi + 1) begin : GEN_PROD
        assign prod[gi] = sym_sum[gi] * coeff_rom[gi];
    end
endgenerate
assign prod[8] = center_val * coeff_rom[8];

// ── Adder Tree / Accumulator ─────────────────────────────────────────────────
localparam integer B_ACC = B_IN + COEFF_W + 6;
wire signed [B_ACC-1:0] total_sum = 
    prod[0] + prod[1] + prod[2] + prod[3] +
    prod[4] + prod[5] + prod[6] + prod[7] + prod[8];

// ── Rounding, Saturation & Output Register ────────────────────────────────────
localparam integer SHIFT = COEFF_W - 1; // 15
wire signed [B_ACC-1:0] rounded = total_sum + (1 << (SHIFT - 1));
wire signed [B_ACC-1:0] shifted = rounded >>> SHIFT;

always @(posedge clk) begin
    if (!rst_n) begin
        data_out  <= {B_OUT{1'b0}};
        valid_out <= 1'b0;
    end else begin
        valid_out <= 1'b0;
        if (valid_in && (dec_phase == 1'b0)) begin
            // Saturate to signed B_OUT
            if (shifted > $signed({1'b0, {(B_OUT-1){1'b1}}}))
                data_out <= {1'b0, {(B_OUT-1){1'b1}}};
            else if (shifted < $signed({1'b1, {(B_OUT-1){1'b0}}}))
                data_out <= {1'b1, {(B_OUT-1){1'b0}}};
            else
                data_out <= shifted[B_OUT-1:0];

            valid_out <= 1'b1;
        end
    end
end

endmodule
