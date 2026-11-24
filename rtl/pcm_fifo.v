// =============================================================================
// Module: pcm_fifo
// Description: Synchronous Audio FIFO with Programmable Watermark IRQ
// Width: 16 bits (PCM Audio)
// Depth: 64 entries (parameterizable)
// Features: Almost-full, almost-empty, watermark threshold IRQ, overflow flag
// =============================================================================

`timescale 1ns / 1ps

module pcm_fifo #(
    parameter DATA_WIDTH = 16,
    parameter DEPTH      = 64,
    parameter ADDR_WIDTH = 6
)(
    input  wire                   clk,
    input  wire                   rst_n,
    
    // Write interface (from decimation filter)
    input  wire                   wr_en,
    input  wire [DATA_WIDTH-1:0]  wr_data,
    
    // Read interface (from APB bus or I2S/PWM transmitter)
    input  wire                   rd_en,
    output reg  [DATA_WIDTH-1:0]  rd_data,
    
    // Watermark configuration
    input  wire [ADDR_WIDTH:0]    watermark,
    
    // Status flags
    output wire                   empty,
    output wire                   full,
    output reg  [ADDR_WIDTH:0]    count,
    output reg                    overflow,
    output wire                   irq
);

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_WIDTH-1:0] wr_ptr;
    reg [ADDR_WIDTH-1:0] rd_ptr;

    assign empty = (count == 0);
    assign full  = (count == DEPTH);
    assign irq   = (count >= watermark);

    // Write Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr   <= {ADDR_WIDTH{1'b0}};
            overflow <= 1'b0;
        end else if (wr_en) begin
            if (!full) begin
                mem[wr_ptr] <= wr_data;
                wr_ptr      <= (wr_ptr == DEPTH - 1) ? {ADDR_WIDTH{1'b0}} : wr_ptr + 1'b1;
            end else begin
                overflow    <= 1'b1; // Sticky overflow indicator
            end
        end
    end

    // Read Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr  <= {ADDR_WIDTH{1'b0}};
            rd_data <= {DATA_WIDTH{1'b0}};
        end else if (rd_en && !empty) begin
            rd_data <= mem[rd_ptr];
            rd_ptr  <= (rd_ptr == DEPTH - 1) ? {ADDR_WIDTH{1'b0}} : rd_ptr + 1'b1;
        end
    end

    // Counter Tracking
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            case ({wr_en && !full, rd_en && !empty})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

endmodule
