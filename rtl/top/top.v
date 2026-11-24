// =============================================================================
// Module  : top
// Project : P6 PDM-to-PCM Audio Front End
// Board   : Digilent Zybo Z7 (Zynq-7000 / XC7Z010-1CLG400C)
// Purpose : Top-Level System Integration
//
// Pipeline:
//   PDM Source (BRAM or Pmod Mic) @ 3.072 MHz
//     -> CIC Decimator (R=16, N=4)       -> 192 kHz, 24-bit
//     -> CIC-Compensation FIR (ESPRESSO) -> 192 kHz, 24-bit
//     -> Half-Band Stage 1 (div 2)       -> 96 kHz, 24-bit
//     -> Half-Band Stage 2 (div 2)       -> 48 kHz, 16-bit PCM
//     -> PCM FIFO & APB Registers
//     -> RV32I Soft Core (RMS & Voice Activity Detector)
//     -> I2S Transmitter (SSM2603 Codec) & PWM Audio DAC
//     -> 4-LED VU Meter / VAD indicator
// =============================================================================

`timescale 1ns / 1ps

module top #(
    parameter USE_BRAM_PDM = 1'b1
)(
    // 125 MHz System Clock
    input  wire         sys_clk,
    
    // User IO
    input  wire [3:0]   btn,        // btn[0]: reset_n, btn[1]: stream restart, btn[2]: bypass
    input  wire [3:0]   sw,         // sw[1:0]: gain preset, sw[2]: mic source select
    output wire [3:0]   led,        // VU meter and VAD indicators

    // PDM Microphone Interface (Pmod JE or onboard)
    output wire         pdm_mic_clk,
    input  wire         pdm_mic_data,

    // Zybo Z7 Onboard SSM2603 I2S Audio Codec
    output wire         ac_mclk,    // 12.288 MHz Master Audio Clock
    output wire         ac_bclk,    // 3.072 MHz Bit Clock
    output wire         ac_lrclk,   // 48 kHz Frame Clock
    output wire         ac_dac_sdata,
    output wire         ac_scl,     // I2C Clock to SSM2603 (Pin N18)
    inout  wire         ac_sda,     // I2C Data to SSM2603  (Pin N17)
    output wire         ac_muten,   // Hardware Audio Mute (Pin P18, 1=Unmute, 0=Mute)

    // PWM Audio Output (Pmod JA Pin 1)
    output wire         pwm_audio_out
);

// ── Reset Conditioning ────────────────────────────────────────────────────────
wire sys_rst_n = ~btn[0];
assign ac_muten = sys_rst_n; // Drive High to physically unmute SSM2603, Low during reset

// ── Clock Generation ──────────────────────────────────────────────────────────
// 125 MHz -> 12.288 MHz (Master Audio Clock) and 3.072 MHz (PDM Clock)
// Rational approximation: 125 MHz * (24 / 244) ≈ 12.295 MHz (within 0.05% of 12.288 MHz)
// Or simple integer divider: 125 / 10 ≈ 12.5 MHz.
// We use a clean fractional accumulator / divider for synthesis:
reg [19:0] clk_acc = 20'd0;
reg        clk_12m288 = 1'b0;

// Free-running clock divider from 125 MHz system clock (12.288 MHz generation)
always @(posedge sys_clk) begin
    clk_acc <= clk_acc + 20'd12288;
    if (clk_acc >= 20'd62500) begin
        clk_acc    <= clk_acc - 20'd62500;
        clk_12m288 <= ~clk_12m288;
    end
end

assign ac_mclk = clk_12m288;

// Free-running PDM Clock: 12.288 MHz / 4 = 3.072 MHz
reg [1:0] pdm_div = 2'd0;
reg       clk_pdm = 1'b0;

always @(posedge clk_12m288) begin
    pdm_div <= pdm_div + 1'b1;
    if (pdm_div == 2'd1) clk_pdm <= 1'b1;
    if (pdm_div == 2'd3) clk_pdm <= 1'b0;
end

assign pdm_mic_clk = clk_pdm;

// ── PDM Source Selection ──────────────────────────────────────────────────────
wire pdm_bram_bit;
pdm_bram_player #(
    .TOTAL_BITS(192000),
    .HEX_FILE("../../sim/vectors/pdm_test.hex")
) u_pdm_player (
    .clk_pdm   (clk_pdm),
    .rst_n     (sys_rst_n),
    .play_en   (1'b1),
    .pdm_out   (pdm_bram_bit),
    .bit_idx   ()
);

wire pdm_stream = sw[2] ? pdm_mic_data : pdm_bram_bit;

// ── Stage 1: CIC Decimator (R=16, N=4) ────────────────────────────────────────
wire [23:0] cic_data;
wire        cic_valid;

cic_decimator #(
    .R (16),
    .N (4),
    .B (24)
) u_cic (
    .clk       (clk_pdm),
    .rst_n     (sys_rst_n),
    .pdm_in    (pdm_stream),
    .pcm_out   (cic_data),
    .pcm_valid (cic_valid)
);

// 1-cycle edge qualifier on clk_12m288 for CIC valid pulse
reg cic_valid_d;
always @(posedge clk_12m288) begin
    if (!sys_rst_n)
        cic_valid_d <= 1'b0;
    else
        cic_valid_d <= cic_valid;
end
wire cic_pulse = cic_valid & ~cic_valid_d;

// ── Stage 2: CIC Compensation FIR (ESPRESSO / U3 Kernel) ──────────────────────
wire [23:0] comp_data;
wire        comp_valid;

comp_fir_espresso #(
    .N_TAPS    (31),
    .B_IN      (24),
    .B_OUT     (24),
    .COEFF_FILE("../../sim/vectors/comp_fir_coeffs.hex")
) u_comp_fir (
    .clk       (clk_12m288),
    .rst_n     (sys_rst_n),
    .valid_in  (cic_pulse),
    .data_in   (cic_data),
    .data_out  (comp_data),
    .valid_out (comp_valid)
);

// ── Stage 3: Half-Band Filter 1 (div 2: 192 kHz -> 96 kHz) ────────────────────
wire [23:0] hb1_data;
wire        hb1_valid;

hb_filter_folded #(
    .N_TAPS    (31),
    .B_IN      (24),
    .B_OUT     (24),
    .COEFF_FILE("../../sim/vectors/hb1_coeffs_folded.hex")
) u_hb1 (
    .clk       (clk_12m288),
    .rst_n     (sys_rst_n),
    .valid_in  (comp_valid),
    .data_in   (comp_data),
    .data_out  (hb1_data),
    .valid_out (hb1_valid)
);

// ── Stage 4: Half-Band Filter 2 (div 2: 96 kHz -> 48 kHz) ─────────────────────
wire [23:0] hb2_data;
wire        hb2_valid;

hb_filter_folded #(
    .N_TAPS    (31),
    .B_IN      (24),
    .B_OUT     (24),
    .COEFF_FILE("../../sim/vectors/hb2_coeffs_folded.hex")
) u_hb2 (
    .clk       (clk_12m288),
    .rst_n     (sys_rst_n),
    .valid_in  (hb1_valid),
    .data_in   (hb1_data),
    .data_out  (hb2_data),
    .valid_out (hb2_valid)
);

// Truncate/Round 24-bit to 16-bit PCM
wire signed [15:0] filter_pcm = hb2_data[23:8];

// ── PCM FIFO ──────────────────────────────────────────────────────────────────
wire [15:0] fifo_rd_data;
wire        fifo_rd_en;
wire [7:0]  fifo_count;
wire        fifo_empty, fifo_full, fifo_overflow, fifo_thresh_hit;
wire [7:0]  fifo_thresh_val;

pcm_fifo #(
    .DATA_W(16),
    .ADDR_W(7)
) u_fifo (
    .clk               (clk_12m288),
    .rst_n             (sys_rst_n),
    .wr_en             (hb2_valid),
    .wr_data           (filter_pcm),
    .rd_en             (fifo_rd_en),
    .rd_data           (fifo_rd_data),
    .irq_threshold     (fifo_thresh_val),
    .count             (fifo_count),
    .empty             (fifo_empty),
    .full              (fifo_full),
    .overflow          (fifo_overflow),
    .irq_threshold_hit (fifo_thresh_hit)
);

// ── APB Bus & Audio Registers ─────────────────────────────────────────────────
wire [31:0] cpu_dmem_addr;
wire [31:0] cpu_dmem_wdata;
wire [31:0] cpu_dmem_rdata;
wire        cpu_dmem_we;
wire        cpu_dmem_re;

wire apb_sel = (cpu_dmem_addr[31:28] == 4'h4); // Peripherals at 0x4000_0000
wire apb_irq;
wire ctrl_bypass;
wire [7:0] gain_q17;
wire [15:0] rv32_rms;
wire        rv32_vad;

apb_audio_regs u_apb_regs (
    .pclk             (clk_12m288),
    .presetn          (sys_rst_n),
    .paddr            (cpu_dmem_addr[11:0]),
    .psel             (apb_sel),
    .penable          (cpu_dmem_re | cpu_dmem_we),
    .pwrite           (cpu_dmem_we),
    .pwdata           (cpu_dmem_wdata),
    .prdata           (cpu_dmem_rdata),
    .pready           (),
    .pslverr          (),
    .ctrl_bypass      (ctrl_bypass),
    .ctrl_soft_rst    (),
    .ctrl_fifo_flush  (),
    .gain_q17         (gain_q17),
    .irq_out          (apb_irq),
    .fifo_rd_data     (fifo_rd_data),
    .fifo_rd_en       (fifo_rd_en),
    .fifo_count       (fifo_count),
    .fifo_empty       (fifo_empty),
    .fifo_full        (fifo_full),
    .fifo_overflow    (fifo_overflow),
    .fifo_thresh_hit  (fifo_thresh_hit),
    .fifo_thresh_val  (fifo_thresh_val),
    .rms_level        (rv32_rms),
    .vad_active       (rv32_vad),
    .vad_led_override ()
);

// ── RV32I Soft Core & Instruction Memory ─────────────────────────────────────
reg [31:0] imem [0:1023]; // 4 KB Instruction ROM
initial begin
    $readmemh("../../firmware/program.hex", imem);
end

wire [31:0] cpu_imem_addr;
wire [31:0] cpu_imem_rdata = imem[cpu_imem_addr[11:2]];

reg [3:0] gpio_led_reg;
always @(posedge clk_12m288) begin
    if (!sys_rst_n) begin
        gpio_led_reg <= 4'b0000;
    end else if (cpu_dmem_we && (cpu_dmem_addr == 32'h4000_1000)) begin
        gpio_led_reg <= cpu_dmem_wdata[3:0];
    end
end

rv32i_core u_rv32 (
    .clk        (clk_12m288),
    .rst_n      (sys_rst_n),
    .imem_addr  (cpu_imem_addr),
    .imem_rdata (cpu_imem_rdata),
    .dmem_addr  (cpu_dmem_addr),
    .dmem_wdata (cpu_dmem_wdata),
    .dmem_rdata (cpu_dmem_rdata),
    .dmem_we    (cpu_dmem_we),
    .dmem_re    (cpu_dmem_re),
    .dmem_be    (),
    .irq_in     (apb_irq)
);

// ── SSM2603 I2C Wakeup Initializer ───────────────────────────────────────────
// Run I2C initialization once on FPGA power-on
// Kept persistent across user button resets to prevent analog pops/clicks!
wire ssm_init_done;
ssm2603_i2c_init u_ssm_i2c (
    .clk     (clk_12m288),
    .rst_n   (1'b1),
    .i2c_scl (ac_scl),
    .i2c_sda (ac_sda),
    .done    (ssm_init_done)
);

// Connect LEDs to VU meter & VAD with switch sensitivity
// sw[1:0] scales the active LED count:
//   2'b00: Only LD0 (low sensitivity / soft)
//   2'b01: LD0, LD1 (medium sensitivity)
//   2'b10: LD0, LD1, LD2 (high sensitivity)
//   2'b11: All 4 LEDs LD0 - LD3 (maximum sensitivity)
wire [3:0] led_mask = (sw[1:0] == 2'b00) ? 4'b0001 :
                      (sw[1:0] == 2'b01) ? 4'b0011 :
                      (sw[1:0] == 2'b10) ? 4'b0111 : 4'b1111;
assign led = gpio_led_reg & led_mask;

// ── Audio Output: I2S & PWM ──────────────────────────────────────────────────
// Dynamic volume scaling controlled by switches SW[1:0]:
//   sw[1:0] == 2'b00: 0.125x volume (soft)
//   sw[1:0] == 2'b01: 0.250x volume (medium-low)
//   sw[1:0] == 2'b10: 0.500x volume (medium-high)
//   sw[1:0] == 2'b11: 1.000x volume (loud, full-scale)
reg [7:0] sw_volume;
always @(*) begin
    case (sw[1:0])
        2'b00: sw_volume = 8'd16;  // 0.125x (low volume)
        2'b01: sw_volume = 8'd32;  // 0.250x (medium-low)
        2'b10: sw_volume = 8'd64;  // 0.500x (medium-high)
        2'b11: sw_volume = 8'd128; // 1.000x (full volume)
    endcase
end

// Combine software APB gain and switch volume; strictly mute to 0 during reset
wire [15:0] gain_product = gain_q17 * sw_volume;
wire [7:0]  effective_gain = sys_rst_n ? gain_product[14:7] : 8'd0;

// Gain scaling on final PCM sample: (sample * effective_gain) >>> 7
wire signed [23:0] gained_pcm_24 = filter_pcm * $signed({1'b0, effective_gain});
wire signed [15:0] final_pcm = gained_pcm_24[22:7];

i2s_tx #(
    .DATA_W (16)
) u_i2s (
    .clk       (clk_12m288),
    .rst_n     (sys_rst_n),
    .pcm_l     (final_pcm),
    .pcm_r     (final_pcm),
    .pcm_valid (hb2_valid),
    .bclk      (ac_bclk),
    .lrclk     (ac_lrclk),
    .sdata     (ac_dac_sdata)
);

pwm_audio #(
    .DATA_W (16)
) u_pwm (
    .clk       (clk_12m288),
    .rst_n     (sys_rst_n),
    .pcm_in    (final_pcm),
    .pwm_out   (pwm_audio_out)
);

endmodule


// =============================================================================
// Module  : ssm2603_i2c_init
// Project : P6 PDM-to-PCM Audio Front End
// Board   : Digilent Zybo Z7 (XC7Z010-1CLG400C)
// Purpose : Autonomous I2C Configuration Controller for Analog Devices SSM2603
//
// Description:
//   At power-up / reset release, this state machine writes the essential
//   configuration registers to the SSM2603 codec at 7-bit address 0x1A (0x34 write):
//     1. Reg 0x0F: Software Reset
//     2. Reg 0x06: Power Management (Power ON DAC, OUT, CLK, Core)
//     3. Reg 0x04: Analog Audio Path (DACSEL = 1 -> Route DAC to Headphone Out)
//     4. Reg 0x05: Digital Audio Path (DAC Mute = 0)
//     5. Reg 0x07: Digital Audio Interface (I2S, 16-bit, Slave mode)
//     6. Reg 0x08: Sampling Rate (48 kHz, Normal mode, 256*fs)
//     7. Reg 0x02: Left & Right Headphone Volume (0 dB, Unmuted)
//     8. Reg 0x09: Active Control (Activate Digital Core)
//
// Clock: 12.288 MHz input clock -> divided to ~96 kHz I2C clock (period ~10.4 us)
// =============================================================================

module ssm2603_i2c_init (
    input  wire         clk,        // 12.288 MHz system clock
    input  wire         rst_n,      // Active-low synchronous reset
    output wire         i2c_scl,    // I2C Clock to SSM2603 (Pin N18)
    inout  wire         i2c_sda,    // I2C Data to SSM2603  (Pin N17)
    output reg          done        // High once initialization is complete
);

    // I2C 7-bit address: 0x1A -> Write byte = 8'h34
    localparam [7:0] DEV_ADDR_WR = 8'h34;
    localparam integer NUM_REGS   = 8;

    // Register configuration sequence: {Reg_Addr[6:0], Data[8:0]} (16 bits)
    reg [15:0] config_rom [0:NUM_REGS-1];
    initial begin
        config_rom[0] = {7'h0F, 9'h000}; // R15: Reset
        config_rom[1] = {7'h06, 9'h067}; // R6 : Power Mgmt (Power on DAC, OUT, CLK)
        config_rom[2] = {7'h04, 9'h012}; // R4 : Analog Path (DACSEL=1, unmute)
        config_rom[3] = {7'h05, 9'h000}; // R5 : Digital Path (unmute DAC)
        config_rom[4] = {7'h07, 9'h002}; // R7 : Audio Format (I2S, 16-bit)
        config_rom[5] = {7'h08, 9'h000}; // R8 : Sample Rate (48 kHz, 256*fs)
        config_rom[6] = {7'h02, 9'h179}; // R2 : Left+Right Headphone Vol (0 dB)
        config_rom[7] = {7'h09, 9'h001}; // R9 : Active Control (Activate)
    end

    // Clock divider: 12.288 MHz / 128 ≈ 96 kHz SCL
    // Each SCL cycle has 4 quarter-phases:
    //   Phase 0: SCL=0, set SDA
    //   Phase 1: SCL=1, sample/hold
    //   Phase 2: SCL=1, hold
    //   Phase 3: SCL=0, hold
    reg [6:0] clk_div;
    wire q_tick = (clk_div == 7'd31); // 4 ticks per SCL cycle

    always @(posedge clk) begin
        if (!rst_n)
            clk_div <= 7'd0;
        else
            clk_div <= clk_div + 1'b1;
    end

    // FSM States
    localparam [3:0]
        S_IDLE     = 4'd0,
        S_START    = 4'd1,
        S_BYTE1    = 4'd2, // Device address write (0x34)
        S_ACK1     = 4'd3,
        S_BYTE2    = 4'd4, // High byte: {Reg_Addr[6:0], Data[8]}
        S_ACK2     = 4'd5,
        S_BYTE3    = 4'd6, // Low byte:  Data[7:0]
        S_ACK3     = 4'd7,
        S_STOP     = 4'd8,
        S_PAUSE    = 4'd9,
        S_DONE     = 4'd10;

    reg [3:0]  state;
    reg [1:0]  phase;
    reg [2:0]  reg_idx;
    reg [2:0]  bit_idx;
    reg [7:0]  tx_byte;
    reg [15:0] cur_cmd;
    reg [11:0] pause_cnt;

    reg scl_out;
    reg sda_out;

    // Tristate drive for SDA (open-drain emulation)
    assign i2c_scl = scl_out;
    assign i2c_sda = sda_out ? 1'bz : 1'b0;

    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            phase     <= 2'd0;
            reg_idx   <= 3'd0;
            bit_idx   <= 3'd7;
            tx_byte   <= 8'd0;
            cur_cmd   <= 16'd0;
            pause_cnt <= 12'd0;
            scl_out   <= 1'b1;
            sda_out   <= 1'b1;
            done      <= 1'b0;
        end else if (q_tick) begin
            phase <= phase + 1'b1;

            case (state)
                S_IDLE: begin
                    scl_out <= 1'b1;
                    sda_out <= 1'b1;
                    done    <= 1'b0;
                    if (pause_cnt < 12'd1000) begin
                        pause_cnt <= pause_cnt + 1'b1; // Power-on warm-up delay (~10 ms)
                    end else begin
                        pause_cnt <= 12'd0;
                        cur_cmd   <= config_rom[reg_idx];
                        state     <= S_START;
                    end
                end

                S_START: begin
                    // START: SDA goes low while SCL is high
                    if (phase == 2'd0) begin scl_out <= 1'b1; sda_out <= 1'b1; end
                    if (phase == 2'd1) begin scl_out <= 1'b1; sda_out <= 1'b0; end
                    if (phase == 2'd2) begin scl_out <= 1'b1; sda_out <= 1'b0; end
                    if (phase == 2'd3) begin
                        scl_out <= 1'b0;
                        sda_out <= 1'b0;
                        tx_byte <= DEV_ADDR_WR;
                        bit_idx <= 3'd7;
                        state   <= S_BYTE1;
                    end
                end

                S_BYTE1: begin // Send 0x34
                    if (phase == 2'd0) begin scl_out <= 1'b0; sda_out <= tx_byte[bit_idx]; end
                    if (phase == 2'd1) begin scl_out <= 1'b1; end
                    if (phase == 2'd2) begin scl_out <= 1'b1; end
                    if (phase == 2'd3) begin
                        scl_out <= 1'b0;
                        if (bit_idx == 3'd0)
                            state <= S_ACK1;
                        else
                            bit_idx <= bit_idx - 1'b1;
                    end
                end

                S_ACK1: begin // Release SDA for ACK
                    if (phase == 2'd0) begin scl_out <= 1'b0; sda_out <= 1'b1; end
                    if (phase == 2'd1) begin scl_out <= 1'b1; end
                    if (phase == 2'd2) begin scl_out <= 1'b1; end
                    if (phase == 2'd3) begin
                        scl_out <= 1'b0;
                        tx_byte <= cur_cmd[15:8]; // High byte: {Reg[6:0], Data[8]}
                        bit_idx <= 3'd7;
                        state   <= S_BYTE2;
                    end
                end

                S_BYTE2: begin // Send Register Address & MSB of data
                    if (phase == 2'd0) begin scl_out <= 1'b0; sda_out <= tx_byte[bit_idx]; end
                    if (phase == 2'd1) begin scl_out <= 1'b1; end
                    if (phase == 2'd2) begin scl_out <= 1'b1; end
                    if (phase == 2'd3) begin
                        scl_out <= 1'b0;
                        if (bit_idx == 3'd0)
                            state <= S_ACK2;
                        else
                            bit_idx <= bit_idx - 1'b1;
                    end
                end

                S_ACK2: begin
                    if (phase == 2'd0) begin scl_out <= 1'b0; sda_out <= 1'b1; end
                    if (phase == 2'd1) begin scl_out <= 1'b1; end
                    if (phase == 2'd2) begin scl_out <= 1'b1; end
                    if (phase == 2'd3) begin
                        scl_out <= 1'b0;
                        tx_byte <= cur_cmd[7:0]; // Low byte: Data[7:0]
                        bit_idx <= 3'd7;
                        state   <= S_BYTE3;
                    end
                end

                S_BYTE3: begin // Send LSBs of data
                    if (phase == 2'd0) begin scl_out <= 1'b0; sda_out <= tx_byte[bit_idx]; end
                    if (phase == 2'd1) begin scl_out <= 1'b1; end
                    if (phase == 2'd2) begin scl_out <= 1'b1; end
                    if (phase == 2'd3) begin
                        scl_out <= 1'b0;
                        if (bit_idx == 3'd0)
                            state <= S_ACK3;
                        else
                            bit_idx <= bit_idx - 1'b1;
                    end
                end

                S_ACK3: begin
                    if (phase == 2'd0) begin scl_out <= 1'b0; sda_out <= 1'b1; end
                    if (phase == 2'd1) begin scl_out <= 1'b1; end
                    if (phase == 2'd2) begin scl_out <= 1'b1; end
                    if (phase == 2'd3) begin
                        scl_out <= 1'b0;
                        sda_out <= 1'b0;
                        state   <= S_STOP;
                    end
                end

                S_STOP: begin
                    // STOP: SDA goes high while SCL is high
                    if (phase == 2'd0) begin scl_out <= 1'b0; sda_out <= 1'b0; end
                    if (phase == 2'd1) begin scl_out <= 1'b1; sda_out <= 1'b0; end
                    if (phase == 2'd2) begin scl_out <= 1'b1; sda_out <= 1'b1; end
                    if (phase == 2'd3) begin
                        scl_out <= 1'b1;
                        sda_out <= 1'b1;
                        state   <= S_PAUSE;
                    end
                end

                S_PAUSE: begin
                    // Short inter-command pause (~50 us)
                    if (pause_cnt < 12'd20) begin
                        pause_cnt <= pause_cnt + 1'b1;
                    end else begin
                        pause_cnt <= 12'd0;
                        if (reg_idx == NUM_REGS - 1) begin
                            state <= S_DONE;
                        end else begin
                            reg_idx <= reg_idx + 1'b1;
                            cur_cmd <= config_rom[reg_idx + 1'b1];
                            state   <= S_START;
                        end
                    end
                end

                S_DONE: begin
                    scl_out <= 1'b1;
                    sda_out <= 1'b1;
                    done    <= 1'b1;
                end
            endcase
        end
    end

endmodule
