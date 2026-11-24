"""
P6 Golden Model — Bit-Exact CIC Decimator
Implements the Hogenauer CIC filter in Python with intentional fixed-point
integer arithmetic so the output matches RTL bit-for-bit.

Reference: E.B. Hogenauer, "An economical class of digital filters for
           decimation and interpolation," IEEE TASP 29(2):155-162, 1981.

Usage:
    python cic_model.py
    → processes sim/vectors/pdm_test.txt and produces sim/vectors/cic_out.hex
"""

import numpy as np
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from params import *

# ─────────────────────────────────────────────────────────────────────────────
# CIC internal register width (must match RTL)
# B_in=1 (PDM mapped to 0/+1), growth = N*ceil(log2(R)) = 4*4 = 16 bits
# We use 24 bits internally for margin; RTL will use same width.
# ─────────────────────────────────────────────────────────────────────────────
CIC_WIDTH  = B_CIC_OUT    # 24 bits  (signed)
CIC_MAX    = (1 << (CIC_WIDTH - 1)) - 1
CIC_MIN    = -(1 << (CIC_WIDTH - 1))


def _wrap(x: int, bits: int = CIC_WIDTH) -> int:
    """Simulate hardware integer wrap-around (two's complement overflow)."""
    mask   = (1 << bits) - 1
    val    = x & mask
    if val >= (1 << (bits - 1)):
        val -= (1 << bits)
    return val


def cic_decimate(pdm: np.ndarray,
                 R: int = R_CIC,
                 N: int = N_CIC,
                 M: int = M_CIC,
                 width: int = CIC_WIDTH) -> np.ndarray:
    """
    Bit-exact CIC decimator.

    PDM input: 0 or 1 uint8  →  mapped to 0 / +1 (unsigned accumulation)
    Output: signed integers at rate Fs_pdm / R

    Integrators run at input rate (Fs_pdm).
    Combs run at output rate (Fs_pdm / R) with delay M.

    Parameters
    ----------
    pdm   : 1-D uint8 array of PDM bits (0 or 1)
    R, N, M : CIC parameters (decimation ratio, stages, diff delay)
    width : internal register bit width

    Returns
    -------
    out : int32 array of CIC output samples
    """
    # ── Stage 1: N integrators at full rate ──────────────────────────────────
    integrators = [0] * N
    n_samples   = len(pdm) // R          # number of output samples
    stage_buf   = np.zeros(len(pdm), dtype=np.int64)

    for i, bit in enumerate(pdm):
        x = int(bit)                     # 0 or 1 (unsigned PDM)
        for k in range(N):
            integrators[k] = _wrap(integrators[k] + x, width)
            x = integrators[k]
        stage_buf[i] = integrators[-1]   # save last integrator output

    # ── Stage 2: Decimate (take every R-th sample) ───────────────────────────
    decimated = stage_buf[R-1::R][:n_samples]

    # ── Stage 3: N comb sections at output rate ───────────────────────────────
    # Each comb: y[n] = x[n] - x[n-M]
    combs = np.copy(decimated)
    for _ in range(N):
        # delay line of depth M
        prev  = np.zeros(len(combs) + M, dtype=np.int64)
        prev[M:] = combs
        combs = np.array([_wrap(int(prev[i+M]) - int(prev[i]), width)
                          for i in range(len(combs))], dtype=np.int64)

    return combs.astype(np.int32)


def cic_frequency_response(R: int = R_CIC,
                            N: int = N_CIC,
                            M: int = M_CIC,
                            n_points: int = 4096) -> tuple:
    """
    Compute the CIC magnitude response (dB) normalised to Fs_pdm.
    Returns (frequencies_Hz, magnitude_dB).
    """
    f = np.linspace(0, F_PDM / 2, n_points)
    eps = 1e-12
    # H(f) = |sin(π f R M / Fs_pdm) / (R M sin(π f / Fs_pdm))|^N
    num   = np.abs(np.sin(np.pi * f * R * M / F_PDM)) + eps
    den   = R * M * (np.abs(np.sin(np.pi * f / F_PDM)) + eps)
    H     = (num / den) ** N
    H_dB  = 20 * np.log10(H + eps)
    return f, H_dB


