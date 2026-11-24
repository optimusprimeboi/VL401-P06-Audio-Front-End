"""
Filter Design and Golden Model Synthesis
Author: Senior FPGA / DSP / RTL Systems Architect
Project: PDM-to-PCM Audio Front End (3.072 MHz -> 48 kHz)
"""

import numpy as np
import scipy.signal as signal
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import os

os.makedirs("docs/plots", exist_ok=True)
os.makedirs("rtl/include", exist_ok=True)

# -------------------------------------------------------------
# CSD Conversion Utility
# -------------------------------------------------------------
def to_csd(val):
    """
    Convert an integer to Canonical Signed Digit (CSD) representation.
    Returns a list of tuples: (sign, power_of_two) such that val = sum(sign * 2**power)
    where sign in {+1, -1} and no adjacent terms exist.
    """
    if val == 0:
        return []
    
    neg = val < 0
    num = abs(int(val))
    
    csd_terms = []
    p = 0
    while num > 0:
        if num & 1:
            if num & 2:
                term_sign = -1 if not neg else +1
                csd_terms.append((term_sign, p))
                num += 1
            else:
                term_sign = +1 if not neg else -1
                csd_terms.append((term_sign, p))
        num >>= 1
        p += 1
        
    return sorted(csd_terms, key=lambda x: -x[1])

def csd_to_string(csd_terms):
    if not csd_terms:
        return "0"
    parts = []
    for s, p in csd_terms:
        sign_str = "+" if s > 0 else "-"
        parts.append(f"{sign_str}(1<<{p})")
    res = " ".join(parts)
    if res.startswith("+"):
        res = res[1:].strip()
    return res

def quantize_to_csd(coeff_float, scale_factor, max_terms=3):
    target = round(coeff_float * scale_factor)
    terms = to_csd(target)
    if len(terms) > max_terms:
        terms = terms[:max_terms]
    val = sum(s * (1 << p) for s, p in terms)
    return val, terms

# -------------------------------------------------------------
# Filter 1: CIC Filter Parameters
# -------------------------------------------------------------
R_cic = 16
N_cic = 4
M_cic = 1
Fs_in = 3072000
Fs_cic = Fs_in // R_cic  # 192 kHz

G_cic = (R_cic * M_cic) ** N_cic
print(f"CIC Decimator: R={R_cic}, N={N_cic}, M={M_cic}")
print(f"CIC DC Gain: {G_cic} (2^{int(np.log2(G_cic))})")
print(f"CIC Bit Growth: N*log2(R*M) = {N_cic * int(np.log2(R_cic * M_cic))} bits")

# -------------------------------------------------------------
# Filter 2: CIC Compensation FIR (at 192 kHz)
# -------------------------------------------------------------
# Droop compensation:
# Inverse sinc^4: 1 / [ sin(pi*f*R/Fs_in) / (R*sin(pi*f/Fs_in)) ]^4
# Passband: 0 to 20 kHz. Stopband: 24 to 96 kHz.
num_taps_comp = 9
f_pb = np.linspace(1e-4, 20000, 30)
gain_pb = ( (R_cic * np.sin(np.pi * f_pb / Fs_in)) / np.sin(np.pi * f_pb * R_cic / Fs_in) ) ** N_cic

freq_pts = np.concatenate([[0], f_pb, [24000, 96000]])
freq_pts_norm = freq_pts / (Fs_cic / 2.0)
freq_pts_norm[-1] = 1.0  # Exactly 1.0
gain_pts = np.concatenate([[1.0], gain_pb, [1.02, 0.4]])

h_comp_ideal = signal.firwin2(num_taps_comp, freq_pts_norm, gain_pts, window='hamming')
h_comp_ideal = h_comp_ideal / np.sum(h_comp_ideal)

# Quantize to Q12 (scale = 4096)
scale_comp = 4096
h_comp_int = np.zeros(num_taps_comp, dtype=int)
for i in range(num_taps_comp):
    val, _ = quantize_to_csd(h_comp_ideal[i], scale_comp, max_terms=3)
    h_comp_int[i] = val

