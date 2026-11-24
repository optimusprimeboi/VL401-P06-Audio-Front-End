//===========================================================================
// zybo_clock_wiz.v — MMCM Clock Wizard Wrapper for Zybo Z7
//
// Input : sysclk  = 125.000 MHz (K17, single-ended LVCMOS33)
// Output: clk_49m152 = 49.152 MHz  (processing clock — all RTL logic)
//         clk_12m288 = 12.288 MHz  (SSM2603 MCLK = 256 × 48 kHz)
//         locked     = MMCM lock indicator
//
// MMCM Parameters (MMCME2_ADV, Zynq-7000 / Artix-7):
//   Hardware Granularity: CLKFBOUT_MULT_F step is 0.125
//   VCO = 125 × CLKFBOUT_MULT_F / DIVCLK_DIVIDE
//       = 125 × 37.750 / 4 = 1179.6875 MHz  (in-spec: 600–1600 MHz)
//   clk_49m152 : CLKOUT0_DIVIDE_F = 24.0  → 1179.6875 / 24 = 49.1536 MHz (33.5 ppm error) ✓
//   clk_12m288 : CLKOUT1_DIVIDE   = 96    → 1179.6875 / 96 = 12.2884 MHz (33.5 ppm error) ✓
//   Pure integer O0/O1 ratio (96 = 4 × 24) guarantees phase coherence.
//
// Clock-Enable outputs (synchronous to clk_49m152):
//   ce_pdm_3m072 : 1-cycle pulse every 16 cycles  (49.152 / 16 = 3.072 MHz tick)
//   ce_bclk_3m072: same as ce_pdm (I2S BCLK tick, shared)
//   ce_pcm_48k   : 1-cycle pulse every 1024 cycles (49.152 / 1024 = 48 kHz tick)
//
// Author : RTL_project_fin / Zybo Z7 port
// Target : xc7z010clg400-1 / xc7z020clg400-1 (Zybo Z7)
//===========================================================================
`timescale 1ns / 1ps

module zybo_clock_wiz (
    // Primary input clock (125 MHz, K17)
    input  wire sysclk,

    // Derived clocks
    output wire clk_49m152,     // 49.152 MHz — all processing logic
    output wire clk_12m288,     // 12.288 MHz — SSM2603 MCLK

    // Clock-enable strobes (synchronous to clk_49m152)
    output reg  ce_pdm_3m072,   // 3.072 MHz PDM/BCLK tick
    output reg  ce_bclk_3m072,  // 3.072 MHz I2S BCLK tick (same phase)
    output reg  ce_pcm_48k,     // 48 kHz PCM sample strobe

    // Lock indicator
    output wire locked
);

    //----------------------------------------------------------------------
    // Internal signals
    //----------------------------------------------------------------------
    wire clkfb_out, clkfb_in;
    wire clk0_raw, clk1_raw;

    //----------------------------------------------------------------------
    // IBUFG — buffer the incoming single-ended 125 MHz clock
    //----------------------------------------------------------------------
    wire sysclk_ibuf;
    IBUFG u_ibufg (
        .I  (sysclk),
        .O  (sysclk_ibuf)
    );

    //----------------------------------------------------------------------
    // MMCME2_ADV — synthesise 49.152 MHz and 12.288 MHz from 125 MHz
    //----------------------------------------------------------------------
    MMCME2_ADV #(
        // Input clock
        .CLKIN1_PERIOD      (8.000),        // 125 MHz → 8 ns period

        // VCO: 125 × 37.750 / 4 = 1179.6875 MHz (Granularity = 0.125 step)
        .CLKFBOUT_MULT_F    (37.750),
        .DIVCLK_DIVIDE      (4),
        .CLKFBOUT_PHASE     (0.000),

        // CLKOUT0 → 49.1536 MHz (~49.152 MHz processing clock)
        .CLKOUT0_DIVIDE_F   (24.000),
        .CLKOUT0_PHASE      (0.000),
        .CLKOUT0_DUTY_CYCLE (0.500),

        // CLKOUT1 → 12.2884 MHz (~12.288 MHz audio MCLK, 4 × CLKOUT0)
        .CLKOUT1_DIVIDE     (96),
        .CLKOUT1_PHASE      (0.000),
        .CLKOUT1_DUTY_CYCLE (0.500),

        // Unused outputs
        .CLKOUT2_DIVIDE     (1),
        .CLKOUT3_DIVIDE     (1),
        .CLKOUT4_DIVIDE     (1),
        .CLKOUT5_DIVIDE     (1),
        .CLKOUT6_DIVIDE     (1),

        // Bandwidth / compensation
        .BANDWIDTH          ("OPTIMIZED"),
        .COMPENSATION       ("ZHOLD"),
        .STARTUP_WAIT       ("FALSE"),
        .REF_JITTER1        (0.010)
    ) u_mmcm (
        // Clocks in
        .CLKIN1     (sysclk_ibuf),
        .CLKIN2     (1'b0),
        .CLKINSEL   (1'b1),         // select CLKIN1

        // Feedback
        .CLKFBOUT   (clkfb_out),
        .CLKFBIN    (clkfb_in),

        // Outputs
        .CLKOUT0    (clk0_raw),     // 49.152 MHz
        .CLKOUT0B   (),
        .CLKOUT1    (clk1_raw),     // 12.288 MHz
        .CLKOUT1B   (),
        .CLKOUT2    (), .CLKOUT2B   (),
        .CLKOUT3    (), .CLKOUT3B   (),
        .CLKOUT4    (),
        .CLKOUT5    (),
        .CLKOUT6    (),

        // Control
        .LOCKED     (locked),
        .PWRDWN     (1'b0),
        .RST        (1'b0),

        // Dynamic reconfiguration — tie off
        .DADDR      (7'b0),
        .DCLK       (1'b0),
        .DEN        (1'b0),
        .DI         (16'b0),
        .DWE        (1'b0),
        .DO         (),
        .DRDY       (),

        // Phase shift — tie off
        .PSCLK      (1'b0),
        .PSEN       (1'b0),
        .PSINCDEC   (1'b0),
        .PSDONE     ()
    );

    //----------------------------------------------------------------------
    // BUFG — global clock buffers on each output
    //----------------------------------------------------------------------
    BUFG u_bufg_clkfb (
        .I (clkfb_out),
        .O (clkfb_in)
    );

    BUFG u_bufg_clk0 (
        .I (clk0_raw),
        .O (clk_49m152)
    );

    BUFG u_bufg_clk1 (
        .I (clk1_raw),
        .O (clk_12m288)
    );

    //----------------------------------------------------------------------
    // Clock-Enable Generator (synchronous to clk_49m152)
    //
    //   PDM tick  : divide by 16   (49.152 MHz / 16 = 3.072 MHz)
    //   PCM strobe: divide by 1024 (49.152 MHz / 1024 = 48 kHz)
    //----------------------------------------------------------------------
    reg [3:0]  pdm_div_cnt;     // 0..15
    reg [9:0]  pcm_div_cnt;     // 0..1023

    // Reset is external; initialise counters to 0.
    // Both counters run freely once locked. External logic should gate
    // processing with the 'locked' signal.

    always @(posedge clk_49m152) begin
        // --- PDM / BCLK divider (÷16) -----------------------------------
        if (pdm_div_cnt == 4'd15) begin
            pdm_div_cnt   <= 4'd0;
            ce_pdm_3m072  <= 1'b1;
            ce_bclk_3m072 <= 1'b1;
        end else begin
            pdm_div_cnt   <= pdm_div_cnt + 4'd1;
            ce_pdm_3m072  <= 1'b0;
            ce_bclk_3m072 <= 1'b0;
        end

        // --- PCM strobe (÷1024) -----------------------------------------
        if (pcm_div_cnt == 10'd1023) begin
            pcm_div_cnt <= 10'd0;
            ce_pcm_48k  <= 1'b1;
        end else begin
            pcm_div_cnt <= pcm_div_cnt + 10'd1;
            ce_pcm_48k  <= 1'b0;
        end
    end

endmodule
