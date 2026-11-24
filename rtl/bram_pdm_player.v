// =============================================================================
// Module: bram_pdm_player
// Description: Dual-Mode PDM Stream Generator
// Modes:
//   tone_sel = 0 : Pure 440 Hz Concert Pitch Tone (Smooth, pleasant listening)
//   tone_sel = 1 : 20 ms BRAM Multi-tone Benchmark Audio (1 kHz + 5 kHz + 12 kHz)
// =============================================================================

`timescale 1ns / 1ps

module bram_pdm_player #(
    parameter MEM_WORDS  = 1920,
    parameter ADDR_WIDTH = 11,
    parameter INIT_FILE  = "C:/Users/Lenovo/Downloads/VL401_Group06_P06_Final_Submission/pdm_stimulus_words.hex"
)(
    input  wire        clk,          // System clock (49.152 MHz)
    input  wire        rst_n,        // Active-low reset
    input  wire        enable,       // Playback enable (SW0)
    input  wire        tone_sel,     // 0 = 440 Hz pure tone, 1 = BRAM benchmark
    
    output reg         pdm_clk_en,   // 3.072 MHz strobe
    output reg         pdm_bit_out   // 1-bit PDM stream to decimation chain
);

    // Clock divider: 49.152 MHz / 16 = 3.072 MHz
    reg [3:0] clk_div;
    wire tick_3m072 = (clk_div == 4'd15);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_div    <= 4'd0;
            pdm_clk_en <= 1'b0;
        end else if (enable) begin
            clk_div    <= clk_div + 4'd1;
            pdm_clk_en <= tick_3m072;
        end else begin
            clk_div    <= 4'd0;
            pdm_clk_en <= 1'b0;
        end
    end

    // -------------------------------------------------------------
    // Mode 0: Clean 440 Hz Tone Generator (3491 ticks high / 3491 ticks low)
    // -------------------------------------------------------------
    reg [12:0] tone_cnt;
    reg        tone_bit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tone_cnt <= 13'd0;
            tone_bit <= 1'b0;
        end else if (enable && tick_3m072) begin
            if (tone_cnt >= 13'd3490) begin
                tone_cnt <= 13'd0;
                tone_bit <= ~tone_bit;
            end else begin
                tone_cnt <= tone_cnt + 13'd1;
            end
        end else if (!enable) begin
            tone_cnt <= 13'd0;
            tone_bit <= 1'b0;
        end
    end

    // -------------------------------------------------------------
    // Mode 1: BRAM Storage for Benchmark PDM words
    // -------------------------------------------------------------
    (* rom_style = "block" *) reg [31:0] bram_mem [0:MEM_WORDS-1];
    
    integer k;
    initial begin
        for (k = 0; k < MEM_WORDS; k = k + 1) begin
            bram_mem[k] = ((k / 48) % 2 == 0) ? 32'hAAAAAAAA : 32'h55555555;
        end
        $readmemh(INIT_FILE, bram_mem);
        $display("[BRAM_DEBUG %m] INIT_FILE=%s, bram_mem[0]=%h, bram_mem[1]=%h", INIT_FILE, bram_mem[0], bram_mem[1]);
    end

    reg [ADDR_WIDTH-1:0] word_addr;
    reg [4:0]            bit_idx;
    reg [31:0]           curr_word;
    reg                  bram_bit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            word_addr <= {ADDR_WIDTH{1'b0}};
            bit_idx   <= 5'd0;
            curr_word <= 32'd0;
            bram_bit  <= 1'b0;
        end else if (enable && tick_3m072) begin
            if (bit_idx == 5'd0) begin
                curr_word <= bram_mem[word_addr];
                bram_bit  <= bram_mem[word_addr][0];
                bit_idx   <= 5'd1;
            end else begin
                bram_bit  <= curr_word[bit_idx];
                if (bit_idx == 5'd31) begin
                    bit_idx   <= 5'd0;
                    word_addr <= (word_addr == MEM_WORDS - 1) ? {ADDR_WIDTH{1'b0}} : word_addr + 1'b1;
                end else begin
                    bit_idx   <= bit_idx + 5'd1;
                end
            end
        end else if (!enable) begin
            bram_bit <= 1'b0;
        end
    end

    // Active PDM Bit Mux (Mutes when enable is 0)
    always @(*) begin
        if (!enable) begin
            pdm_bit_out = 1'b0;
        end else if (!tone_sel) begin
            pdm_bit_out = tone_bit; // Smooth 440 Hz
        end else begin
            pdm_bit_out = bram_bit; // Benchmark multi-tone
        end
    end

endmodule
