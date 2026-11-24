"""
P6 Golden Model — Full Chain Runner + SNR Measurement

Runs the complete PDM → CIC → Comp FIR → HB1 → HB2 → PCM pipeline,
computes SNR vs. an ideal reference, and generates all test vectors
needed by the RTL testbenches in one shot.

Deliverable output:
  - sim/vectors/pdm_test.(txt/hex/bin)
  - sim/vectors/cic_out.hex
  - sim/vectors/comp_fir_out.hex
  - sim/vectors/hb1_out.hex
  - sim/vectors/hb2_out.hex
  - sim/vectors/pcm_out.hex
  - sim/vectors/snr_report.txt
  - sim/vectors/chain_response.png

Usage:
    python chain.py
"""

import numpy as np
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from params import *

VEC = os.path.join(os.path.dirname(__file__), VEC_DIR)
os.makedirs(VEC, exist_ok=True)


def _load_or_compute(path: str, bits: int, compute_fn):
    """Helper: load hex vector if exists, else compute and save."""
    if os.path.exists(path):
        raw = np.array([int(l.strip(), 16) for l in open(path) if l.strip()],
                       dtype=np.int64)
        mask = (1 << (bits - 1))
        raw  = np.where(raw >= mask, raw - (1 << bits), raw)
        return raw.astype(np.int32)
    return compute_fn()


def run_full_chain(force: bool = False) -> dict:
    """
    Run entire decimation chain. Returns dict of all intermediate signals.
    Set force=True to recompute even if vectors exist.
    """
    from pdm_gen  import make_test_pdm, save_pdm_vectors
    from cic_model import cic_decimate, save_cic_vectors
    from comp_fir  import design_comp_fir, apply_comp_fir, save_comp_vectors
    from halfband  import design_halfband, apply_halfband, save_halfband_vectors

    print("=" * 60)
    print("  P6 FULL CHAIN — Golden Model Run")
    print("=" * 60)

    # ── Step 0: Generate PDM ──────────────────────────────────────────────────
    pdm_path = os.path.join(VEC, "pdm_test.txt")
    if force or not os.path.exists(pdm_path):
        print("[chain] Generating multi-tone PDM stream …")
        audio, pdm = make_test_pdm()
        save_pdm_vectors(pdm)
    else:
        print("[chain] Loading existing PDM vectors …")
        pdm   = np.loadtxt(pdm_path, dtype=np.uint8)
        audio = None

    # ── Step 1: CIC decimation ────────────────────────────────────────────────
    print(f"[chain] CIC decimation (R={R_CIC}, N={N_CIC}) …")
    cic_path = os.path.join(VEC, "cic_out.hex")
    if force or not os.path.exists(cic_path):
        cic_out = cic_decimate(pdm)
        save_cic_vectors(cic_out)
    else:
        cic_out = _load_or_compute(cic_path, 24, lambda: cic_decimate(pdm))
    print(f"         {len(pdm)} bits → {len(cic_out)} samples @ {F_CIC_OUT/1e3:.0f} kHz")

    # ── Step 2: CIC Compensation FIR ─────────────────────────────────────────
    print(f"[chain] CIC Compensation FIR ({COMP_NTAPS} taps) …")
    comp_path = os.path.join(VEC, "comp_fir_out.hex")
    comp_design = design_comp_fir()
    if force or not os.path.exists(comp_path):
        comp_out = apply_comp_fir(cic_out, comp_design["h_q"])
        save_comp_vectors(comp_out, comp_design["h_q"])
    else:
        comp_out = _load_or_compute(comp_path, 24, lambda: apply_comp_fir(cic_out, comp_design["h_q"]))

    # ── Step 3: Half-Band 1 (÷2, 192→96 kHz) ────────────────────────────────
    print(f"[chain] HB1 filter (÷2, {HB1_FS/1e3:.0f}→{HB1_FS/2e3:.0f} kHz) …")
    hb1_design = design_halfband(HB1_NTAPS, HB1_FS, HB1_FPASS)
    hb1_path   = os.path.join(VEC, "hb1_out.hex")
    if force or not os.path.exists(hb1_path):
        hb1_out = apply_halfband(comp_out, hb1_design)
        save_halfband_vectors(hb1_out, 1, hb1_design)
    else:
        hb1_out = _load_or_compute(hb1_path, 24, lambda: apply_halfband(comp_out, hb1_design))

    # ── Step 4: Half-Band 2 (÷2, 96→48 kHz) ─────────────────────────────────
    print(f"[chain] HB2 filter (÷2, {HB2_FS/1e3:.0f}→{HB2_FS/2e3:.0f} kHz) …")
    hb2_design = design_halfband(HB2_NTAPS, HB2_FS, HB2_FPASS)
    hb2_path   = os.path.join(VEC, "hb2_out.hex")
    if force or not os.path.exists(hb2_path):
        hb2_out = apply_halfband(hb1_out, hb2_design)
        save_halfband_vectors(hb2_out, 2, hb2_design)
    else:
        hb2_out = _load_or_compute(hb2_path, 24, lambda: apply_halfband(hb1_out, hb2_design))

    # ── Step 5: Truncate to 16-bit PCM ───────────────────────────────────────
    pcm_out = np.clip(
        np.round(hb2_out.astype(float) / (1 << 8)),
        -32768, 32767
    ).astype(np.int16)

    pcm_path = os.path.join(VEC, "pcm_out.hex")
    with open(pcm_path, "w") as fh:
        for s in pcm_out:
            fh.write(f"{int(s) & 0xFFFF:04x}\n")
    print(f"[chain] PCM output: {len(pcm_out)} samples @ {F_AUDIO_OUT/1e3:.0f} kHz → {pcm_path}")

    return {
        "pdm"      : pdm,
        "audio"    : audio,
        "cic_out"  : cic_out,
        "comp_out" : comp_out,
        "hb1_out"  : hb1_out,
        "hb2_out"  : hb2_out,
        "pcm_out"  : pcm_out,
        "hb1_design": hb1_design,
        "hb2_design": hb2_design,
        "comp_design": comp_design,
    }


