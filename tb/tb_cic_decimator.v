// =============================================================================
// Testbench : tb_cic_decimator
// Project   : P6 PDM-to-PCM Audio Front End
// Purpose   : Self-checking simulation of cic_decimator.v
//
// Method:
//   1. Load PDM bit-stream from sim/vectors/pdm_test.txt  ($readmemb, 1 bit/line)
//   2. Drive one PDM bit per clock to DUT
//   3. Load expected output from sim/vectors/cic_out.hex  ($readmemh, 6 hex/line)
//   4. On every pcm_valid pulse compare DUT output vs. expected
//   5. Report PASS / FAIL + mismatch count at the end
//
// How to simulate (Icarus Verilog):
//   iverilog -DSIMULATION -o tb_cic tb_cic_decimator.v ../../rtl/cic/cic_decimator.v
//   vvp tb_cic
//
// How to simulate (Vivado xsim):
//   Add both files to a Vivado project, set tb_cic_decimator as top, run sim.
// =============================================================================

`timescale 1ns / 1ps
`define SIMULATION

module tb_cic_decimator;

// ── Parameters ────────────────────────────────────────────────────────────────
localparam integer R         = 16;
localparam integer N         = 4;
localparam integer B         = 24;

// Simulation-only limits (keep runtime reasonable)
localparam integer MAX_PDM   = 200_000;    // PDM bits to process (0.065 s)
localparam integer MAX_PCM   = MAX_PDM / R; // Expected PCM output samples

// Clock: 3.072 MHz → period = 325.52 ns ≈ 326 ns
localparam real    CLK_PERIOD = 326.0;      // ns

// File paths (relative to simulation working directory)
localparam string  PDM_FILE  = "../../sim/vectors/pdm_test.txt";
localparam string  EXP_FILE  = "../../sim/vectors/cic_out.hex";

// ── DUT Signals ───────────────────────────────────────────────────────────────
reg              clk;
reg              rst_n;
reg              pdm_in;
wire [B-1:0]     pcm_out;
wire             pcm_valid;

// ── Stimulus / Reference Memories ─────────────────────────────────────────────
reg  [0:0]       pdm_mem  [0:MAX_PDM-1];    // 1-bit PDM stream
reg  [B-1:0]     exp_mem  [0:MAX_PCM-1];    // expected 24-bit CIC output

// ── Counters / Status ─────────────────────────────────────────────────────────
integer          pdm_idx;
integer          pcm_idx;
integer          mismatch;
integer          total_checked;

// ── DUT Instantiation ─────────────────────────────────────────────────────────
cic_decimator #(
    .R (R),
    .N (N),
    .B (B)
) dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .pdm_in    (pdm_in),
    .pcm_out   (pcm_out),
    .pcm_valid (pcm_valid)
);

// ── Clock Generation ──────────────────────────────────────────────────────────
initial clk = 1'b0;
always #(CLK_PERIOD / 2.0) clk = ~clk;

// ── Load Reference Data ───────────────────────────────────────────────────────
initial begin
    // Load PDM bits (one per line: "0" or "1")
    $readmemb(PDM_FILE, pdm_mem);
    // Load expected CIC output (6-hex-digit signed 24-bit, one per line)
    $readmemh(EXP_FILE, exp_mem);
    $display("[TB] Loaded PDM vectors from %s", PDM_FILE);
    $display("[TB] Loaded expected CIC output from %s", EXP_FILE);
end

// ── Reset + Stimulus ──────────────────────────────────────────────────────────
initial begin
    rst_n    = 1'b0;
    pdm_in   = 1'b0;
    pdm_idx  = 0;
    pcm_idx  = 0;
    mismatch = 0;
    total_checked = 0;

    // Hold reset for 4 clock cycles
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    $display("[TB] Reset released at %0t ns", $time);

    // Drive PDM bits one per clock (first bit immediately on reset release)
    while (pdm_idx < MAX_PDM) begin
        pdm_in = pdm_mem[pdm_idx][0];
        pdm_idx = pdm_idx + 1;
        @(negedge clk);
    end

    // Wait for last output to emerge (pipeline latency ≤ N extra cycles)
    repeat (N + 4) @(posedge clk);

    // ── Final Report ──────────────────────────────────────────────────────────
    $display("=========================================");
    if (mismatch == 0 && total_checked > 0) begin
        $display("[TB] *** PASS *** — %0d samples checked, 0 mismatches",
                 total_checked);
    end else if (total_checked == 0) begin
        $display("[TB] *** WARNING *** — No valid outputs captured!");
    end else begin
        $display("[TB] *** FAIL *** — %0d / %0d mismatches",
                 mismatch, total_checked);
    end
    $display("=========================================");
    $finish;
end

// ── Output Checker ────────────────────────────────────────────────────────────
// Sign-extend the 24-bit hex from expected memory before comparing.
// Golden model stores values as unsigned 24-bit 2's complement.
function signed [B-1:0] sign_ext;
    input [B-1:0] raw;
    // raw is already B bits; Verilog interprets as signed if declared signed
    sign_ext = raw;
endfunction

always @(posedge clk) begin
    if (pcm_valid && rst_n) begin
        if (pcm_idx < MAX_PCM) begin
            total_checked = total_checked + 1;

            // Skip first few samples — CIC has a startup transient
            // (comb delay regs start at 0 → first N outputs differ)
            if (pcm_idx >= N) begin
                if (pcm_out !== exp_mem[pcm_idx]) begin
                    mismatch = mismatch + 1;
                    if (mismatch <= 10)   // Print only first 10 mismatches
                        $display("[TB] MISMATCH sample %0d: got %06x, exp %06x  (diff %0d)",
                                 pcm_idx,
                                 pcm_out,
                                 exp_mem[pcm_idx],
                                 $signed(pcm_out) - $signed(exp_mem[pcm_idx]));
                end
            end
            pcm_idx = pcm_idx + 1;
        end
    end
end

// ── Timeout Guard ─────────────────────────────────────────────────────────────
initial begin
    // 100 ms timeout in simulation time
    #(100_000_000);
    $display("[TB] TIMEOUT — simulation did not complete in time");
    $finish;
end

// ── Waveform Dump (for GTKWave) ───────────────────────────────────────────────
initial begin
    $dumpfile("tb_cic_decimator.vcd");
    $dumpvars(0, tb_cic_decimator);
end

// ── Progress Monitor ─────────────────────────────────────────────────────────
always @(posedge clk) begin
    if (pcm_valid && rst_n && (pcm_idx % 1000 == 0) && pcm_idx > 0)
        $display("[TB] Progress: %0d PDM bits in, %0d PCM samples out",
                 pdm_idx, pcm_idx);
end

endmodule
