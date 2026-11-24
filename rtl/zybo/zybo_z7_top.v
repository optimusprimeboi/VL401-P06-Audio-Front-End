//===========================================================================
// zybo_z7_top.v — Digilent Zybo Board Top-Level: PDM-to-PCM Audio Front End
//
// Target Hardware : Digilent Zybo Z7-10 (XC7Z010-1CLG400C)
// Headphone Out   : Jack J5 (HPH OUT) powered by Analog Devices SSM2603
//
// Direct Hardware Control Mapping:
//   - SW0 (G15) : Audio Play/Pause (1 = Play Audio, 0 = Pure Silence / Mute)
//   - SW1 (P15) : Filter Selection (0 = 9-Tap Remez FIR, 1 = 3-Tap Dolecek IEEE Paper FIR)
//   - SW2 (W13) : Architecture Select (0 = Parallel U3 Graph MCM, 1 = Folded Hand-HLS FIR)
//   - SW3 (T16) : Decimation Mode (0 = Decimated 16-bit PCM, 1 = Raw CIC Bypass)
//   - BTN1 (P16): Volume Down (Decreases Gain)
//   - BTN2 (K19): Volume Up   (Increases Gain)
//   - BTN3 (Y16): Tone Switch (Toggle between Smooth 440 Hz Tone and 3-Tone Benchmark)
//   - BTN0 (K18): System Reset (Active-High Reset)
//===========================================================================