# ─────────────────────────────────────────────────────────────────────────────
def measure_snr(pcm_out: np.ndarray,
                tones: list = TEST_TONES,
                fs: float = F_AUDIO_OUT,
                n_fft: int = 8192) -> dict:
    """
    Measure SNR for each test tone.

    Strategy (single-tone THD+N method, Blackman window):
      - For each tone: signal power = 5 bins centred on fundamental
      - Noise+distortion = rest of audio band excluding DC
      - SNR (dB) = 10*log10(signal_power / noise_power)

    Returns dict: { tone_hz: snr_db, ... }
    """
    n     = min(n_fft, len(pcm_out))
    win   = np.blackman(n)
    x     = pcm_out[:n].astype(float)
    x    -= np.mean(x)       # remove DC
    x    *= win
    X     = np.fft.rfft(x)
    P     = np.abs(X) ** 2
    freqs = np.fft.rfftfreq(n, d=1.0 / fs)

    # Audio band: skip DC, go up to F_PASS
    audio_mask = (freqs > 10) & (freqs <= F_PASS)

    results = {}
    for f_tone in tones:
        idx  = np.argmin(np.abs(freqs - f_tone))
        bw   = 5                 # +/-5 bins for signal capture
        lo   = max(1, idx - bw)
        hi   = min(len(P) - 1, idx + bw + 1)
        P_sig = np.sum(P[lo:hi])

        # Noise = audio band minus signal bins
        noise_mask = audio_mask.copy()
        noise_mask[lo:hi] = False
        P_noi = np.sum(P[noise_mask])

        snr = 10 * np.log10(P_sig / P_noi) if (P_noi > 0 and P_sig > 0) else float("nan")
        results[f_tone] = snr
        print(f"  SNR @ {f_tone:>6d} Hz : {snr:6.1f} dB")

    return results


