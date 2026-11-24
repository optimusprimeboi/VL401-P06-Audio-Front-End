`timescale 1ns/1ps
module tb_pdm_top_trace;
    reg clk = 0;
    reg rst_n = 0;
    wire [15:0] final_pcm_sample;
    wire [7:0] led_vu_meter;

    always #10.1725 clk = ~clk; // 49.152 MHz

    pdm_top #(
        .USE_BRAM_SOURCE(1),
        .FIFO_DEPTH(64)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_override(1'b1),
        .cfg_pdm_enable(1'b1),
        .cfg_use_paper(1'b0),
        .cfg_use_folded(1'b0),
        .cfg_bypass_mode(1'b0),
        .cfg_tone_sel(1'b1),
        .cfg_gain(16'h1000),
        .pdm_mic_data_in(1'b0),
        .pdm_mic_clk_out(),
        .psel(1'b0),
        .penable(1'b0),
        .pwrite(1'b0),
        .paddr(8'h0),
        .pwdata(32'h0),
        .prdata(),
        .pready(),
        .pslverr(),
        .irq(),
        .i2s_bclk(),
        .i2s_lrclk(),
        .i2s_sdata(),
        .audio_pwm_out(),
        .led_vu_meter(led_vu_meter)
    );

    integer sample_idx = 0;
    always @(posedge clk) begin
        if (rst_n && dut.pre_gain_valid) begin
            sample_idx = sample_idx + 1;
            $display("[Sample #%02d] CIC=%6d | FIR=%6d | HB1=%6d | HB2=%6d | PCM=%6d",
                     sample_idx, dut.cic_out, dut.stage2_out, dut.hb1_out, dut.filter_chain_out, dut.final_pcm_sample);
            if (sample_idx >= 30) $finish;
        end
    end

    initial begin
        #200;
        rst_n = 1;
        #10000000;
        $finish;
    end
endmodule
