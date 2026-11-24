// =============================================================================
// Module: pdm_top
// Description: Top-Level Integration of PDM-to-PCM Audio Front End System
// Architecture:
//   - BRAM PDM Stream Player / External Mic Input MUX
//   - CIC Decimator (R=16, N=4)
//   - CIC Compensation FIR (9-Tap Remez / 3-Tap Dolecek Paper selectable)
//   - Half-Band Stage 1 (11-Tap, 192 kHz -> 96 kHz)
//   - Half-Band Stage 2 (23-Tap, Parallel U3 Graph MCM vs Folded Hand-HLS selectable)
//   - Digital Gain & Saturation Unit (ESPRESSO/BDD optimized)
//   - VAD & RMS Energy Computer
//   - PCM Audio FIFO with Watermark IRQ
//   - AMBA APB Slave Control Interface
//   - I2S Transmitter & PWM Audio DAC
//   - 8-bit LED VU Meter Display
// =============================================================================

`timescale 1ns / 1ps

module pdm_top #(
    parameter USE_BRAM_SOURCE = 1,
    parameter FIFO_DEPTH      = 64
)(
    // Clock and Reset
    input  wire        clk,            // System Clock (49.152 MHz)
    input  wire        rst_n,          // Asynchronous Active-Low Reset
    
    // Hardware Direct Control Inputs (Override APB defaults when used standalone)
    input  wire        cfg_override,   // 1 = use switch/button inputs
    input  wire        cfg_pdm_enable, // SW0 (1 = Play, 0 = Pause)
    input  wire        cfg_use_paper,  // SW1 (1 = Dolecek paper filter, 0 = Remez)
    input  wire        cfg_use_folded, // SW2 (1 = Folded Hand-HLS, 0 = Parallel)
    input  wire        cfg_bypass_mode,// SW3 (1 = Raw CIC Bypass, 0 = Decimated PCM)
    input  wire        cfg_tone_sel,   // BTN3 (0 = 440 Hz tone, 1 = Multi-tone)
    input  wire signed [15:0] cfg_gain,// BTN1/BTN2 (Digital Gain)

    // External Microphone Interface (if present)
    input  wire        pdm_mic_data_in,
    output wire        pdm_mic_clk_out,
    
    // APB3 / APB4 Slave Bus
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [7:0]  paddr,
    input  wire [31:0] pwdata,
    output wire [31:0] prdata,
    output wire        pready,
    output wire        pslverr,
    output wire        irq,
    
    // Audio Outputs
    output wire        i2s_bclk,
    output wire        i2s_lrclk,
    output wire        i2s_sdata,
    output wire        audio_pwm_out,
    
    // Diagnostic / Demo Outputs
    output wire [7:0]  led_vu_meter
);

    // -------------------------------------------------------------
    // 1. Control & Status Signals from APB Core
    // -------------------------------------------------------------
    wire        pdm_enable;
    wire        soft_reset;
    wire        bypass_mode;
    wire        use_paper_filter;
    wire        use_folded_hb2;
    wire signed [15:0] digital_gain;
    wire [6:0]  watermark;
    wire [15:0] vad_threshold;

    wire        effective_rst_n = cfg_override ? rst_n : (rst_n && (!soft_reset));

    // Multiplex between APB register control and hardware switch/button inputs
    wire        ctrl_pdm_enable   = cfg_override ? cfg_pdm_enable   : pdm_enable;
    wire        ctrl_use_paper    = cfg_override ? cfg_use_paper    : use_paper_filter;
    wire        ctrl_use_folded   = cfg_override ? cfg_use_folded   : use_folded_hb2;
    wire        ctrl_bypass_mode  = cfg_override ? cfg_bypass_mode  : bypass_mode;
    wire signed [15:0] ctrl_gain  = cfg_override ? cfg_gain         : digital_gain;

    // -------------------------------------------------------------
    // 2. PDM Source Selection (BRAM Player vs External Mic)
    // -------------------------------------------------------------
    wire pdm_clk_en;
    wire bram_pdm_bit;

    bram_pdm_player #(
        .MEM_WORDS(1920),
        .ADDR_WIDTH(11),
        .INIT_FILE("C:/Users/Lenovo/Downloads/VL401_Group06_P06_Final_Submission/pdm_stimulus_words.hex")
    ) u_bram_player (
        .clk        (clk),
        .rst_n      (effective_rst_n),
        .enable     (ctrl_pdm_enable),
        .tone_sel   (cfg_tone_sel),
        .pdm_clk_en (pdm_clk_en),
        .pdm_bit_out(bram_pdm_bit)
    );

    assign pdm_mic_clk_out = pdm_clk_en;
    wire active_pdm_bit = USE_BRAM_SOURCE ? bram_pdm_bit : pdm_mic_data_in;

    // -------------------------------------------------------------
    // 3. Stage 1: CIC Decimator (3.072 MHz -> 192 kHz)
    // -------------------------------------------------------------
    wire signed [17:0] cic_out;
    wire               cic_valid;

    cic_decimator #(
        .R(16),
        .N(4),
        .WIDTH(18)
    ) u_cic_decimator (
        .clk       (clk),
        .rst_n     (effective_rst_n),
        .pdm_clk_en(pdm_clk_en),
        .pdm_in    (active_pdm_bit),
        .cic_out   (cic_out),
        .cic_valid (cic_valid)
    );

    // -------------------------------------------------------------
    // 4. Stage 2: CIC Compensation FIR (192 kHz)
    // -------------------------------------------------------------
    wire signed [19:0] comp_remez_out;
    wire               comp_remez_valid;
    wire signed [19:0] comp_paper_out;
    wire               comp_paper_valid;

    // Scale CIC output (DC gain = 65536) to 16-bit audio scale (32768)
    wire signed [17:0] cic_scaled = (cic_out + 18'sd1) >>> 1;

    cic_compensation_fir #(
        .IN_WIDTH (18),
        .OUT_WIDTH(20)
    ) u_comp_fir_remez (
        .clk      (clk),
        .rst_n    (effective_rst_n),
        .in_valid (cic_valid),
        .in_data  (cic_scaled),
        .out_valid(comp_remez_valid),
        .out_data (comp_remez_out)
    );

    paper_dolecek_compensation #(
        .IN_WIDTH (18),
        .OUT_WIDTH(20)
    ) u_comp_fir_paper (
        .clk      (clk),
        .rst_n    (effective_rst_n),
        .in_valid (cic_valid),
        .in_data  (cic_scaled),
        .out_valid(comp_paper_valid),
        .out_data (comp_paper_out)
    );

    wire signed [19:0] stage2_out   = ctrl_use_paper ? comp_paper_out   : comp_remez_out;
    wire               stage2_valid = ctrl_use_paper ? comp_paper_valid : comp_remez_valid;

    // -------------------------------------------------------------
    // 5. Stage 3: Half-Band Decimation Stage 1 (192 kHz -> 96 kHz)
    // -------------------------------------------------------------
    wire signed [19:0] hb1_out;
    wire               hb1_valid;

    halfband_stage1 #(
        .IN_WIDTH (20),
        .OUT_WIDTH(20)
    ) u_halfband_stage1 (
        .clk      (clk),
        .rst_n    (effective_rst_n),
        .in_valid (stage2_valid),
        .in_data  (stage2_out),
        .out_valid(hb1_valid),
        .out_data (hb1_out)
    );

    // -------------------------------------------------------------
    // 6. Stage 4: Half-Band Decimation Stage 2 (96 kHz -> 48 kHz)
    // -------------------------------------------------------------
    wire signed [19:0] hb2_par_out;
    wire               hb2_par_valid;
    wire signed [19:0] hb2_folded_out;
    wire               hb2_folded_valid;
    wire               hb2_folded_busy;

    halfband_stage2 #(
        .IN_WIDTH (20),
        .OUT_WIDTH(20)
    ) u_halfband_stage2_par (
        .clk      (clk),
        .rst_n    (effective_rst_n),
        .in_valid (hb1_valid),
        .in_data  (hb1_out),
        .out_valid(hb2_par_valid),
        .out_data (hb2_par_out)
    );

    halfband_fir_folded #(
        .IN_WIDTH (20),
        .OUT_WIDTH(20)
    ) u_halfband_stage2_folded (
        .clk      (clk),
        .rst_n    (effective_rst_n),
        .in_valid (hb1_valid),
        .in_data  (hb1_out),
        .out_valid(hb2_folded_valid),
        .out_data (hb2_folded_out),
        .busy     (hb2_folded_busy)
    );

    wire signed [19:0] filter_chain_out   = ctrl_use_folded ? hb2_folded_out   : hb2_par_out;
    wire               filter_chain_valid = ctrl_use_folded ? hb2_folded_valid : hb2_par_valid;

    // -------------------------------------------------------------
    // 7. Bypass Mode MUX & Digital Gain Scaling
    // -------------------------------------------------------------
    wire signed [19:0] pre_gain_data  = ctrl_bypass_mode ? {cic_out, 2'b00} : filter_chain_out;
    wire               pre_gain_valid = ctrl_bypass_mode ? cic_valid        : filter_chain_valid;

    // Digital Gain: Q4.12 fixed point multiplication
    wire signed [35:0] gained_prod = pre_gain_data * ctrl_gain;
    wire signed [23:0] gained_scaled = (gained_prod + 36'sd2048) >>> 12;

    // -------------------------------------------------------------
    // 8. 16-Bit Saturation and Rounding Unit (ESPRESSO / BDD Optimized)
    // -------------------------------------------------------------
    wire signed [15:0] final_pcm_sample;
    wire               overflow_flag;
    wire               underflow_flag;

    saturation_unit #(
        .IN_WIDTH(24)
    ) u_sat_unit (
        .in_data       (gained_scaled),
        .out_pcm       (final_pcm_sample),
        .overflow_flag (overflow_flag),
        .underflow_flag(underflow_flag)
    );

    // -------------------------------------------------------------
    // 9. Voice Activity Detection & Hardware RMS Computer
    // -------------------------------------------------------------
    wire [15:0] hw_rms_energy;
    wire        hw_vad_active;

    vad_engine #(
        .WINDOW_SIZE(256),
        .LOG2_WIN   (8)
    ) u_vad_engine (
        .clk          (clk),
        .rst_n        (effective_rst_n),
        .sample_valid (pre_gain_valid),
        .pcm_sample   (final_pcm_sample),
        .vad_threshold(vad_threshold),
        .hangover_val (4'd8),
        .rms_energy   (hw_rms_energy),
        .vad_active   (hw_vad_active)
    );

    // -------------------------------------------------------------
    // 10. Synchronous Audio FIFO
    // -------------------------------------------------------------
    wire        fifo_empty;
    wire        fifo_full;
    wire        fifo_overflow;
    wire [6:0]  fifo_count;
    wire [15:0] fifo_rd_data;
    wire        fifo_rd_en;
    wire        fifo_irq_raw;

    pcm_fifo #(
        .DATA_WIDTH(16),
        .DEPTH     (FIFO_DEPTH),
        .ADDR_WIDTH(6)
    ) u_pcm_fifo (
        .clk      (clk),
        .rst_n    (effective_rst_n),
        .wr_en    (pre_gain_valid),
        .wr_data  (final_pcm_sample),
        .rd_en    (fifo_rd_en),
        .rd_data  (fifo_rd_data),
        .watermark(watermark),
        .empty    (fifo_empty),
        .full     (fifo_full),
        .count    (fifo_count),
        .overflow (fifo_overflow),
        .irq      (fifo_irq_raw)
    );

    // -------------------------------------------------------------
    // 11. Embedded 32-bit RISC-V Soft Core (RV32I) & APB Subsystem
    // -------------------------------------------------------------
    wire [31:0] cpu_imem_addr;
    wire [31:0] cpu_imem_rdata;
    wire [31:0] cpu_dmem_addr;
    wire [31:0] cpu_dmem_wdata;
    wire [31:0] cpu_dmem_rdata;
    wire        cpu_dmem_we;
    wire        cpu_dmem_re;

    (* rom_style = "block" *) reg [31:0] imem [0:1023]; // 4 KB Instruction ROM
    initial begin
        $readmemh("program.hex", imem);
    end
    assign cpu_imem_rdata = imem[cpu_imem_addr[11:2]];

    rv32i_core #(
        .RESET_ADDR(32'h0000_0000)
    ) u_rv32_core (
        .clk        (clk),
        .rst_n      (effective_rst_n),
        .imem_addr  (cpu_imem_addr),
        .imem_rdata (cpu_imem_rdata),
        .dmem_addr  (cpu_dmem_addr),
        .dmem_wdata (cpu_dmem_wdata),
        .dmem_rdata (cpu_dmem_rdata),
        .dmem_we    (cpu_dmem_we),
        .dmem_re    (cpu_dmem_re),
        .dmem_be    (),
        .irq_in     (irq)
    );

    // Multiplex APB inputs between external master and internal RV32I core
    wire        cpu_apb_access = (cpu_dmem_addr[31:16] == 16'h4000) && (cpu_dmem_re | cpu_dmem_we);
    wire        mux_psel    = psel | cpu_apb_access;
    wire        mux_penable = penable | cpu_apb_access;
    wire        mux_pwrite  = psel ? pwrite : cpu_dmem_we;
    wire [7:0]  mux_paddr   = psel ? paddr  : cpu_dmem_addr[7:0];
    wire [31:0] mux_pwdata  = psel ? pwdata : cpu_dmem_wdata;
    assign cpu_dmem_rdata   = prdata;

    apb_pdm_top #(
        .ADDR_WIDTH(8),
        .DATA_WIDTH(32)
    ) u_apb_core (
        .pclk            (clk),
        .presetn         (rst_n),
        .psel            (mux_psel),
        .penable         (mux_penable),
        .pwrite          (mux_pwrite),
        .paddr           (mux_paddr),
        .pwdata          (mux_pwdata),
        .prdata          (prdata),
        .pready          (pready),
        .pslverr         (pslverr),
        .pdm_enable      (pdm_enable),
        .soft_reset      (soft_reset),
        .bypass_mode     (bypass_mode),
        .use_paper_filter(use_paper_filter),
        .use_folded_hb2  (use_folded_hb2),
        .digital_gain    (digital_gain),
        .fifo_empty      (fifo_empty),
        .fifo_full       (fifo_full),
        .fifo_overflow   (fifo_overflow),
        .fifo_count      (fifo_count),
        .fifo_rd_data    (fifo_rd_data),
        .fifo_rd_en      (fifo_rd_en),
        .watermark       (watermark),
        .hw_rms_energy   (hw_rms_energy),
        .hw_vad_active   (hw_vad_active),
        .vad_threshold   (vad_threshold),
        .fifo_irq_raw    (fifo_irq_raw),
        .irq             (irq)
    );

    // -------------------------------------------------------------
    // 12. Audio Output DACs (I2S & PWM)
    // -------------------------------------------------------------
    i2s_transmitter u_i2s_tx (
        .clk         (clk),
        .rst_n       (effective_rst_n),
        .sample_valid(pre_gain_valid),
        .pcm_sample  (final_pcm_sample),
        .i2s_bclk    (i2s_bclk),
        .i2s_lrclk   (i2s_lrclk),
        .i2s_sdata   (i2s_sdata)
    );

    pwm_audio_dac u_pwm_dac (
        .clk          (clk),
        .rst_n        (effective_rst_n),
        .pcm_sample   (final_pcm_sample),
        .audio_pwm_out(audio_pwm_out)
    );

    // -------------------------------------------------------------
    // 13. LED VU Meter Display (8 LEDs)
    // -------------------------------------------------------------
    reg [6:0] vu_bar;
    always @(*) begin
        if (hw_rms_energy > 16'h4000)      vu_bar = 7'b1111111;
        else if (hw_rms_energy > 16'h2000) vu_bar = 7'b0111111;
        else if (hw_rms_energy > 16'h1000) vu_bar = 7'b0011111;
        else if (hw_rms_energy > 16'h0800) vu_bar = 7'b0001111;
        else if (hw_rms_energy > 16'h0400) vu_bar = 7'b0000111;
        else if (hw_rms_energy > 16'h0200) vu_bar = 7'b0000011;
        else if (hw_rms_energy > 16'h0080) vu_bar = 7'b0000001;
        else                               vu_bar = 7'b0000000;
    end

    assign led_vu_meter = {hw_vad_active, vu_bar};

endmodule
