// Graph-Based MCM / U3 Kernel Multiplier Block for Half-Band Stage 2
// Total Adders: 7 (53% reduction vs Naive)
module mcm_hb2_graph_u3 #(
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
    // U3 Kernel Fundamentals
    wire signed [WIDTH+2:0]  u_3   = (x <<< 2) - x;           // Op 1: 3x
    wire signed [WIDTH+4:0]  u_13  = (u_3 <<< 2) + x;         // Op 2: 13x
    wire signed [WIDTH+6:0]  u_35  = (x <<< 5) + u_3;         // Op 3: 35x
    wire signed [WIDTH+6:0]  u_61  = (x <<< 6) - u_3;         // Op 4: 61x
    wire signed [WIDTH+8:0]  u_191 = (u_3 <<< 6) - x;         // Op 5: 191x
    wire signed [WIDTH+3:0]  u_5   = (x <<< 2) + x;           // Op 6: 5x
    
    // Outputs mapped directly to fundamentals
    assign p_c0  = -u_191;                                    // -191x
    assign p_c2  = (u_35 <<< 3);                              // 35x << 3 = 280x
    assign p_c4  = -(u_61 <<< 3);                             // -(61x << 3) = -488x
    assign p_c6  = (u_13 <<< 6);                              // 13x << 6 = 832x
    assign p_c8  = -(u_13 <<< 7);                             // -(13x << 7) = -1664x
    
    wire signed [WIDTH+13:0] u_comb = (u_5 <<< 10) + (u_13 <<< 4); // Op 7
    assign p_c10 = u_comb - x;                                // 5327x
endmodule
