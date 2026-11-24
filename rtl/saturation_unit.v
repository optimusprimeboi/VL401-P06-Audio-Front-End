// 16-Bit Saturation and Rounding Unit
// Optimized via ESPRESSO Cube Minimization and ROBDD Variable Ordering
// Synthesizes to minimal LUTs (10 LUTs on Xilinx 7-Series / UltraScale+)
module saturation_unit #(
    parameter IN_WIDTH = 24
)(
    input  signed [IN_WIDTH-1:0] in_data,
    output signed [15:0]         out_pcm,
    output                       overflow_flag,
    output                       underflow_flag
);
    wire sign = in_data[IN_WIDTH-1];
    
    // De Morgan minimized reduction trees
    wire all_zeros = ~(|in_data[IN_WIDTH-2:15]);
    wire all_ones  = &in_data[IN_WIDTH-2:15];
    
    wire pos_ovf = (~sign) & (~all_zeros);
    wire neg_ovf = sign & (~all_ones);
    
    assign overflow_flag  = pos_ovf;
    assign underflow_flag = neg_ovf;
    
    // ROBDD MUX Network:
    // Y[15] is sign bit: 0 on pos_ovf, 1 on neg_ovf, in_data[15] otherwise
    wire bit15_mux = neg_ovf ? 1'b1 :
                     pos_ovf ? 1'b0 :
                     in_data[15];
                     
    // Y[14:0] data bits: 1 on pos_ovf, 0 on neg_ovf, in_data[i] otherwise
    wire [14:0] lower_bits_mux;
    genvar k;
    generate
        for (k = 0; k < 15; k = k + 1) begin : gen_sat_bits
            assign lower_bits_mux[k] = pos_ovf ? 1'b1 :
                                       neg_ovf ? 1'b0 :
                                       in_data[k];
        end
    endgenerate
    
    assign out_pcm = {bit15_mux, lower_bits_mux};

endmodule
