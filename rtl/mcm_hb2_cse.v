// Common Subexpression Elimination (CSE) Multiplier Block for Half-Band Stage 2
// Total Adders: 8 (47% reduction vs Naive)
module mcm_hb2_cse #(
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
    // Shared Subexpressions
    wire signed [WIDTH+2:0]  s_3x  = (x <<< 1) + x;            // 1 adder
    wire signed [WIDTH+4:0]  s_13x = (s_3x <<< 2) + x;         // 1 adder
    wire signed [WIDTH+3:0]  s_5x  = (x <<< 2) + x;            // 1 adder

    // Output Coefficients
    assign p_c0  = -((s_3x <<< 6) - x);                        // 1 adder: -(192x - x) = -191x
    assign p_c2  = (x <<< 8) + (s_3x <<< 3);                   // 1 adder: 256x + 24x = 280x
    assign p_c4  = -(x <<< 9) + (s_3x <<< 3);                  // 1 adder: -512x + 24x = -488x
    assign p_c6  = (s_13x <<< 6);                              // 0 adders: 13x << 6 = 832x
    assign p_c8  = -(p_c6 <<< 1);                              // 0 adders: -1664x (wire negate/shift)
    
    wire signed [WIDTH+13:0] temp_5327 = (s_5x <<< 10) + (s_13x <<< 4); // 1 adder
    assign p_c10 = temp_5327 - x;                              // 1 adder: 5327x
endmodule
