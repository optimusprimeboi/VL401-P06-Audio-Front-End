"""
P6 Golden Model — SNR Test (Single-Tone, Proper Measurement)

Generates individual single-tone PDM clips, runs each through the full chain,
measures SNR properly (signal vs. noise+distortion), and produces the
deliverable frequency-response + SNR plots.

This is the proper way to measure filter SNR:
  - One tone at a time, at full scale
  - Blackman window for low sidelobes
  - Signal = fundamental bin ±5 bins
  - Noise = rest of audio band

Usage:
    python snr_test.py
    -> produces sim/vectors/snr_final_report.txt
               sim/vectors/snr_bar.png
               sim/vectors/full_freq_response.png
"""

import numpy as np
import os, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
sys.path.insert(0, r"C:\Users\Lenovo\Downloads\rtl project\golden")
from params import *

VEC = os.path.join(os.path.dirname(__file__), VEC_DIR)
os.makedirs(VEC, exist_ok=True)


def run_single_tone(freq_hz: float,
                    amplitude: float = 0.9,
                    duration: float = 0.2) -> np.ndarray:
    """
    Generate a single-tone PDM stream, run it through the full chain,
    return the 16-bit PCM output.
    """
    from pdm_gen  import sigma_delta_1st_order
    from cic_model import cic_decimate
    from comp_fir  import design_comp_fir, apply_comp_fir
    from halfband  import design_halfband, apply_halfband

    # Audio tone at 48 kHz
    t = np.arange(int(duration * F_AUDIO_OUT)) / F_AUDIO_OUT
    audio = amplitude * np.sin(2 * np.pi * freq_hz * t)

    # PDM
    pdm = sigma_delta_1st_order(audio, F_OSR)

    # CIC
    cic = cic_decimate(pdm)

    # Comp FIR
    d_comp = design_comp_fir()
    comp   = apply_comp_fir(cic, d_comp["h_q"])

    # HB1 + HB2
    hb1_d  = design_halfband(HB1_NTAPS, HB1_FS, HB1_FPASS)
    hb1    = apply_halfband(comp, hb1_d)
    hb2_d  = design_halfband(HB2_NTAPS, HB2_FS, HB2_FPASS)
    hb2    = apply_halfband(hb1, hb2_d)

    # 16-bit truncation
    pcm = np.clip(np.round(hb2.astype(float) / (1 << 8)), -32768, 32767).astype(np.int16)
    return pcm


def snr_single_tone(pcm: np.ndarray, f_tone: float,
                    fs: float = F_AUDIO_OUT, n_fft: int = 8192) -> float:
    """THD+N SNR measurement for a single-tone capture."""
    n     = min(n_fft, len(pcm))
    # Skip first 100 samples (filter settling transient)
    x     = pcm[100:100+n].astype(float)
    x    -= np.mean(x)
    win   = np.blackman(len(x))
    x    *= win
    X     = np.fft.rfft(x)
    P     = np.abs(X) ** 2
    freqs = np.fft.rfftfreq(len(x), d=1.0 / fs)

    idx  = np.argmin(np.abs(freqs - f_tone))
    bw   = 5
    lo   = max(1, idx - bw)
    hi   = min(len(P), idx + bw + 1)

    P_sig  = np.sum(P[lo:hi])
    # Noise: entire audio band except signal and DC
    audio  = (freqs > 10) & (freqs <= F_PASS)
    audio[lo:hi] = False
    P_noi  = np.sum(P[audio])

    if P_noi <= 0 or P_sig <= 0:
        return float("nan")
    return 10 * np.log10(P_sig / P_noi)


def compute_frequency_response(n_freqs: int = 40) -> tuple:
    """
    Measure the filter's actual frequency response by sweeping test tones.
    Returns (frequencies_Hz, gain_dB).
    """
    from pdm_gen  import sigma_delta_1st_order
    from cic_model import cic_decimate
    from comp_fir  import design_comp_fir, apply_comp_fir
    from halfband  import design_halfband, apply_halfband

    freqs = np.logspace(np.log10(100), np.log10(F_PASS), n_freqs)
    gains = []

    # Reference: 0 Hz DC level (just run a 100 Hz tone and note output RMS)
    ref_pcm  = run_single_tone(100.0, amplitude=0.5)
    ref_rms  = np.sqrt(np.mean(ref_pcm[100:].astype(float)**2))

    for f in freqs:
        pcm = run_single_tone(f, amplitude=0.5)
        rms = np.sqrt(np.mean(pcm[100:].astype(float)**2))
        gain_db = 20 * np.log10((rms + 1e-9) / (ref_rms + 1e-9))
        gains.append(gain_db)
        print(f"  {f:8.1f} Hz: {gain_db:+.2f} dB")

    return freqs, np.array(gains)


