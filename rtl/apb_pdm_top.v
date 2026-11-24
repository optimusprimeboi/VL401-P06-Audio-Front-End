// =============================================================================
// Module: apb_pdm_top
// Description: APB3/APB4 Slave Interface and Control Core for PDM Audio Front End
// Features: Memory-mapped control, gain scaling, status flags, watermark IRQ
// Memory Map:
//   0x00: CR (Control: enable, soft_reset, bypass, irq_en, use_paper, use_folded)
//   0x04: SR (Status: empty, full, overflow, vad_active, fifo_count)
//   0x08: GAIN (Digital Gain: Q4.12 format, default 0x1000 = 1.0x)
//   0x0C: DATA (FIFO Read Port: pop on read)
//   0x10: WATERMARK (FIFO IRQ Threshold)
//   0x14: RMS_ENERGY (Hardware VAD Windowed RMS Energy)
//   0x18: VAD_THRESH (VAD Detection Threshold)
// =============================================================================

`timescale 1ns / 1ps

module apb_pdm_top #(
    parameter ADDR_WIDTH = 8,
    parameter DATA_WIDTH = 32
)(
    // APB Bus Interface
    input  wire                   pclk,
    input  wire                   presetn,
    input  wire                   psel,
    input  wire                   penable,
    input  wire                   pwrite,
    input  wire [ADDR_WIDTH-1:0]  paddr,
    input  wire [DATA_WIDTH-1:0]  pwdata,
    output reg  [DATA_WIDTH-1:0]  prdata,
    output wire                   pready,
    output wire                   pslverr,
    
    // Core Control Signals
    output wire                   pdm_enable,
    output wire                   soft_reset,
    output wire                   bypass_mode,
    output wire                   use_paper_filter,
    output wire                   use_folded_hb2,
    output wire signed [15:0]     digital_gain,
    
    // FIFO Interface
    input  wire                   fifo_empty,
    input  wire                   fifo_full,
    input  wire                   fifo_overflow,
    input  wire [6:0]             fifo_count,
    input  wire [15:0]            fifo_rd_data,
    output reg                    fifo_rd_en,
    output wire [6:0]             watermark,
    
    // VAD & Energy Interface
    input  wire [15:0]            hw_rms_energy,
    input  wire                   hw_vad_active,
    output wire [15:0]            vad_threshold,
    
    // Interrupt Request
    input  wire                   fifo_irq_raw,
    output wire                   irq
);

    // Register Offsets
    localparam ADDR_CR         = 8'h00,
               ADDR_SR         = 8'h04,
               ADDR_GAIN       = 8'h08,
               ADDR_DATA       = 8'h0C,
               ADDR_WATERMARK  = 8'h10,
               ADDR_RMS        = 8'h14,
               ADDR_VAD_THRESH = 8'h18;

    // Registers
    reg [5:0]  reg_cr;         // [0]=en, [1]=soft_rst, [2]=bypass, [3]=irq_en, [4]=paper, [5]=folded
    reg [15:0] reg_gain;       // Q4.12
    reg [6:0]  reg_watermark;
    reg [15:0] reg_vad_thresh;

    assign pdm_enable       = reg_cr[0];
    assign soft_reset       = reg_cr[1];
    assign bypass_mode      = reg_cr[2];
    assign use_paper_filter = reg_cr[4];
    assign use_folded_hb2   = reg_cr[5];
    assign digital_gain     = reg_gain;
    assign watermark        = reg_watermark;
    assign vad_threshold    = reg_vad_thresh;
    assign irq              = reg_cr[3] & fifo_irq_raw;

    assign pready  = 1'b1; // Zero wait-state APB slave
    assign pslverr = 1'b0;

    // APB Write Transfer
    wire apb_write = psel & penable & pwrite;
    wire apb_read  = psel & (!penable) & (!pwrite); // Start of read phase

    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            reg_cr         <= 6'b000001; // Enable by default
            reg_gain       <= 16'h1000;  // 1.0x in Q4.12
            reg_watermark  <= 7'd16;     // 16 samples
            reg_vad_thresh <= 16'h0080;  // Default threshold
        end else if (apb_write) begin
            case (paddr[7:0])
                ADDR_CR:         reg_cr         <= pwdata[5:0];
                ADDR_GAIN:       reg_gain       <= pwdata[15:0];
                ADDR_WATERMARK:  reg_watermark  <= pwdata[6:0];
                ADDR_VAD_THRESH: reg_vad_thresh <= pwdata[15:0];
                default: ;
            endcase
        end else if (reg_cr[1]) begin
            // Self-clearing soft reset
            reg_cr[1] <= 1'b0;
        end
    end

    // APB Read Transfer & FIFO Read Strobe
    always @(*) begin
        fifo_rd_en = 1'b0;
        case (paddr[7:0])
            ADDR_CR: begin
                prdata = {26'd0, reg_cr};
            end
            ADDR_SR: begin
                prdata = {16'd0, 1'b0, fifo_count, 4'd0, hw_vad_active, fifo_overflow, fifo_full, fifo_empty};
            end
            ADDR_GAIN: begin
                prdata = {16'd0, reg_gain};
            end
            ADDR_DATA: begin
                prdata = {16'd0, fifo_rd_data};
                if (psel && penable && !pwrite) begin
                    fifo_rd_en = 1'b1; // Pop FIFO on completed APB read
                end
            end
            ADDR_WATERMARK: begin
                prdata = {25'd0, reg_watermark};
            end
            ADDR_RMS: begin
                prdata = {16'd0, hw_rms_energy};
            end
            ADDR_VAD_THRESH: begin
                prdata = {16'd0, reg_vad_thresh};
            end
            default: begin
                prdata = 32'd0;
            end
        endcase
    end

endmodule
