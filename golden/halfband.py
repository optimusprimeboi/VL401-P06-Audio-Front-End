"""
P6 Golden Model — Half-Band Filter Design
Designs two half-band FIR filters for the decimation chain:
  HB1: 192 kHz → 96 kHz
  HB2:  96 kHz → 48 kHz

Also generates folded (shared-MAC) and parallel coefficient tables
for RTL implementation comparison.

Reference: every other coefficient in a half-band filter is zero
(except the centre tap), so ~50% of multiplications are free.
"""

import numpy as np
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from params import *


# ─────────────────────────────────────────────────────────────────────────────
def design_halfband(n_taps: int,
                    fs: float,
                    f_pass: float,
                    coeff_bits: int = COEFF_BITS) -> dict:
    """
    Design a linear-phase half-band FIR filter.

    A true half-band filter has:
      - Passband  : [0,  f_pass]
      - Stopband  : [fs/2 - f_pass, fs/2]
      - Transition: [f_pass, fs/2 - f_pass]
      - Every even-indexed coefficient (except centre) = 0
      - Passband + stopband ripple are equal

    Strategy: use scipy.signal.firwin with transition width set by f_pass,
    then zero out even taps (enforce half-band property).

    Returns
    -------
    dict with keys: h_float, h_q, h_q_norm, n_taps, fs, f_pass,
                    nonzero_coeffs, zero_coeffs, folded_coeffs
    """
    from scipy.signal import firwin

    # Half-band: cutoff at fs/4, which is where H = 0.5
    cutoff = fs / 4.0
    # Use firwin (Kaiser window gives good stopband)
    h = firwin(n_taps, cutoff, window=("kaiser", 8.0), fs=fs)

    # Enforce exact zero on even-indexed non-centre taps (half-band property)
    centre = n_taps // 2
    for i in range(n_taps):
        if i != centre and (i - centre) % 2 == 0:
            h[i] = 0.0

    # Renormalise so DC gain = 1
    h /= np.sum(h)

    # Quantise
    scale = (2 ** (coeff_bits - 1)) - 1
    h_q   = np.round(h / np.max(np.abs(h)) * scale).astype(np.int32)

    # Force exact zeros in quantised version too
    for i in range(n_taps):
        if i != centre and (i - centre) % 2 == 0:
            h_q[i] = 0

    # Unique non-zero coefficients (exploit symmetry + zeros)
    # For a symmetric half-band of N taps, unique non-zero = (N//4) + 1 (centre)
    nonzero_idx   = [i for i in range(n_taps) if h_q[i] != 0]
    unique_nz_idx = [i for i in nonzero_idx if i <= centre]   # left half + centre

    folded = h_q[unique_nz_idx]  # coefficients used in folded (shared MAC) impl.

    return {
        "h_float"      : h,
        "h_q"          : h_q,
        "h_q_norm"     : h_q.astype(float) / scale,
        "scale"        : scale,
        "n_taps"       : n_taps,
        "fs"           : fs,
        "f_pass"       : f_pass,
        "centre_idx"   : centre,
        "nonzero_idx"  : nonzero_idx,
        "unique_nz"    : unique_nz_idx,
        "folded_coeffs": folded,      # for folded shared-MAC RTL
        "n_nonzero"    : len(nonzero_idx),
        "n_zero"       : n_taps - len(nonzero_idx),
        "n_unique_mults": len(unique_nz_idx),  # multiplications in folded impl.
    }


def halfband_frequency_response(design: dict, n_points: int = 4096) -> tuple:
    """Return (frequencies_Hz, magnitude_dB) for a designed half-band."""
    from scipy.signal import freqz
    fs = design["fs"]
    w, H = freqz(design["h_float"], worN=n_points, fs=fs)
    return w, 20 * np.log10(np.abs(H) + 1e-12)


def measure_stopband_attenuation(design: dict) -> float:
    """Return minimum stopband attenuation (dB, positive value)."""
    from scipy.signal import freqz
    fs     = design["fs"]
    f_stop = fs / 2 - design["f_pass"]
    w, H   = freqz(design["h_float"], worN=16384, fs=fs)
    mask   = w >= f_stop
    return -np.max(20 * np.log10(np.abs(H[mask]) + 1e-12))


def apply_halfband(data: np.ndarray, design: dict) -> np.ndarray:
    """Apply HB filter and decimate by 2 (exact bit-accurate integer arithmetic matching RTL)."""
    h_q = design["h_q"].astype(np.int64)
    n_taps = len(h_q)
    shift = COEFF_FRAC # 15
    round_const = 1 << (shift - 1)

    padded = np.concatenate([np.zeros(n_taps - 1, dtype=np.int64), data.astype(np.int64)])
    acc = np.convolve(padded, h_q, mode='valid')
    shifted = (acc + round_const) >> shift
    out_all = np.clip(shifted, -(1 << 23), (1 << 23) - 1).astype(np.int32)
    decimated = out_all[::2] # Downsample by 2
    return decimated


def save_halfband_vectors(out: np.ndarray, stage: int,
                          design: dict, out_dir: str = None):
    """Save HB output samples and coefficient ROM init file."""
    if out_dir is None:
        out_dir = os.path.join(os.path.dirname(__file__), VEC_DIR)
    os.makedirs(out_dir, exist_ok=True)

    # Output samples
    spath = os.path.join(out_dir, f"hb{stage}_out.hex")
    with open(spath, "w") as fh:
        for s in out:
            fh.write(f"{int(s) & 0xFFFFFF:06x}\n")

    # Folded coefficients (unique non-zero, for shared-MAC ROM)
    cpath = os.path.join(out_dir, f"hb{stage}_coeffs_folded.hex")
    with open(cpath, "w") as fh:
        for c in design["folded_coeffs"]:
            fh.write(f"{int(c) & 0xFFFF:04x}\n")

    # Full coefficient array (for parallel/direct-form ROM)
    ppath = os.path.join(out_dir, f"hb{stage}_coeffs_parallel.hex")
    with open(ppath, "w") as fh:
        for c in design["h_q"]:
            fh.write(f"{int(c) & 0xFFFF:04x}\n")

    print(f"[halfband] HB{stage}: {len(out)} samples → {spath}")
    print(f"           Non-zero taps: {design['n_nonzero']}/{design['n_taps']}, "
          f"unique multiplications: {design['n_unique_mults']}")
    print(f"           Folded coeffs: {design['folded_coeffs']}")


