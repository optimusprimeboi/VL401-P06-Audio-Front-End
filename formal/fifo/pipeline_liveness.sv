// =============================================================================
// File    : pipeline_liveness.sv
// Project : P6 PDM-to-PCM Audio Front End
// Purpose : Formal Liveness & Latency Proof for Decimation Chain
//
// CTL Specification Proven:
//   Liveness: Every sample tick eventually yields a PCM output sample
//   CTL: AG (pdm_tick -> AF pcm_valid)
//   Bounded Form: In any window of R_TOTAL = 64 PDM ticks, pcm_valid
//                 must fire at least once.
// =============================================================================

`timescale 1ns / 1ps

module pipeline_liveness (
    input wire clk,
    input wire rst_n,
    input wire pdm_in
);

wire [23:0] pcm_out;
wire        pcm_valid;

// Instantiate front-end CIC decimator (R=16)
cic_decimator #(
    .R (16),
    .N (4),
    .B (24)
) u_cic (
    .clk       (clk),
    .rst_n     (rst_n),
    .pdm_in    (pdm_in),
    .pcm_out   (pcm_out),
    .pcm_valid (pcm_valid)
);

// ── SVA Liveness & Bounded Response Proofs ───────────────────────────────────
`ifdef FORMAL

default clocking cb @(posedge clk); endclocking
default disable iff (!rst_n);

// Watchdog counter: cycles elapsed since last pcm_valid
reg [5:0] watchdog_cnt;
always @(posedge clk) begin
    if (!rst_n) begin
        watchdog_cnt <= 6'd0;
    end else begin
        if (pcm_valid)
            watchdog_cnt <= 6'd0;
        else
            watchdog_cnt <= watchdog_cnt + 1'b1;
    end
end

// Liveness Assertion:
// The CIC decimates by R=16. Therefore, pcm_valid MUST assert within
// at most 16 clock cycles after reset deassertion.
property p_cic_liveness_bounded;
    watchdog_cnt <= 6'd16;
endproperty
assert_liveness: assert property (p_cic_liveness_bounded);

// Periodic strobe property: pcm_valid must be high exactly every 16 cycles
property p_periodic_strobe;
    pcm_valid |=> (!pcm_valid [*15]) ##1 pcm_valid;
endproperty
assert_periodic: assert property (p_periodic_strobe);

`endif

endmodule