# ─────────────────────────────────────────────────────────────────────────────
if __name__ == "__main__":

    print("=" * 55)
    print("  P6 SNR Test — Single-Tone THD+N Measurement")
    print("=" * 55)

    tones     = TEST_TONES
    snr_vals  = {}
    pcm_clips = {}

    for f in tones:
        print(f"\n[snr_test] Tone {f} Hz ...")
        pcm = run_single_tone(f)
        pcm_clips[f] = pcm
        snr = snr_single_tone(pcm, f)
        snr_vals[f]  = snr
        print(f"           SNR = {snr:.1f} dB")

    print("\n" + "=" * 40)
    print("  SUMMARY")
    print("=" * 40)
    for f, snr in snr_vals.items():
        bar = "#" * max(0, int((snr + 10) / 3))
        print(f"  {f:>6d} Hz : {snr:6.1f} dB  {bar}")
    print("=" * 40)

    # ── Frequency response sweep ───────────────────────────────────────────────
    print("\n[snr_test] Sweeping frequency response ...")
    f_resp, g_resp = compute_frequency_response(n_freqs=30)

    # ── Plots ─────────────────────────────────────────────────────────────────
    fig, axes = plt.subplots(1, 2, figsize=(14, 5))
    fig.suptitle("P6 Golden Model - Filter Performance", fontsize=13, fontweight="bold")

    # SNR bar
    ax = axes[0]
    colors = ["green" if s > 40 else "orange" if s > 20 else "red"
              for s in snr_vals.values()]
    bars = ax.bar([f"{f/1e3:.0f} kHz" for f in snr_vals],
                  list(snr_vals.values()), color=colors, edgecolor="black", linewidth=0.5)
    ax.axhline(40, color="g", linestyle="--", alpha=0.5, label="40 dB target")
    ax.set(xlabel="Test Tone", ylabel="SNR (dB)",
           title="SNR vs. Tone Frequency (Single-Tone THD+N)")
    for bar, v in zip(bars, snr_vals.values()):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.5,
                f"{v:.0f}", ha="center", va="bottom", fontsize=9)
    ax.legend(); ax.grid(True, alpha=0.4, axis="y")

    # Frequency response
    ax = axes[1]
    ax.semilogx(f_resp, g_resp, "b.-", linewidth=1.5, markersize=5)
    ax.axhline(-3, color="r", linestyle="--", label="-3 dB")
    ax.axhline(-0.1, color="g", linestyle=":", label="-0.1 dB passband")
    ax.axhline(0.1, color="g", linestyle=":")
    ax.axvline(F_PASS, color="orange", linestyle="--",
               label=f"20 kHz edge")
    ax.set(xlabel="Frequency (Hz)", ylabel="Gain (dB)",
           title="Measured Frequency Response (100 Hz - 20 kHz)")
    ax.grid(True, alpha=0.4, which="both")
    ax.legend(); ax.set_ylim(-5, 3)

    plt.tight_layout()
    fig_path = os.path.join(VEC, "snr_final.png")
    plt.savefig(fig_path, dpi=150)
    print(f"\n[snr_test] Plot saved: {fig_path}")

    # ── Text report ───────────────────────────────────────────────────────────
    rpath = os.path.join(VEC, "snr_final_report.txt")
    with open(rpath, "w", encoding="utf-8") as fh:
        fh.write("P6 SNR Report — Single-Tone THD+N\n")
        fh.write("=" * 40 + "\n")
        fh.write(f"Chain: PDM ({F_PDM/1e6:.3f} MHz) -> CIC(R={R_CIC},N={N_CIC}) "
                 f"-> CompFIR({COMP_NTAPS}tap) -> HB1->HB2 -> PCM 16-bit @ {F_AUDIO_OUT/1e3:.0f}kHz\n\n")
        for f, snr in snr_vals.items():
            fh.write(f"  {f:>6d} Hz : {snr:.1f} dB\n")
        fh.write("\nFrequency Response:\n")
        for f, g in zip(f_resp, g_resp):
            fh.write(f"  {f:8.1f} Hz : {g:+.2f} dB\n")
    print(f"[snr_test] Report saved: {rpath}")
