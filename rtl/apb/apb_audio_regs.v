// =============================================================================
// Module  : apb_audio_regs
// Project : P6 PDM-to-PCM Audio Front End
// Purpose : APB Register Interface for Audio Subsystem
//
// Register Map (32-bit aligned, Byte Offset):
//   0x00 : CTRL        [RW] bit 0: bypass filter chain
//                           bit 1: soft reset datapath
//                           bit 2: fifo flush
//   0x04 : GAIN        [RW] [7:0]: Q1.7 linear audio gain (0x80 = 1.0x)
//   0x08 : STATUS      [RO] bit 0: fifo_empty
//                           bit 1: fifo_full
//                           bit 2: fifo_overflow
//                           bit 3: pcm_valid
//   0x0C : PCM_DATA    [RO] Read pops one 16-bit PCM sample from FIFO
//   0x10 : IRQ_EN      [RW] bit 0: FIFO threshold interrupt enable
//                           bit 1: FIFO overflow interrupt enable
//   0x14 : IRQ_STATUS  [W1C]bit 0: FIFO threshold hit (write 1 to clear)
//                           bit 1: FIFO overflow occurred (write 1 to clear)
//   0x18 : FIFO_COUNT  [RO] Current number of samples in FIFO
//   0x1C : FIFO_THRESH [RW] Programmable watermark for threshold interrupt
//   0x20 : RMS_LEVEL   [RW] Firmware/hardware 16-bit RMS audio level
//   0x24 : VAD_STATUS  [RW] bit 0: Voice Activity Detected (1 = active)
//                           bit 1: VAD LED override enable
// =============================================================================

`timescale 1ns / 1ps

module apb_audio_regs #(
    parameter integer ADDR_W = 12
)(
    input  wire                 pclk,
    input  wire                 presetn,

    // APB3 Slave Interface
    input  wire [ADDR_W-1:0]    paddr,
    input  wire                 psel,
    input  wire                 penable,
    input  wire                 pwrite,
    input  wire [31:0]          pwdata,
    output reg  [31:0]          prdata,
    output wire                 pready,
    output wire                 pslverr,

    // Audio Subsystem Control Signals
    output reg                  ctrl_bypass,
    output reg                  ctrl_soft_rst,
    output reg                  ctrl_fifo_flush,   // bit 2: flush FIFO
    output reg  [7:0]           gain_q17,
    output wire                 irq_out,

    // FIFO Interface
    input  wire [15:0]          fifo_rd_data,
    output reg                  fifo_rd_en,
    input  wire [7:0]           fifo_count,
    input  wire                 fifo_empty,
    input  wire                 fifo_full,
    input  wire                 fifo_overflow,
    input  wire                 fifo_thresh_hit,
    output reg  [7:0]           fifo_thresh_val,

    // RMS & VAD Status Registers
    output reg  [15:0]          rms_level,
    output reg                  vad_active,
    output reg                  vad_led_override
);

assign pready  = 1'b1;  // Single-cycle zero-wait-state APB transfers
assign pslverr = 1'b0;

// Internal Registers
reg [1:0]  irq_en;
reg [1:0]  irq_stat;

// Interrupt Generation
assign irq_out = (irq_en[0] & irq_stat[0]) | (irq_en[1] & irq_stat[1]);

// APB Write Transfer condition
wire apb_write = psel && penable && pwrite;
wire apb_read  = psel && !pwrite;

// Register Write Logic
always @(posedge pclk) begin
    if (!presetn) begin
        ctrl_bypass      <= 1'b0;
        ctrl_soft_rst    <= 1'b0;
        ctrl_fifo_flush  <= 1'b0;
        gain_q17         <= 8'h80; // Default unity gain (1.0 in Q1.7)
        irq_en           <= 2'b00;
        irq_stat         <= 2'b00;
        fifo_thresh_val  <= 8'd64; // Default half-full
        rms_level        <= 16'd0;
        vad_active       <= 1'b0;
        vad_led_override <= 1'b0;
    end else begin
        // Automatic interrupt status capture
        if (fifo_thresh_hit) irq_stat[0] <= 1'b1;
        if (fifo_overflow)   irq_stat[1] <= 1'b1;

        if (apb_write) begin
            case (paddr[7:0])
                8'h00: begin
                    ctrl_bypass      <= pwdata[0];
                    ctrl_soft_rst    <= pwdata[1];
                    ctrl_fifo_flush  <= pwdata[2];
                end
                8'h04: gain_q17 <= pwdata[7:0];
                8'h10: irq_en   <= pwdata[1:0];
                8'h14: irq_stat <= irq_stat & ~pwdata[1:0]; // Write 1 to clear
                8'h1C: fifo_thresh_val <= pwdata[7:0];
                8'h20: rms_level       <= pwdata[15:0];
                8'h24: begin
                    vad_active       <= pwdata[0];
                    vad_led_override <= pwdata[1];
                end
                default: ;
            endcase
        end
    end
end

// APB Read & FIFO Pop Logic
always @(posedge pclk) begin
    if (!presetn) begin
        fifo_rd_en <= 1'b0;
    end else begin
        // Generate single-cycle pulse when reading PCM_DATA register (offset 0x0C)
        fifo_rd_en <= (psel && penable && !pwrite && (paddr[7:0] == 8'h0C) && !fifo_empty);
    end
end

always @(*) begin
    case (paddr[7:0])
        8'h00: prdata = {29'd0, ctrl_fifo_flush, ctrl_soft_rst, ctrl_bypass};
        8'h04: prdata = {24'd0, gain_q17};
        8'h08: prdata = {28'd0, 1'b0, fifo_overflow, fifo_full, fifo_empty};
        8'h0C: prdata = {{16{fifo_rd_data[15]}}, fifo_rd_data}; // Sign-extend 16b -> 32b
        8'h10: prdata = {30'd0, irq_en};
        8'h14: prdata = {30'd0, irq_stat};
        8'h18: prdata = {24'd0, fifo_count};
        8'h1C: prdata = {24'd0, fifo_thresh_val};
        8'h20: prdata = {16'd0, rms_level};
        8'h24: prdata = {30'd0, vad_led_override, vad_active};
        default: prdata = 32'd0;
    endcase
end

endmodule