def cic_passband_droop(R: int = R_CIC,
                        N: int = N_CIC,
                        M: int = M_CIC,
                        f_pass: float = F_PASS) -> float:
    """Return the CIC passband droop at f_pass (dB, negative = attenuation)."""
    f, H = cic_frequency_response(R, N, M)
    idx  = np.argmin(np.abs(f - f_pass))
    return H[idx]   # dB at passband edge (H[0] = 0 dB by definition)


def save_cic_vectors(cic_out: np.ndarray, out_dir: str = None):
    """Save CIC output as signed hex for RTL testbench ($readmemh)."""
    if out_dir is None:
        out_dir = os.path.join(os.path.dirname(__file__), VEC_DIR)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "cic_out.hex")
    with open(path, "w") as fh:
        for s in cic_out:
            # 6-digit hex for 24-bit signed (two's complement)
            fh.write(f"{int(s) & 0xFFFFFF:06x}\n")
    print(f"[cic_model] Saved {len(cic_out)} samples → {path}")
    return path


# ─────────────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import matplotlib.pyplot as plt
    from pdm_gen import make_test_pdm, save_pdm_vectors

    # ── Generate PDM if not already saved ────────────────────────────────────
    vec_dir = os.path.join(os.path.dirname(__file__), VEC_DIR)
    pdm_txt = os.path.join(vec_dir, "pdm_test.txt")
    if os.path.exists(pdm_txt):
        print("[cic_model] Loading existing PDM vectors …")
        pdm = np.loadtxt(pdm_txt, dtype=np.uint8)
    else:
        print("[cic_model] Generating PDM vectors …")
        _, pdm = make_test_pdm()
        save_pdm_vectors(pdm)

    # ── Run CIC ───────────────────────────────────────────────────────────────
    print(f"[cic_model] Running CIC (R={R_CIC}, N={N_CIC}, M={M_CIC}) …")
    cic_out = cic_decimate(pdm)
    print(f"[cic_model] {len(pdm)} PDM bits → {len(cic_out)} CIC samples")
    print(f"[cic_model] Output range: [{cic_out.min()}, {cic_out.max()}]")
    print(f"[cic_model] Passband droop at {F_PASS/1e3:.0f} kHz: "
          f"{cic_passband_droop():.2f} dB")
    save_cic_vectors(cic_out)

    # ── Plots ─────────────────────────────────────────────────────────────────
    fig, axes = plt.subplots(2, 1, figsize=(12, 8))
    fig.suptitle(f"CIC Decimator  (R={R_CIC}, N={N_CIC}, M={M_CIC})",
                 fontsize=13, fontweight="bold")

    # Frequency response
    f_resp, H_resp = cic_frequency_response()
    axes[0].plot(f_resp / 1e3, H_resp, "b", linewidth=1.2)
    axes[0].axvline(F_PASS / 1e3, color="r", linestyle="--",
                    label=f"Passband {F_PASS/1e3:.0f} kHz")
    axes[0].axvline(F_CIC_OUT / 2e3, color="g", linestyle="--",
                    label=f"CIC Nyquist {F_CIC_OUT/2e3:.0f} kHz")
    axes[0].set(xlabel="Frequency (kHz)", ylabel="Magnitude (dB)",
                title="CIC Frequency Response (full band)",
                xlim=(0, F_PDM / 2e3), ylim=(-120, 5))
    axes[0].legend(); axes[0].grid(True, alpha=0.4)

    # Output spectrum
    n_fft = min(4096, len(cic_out))
    win   = np.hanning(n_fft)
    spec  = 20 * np.log10(
                np.abs(np.fft.rfft(cic_out[:n_fft].astype(float) * win)) + 1e-9)
    freqs = np.fft.rfftfreq(n_fft, d=1.0 / F_CIC_OUT) / 1e3
    axes[1].plot(freqs, spec, linewidth=0.7)
    axes[1].axvline(F_PASS / 1e3, color="r", linestyle="--",
                    label=f"Audio passband {F_PASS/1e3:.0f} kHz")
    axes[1].set(xlabel="Frequency (kHz)", ylabel="dBFS",
                title=f"CIC Output Spectrum  (Fs = {F_CIC_OUT/1e3:.0f} kHz)",
                xlim=(0, F_CIC_OUT / 2e3))
    axes[1].legend(); axes[1].grid(True, alpha=0.4)

    plt.tight_layout()
    fig_path = os.path.join(vec_dir, "cic_response.png")
    plt.savefig(fig_path, dpi=150)
    plt.show()
    print(f"[cic_model] Saved plot → {fig_path}")
