"""
P6 Golden Model — PDM Generator
Implements a 1st-order sigma-delta modulator to synthesise a 1-bit PDM stream
from a band-limited audio signal.

Usage:
    python pdm_gen.py
    → produces sim/vectors/pdm_test.bin and sim/vectors/pdm_test.hex
"""

from __future__ import annotations
import numpy as np
import os, sys
from typing import Tuple
sys.path.insert(0, os.path.dirname(__file__))
from params import *

# ─────────────────────────────────────────────────────────────────────────────
def sigma_delta_1st_order(audio_48k: np.ndarray, osr: int = F_OSR) -> np.ndarray:
    """
    1st-order sigma-delta modulator.

    Upsamples audio_48k by `osr` (zero-insertion + LP filter) then runs the
    SDM loop to produce a 1-bit PDM stream at F_PDM = 48kHz × osr.

    Parameters
    ----------
    audio_48k : float array, samples in [-1.0, +1.0], at 48 kHz
    osr       : oversampling ratio (default 64 → 3.072 MHz output)

    Returns
    -------
    pdm : uint8 array of 0/1 values at F_PDM
    """
    from scipy.signal import firwin, lfilter

    # ── 1. Upsample: insert zeros ─────────────────────────────────────────────
    n_in   = len(audio_48k)
    n_up   = n_in * osr
    up     = np.zeros(n_up)
    up[::osr] = audio_48k * osr   # scale to preserve energy after filtering

    # ── 2. Anti-imaging LP filter (simple FIR, passband = 20 kHz / F_PDM) ────
    n_taps = 127
    cutoff = F_PASS / (F_PDM / 2)          # normalised Nyquist = 1
    lp     = firwin(n_taps, cutoff)
    up_filt = lfilter(lp, 1.0, up)

    # ── 3. Sigma-delta loop ───────────────────────────────────────────────────
    pdm  = np.zeros(n_up, dtype=np.uint8)
    integrator = 0.0

    for i in range(n_up):
        integrator += up_filt[i]
        if integrator >= 0.0:
            pdm[i]     = 1
            integrator -= 1.0
        else:
            pdm[i]     = 0
            integrator += 1.0

    return pdm


def make_test_pdm(
    tones: list = TEST_TONES,
    duration: float = TEST_DURATION_S,
    amplitude: float = 0.5,
    fs_audio: int = F_AUDIO_OUT,
    osr: int = F_OSR,
    seed: int = 0,
    add_noise: bool = True,
    noise_floor_db: float = -80.0
) -> Tuple[np.ndarray, np.ndarray]:
    """
    Build a multi-tone test signal and convert to PDM.

    Returns (audio_48k, pdm_stream) both as numpy arrays.
    """
    rng   = np.random.default_rng(seed)
    t     = np.arange(int(duration * fs_audio)) / fs_audio
    audio = np.zeros_like(t)

    for f in tones:
        phase = rng.uniform(0, 2 * np.pi)
        audio += amplitude / len(tones) * np.sin(2 * np.pi * f * t + phase)

    if add_noise:
        noise_amp = 10 ** (noise_floor_db / 20)
        audio    += noise_amp * rng.standard_normal(len(t))

    # clip to [-1, +1]
    audio = np.clip(audio, -1.0, 1.0)
    pdm   = sigma_delta_1st_order(audio, osr)
    return audio, pdm


def save_pdm_vectors(pdm: np.ndarray, out_dir: str = None):
    """
    Save PDM stream as:
      - .bin  : raw bytes (8 PDM bits packed per byte, MSB first)
      - .hex  : $readmemh-compatible, one byte per line (for BRAM init)
      - .txt  : one bit per line (for simple Verilog $readmemb)
    """
    if out_dir is None:
        out_dir = os.path.join(os.path.dirname(__file__), VEC_DIR)
    os.makedirs(out_dir, exist_ok=True)

    # ── pack bits into bytes ──────────────────────────────────────────────────
    n_pad  = (8 - len(pdm) % 8) % 8
    padded = np.concatenate([pdm, np.zeros(n_pad, dtype=np.uint8)])
    packed = np.packbits(padded)           # MSB first

    base = os.path.join(out_dir, "pdm_test")
    packed.tofile(base + ".bin")

    with open(base + ".hex", "w") as fh:
        for b in packed:
            fh.write(f"{b:02x}\n")

    with open(base + ".txt", "w") as ft:
        for bit in pdm:
            ft.write(f"{int(bit)}\n")

    print(f"[pdm_gen] Saved {len(pdm)} PDM bits -> {base}.(bin/hex/txt)")
    return base


# ─────────────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import matplotlib.pyplot as plt

    print(f"[pdm_gen] Generating {TEST_DURATION_S}s multi-tone PDM stream")
    print(f"          Tones : {TEST_TONES} Hz")
    print(f"          Fs_pdm: {F_PDM/1e6:.3f} MHz  (OSR={F_OSR}×{F_AUDIO_OUT} Hz)")

    audio, pdm = make_test_pdm()
    out_base   = save_pdm_vectors(pdm)

    # ── quick spectrum check ──────────────────────────────────────────────────
    n_fft  = 4096
    window = np.hanning(n_fft)
    chunk  = pdm[:n_fft].astype(float) * 2 - 1   # map {0,1} → {-1,+1}
    spec   = 20 * np.log10(np.abs(np.fft.rfft(chunk * window)) + 1e-12)
    freqs  = np.fft.rfftfreq(n_fft, d=1.0 / F_PDM)

    fig, axes = plt.subplots(2, 1, figsize=(12, 7))
    fig.suptitle("PDM Generator Output", fontsize=13, fontweight="bold")

    axes[0].plot(np.arange(len(audio)) / F_AUDIO_OUT * 1e3, audio, linewidth=0.5)
    axes[0].set(xlabel="Time (ms)", ylabel="Amplitude", title="Audio Input (48 kHz)")
    axes[0].grid(True, alpha=0.4)

    axes[1].plot(freqs / 1e3, spec, linewidth=0.5)
    axes[1].axvline(F_PASS / 1e3, color="r", linestyle="--", label=f"Passband edge {F_PASS/1e3} kHz")
    axes[1].set(xlabel="Frequency (kHz)", ylabel="dBFS", title="PDM Spectrum (first 4096 bits)")
    axes[1].set_xlim(0, F_PDM / 2e3)
    axes[1].set_ylim(-100, 10)
    axes[1].legend()
    axes[1].grid(True, alpha=0.4)

    plt.tight_layout()
    out_fig = os.path.join(os.path.dirname(out_base), "pdm_spectrum.png")
    plt.savefig(out_fig, dpi=150)
    plt.show()
    print(f"[pdm_gen] Saved spectrum → {out_fig}")
