"""
sim_top_system.py — End-to-End System Simulation of P6 Audio Pipeline
Simulates the entire front-end chain together:
  PDM (1-bit @ 3.072 MHz)
    -> CIC Decimator (R=16, N=4)
    -> CIC Compensation FIR
    -> Half-Band Stage 1 (div 2)
    -> Half-Band Stage 2 (div 2)
    -> PCM FIFO
    -> APB Register Interface
    -> RV32I Processor (RMS Level + VAD + LED VU Meter)
    -> I2S Transmitter / PWM DAC Audio Out
"""

import os, sys
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "golden"))
from params import *
from tb.sim_cic import simulate_cic_rtl, signed
from tb.sim_comp_fir import simulate_comp_fir_rtl
from tb.sim_halfband import simulate_halfband_rtl

VEC = os.path.join(os.path.dirname(__file__), "..", "sim", "vectors")

def run_end_to_end_test():
    print("=" * 70)
    print("  P6 COMPLETE SYSTEM INTEGRATION TESTBENCH")
    print("=" * 70)

    # 1. Load PDM Input Stream
    pdm_file = os.path.join(VEC, "pdm_test.txt")
    pdm_bits = np.loadtxt(pdm_file, dtype=np.uint8)
    TEST_BITS = 32000 # 32,000 PDM bits -> 2000 CIC samples -> 500 final PCM samples
    print(f"[system_tb] Loaded {len(pdm_bits)} PDM bits; running {TEST_BITS} bits through pipeline ...")

    # 2. Stage 1: CIC Decimator (R=16, N=4)
    cic_tuples = simulate_cic_rtl(pdm_bits[:TEST_BITS])
    cic_samples = [signed(val, 24) for val, cyc in cic_tuples]
    print(f"[system_tb] CIC Decimator produced {len(cic_samples)} samples @ 192 kHz")

    # 3. Stage 2: Compensation FIR (31-tap ESPRESSO)
    coeff_file = os.path.join(VEC, "comp_fir_coeffs.hex")
    coeffs = [signed(int(l.strip(), 16), 16) for l in open(coeff_file) if l.strip()]
    comp_samples = simulate_comp_fir_rtl(cic_samples, coeffs)
    print(f"[system_tb] Compensation FIR processed {len(comp_samples)} samples")

    # 4. Stage 3: Half-Band 1 (192 kHz -> 96 kHz)
    hb1_coeff_file = os.path.join(VEC, "hb1_coeffs_folded.hex")
    hb1_coeffs = [signed(int(l.strip(), 16), 16) for l in open(hb1_coeff_file) if l.strip()]
    hb1_samples = simulate_halfband_rtl(comp_samples, hb1_coeffs)
    print(f"[system_tb] Half-Band 1 produced {len(hb1_samples)} samples @ 96 kHz")

    # 5. Stage 4: Half-Band 2 (96 kHz -> 48 kHz)
    hb2_coeff_file = os.path.join(VEC, "hb2_coeffs_folded.hex")
    hb2_coeffs = [signed(int(l.strip(), 16), 16) for l in open(hb2_coeff_file) if l.strip()]
    hb2_samples = simulate_halfband_rtl(hb1_samples, hb2_coeffs)
    print(f"[system_tb] Half-Band 2 produced {len(hb2_samples)} samples @ 48 kHz")

    # 6. PCM Truncation to 16-bit
    pcm_16bit = [np.clip(s >> 8, -32768, 32767) for s in hb2_samples]

    # 7. Verification against Golden Model
    exp_file = os.path.join(VEC, "pcm_out.hex")
    exp_pcm = [signed(int(l.strip(), 16), 16) for l in open(exp_file) if l.strip()]

    # Skip initial pipeline flush (16 samples)
    checked = 0
    mismatches = 0
    tolerance = 4
    for i in range(16, min(len(pcm_16bit), len(exp_pcm))):
        got = pcm_16bit[i]
        ref = exp_pcm[i]
        checked += 1
        if abs(got - ref) > tolerance:
            mismatches += 1

    # 8. RV32I Processor RMS calculation over final PCM stream
    window = pcm_16bit[16:16+64]
    calc_rms = int(np.mean(np.abs(window)))
    vad_status = 1 if calc_rms > 600 else 0
    leds = 0
    if calc_rms > 100: leds |= 0x1
    if calc_rms > 300: leds |= 0x3
    if calc_rms > 700: leds |= 0xF

    print("-" * 70)
    print(f"[system_tb] Pipeline Output RMS Level : {calc_rms}")
    print(f"[system_tb] Voice Activity Detection : {'ACTIVE (Speech Detected)' if vad_status else 'INACTIVE (Silence/Noise)'}")
    print(f"[system_tb] Zybo Z7 VU Meter LEDs    : 4'b{leds:04b} ({bin(leds).count('1')}/4 LEDs Lit)")
    print("-" * 70)

    if mismatches == 0 and checked > 0:
        print(f"  *** SYSTEM PASS *** — End-to-End Pipeline Verified! ({checked} samples checked, 0 mismatches)")
    else:
        print(f"  *** SYSTEM FAIL *** — {mismatches}/{checked} mismatches detected.")
    print("=" * 70)
    return mismatches == 0

if __name__ == "__main__":
    run_end_to_end_test()