`timescale 1ns / 1ps

module zybo_z7_top #(
    parameter USE_BRAM_SOURCE = 1,
    parameter BTN_ACTIVE_HIGH = 1
)(
    // -------------------------------------------------------------
    // Primary Clock & Reset (Zybo Z7 Hardware Pins)
    // -------------------------------------------------------------
    input  wire        sysclk,          // K17 (125.000 MHz Oscillator)
    input  wire        rst_n,           // K18 (BTN0 Push Button Reset)

    // -------------------------------------------------------------
    // 4 Slide Switches (Interactive Real-time Audio Controls)
    // -------------------------------------------------------------
    input  wire [3:0]  sw,              // SW0(G15), SW1(P15), SW2(W13), SW3(T16)

    // -------------------------------------------------------------
    // 3 User Buttons (Volume & Tone Selection)
    // -------------------------------------------------------------
    input  wire [3:1]  btn,             // BTN1(P16), BTN2(K19), BTN3(Y16)

    // -------------------------------------------------------------
    // PDM MEMS Microphone Interface (Pmod JE / MIC3 Header)
    // -------------------------------------------------------------
    input  wire        pdm_mic_data,    // V12 (JE1) - 1-bit PDM data in
    output wire        pdm_mic_clk,     // W16 (JE2) - 3.072 MHz PDM clock out
    output wire        audio_pwm_out,   // J15 (JE3) - Direct 1-bit Delta-Sigma Audio

    // -------------------------------------------------------------
    // SSM2603 Audio Codec / I2S DAC Interface (3.5mm Headphone Jack J5)
    // -------------------------------------------------------------
    output wire        i2s_mclk,        // R17 (AC_MCLK  - 12.288 MHz Codec Master Clock)
    output wire        i2s_bclk,        // R19 (AC_BCLK  - 3.072 MHz Bit Clock)
    output wire        i2s_lrclk,       // T19 (AC_PBLRC - 48 kHz Frame Sync)
    output wire        i2s_sdata,       // R18 (AC_PBDAT - Serial Audio Data)
    output wire        ac_muten,        // P18 (AC_MUTEN - Hardware Mute, Active-Low)
    inout  wire        ac_scl,          // N18 (AC_SCL   - I2C Clock)
    inout  wire        ac_sda,          // N17 (AC_SDA   - I2C Data)

    // -------------------------------------------------------------
    // 4-bit User LEDs: Hardware VU Meter & Voice Activity Detection
    // -------------------------------------------------------------
    output wire [3:0]  led              // M14, M15, G14, D18
);

    // =========================================================================
    // 1. Clock Generation via MMCM Wrapper (zybo_clock_wiz)
    // =========================================================================
    wire clk_49m152;
    wire clk_12m288;
    wire ce_pdm_3m072;
    wire ce_bclk_3m072;
    wire ce_pcm_48k;
    wire mmcm_locked;

    zybo_clock_wiz u_clk_wiz (
        .sysclk        (sysclk),
        .clk_49m152    (clk_49m152),
        .clk_12m288    (clk_12m288),
        .ce_pdm_3m072  (ce_pdm_3m072),
        .ce_bclk_3m072 (ce_bclk_3m072),
        .ce_pcm_48k    (ce_pcm_48k),
        .locked        (mmcm_locked)
    );

    // =========================================================================
    // 2. Synchronous Reset De-assertion Architecture
    // =========================================================================
    wire raw_reset_n = BTN_ACTIVE_HIGH ? (!rst_n) : rst_n;

    reg [2:0] rst_sync;
    always @(posedge clk_49m152 or negedge raw_reset_n) begin
        if (!raw_reset_n)
            rst_sync <= 3'b000;
        else
            rst_sync <= {rst_sync[1:0], mmcm_locked};
    end
    wire effective_rst_n = rst_sync[2];

    // =========================================================================
    // 3. Audio Master Clock (MCLK) Forwarding via ODDR Primitive
    // =========================================================================
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_oddr_mclk (
        .C  (clk_12m288),
        .CE (1'b1),
        .D1 (1'b1),
        .D2 (1'b0),
        .R  (1'b0),
        .S  (1'b0),
        .Q  (i2s_mclk)
    );

    // =========================================================================
    // 4. SSM2603 Audio Codec Autonomous I2C Initialization
    // =========================================================================
    wire codec_init_done;

    ssm2603_i2c_init #(
        .CLK_FREQ_HZ (49_152_000),
        .I2C_FREQ_HZ (50_000)
    ) u_codec_init (
        .clk       (clk_49m152),
        .rst_n     (effective_rst_n),
        .ac_muten  (ac_muten),
        .ac_scl    (ac_scl),
        .ac_sda    (ac_sda),
        .init_done (codec_init_done)
    );

    // =========================================================================
    // 5. Button Debouncer, Discrete 4-Level Volume Gain & Tone Selection
    // =========================================================================
    reg [3:1]  btn_sync0, btn_sync1, btn_prev;
    reg [18:0] debounce_cnt;
    wire       btn_tick = (debounce_cnt == 19'd491_520); // 10ms sampling tick

    always @(posedge clk_49m152 or negedge effective_rst_n) begin
        if (!effective_rst_n) begin
            debounce_cnt <= 19'd0;
            btn_sync0    <= 3'b000;
            btn_sync1    <= 3'b000;
        end else begin
            btn_sync0 <= btn;
            btn_sync1 <= btn_sync0;
            if (debounce_cnt >= 19'd491_520)
                debounce_cnt <= 19'd0;
            else
                debounce_cnt <= debounce_cnt + 19'd1;
        end
    end

    reg [1:0]         vol_step;      // 0 = Quiet, 1 = Medium, 2 = Normal, 3 = Loud
    reg signed [15:0] gain_reg;
    reg               tone_sel_reg;

    always @(posedge clk_49m152 or negedge effective_rst_n) begin
        if (!effective_rst_n) begin
            vol_step     <= 2'd2;        // Default: Level 2 (Normal)
            gain_reg     <= 16'h1000;    // 1.0x Q4.12
            tone_sel_reg <= 1'b1;        // Default: 1 = Real Recorded Audio Stream from BRAM (pdm_stimulus_words.hex)
            btn_prev     <= 3'b000;
        end else if (btn_tick) begin
            btn_prev <= btn_sync1;

            // BTN1: Volume Down (steps 3 -> 2 -> 1 -> 0)
            if (btn_sync1[1] && !btn_prev[1]) begin
                if (vol_step > 2'd0)
                    vol_step <= vol_step - 2'd1;
            end

            // BTN2: Volume Up (steps 0 -> 1 -> 2 -> 3)
            if (btn_sync1[2] && !btn_prev[2]) begin
                if (vol_step < 2'd3)
                    vol_step <= vol_step + 2'd1;
            end

            // BTN3: Toggle Tone (440 Hz pure tone <-> Multi-tone benchmark)
            if (btn_sync1[3] && !btn_prev[3]) begin
                tone_sel_reg <= ~tone_sel_reg;
            end

            // Decode 4 discrete volume gain levels (Q4.12)
            case (vol_step)
                2'd0: gain_reg <= 16'h0200; // Level 0: 0.125x (-18 dB, Quiet)
                2'd1: gain_reg <= 16'h0600; // Level 1: 0.375x (-8.5 dB, Medium)
                2'd2: gain_reg <= 16'h1000; // Level 2: 1.000x (0 dB, Normal)
                2'd3: gain_reg <= 16'h2400; // Level 3: 2.250x (+7 dB, Loud)
            endcase
        end
    end

    // =========================================================================
    // 6. Complete PDM-to-PCM Audio Front End Pipeline (pdm_top)
    // =========================================================================
    wire [7:0] vu_meter_8bit;

    pdm_top #(
        .USE_BRAM_SOURCE (USE_BRAM_SOURCE),
        .FIFO_DEPTH      (64)
    ) u_pdm_pipeline (
        .clk             (clk_49m152),
        .rst_n           (effective_rst_n),

        // Direct Hardware Controls from Switches and Buttons
        .cfg_override    (1'b1),
        .cfg_pdm_enable  (sw[0]),         // SW0: Play (1) / Mute (0)
        .cfg_use_paper   (sw[1]),         // SW1: Dolecek (1) / Remez (0)
        .cfg_use_folded  (sw[2]),         // SW2: Folded (1) / Parallel (0)
        .cfg_bypass_mode (sw[3]),         // SW3: Bypass (1) / Decimated (0)
        .cfg_tone_sel    (tone_sel_reg),  // BTN3: 440 Hz (0) / Multi-tone (1)
        .cfg_gain        (gain_reg),      // BTN1/2: Dynamic Volume Gain

        // Microphone interface
        .pdm_mic_data_in (pdm_mic_data),
        .pdm_mic_clk_out (pdm_mic_clk),

        // APB3 slave bus (idle)
        .psel            (1'b0),
        .penable         (1'b0),
        .pwrite          (1'b0),
        .paddr           (8'h00),
        .pwdata          (32'h00000000),
        .prdata          (),
        .pready          (),
        .pslverr         (),
        .irq             (),

        // Digital audio outputs
        .i2s_bclk        (i2s_bclk),
        .i2s_lrclk       (i2s_lrclk),
        .i2s_sdata       (i2s_sdata),
        .audio_pwm_out   (audio_pwm_out),

        // Hardware VU meter (8-bit)
        .led_vu_meter    (vu_meter_8bit)
    );

    // =========================================================================
    // 7. 4-bit LED Output Mapping (Discrete Dot-Mode & Live Mute Guard)
    // =========================================================================
    //   - SW0 = 0 (Mute) : ALL LEDs strictly OFF (4'b0000)
    //   - SW0 = 1 (Play) : EXACTLY ONE LED ON for active volume level:
    //                      LD0 only = Quiet  (-18 dB)
    //                      LD1 only = Medium (-8.5 dB)
    //                      LD2 only = Normal (0 dB default)
    //                      LD3 only = Loud   (+7 dB)
    assign led = (!sw[0]) ? 4'b0000 :
                 (vol_step == 2'd0) ? 4'b0001 :
                 (vol_step == 2'd1) ? 4'b0010 :
                 (vol_step == 2'd2) ? 4'b0100 :
                                      4'b1000;

endmodule
