// =============================================================================
// Module  : cic_decimator
// Project : P6 PDM-to-PCM Audio Front End
// Purpose : Hogenauer CIC decimation filter
//           R=16 (decimation), N=4 (stages), M=1 (differential delay)
//           Input : 1-bit PDM @ 3.072 MHz
//           Output: 24-bit signed PCM @ 192 kHz (3.072 MHz / 16)
//
// Architecture
//   - N integrators running at full PDM clock rate (no multipliers)
//   - 4-bit decimation counter; fires dec_en every R clocks
//   - N comb sections running at dec_en rate (combinational per enable)
//   - All arithmetic is 24-bit two's-complement wrap (matches golden model)
//
// Bit-width analysis (Hogenauer 1981):
//   B_growth = N * ceil(log2(R*M)) = 4 * ceil(log2(16)) = 16 bits
//   B_total  = B_in + B_growth = 1 + 16 = 17 bits minimum
//   We use B=24 for head-room and clean byte alignment.
//
// Reference: E.B. Hogenauer, "An economical class of digital filters for
//            decimation and interpolation," IEEE TASP 29(2):155-162, 1981.
// =============================================================================

`timescale 1ns / 1ps

module cic_decimator #(
    parameter integer R = 16,    // Decimation ratio
    parameter integer N = 4,     // Number of CIC stages
    parameter integer B = 24     // Internal & output bit width (signed)
)(
    // ── Clock / Reset ─────────────────────────────────────────────────────────
    input  wire             clk,        // PDM-rate clock (3.072 MHz)
    input  wire             rst_n,      // Synchronous active-low reset

    // ── Input ─────────────────────────────────────────────────────────────────
    input  wire             pdm_in,     // 1-bit PDM sample (0 or 1)

    // ── Output ────────────────────────────────────────────────────────────────
    output reg  [B-1:0]     pcm_out,    // Signed 2's-complement PCM sample
    output reg              pcm_valid   // One-cycle strobe: new sample ready
);

// ── Derived Parameters ────────────────────────────────────────────────────────
localparam integer CNT_W = $clog2(R);  // decimation counter width (4 bits)

// ── Integrators (run every clock at PDM rate) ─────────────────────────────────
// Each integrator: y[n] = y[n-1] + x[n]   (wrapping 24-bit arithmetic)
// PDM input is unsigned {0,1}, sign-extended to B bits.
reg signed [B-1:0] intg [0:N-1];
wire signed [B-1:0] intg_next [0:N-1];

assign intg_next[0] = intg[0] + {{(B-1){1'b0}}, pdm_in};
genvar ik;
generate
    for (ik = 1; ik < N; ik = ik + 1) begin : GEN_INTG_NEXT
        assign intg_next[ik] = intg[ik] + intg_next[ik-1];
    end
endgenerate

integer ki;
always @(posedge clk) begin
    if (!rst_n) begin
        for (ki = 0; ki < N; ki = ki + 1)
            intg[ki] <= {B{1'b0}};
    end else begin
        for (ki = 0; ki < N; ki = ki + 1)
            intg[ki] <= intg_next[ki];
    end
end

// ── Decimation Counter ────────────────────────────────────────────────────────
reg [CNT_W-1:0] dec_cnt;
reg             dec_en;    // one-cycle enable every R clocks

always @(posedge clk) begin
    if (!rst_n) begin
        dec_cnt <= {CNT_W{1'b0}};
        dec_en  <= 1'b0;
    end else begin
        dec_en <= 1'b0;
        if (dec_cnt == R - 1) begin
            dec_cnt <= {CNT_W{1'b0}};
            dec_en  <= 1'b1;
        end else begin
            dec_cnt <= dec_cnt + 1'b1;
        end
    end
end

// ── Comb Sections (run at dec_en rate = 192 kHz) ──────────────────────────────
// Each comb stage: y[n] = x[n] - x[n-M]  (M=1 differential delay)
// The combinational cascade is registered once per dec_en pulse.
// Delay registers hold the previous input to each comb stage.

reg  signed [B-1:0] comb_dly [0:N-1];   // delay-1 registers

// Combinational cascade: comb_wire[0] = last integrator,
//   comb_wire[k+1] = comb_wire[k] - comb_dly[k]
wire signed [B-1:0] comb_wire [0:N];
assign comb_wire[0] = intg[N-1];         // tap last integrator

genvar gi;
generate
    for (gi = 0; gi < N; gi = gi + 1) begin : GEN_COMB
        assign comb_wire[gi+1] = comb_wire[gi] - comb_dly[gi];
    end
endgenerate

// Register comb outputs on each dec_en pulse
integer ci;
always @(posedge clk) begin
    if (!rst_n) begin
        for (ci = 0; ci < N; ci = ci + 1)
            comb_dly[ci] <= {B{1'b0}};
        pcm_out   <= {B{1'b0}};
        pcm_valid <= 1'b0;
    end else begin
        pcm_valid <= 1'b0;
        if (dec_en) begin
            // Advance all delay registers
            for (ci = 0; ci < N; ci = ci + 1)
                comb_dly[ci] <= comb_wire[ci];
            // Latch final comb output
            pcm_out   <= comb_wire[N];
            pcm_valid <= 1'b1;
        end
    end
end

// ── Overflow / Debug Assertions (synthesis-off) ───────────────────────────────
`ifdef SIMULATION
// Sanity: integrators should stay within the B-bit signed range.
// For a well-behaved PDM input (avg <= 0.9), they won't overflow.
// This just prints a warning; the RTL wraps silently like hardware would.
always @(posedge clk) begin
    if (rst_n && dec_en) begin
        if (^pcm_out === 1'bx)
            $display("WARNING [cic_decimator] pcm_out contains X at time %0t", $time);
    end
end
`endif

endmodule
