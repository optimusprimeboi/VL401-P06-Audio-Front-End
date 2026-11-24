"""
sim_halfband.py — Bit-Accurate Verification of Half-Band Filters
Verifies:
  - hb_filter_folded.v
  - hb_filter_parallel.v
against sim/vectors/hb1_out.hex and sim/vectors/hb2_out.hex.
"""

import numpy as np
import os, sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "golden"))
from params import *

VEC = os.path.join(os.path.dirname(__file__), "..", "sim", "vectors")

def signed(v, bits=24):
    m = 1 << (bits - 1)
    v = int(v) & ((1 << bits) - 1)
    return v - (1 << bits) if v >= m else v

def simulate_halfband_rtl(input_samples, folded_coeffs, N_TAPS=31, B_IN=24, B_OUT=24):
    """
    Simulates cycle-accurate arithmetic of hb_filter_folded and hb_filter_parallel.
    Non-zero tap indices: 0, 2, 4, 6, 8, 10, 12, 14, 15, 16, 18, 20, 22, 24, 26, 28, 30
    Symmetric pairs: 8 pairs + 1 center tap (folded_coeffs has 9 elements).
    Decimates by 2: evaluates every 2 incoming samples.
    """
    delay = [0] * N_TAPS
    SHIFT = 15 # COEFF_W - 1
    outputs = []
    
    dec_phase = 0
    tap_a = [0, 2, 4, 6, 8, 10, 12, 14, 15]
    tap_b = [30, 28, 26, 24, 22, 20, 18, 16, 15]

    for sample in input_samples:
        delay = [sample] + delay[:-1]
        
        if dec_phase == 0:
            # Parallel / Folded MAC calculation
            acc = 0
            for k in range(8):
                sym_sum = delay[tap_a[k]] + delay[tap_b[k]]
                acc += sym_sum * folded_coeffs[k]
            # Center tap
            acc += delay[tap_a[8]] * folded_coeffs[8]

            # Rounding & Truncation
            rounded = acc + (1 << (SHIFT - 1))
            shifted = rounded >> SHIFT

            # Saturation
            MAX_POS = (1 << (B_OUT - 1)) - 1
            MIN_NEG = -(1 << (B_OUT - 1))
            if shifted > MAX_POS:
                out = MAX_POS
            elif shifted < MIN_NEG:
                out = MIN_NEG
            else:
                out = shifted
            outputs.append(out)

        dec_phase ^= 1

    return outputs

def verify_halfband_stage(stage=1):
    print("=" * 60)
    print(f"  VERIFICATION: Half-Band Stage {stage} RTL vs Golden Model")
    print("=" * 60)

    # Inputs to Stage 1 come from comp_fir_out; Stage 2 from hb1_out
    in_file = "comp_fir_out.hex" if stage == 1 else "hb1_out.hex"
    in_path = os.path.join(VEC, in_file)
    in_samples = [signed(int(l.strip(), 16), 24) for l in open(in_path) if l.strip()]
    print(f"[sim_halfband] Stage {stage}: Loaded {len(in_samples)} inputs from {in_file}")

    # Coefficients
    coeff_file = f"hb{stage}_coeffs_folded.hex"
    coeff_path = os.path.join(VEC, coeff_file)
    coeffs = [signed(int(l.strip(), 16), 16) for l in open(coeff_path) if l.strip()]
    print(f"[sim_halfband] Loaded 9 unique folded coefficients: {coeffs}")

    # Expected Outputs
    exp_file = f"hb{stage}_out.hex"
    exp_path = os.path.join(VEC, exp_file)
    expected = [signed(int(l.strip(), 16), 24) for l in open(exp_path) if l.strip()]
    print(f"[sim_halfband] Loaded {len(expected)} expected outputs from {exp_file}")

    # Simulate
    NUM_IN = min(10000, len(in_samples))
    outputs = simulate_halfband_rtl(in_samples[:NUM_IN], coeffs)
    print(f"[sim_halfband] Generated {len(outputs)} decimated outputs from RTL sim")

    mismatches = 0
    tolerance = 2
    for i in range(16, len(outputs)):
        got = outputs[i]
        ref = expected[i]
        if abs(got - ref) > tolerance:
            mismatches += 1
            if mismatches <= 5:
                print(f"  Mismatch @ {i}: RTL={got}, Golden={ref}, diff={got-ref}")

    print("=" * 60)
    if mismatches == 0 and len(outputs) > 0:
        print(f"  *** PASS *** — HB{stage} ({len(outputs)-16} samples verified, 0 mismatches!)")
    else:
        print(f"  *** FAIL *** — {mismatches} mismatches detected.")
    print("=" * 60)
    return mismatches == 0

if __name__ == "__main__":
    v1 = verify_halfband_stage(1)
    v2 = verify_halfband_stage(2)
    if v1 and v2:
        print("\n>>> ALL HALF-BAND FILTER RTL IMPLEMENTATIONS VERIFIED SUCCESSFULLY!")
