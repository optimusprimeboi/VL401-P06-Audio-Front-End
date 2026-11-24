// =============================================================================
// Module: ssm2603_i2c_init
// Description: Robust Autonomous I2C Controller for Zybo Z7 SSM2603 Audio Codec
// Target: Digilent Zybo Z7 (XC7Z010-1CLG400C)
// Clock : 49.152 MHz system clock
// I2C   : ~50 kHz standard mode (clean 4-phase clocking with open-drain outputs)
// =============================================================================

`timescale 1ns / 1ps

module ssm2603_i2c_init #(
    parameter CLK_FREQ_HZ = 49_152_000,
    parameter I2C_FREQ_HZ = 50_000
)(
    input  wire clk,         // 49.152 MHz system clock
    input  wire rst_n,       // Active-low reset

    // SSM2603 Hardware Control Pins
    output wire ac_muten,    // P18: Active-low hardware mute (drive 1 to unmute)
    inout  wire ac_scl,      // N18: I2C Clock (Open-Drain)
    inout  wire ac_sda,      // N17: I2C Data  (Open-Drain)

    // Status
    output reg  init_done    // High when configuration complete
);

    // Keep hardware mute unmuted at all times
    assign ac_muten = 1'b1;

    // Open-drain I2C bus drivers
    reg scl_reg;
    reg sda_reg;
    assign ac_scl = (scl_reg == 1'b0) ? 1'b0 : 1'bz;
    assign ac_sda = (sda_reg == 1'b0) ? 1'b0 : 1'bz;

    // -------------------------------------------------------------
    // 1. Long Startup Delay (~50 ms at 49.152 MHz)
    // -------------------------------------------------------------
    reg [21:0] startup_cnt;
    reg        startup_done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            startup_cnt  <= 22'd0;
            startup_done <= 1'b0;
        end else if (!startup_done) begin
            if (startup_cnt >= 22'd2_500_000) begin
                startup_done <= 1'b1;
            end else begin
                startup_cnt <= startup_cnt + 22'd1;
            end
        end
    end

    // -------------------------------------------------------------
    // 2. Quarter-Period I2C Tick Generator (200 kHz tick for 50 kHz SCL)
    // -------------------------------------------------------------
    localparam TICK_DIV = CLK_FREQ_HZ / (I2C_FREQ_HZ * 4); // 246
    reg [8:0] tick_cnt;
    reg       tick_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt <= 9'd0;
            tick_q   <= 1'b0;
        end else if (startup_done && !init_done) begin
            if (tick_cnt >= TICK_DIV - 1) begin
                tick_cnt <= 9'd0;
                tick_q   <= 1'b1;
            end else begin
                tick_cnt <= tick_cnt + 9'd1;
                tick_q   <= 1'b0;
            end
        end else begin
            tick_cnt <= 9'd0;
            tick_q   <= 1'b0;
        end
    end

    // -------------------------------------------------------------
    // 3. SSM2603 Register Configuration Table (12 transfers)
    // -------------------------------------------------------------
    localparam NUM_REGS = 12;
    wire [15:0] reg_rom [0:NUM_REGS-1];
    assign reg_rom[0]  = {7'd15, 9'h000}; // R15: Soft reset
    assign reg_rom[1]  = {7'd6,  9'h030}; // R6:  Power on device, osc & clkout off
    assign reg_rom[2]  = {7'd0,  9'h017}; // R0:  Left Line-in mute
    assign reg_rom[3]  = {7'd1,  9'h017}; // R1:  Right Line-in mute
    assign reg_rom[4]  = {7'd2,  9'h179}; // R2:  Left HP volume 0 dB, unmute, zero-cross
    assign reg_rom[5]  = {7'd3,  9'h179}; // R3:  Right HP volume 0 dB, unmute, zero-cross
    assign reg_rom[6]  = {7'd4,  9'h012}; // R4:  Analog path: Select DAC, mute mic
    assign reg_rom[7]  = {7'd5,  9'h000}; // R5:  Digital path: Unmute DAC, no de-emphasis
    assign reg_rom[8]  = {7'd7,  9'h002}; // R7:  Digital format: 16-bit I2S Slave mode
    assign reg_rom[9]  = {7'd8,  9'h000}; // R8:  Sample rate: 48 kHz normal (256xFs MCLK)
    assign reg_rom[10] = {7'd9,  9'h001}; // R9:  Activate digital core
    assign reg_rom[11] = {7'd6,  9'h007}; // R6:  Power on DAC & output amps (power down ADC/mic/line)

    // -------------------------------------------------------------
    // 4. I2C Byte Serializer State Machine
    // -------------------------------------------------------------
    localparam ST_IDLE    = 4'd0,
               ST_START_0 = 4'd1,
               ST_START_1 = 4'd2,
               ST_BIT_LOW = 4'd3,
               ST_BIT_MID = 4'd4,
               ST_BIT_HI  = 4'd5,
               ST_STOP_0  = 4'd6,
               ST_STOP_1  = 4'd7,
               ST_STOP_2  = 4'd8,
               ST_PAUSE   = 4'd9,
               ST_DONE    = 4'd10;

    reg [3:0]  state;
    reg [3:0]  reg_idx;
    reg [1:0]  byte_idx;
    reg [4:0]  bit_idx;
    reg [7:0]  curr_byte;
    reg [15:0] pause_cnt;

    always @(*) begin
        case (byte_idx)
            2'd0:    curr_byte = 8'h34; // Slave Address 0x1A << 1 + Write 0
            2'd1:    curr_byte = reg_rom[reg_idx][15:8]; // {reg_addr[6:0], data[8]}
            default: curr_byte = reg_rom[reg_idx][7:0];  // data[7:0]
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            reg_idx   <= 4'd0;
            byte_idx  <= 2'd0;
            bit_idx   <= 5'd0;
            scl_reg   <= 1'b1;
            sda_reg   <= 1'b1;
            init_done <= 1'b0;
            pause_cnt <= 16'd0;
        end else if (tick_q) begin
            case (state)
                ST_IDLE: begin
                    scl_reg <= 1'b1;
                    sda_reg <= 1'b1;
                    if (startup_done && !init_done) begin
                        state <= ST_START_0;
                    end
                end

                // START: SDA falling edge while SCL is HIGH
                ST_START_0: begin
                    scl_reg <= 1'b1;
                    sda_reg <= 1'b0;
                    state   <= ST_START_1;
                end

                ST_START_1: begin
                    scl_reg  <= 1'b0;
                    sda_reg  <= 1'b0;
                    byte_idx <= 2'd0;
                    bit_idx  <= 5'd0;
                    state    <= ST_BIT_LOW;
                end

                // Phase 0: SCL is LOW, set SDA
                ST_BIT_LOW: begin
                    scl_reg <= 1'b0;
                    if (bit_idx < 5'd8) begin
                        sda_reg <= curr_byte[7 - bit_idx];
                    end else begin
                        sda_reg <= 1'b1; // Release for slave ACK
                    end
                    state <= ST_BIT_MID;
                end

                // Phase 1: SCL goes HIGH
                ST_BIT_MID: begin
                    scl_reg <= 1'b1;
                    state   <= ST_BIT_HI;
                end

                // Phase 2: SCL returns LOW, advance
                ST_BIT_HI: begin
                    scl_reg <= 1'b0;
                    if (bit_idx < 5'd8) begin
                        bit_idx <= bit_idx + 5'd1;
                        state   <= ST_BIT_LOW;
                    end else begin
                        bit_idx <= 5'd0;
                        if (byte_idx < 2'd2) begin
                            byte_idx <= byte_idx + 2'd1;
                            state    <= ST_BIT_LOW;
                        end else begin
                            sda_reg <= 1'b0;
                            state   <= ST_STOP_0;
                        end
                    end
                end

                // STOP: SDA rising edge while SCL is HIGH
                ST_STOP_0: begin
                    scl_reg <= 1'b1;
                    sda_reg <= 1'b0;
                    state   <= ST_STOP_1;
                end

                ST_STOP_1: begin
                    scl_reg <= 1'b1;
                    sda_reg <= 1'b1;
                    state   <= ST_STOP_2;
                end

                ST_STOP_2: begin
                    scl_reg   <= 1'b1;
                    sda_reg   <= 1'b1;
                    pause_cnt <= 16'd0;
                    state     <= ST_PAUSE;
                end

                // Inter-command pause (~5 ms)
                ST_PAUSE: begin
                    if (pause_cnt >= 16'd1000) begin
                        if (reg_idx == NUM_REGS - 1) begin
                            init_done <= 1'b1;
                            state     <= ST_DONE;
                        end else begin
                            reg_idx <= reg_idx + 4'd1;
                            state   <= ST_START_0;
                        end
                    end else begin
                        pause_cnt <= pause_cnt + 16'd1;
                    end
                end

                ST_DONE: begin
                    scl_reg   <= 1'b1;
                    sda_reg   <= 1'b1;
                    init_done <= 1'b1;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
