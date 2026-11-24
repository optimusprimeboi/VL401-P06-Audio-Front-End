"""
sim_cic.py — Pure-Python RTL-level CIC simulation
Simulates cic_decimator.v cycle-by-cycle in Python.
Used as a fast verification step when Icarus Verilog is not yet installed.

Compares against sim/vectors/cic_out.hex (golden model output).
"""
import numpy as np
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "golden"))
from params import *

VEC = os.path.join(os.path.dirname(__file__), "..", "sim", "vectors")

def mask(v, bits=24):
    """Two's complement wrap to `bits` width."""
    m = (1 << bits)
    return int(v) & (m - 1)

def signed(v, bits=24):
    m = 1 << (bits - 1)
    v = mask(v, bits)
    return v - (1 << bits) if v >= m else v

def simulate_cic_rtl(pdm_bits, R=R_CIC, N=N_CIC, B=B_CIC_OUT):
    """
    Cycle-accurate RTL simulation of cic_decimator.v
    Returns list of (pcm_out, cycle_number) tuples when pcm_valid fires.
    """
    # ── Registers (initialised to 0, matching RTL rst_n release) ──────────────
    intg      = [0] * N          # integrators[0..N-1]
    comb_dly  = [0] * N          # comb delay registers[0..N-1]
    dec_cnt   = 0
    pcm_out   = 0
    pcm_valid = 0

    outputs = []

    for cycle, bit in enumerate(pdm_bits):
        # ── Integrators ────────────────────────────────────────────────────────
        x = int(bit)
        intg[0] = mask(intg[0] + x, B)
        for k in range(1, N):
            intg[k] = mask(intg[k] + intg[k-1], B)

        # ── Decimation counter ─────────────────────────────────────────────────
        dec_en = 0
        if dec_cnt == R - 1:
            dec_cnt = 0
            dec_en  = 1
        else:
            dec_cnt += 1

        # ── Comb section ───────────────────────────────────────────────────────
        pcm_valid = 0
        if dec_en:
            # Combinational cascade
            wire = [0] * (N + 1)
            wire[0] = intg[N - 1]
            for k in range(N):
                wire[k+1] = mask(wire[k] - comb_dly[k], B)
            # Register update
            for k in range(N):
                comb_dly[k] = wire[k]
            pcm_out   = wire[N]
            pcm_valid = 1
            outputs.append((pcm_out, cycle))

    return outputs


def run_verification():
    # ── Load PDM ──────────────────────────────────────────────────────────────
    pdm_path = os.path.join(VEC, "pdm_test.txt")
    if not os.path.exists(pdm_path):
        print(f"[sim_cic] ERROR: {pdm_path} not found. Run run_golden.py first.")
        return
    pdm = np.loadtxt(pdm_path, dtype=np.uint8)
    print(f"[sim_cic] Loaded {len(pdm)} PDM bits")

    # ── Load expected output ───────────────────────────────────────────────────
    exp_path = os.path.join(VEC, "cic_out.hex")
    exp_raw  = [int(l.strip(), 16) for l in open(exp_path) if l.strip()]
    exp      = [signed(v, 24) for v in exp_raw]
    print(f"[sim_cic] Loaded {len(exp)} expected samples")

    # ── Simulate ──────────────────────────────────────────────────────────────
    MAX_BITS = min(200_000, len(pdm))     # same limit as Verilog TB
    print(f"[sim_cic] Simulating {MAX_BITS} PDM bits ...")
    outputs  = simulate_cic_rtl(pdm[:MAX_BITS])
    print(f"[sim_cic] Got {len(outputs)} PCM samples from RTL sim")

    # ── Compare (skip first N samples: startup transient) ─────────────────────
    mismatches = 0
    skip       = N_CIC
    checked    = 0
    for i, (got_raw, cyc) in enumerate(outputs):
        if i < skip:
            continue
        if i >= len(exp):
            break
        got = signed(got_raw, 24)
        ref = exp[i]
        checked += 1
        if got != ref:
            mismatches += 1
            if mismatches <= 10:
                print(f"  MISMATCH sample {i}: RTL={got:8d} (0x{got_raw:06x}), "
                      f"golden={ref:8d}  diff={got-ref}")

    print("=" * 50)
    if mismatches == 0 and checked > 0:
        print(f"  *** PASS *** — {checked} samples checked, 0 mismatches")
    elif checked == 0:
        print("  *** WARNING *** — Nothing compared")
    else:
        print(f"  *** FAIL *** — {mismatches}/{checked} mismatches")
    print("=" * 50)
    return mismatches == 0


if __name__ == "__main__":
    run_verification()