# ─────────────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import matplotlib.pyplot as plt
    from cic_model import cic_decimate, save_cic_vectors
    from comp_fir  import design_comp_fir, apply_comp_fir, save_comp_vectors
    from pdm_gen   import make_test_pdm, save_pdm_vectors

    vec_dir = os.path.join(os.path.dirname(__file__), VEC_DIR)

    # ── Load or build pipeline up to comp FIR ────────────────────────────────
    pdm_txt  = os.path.join(vec_dir, "pdm_test.txt")
    comp_hex = os.path.join(vec_dir, "comp_fir_out.hex")

    if os.path.exists(comp_hex):
        comp_out = np.array([int(l, 16) for l in open(comp_hex)], dtype=np.int32)
        comp_out = np.where(comp_out >= (1<<23), comp_out - (1<<24), comp_out)
    else:
        if os.path.exists(pdm_txt):
            pdm = np.loadtxt(pdm_txt, dtype=np.uint8)
        else:
            _, pdm = make_test_pdm(); save_pdm_vectors(pdm)
        cic_out = cic_decimate(pdm); save_cic_vectors(cic_out)
        d       = design_comp_fir(); comp_out = apply_comp_fir(cic_out, d["h_q"])
        save_comp_vectors(comp_out, d["h_q"])

    # ── Design and apply HB1 ──────────────────────────────────────────────────
    print(f"[halfband] Designing HB1 ({HB1_NTAPS} taps, Fs={HB1_FS/1e3:.0f} kHz) …")
    hb1    = design_halfband(HB1_NTAPS, HB1_FS, HB1_FPASS)
    hb1_sb = measure_stopband_attenuation(hb1)
    print(f"           Stopband attenuation: {hb1_sb:.1f} dB")
    hb1_out = apply_halfband(comp_out, hb1)
    save_halfband_vectors(hb1_out, 1, hb1)

    # ── Design and apply HB2 ──────────────────────────────────────────────────
    print(f"[halfband] Designing HB2 ({HB2_NTAPS} taps, Fs={HB2_FS/1e3:.0f} kHz) …")
    hb2    = design_halfband(HB2_NTAPS, HB2_FS, HB2_FPASS)
    hb2_sb = measure_stopband_attenuation(hb2)
    print(f"           Stopband attenuation: {hb2_sb:.1f} dB")
    hb2_out = apply_halfband(hb1_out, hb2)
    save_halfband_vectors(hb2_out, 2, hb2)

    # Final: truncate to 16-bit PCM
    pcm_out = np.clip(
        np.round(hb2_out.astype(float) / (1<<8)),   # 24→16 bit
        -32768, 32767
    ).astype(np.int16)
    pcm_path = os.path.join(vec_dir, "pcm_out.hex")
    with open(pcm_path, "w") as fh:
        for s in pcm_out:
            fh.write(f"{int(s) & 0xFFFF:04x}\n")
    print(f"[halfband] PCM output: {len(pcm_out)} samples @ {F_AUDIO_OUT/1e3:.0f} kHz → {pcm_path}")

    # ── Plots ─────────────────────────────────────────────────────────────────
    fig, axes = plt.subplots(2, 2, figsize=(14, 9))
    fig.suptitle("Half-Band Filters", fontsize=13, fontweight="bold")

    for ax, design, stage, label in [
        (axes[0,0], hb1, 1, f"HB1 (192→96 kHz)"),
        (axes[0,1], hb2, 2, f"HB2 (96→48 kHz)"),
    ]:
        f_resp, H_resp = halfband_frequency_response(design)
        ax.plot(f_resp/1e3, H_resp, linewidth=1.2)
        ax.axvline(design["f_pass"]/1e3, color="r", linestyle="--",
                   label=f"Passband {design['f_pass']/1e3:.0f} kHz")
        ax.axhline(-3, color="g", linestyle=":", label="-3 dB")
        ax.axhline(-80, color="orange", linestyle=":", label="-80 dB")
        ax.set(xlabel="Frequency (kHz)", ylabel="dB",
               title=f"{label}  (stopband: {measure_stopband_attenuation(design):.0f} dB)",
               ylim=(-120, 5))
        ax.legend(fontsize=8); ax.grid(True, alpha=0.4)

    for ax, design, stage in [
        (axes[1,0], hb1, 1),
        (axes[1,1], hb2, 2),
    ]:
        coeffs = design["h_q"]
        colors = ["C1" if v == 0 else "C0" for v in coeffs]
        ax.bar(range(len(coeffs)), coeffs, color=colors)
        ax.set(xlabel="Tap index", ylabel="Value (int16)",
               title=f"HB{stage} Coefficients  "
                     f"(zeros={design['n_zero']}, non-zero={design['n_nonzero']})")
        ax.grid(True, alpha=0.4, axis="y")

    plt.tight_layout()
    fig_path = os.path.join(vec_dir, "halfband_design.png")
    plt.savefig(fig_path, dpi=150)
    plt.show()
    print(f"[halfband] Saved plot → {fig_path}")
