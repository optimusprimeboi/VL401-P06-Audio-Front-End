// Naive CSD Multiplier Block for Half-Band Stage 2
// Total Adders: 15
module mcm_hb2_naive #(
    parameter WIDTH = 20
)(
    input  signed [WIDTH-1:0] x,
    output signed [WIDTH+13:0] p_c0,
    output signed [WIDTH+13:0] p_c2,
    output signed [WIDTH+13:0] p_c4,
    output signed [WIDTH+13:0] p_c6,
    output signed [WIDTH+13:0] p_c8,
    output signed [WIDTH+13:0] p_c10
);
  assign p_c0 = - (x <<< 8) + (x <<< 6) + x; // -191 (2 adders)
  assign p_c2 = (x <<< 8) + (x <<< 5) - (x <<< 3); // 280 (2 adders)
  assign p_c4 = - (x <<< 9) + (x <<< 5) - (x <<< 3); // -488 (2 adders)
  assign p_c6 = (x <<< 10) - (x <<< 8) + (x <<< 6); // 832 (2 adders)
  assign p_c8 = - (x <<< 11) + (x <<< 9) - (x <<< 7); // -1664 (2 adders)
  assign p_c10 = (x <<< 12) + (x <<< 10) + (x <<< 8) - (x <<< 6) + (x <<< 4) - x; // 5327 (5 adders)
endmodule