# Enforce symmetry
for i in range(num_taps_comp // 2):
    h_comp_int[num_taps_comp - 1 - i] = h_comp_int[i]
h_comp_int[num_taps_comp // 2] += (scale_comp - np.sum(h_comp_int))
h_comp_q = h_comp_int / scale_comp

print("\n--- CIC Compensation FIR (9 taps, Fs = 192 kHz) ---")
for i in range(num_taps_comp):
    terms = to_csd(h_comp_int[i])
    print(f"h_comp[{i}] = {h_comp_int[i]:6d} / {scale_comp} = {h_comp_q[i]:+.6f} | CSD: {csd_to_string(terms)}")

# -------------------------------------------------------------
# Filter 3: Half-Band Decimation Stage 1 (192 kHz -> 96 kHz)
# -------------------------------------------------------------
num_taps_hb1 = 11
fp_hb1 = 20000 / 192000 # 0.104
fstop_hb1 = 0.5 - fp_hb1 # 0.396
h_hb1_raw = signal.remez(num_taps_hb1, [0, fp_hb1, fstop_hb1, 0.5], [1, 0], weight=[1, 1], fs=1.0)

mid1 = num_taps_hb1 // 2
for k in range(1, mid1 + 1):
    if k % 2 == 0:
        h_hb1_raw[mid1 - k] = 0.0
        h_hb1_raw[mid1 + k] = 0.0
h_hb1_raw[mid1] = 0.5
h_hb1_raw = h_hb1_raw / np.sum(h_hb1_raw)

scale_hb1 = 16384
h_hb1_int = np.zeros(num_taps_hb1, dtype=int)
for i in range(num_taps_hb1):
    val, _ = quantize_to_csd(h_hb1_raw[i], scale_hb1, max_terms=3)
    h_hb1_int[i] = val

for k in range(1, mid1 + 1):
    if k % 2 == 0:
        h_hb1_int[mid1 - k] = 0
        h_hb1_int[mid1 + k] = 0
    else:
        h_hb1_int[mid1 + k] = h_hb1_int[mid1 - k]
h_hb1_int[mid1] = scale_hb1 // 2

diff = scale_hb1 - np.sum(h_hb1_int)
if diff != 0:
    h_hb1_int[mid1 - 1] += diff // 2
    h_hb1_int[mid1 + 1] += diff // 2
h_hb1_q = h_hb1_int / scale_hb1

print("\n--- Half-Band Stage 1 FIR (11 taps, 192 kHz -> 96 kHz) ---")
for i in range(num_taps_hb1):
    terms = to_csd(h_hb1_int[i])
    print(f"h_hb1[{i:2d}] = {h_hb1_int[i]:6d} / {scale_hb1} = {h_hb1_q[i]:+.6f} | CSD: {csd_to_string(terms)}")

# -------------------------------------------------------------
# Filter 4: Half-Band Decimation Stage 2 (96 kHz -> 48 kHz)
# -------------------------------------------------------------
num_taps_hb2 = 23
fp_hb2 = 20000 / 96000 # 0.20833
fstop_hb2 = 0.5 - fp_hb2 # 0.29167
h_hb2_raw = signal.remez(num_taps_hb2, [0, fp_hb2, fstop_hb2, 0.5], [1, 0], weight=[1, 1], fs=1.0)

mid2 = num_taps_hb2 // 2
for k in range(1, mid2 + 1):
    if k % 2 == 0:
        h_hb2_raw[mid2 - k] = 0.0
        h_hb2_raw[mid2 + k] = 0.0
h_hb2_raw[mid2] = 0.5
h_hb2_raw = h_hb2_raw / np.sum(h_hb2_raw)

scale_hb2 = 16384
h_hb2_int = np.zeros(num_taps_hb2, dtype=int)
for i in range(num_taps_hb2):
    val, _ = quantize_to_csd(h_hb2_raw[i], scale_hb2, max_terms=3)
    h_hb2_int[i] = val

for k in range(1, mid2 + 1):
    if k % 2 == 0:
        h_hb2_int[mid2 - k] = 0
        h_hb2_int[mid2 + k] = 0
    else:
        h_hb2_int[mid2 + k] = h_hb2_int[mid2 - k]
h_hb2_int[mid2] = scale_hb2 // 2

diff2 = scale_hb2 - np.sum(h_hb2_int)
if diff2 != 0:
    h_hb2_int[mid2 - 1] += diff2 // 2
    h_hb2_int[mid2 + 1] += diff2 // 2
h_hb2_q = h_hb2_int / scale_hb2

print("\n--- Half-Band Stage 2 FIR (23 taps, 96 kHz -> 48 kHz) ---")
for i in range(num_taps_hb2):
    terms = to_csd(h_hb2_int[i])
    if h_hb2_int[i] != 0:
        print(f"h_hb2[{i:2d}] = {h_hb2_int[i]:6d} / {scale_hb2} = {h_hb2_q[i]:+.6f} | CSD: {csd_to_string(terms)}")

# Save to Verilog header
with open("rtl/include/filter_coeffs.vh", "w") as f:
    f.write("// Auto-generated Filter Coefficients Header\n")
    f.write(f"// CIC: R={R_cic}, N={N_cic}, DC Gain={G_cic}\n\n")
    
    f.write("// CIC Compensation Filter (9 taps, Q12, Scale=4096)\n")
    f.write(f"`define COMP_TAPS {num_taps_comp}\n")
    f.write("`define COMP_SCALE 4096\n")
    f.write("`define COMP_SHIFT 12\n")
    for i in range(num_taps_comp):
        f.write(f"`define H_COMP_{i} 16'sh{h_comp_int[i] & 0xFFFF:04X} // {h_comp_int[i]}\n")
    f.write("\n")
    
    f.write("// Half-Band Filter 1 (11 taps, Q14, Scale=16384)\n")
    f.write(f"`define HB1_TAPS {num_taps_hb1}\n")
    f.write("`define HB1_SCALE 16384\n")
    f.write("`define HB1_SHIFT 14\n")
    for i in range(num_taps_hb1):
        f.write(f"`define H_HB1_{i} 16'sh{h_hb1_int[i] & 0xFFFF:04X} // {h_hb1_int[i]}\n")
    f.write("\n")
    
    f.write("// Half-Band Filter 2 (23 taps, Q14, Scale=16384)\n")
    f.write(f"`define HB2_TAPS {num_taps_hb2}\n")
    f.write("`define HB2_SCALE 16384\n")
    f.write("`define HB2_SHIFT 14\n")
    for i in range(num_taps_hb2):
        f.write(f"`define H_HB2_{i} 16'sh{h_hb2_int[i] & 0xFFFF:04X} // {h_hb2_int[i]}\n")
    f.write("\n")

# -------------------------------------------------------------
# Compute & Plot Overall Frequency Response
# -------------------------------------------------------------
f_plot = np.linspace(10, 48000, 2000)

# 1. CIC response at f_plot (referred to input rate 3.072 MHz, normalized DC=1)
H_cic = (np.sin(np.pi * f_plot * R_cic / Fs_in) / (R_cic * np.sin(np.pi * f_plot / Fs_in))) ** N_cic

# 2. Compensation filter response (Fs = 192 kHz)
w_comp = 2 * np.pi * f_plot / Fs_cic
_, H_comp = signal.freqz(h_comp_q, 1, worN=w_comp)

# 3. HB1 response (Fs = 192 kHz)
w_hb1 = 2 * np.pi * f_plot / Fs_cic
_, H_hb1 = signal.freqz(h_hb1_q, 1, worN=w_hb1)

# 4. HB2 response (Fs = 96 kHz)
w_hb2 = 2 * np.pi * f_plot / 96000
_, H_hb2 = signal.freqz(h_hb2_q, 1, worN=w_hb2)

# Combined response
H_cascade = H_cic * H_comp * H_hb1 * H_hb2
mag_cic_db = 20 * np.log10(np.maximum(np.abs(H_cic), 1e-6))
mag_comp_db = 20 * np.log10(np.maximum(np.abs(H_comp), 1e-6))
mag_cascade_db = 20 * np.log10(np.maximum(np.abs(H_cascade), 1e-6))

# Plot full spectrum
fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 8))
ax1.plot(f_plot / 1000, mag_cic_db, 'r--', label='CIC Decimator (N=4, R=16)')
ax1.plot(f_plot / 1000, mag_comp_db, 'g:', label='CIC Compensation FIR')
ax1.plot(f_plot / 1000, mag_cascade_db, 'b-', linewidth=2, label='Total Cascaded Response')
ax1.set_title('PDM-to-PCM Decimation Chain Frequency Response (0 - 48 kHz)', fontsize=12, fontweight='bold')
ax1.set_xlabel('Frequency (kHz)')
ax1.set_ylabel('Magnitude (dB)')
ax1.set_xlim([0, 48])
ax1.set_ylim([-90, 5])
ax1.grid(True, linestyle='--', alpha=0.7)
ax1.legend(loc='lower left')