def write_snr_report(snr_results: dict, chain: dict, path: str):
    lines = [
        "=" * 50,
        "P6 PDM-to-PCM Golden Model — SNR Report",
        "=" * 50,
        f"Chain: PDM ({F_PDM/1e6:.3f} MHz, 1-bit)",
        f"  → CIC (R={R_CIC}, N={N_CIC}, M={M_CIC}) → {F_CIC_OUT/1e3:.0f} kHz",
        f"  → Comp FIR ({COMP_NTAPS} taps) → {F_CIC_OUT/1e3:.0f} kHz",
        f"  → HB1 (÷2) → {F_HB1_OUT/1e3:.0f} kHz",
        f"  → HB2 (÷2) → {F_HB2_OUT/1e3:.0f} kHz PCM 16-bit",
        "",
        "SNR Results:",
    ]
    for f_tone, snr in snr_results.items():
        lines.append(f"  {f_tone:>6d} Hz : {snr:.1f} dB")

    lines += [
        "",
        "Comp FIR (non-zero unique coefficients):",
        f"  {chain['comp_design']['h_q'][:(COMP_NTAPS+1)//2].tolist()}",
        "",
        "HB1 (folded non-zero coefficients):",
        f"  {chain['hb1_design']['folded_coeffs'].tolist()}",
        "",
        "HB2 (folded non-zero coefficients):",
        f"  {chain['hb2_design']['folded_coeffs'].tolist()}",
        "=" * 50,
    ]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    print(f"[chain] SNR report saved: {path}")


# ─────────────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import matplotlib.pyplot as plt

    chain = run_full_chain(force=False)

    # ── SNR Measurement ───────────────────────────────────────────────────────
    print("\n[chain] Measuring SNR …")
    snr = measure_snr(chain["pcm_out"])
    report_path = os.path.join(VEC, "snr_report.txt")
    write_snr_report(snr, chain, report_path)

    # ── Full Chain Plot ────────────────────────────────────────────────────────
    fig, axes = plt.subplots(3, 2, figsize=(14, 12))
    fig.suptitle("P6 Full Decimation Chain — Spectra at Each Stage",
                 fontsize=13, fontweight="bold")

    stage_data = [
        (chain["cic_out"],  F_CIC_OUT,  "After CIC  (192 kHz)"),
        (chain["comp_out"], F_CIC_OUT,  "After Comp FIR  (192 kHz)"),
        (chain["hb1_out"],  F_HB1_OUT,  "After HB1  (96 kHz)"),
        (chain["hb2_out"],  F_HB2_OUT,  "After HB2  (48 kHz)"),
        (chain["pcm_out"].astype(np.int32), F_AUDIO_OUT, "PCM Output  16-bit (48 kHz)"),
    ]

    for ax, (data, fs, title) in zip(axes.flat, stage_data):
        n_fft = min(4096, len(data))
        win   = np.hanning(n_fft)
        spec  = 20 * np.log10(
                    np.abs(np.fft.rfft(data[:n_fft].astype(float) * win)) + 1e-9)
        freqs = np.fft.rfftfreq(n_fft, d=1.0/fs) / 1e3
        ax.plot(freqs, spec, linewidth=0.8)
        ax.axvline(F_PASS/1e3, color="r", linestyle="--", alpha=0.7,
                   label=f"{F_PASS/1e3:.0f} kHz edge")
        ax.set(xlabel="Frequency (kHz)", ylabel="dBFS", title=title)
        ax.set_ylim(-120, 10)
        ax.legend(fontsize=8); ax.grid(True, alpha=0.4)

    # Last subplot: SNR bar chart
    ax = axes.flat[5]
    tones = list(snr.keys())
    snr_v = list(snr.values())
    ax.bar([f"{f/1e3:.0f} kHz" for f in tones], snr_v, color="steelblue")
    ax.set(ylabel="SNR (dB)", title="SNR per Tone vs. Golden Model")
    ax.grid(True, alpha=0.4, axis="y")
    for i, v in enumerate(snr_v):
        ax.text(i, v + 0.5, f"{v:.0f}", ha="center", fontsize=9)

    plt.tight_layout()
    fig_path = os.path.join(VEC, "chain_response.png")
    plt.savefig(fig_path, dpi=150)
    plt.show()
    print(f"[chain] Saved plot → {fig_path}")
