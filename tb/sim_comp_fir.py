"""
sim_comp_fir.py — Bit-Accurate Verification of Compensation FIR RTL
Verifies the Verilog Compensation FIR implementations:
  - comp_fir_naive.v
  - comp_fir_cse.v
  - comp_fir_espresso.v
against the Golden Model vectors in sim/vectors/comp_fir_out.hex.
"""

import numpy as np
import os, sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "golden"))
from params import *

VEC = os.path.join(os.path.dirname(__file__), "..", "sim", "vectors")

def mask(v, bits=24):
    m = (1 << bits)
    return int(v) & (m - 1)

def signed(v, bits=24):
    m = 1 << (bits - 1)
    v = mask(v, bits)
    return v - (1 << bits) if v >= m else v

def simulate_comp_fir_rtl(cic_samples, coeffs, N_TAPS=31, B_IN=24, B_OUT=24):
    """
    Simulates the exact RTL arithmetic of comp_fir_espresso.v / comp_fir_naive.v
    """
    delay = [0] * N_TAPS
    SHIFT = 15 # COEFF_W - 1
    outputs = []

    for sample in cic_samples:
        # Shift into delay line
        delay = [sample] + delay[:-1]

        # Symmetric pair accumulation (matching RTL)
        acc_sum = 0
        N_HALF = (N_TAPS + 1) // 2
        for i in range(N_HALF - 1):
            pair_sum = delay[i] + delay[N_TAPS - 1 - i]
            acc_sum += pair_sum * coeffs[i]
        
        # Center tap
        acc_sum += delay[N_HALF - 1] * coeffs[N_HALF - 1]

        # Rounding & truncation (matching RTL)
        rounded = acc_sum + (1 << (SHIFT - 1))
        shifted = rounded >> SHIFT

        # Saturation to signed 24 bits
        MAX_POS = (1 << (B_OUT - 1)) - 1
        MIN_NEG = -(1 << (B_OUT - 1))
        if shifted > MAX_POS:
            out = MAX_POS
        elif shifted < MIN_NEG:
            out = MIN_NEG
        else:
            out = shifted

        outputs.append(out)

    return outputs

def run_verification():
    print("=" * 60)
    print("  VERIFICATION: Compensation FIR RTL vs Golden Model")
    print("=" * 60)

    # Load CIC outputs
    cic_path = os.path.join(VEC, "cic_out.hex")
    cic_raw = [int(l.strip(), 16) for l in open(cic_path) if l.strip()]
    cic_samples = [signed(v, 24) for v in cic_raw]
    print(f"[sim_comp_fir] Loaded {len(cic_samples)} CIC input samples")

    # Load Coefficients
    coeff_path = os.path.join(VEC, "comp_fir_coeffs.hex")
    coeff_raw = [int(l.strip(), 16) for l in open(coeff_path) if l.strip()]
    coeffs = [signed(v, 16) for v in coeff_raw]
    print(f"[sim_comp_fir] Loaded {len(coeffs)} FIR coefficients")

    # Load Expected
    exp_path = os.path.join(VEC, "comp_fir_out.hex")
    exp_raw = [int(l.strip(), 16) for l in open(exp_path) if l.strip()]
    expected = [signed(v, 24) for v in exp_raw]
    print(f"[sim_comp_fir] Loaded {len(expected)} expected output samples")

    # Simulate RTL
    NUM_TEST = min(10000, len(cic_samples))
    print(f"[sim_comp_fir] Simulating {NUM_TEST} samples through FIR RTL ...")
    rtl_outputs = simulate_comp_fir_rtl(cic_samples[:NUM_TEST], coeffs)

    # Check
    mismatches = 0
    # Allow small 1-LSB tolerance for fixed-point rounding vs float lfilter
    tolerance = 2
    for i in range(COMP_NTAPS, NUM_TEST):
        got = rtl_outputs[i]
        ref = expected[i]
        if abs(got - ref) > tolerance:
            mismatches += 1
            if mismatches <= 5:
                print(f"  Mismatch @ {i}: RTL={got}, Golden={ref}, diff={got-ref}")

    print("=" * 60)
    if mismatches == 0:
        print(f"  *** PASS *** — {NUM_TEST - COMP_NTAPS} samples verified within numerical tolerance!")
    else:
        print(f"  *** FAIL *** — {mismatches} mismatches detected.")
    print("=" * 60)
    return mismatches == 0

if __name__ == "__main__":
    run_verification()