# Zoom into Passband (0 - 20 kHz)
mask_pb = f_plot <= 20000
f_pb_plot = f_plot[mask_pb] / 1000
ax2.plot(f_pb_plot, mag_cic_db[mask_pb], 'r--', label='Uncompensated CIC')
ax2.plot(f_pb_plot, 20*np.log10(np.maximum(np.abs(H_cic * H_comp)[mask_pb], 1e-6)), 'g-.', label='CIC + Compensation')
ax2.plot(f_pb_plot, mag_cascade_db[mask_pb], 'b-', linewidth=2, label='Total Passband Response')
ax2.set_title('Passband Detail (0 - 20 kHz, < 0.1 dB Ripple)', fontsize=12, fontweight='bold')
ax2.set_xlabel('Frequency (kHz)')
ax2.set_ylabel('Magnitude (dB)')
ax2.set_xlim([0, 20])
ax2.set_ylim([-0.5, 0.5])
ax2.grid(True, linestyle='--', alpha=0.7)
ax2.legend(loc='lower left')

os.makedirs('docs/plots', exist_ok=True)
os.makedirs('model', exist_ok=True)
plt.tight_layout()
plt.savefig('docs/plots/pipeline_frequency_response.png', dpi=300)
plt.close()

# Save coefficient arrays as npy for golden simulator
np.save("model/h_comp.npy", h_comp_int)
np.save("model/h_hb1.npy", h_hb1_int)
np.save("model/h_hb2.npy", h_hb2_int)

print("Saved plots to docs/plots/pipeline_frequency_response.png")
print("Saved coefficient arrays to model/")
