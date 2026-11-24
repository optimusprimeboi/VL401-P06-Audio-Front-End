"""
P6: PDM-to-PCM Audio Front End — Shared Parameters
All rates, filter specs, and bit widths in one place.
Any change here propagates to all golden model scripts.
"""

# ─── Clock / Rate Plan ────────────────────────────────────────────────────────
F_PDM       = 3_072_000     # Hz  — PDM microphone bit clock
F_OSR       = 64            # oversampling ratio for sigma-delta modulator
                            # (PDM gen uses audio * 64 = 3.072 MHz)

R_CIC       = 16            # CIC decimation ratio
N_CIC       = 4             # CIC number of stages (order)
M_CIC       = 1             # CIC differential delay

F_CIC_OUT   = F_PDM // R_CIC           # 192_000 Hz
F_HB1_OUT   = F_CIC_OUT // 2           # 96_000  Hz
F_HB2_OUT   = F_HB1_OUT // 2           # 48_000  Hz  (final PCM rate)
F_AUDIO_OUT = F_HB2_OUT                # 48_000  Hz

# ─── Audio Band ───────────────────────────────────────────────────────────────
F_PASS      = 20_000        # Hz  — audio passband edge (spec: 20 Hz–20 kHz)
F_PASS_LOW  = 20            # Hz

# ─── Bit Widths ───────────────────────────────────────────────────────────────
B_PDM       = 1             # input PDM: 1-bit (0 or 1 → treated as 0/+1)
# CIC internal: B_in + N * ceil(log2(R * M))
import math
B_CIC_GROWTH = N_CIC * math.ceil(math.log2(R_CIC * M_CIC))  # = 16
B_CIC_INTERNAL = B_PDM + B_CIC_GROWTH                         # = 17, use 24
B_CIC_OUT   = 24            # rounded up to clean byte boundary
B_COMP_OUT  = 24            # after compensation FIR
B_HB1_OUT   = 24
B_PCM_OUT   = 16            # final output: 16-bit signed PCM

# ─── Compensation FIR ─────────────────────────────────────────────────────────
COMP_NTAPS  = 31            # number of taps (odd for linear phase)
COMP_FS     = F_CIC_OUT     # runs at 192 kHz

# ─── Half-Band Filters ────────────────────────────────────────────────────────
# HB1: 192 kHz → 96 kHz
HB1_FS      = F_CIC_OUT     # 192 kHz
HB1_FPASS   = F_PASS        # 20 kHz passband
HB1_FSTOP   = HB1_FS/2 - F_PASS  # 76 kHz stopband (= 96 - 20)
HB1_NTAPS   = 31            # adjust if attenuation insufficient

# HB2: 96 kHz → 48 kHz
HB2_FS      = F_HB1_OUT     # 96 kHz
HB2_FPASS   = F_PASS        # 20 kHz
HB2_FSTOP   = HB2_FS/2 - F_PASS  # 28 kHz (= 48 - 20)
HB2_NTAPS   = 31

# ─── Fixed-Point / Quantisation ───────────────────────────────────────────────
COEFF_BITS  = 16            # coefficient word length for CSD analysis
COEFF_FRAC  = 15            # fractional bits (1.15 format, range [-1, +1))

# ─── Test Signal ──────────────────────────────────────────────────────────────
TEST_DURATION_S = 0.5       # seconds of test signal
TEST_TONES  = [1000, 5000, 10000, 19000]  # Hz — tones for SNR measurement

# ─── File Paths (relative to project root) ────────────────────────────────────
VEC_DIR     = "../sim/vectors"
