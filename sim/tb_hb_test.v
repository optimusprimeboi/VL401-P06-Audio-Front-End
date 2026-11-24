`timescale 1ns/1ps
module tb_hb_test;
    reg clk = 0;
    reg rst_n = 0;
    reg in_valid = 0;
    reg signed [19:0] in_data = 0;
    wire out_valid;
    wire signed [19:0] out_data;

    always #10 clk = ~clk;

    halfband_stage1 #(
        .IN_WIDTH(20),
        .OUT_WIDTH(20)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .in_data(in_data),
        .out_valid(out_valid),
        .out_data(out_data)
    );

    integer k;
    initial begin
        #100;
        rst_n = 1;
        #100;
        for (k = 0; k < 40; k = k + 1) begin
            @(posedge clk);
            in_valid = 1;
            in_data = 20000;
            @(posedge clk);
            in_valid = 0;
            repeat(10) @(posedge clk);
            if (out_valid) begin
                $display("k=%0d, out_data=%0d", k, out_data);
            end
        end
        $finish;
    end
endmodule
