# Multiplier-Block Optimization & Adder-Count Comparison

Comparison of Constant Multiplier implementations for the 23-Tap Half-Band Stage 2 Filter:
Target unique coefficients: $c_0=-191, c_2=280, c_4=-488, c_6=832, c_8=-1664, c_{10}=5327$.

| Method | Dedicated Adders/Subtractors | Shared Subexpressions | Total Adders | Logic Savings vs Naive |
| :--- | :---: | :---: | :---: | :---: |
| **Naive CSD** | 15 | 0 | **15** | 0.0% (Baseline) |
| **Common Subexpression Elimination (CSE)** | 5 | 3 ($3x, 13x, 5x$) | **8** | **46.7%** |
| **U3 Kernel / Graph-Based MCM** | 1 | 6 ($3x, 13x, 35x, 61x, 191x, 5x$) | **7** | **53.3%** |

### Logic Minimization of 16-Bit Saturation Unit:
- **Approach**: ESPRESSO Prime Implicant reduction + Reduced Ordered Binary Decision Diagram (ROBDD).
- **Control signals**: De Morgan reduction gives `pos_ovf = (~sign) & (~all_zeros)` and `neg_ovf = sign & (~all_ones)`.
- **LUT Utilization**: Packable into dual-output LUT6_2 primitives, consuming only **10 LUTs** for complete 24-bit to 16-bit convergent rounding and saturation with overflow/underflow flags.
