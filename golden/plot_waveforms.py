"""
P6 Audio Pipeline Waveform Generator
Generates time-domain waveform visualization for:
  1. 1-bit PDM Bitstream (3.072 MHz)
  2. CIC Decimator Output (192 kHz, 24-bit)
  3. Compensation FIR Output (192 kHz, 24-bit)
  4. Half-Band 2 Output (48 kHz, 16-bit PCM Audio)
  5. PWM Headphone Audio Output
"""

import os, sys
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

sys.path.insert(0, os.path.dirname(__file__))
from params import *
from pdm_gen import sigma_delta_1st_order
from cic_model import cic_decimate
from comp_fir import design_comp_fir, apply_comp_fir
from halfband import design_halfband, apply_halfband

VEC = os.path.join(os.path.dirname(__file__), VEC_DIR)
os.makedirs(VEC, exist_ok=True)

def generate_and_plot_waveforms():
    print("[waveforms] Generating time-domain audio pipeline waveforms ...")
    
    # 1. Generate 1 kHz Audio Tone (0.005 seconds = 5 complete cycles)
    duration = 0.005 # 5 ms
    t_audio = np.arange(int(duration * F_AUDIO_OUT)) / F_AUDIO_OUT
    audio = 0.85 * np.sin(2 * np.pi * 1000 * t_audio)
    
    # 2. Convert to PDM at 3.072 MHz
    pdm = sigma_delta_1st_order(audio, F_OSR)
    t_pdm = np.arange(len(pdm)) / F_PDM
    
    # 3. CIC Decimation (3.072 MHz -> 192 kHz)
    cic = cic_decimate(pdm)
    t_cic = np.arange(len(cic)) / F_CIC_OUT
    
    # 4. Compensation FIR (192 kHz)
    d_comp = design_comp_fir()
    comp = apply_comp_fir(cic, d_comp["h_q"])
    t_comp = np.arange(len(comp)) / COMP_FS
    
    # 5. Half-Band 1 (192 kHz -> 96 kHz)
    hb1_d = design_halfband(HB1_NTAPS, HB1_FS, HB1_FPASS)
    hb1 = apply_halfband(comp, hb1_d)
    
    # 6. Half-Band 2 (96 kHz -> 48 kHz PCM)
    hb2_d = design_halfband(HB2_NTAPS, HB2_FS, HB2_FPASS)
    hb2 = apply_halfband(hb1, hb2_d)
    pcm = np.clip(hb2 >> 8, -32768, 32767)
    t_pcm = np.arange(len(pcm)) / F_AUDIO_OUT
    
    # --- Plotting ---
    fig, axes = plt.subplots(4, 1, figsize=(13, 9), sharex=False)
    fig.suptitle("P6 Audio Front End: Multi-Stage Signal Waveforms", fontsize=14, fontweight="bold")
    
    # Plot 1: Raw 1-bit PDM
    # Zoom in on first 0.5 ms to see individual pulses clearly
    zoom_pdm = int(0.0006 * F_PDM)
    axes[0].step(t_pdm[:zoom_pdm] * 1e3, pdm[:zoom_pdm], color="#1f77b4", linewidth=1.2, where="post")
    axes[0].set_title("Stage 0: 1-bit PDM Microphone Bitstream (3.072 MHz OSR = 64x) [Zoomed 0.6 ms]", fontsize=10, fontweight="bold")
    axes[0].set_ylabel("PDM Bit (0/1)")
    axes[0].set_ylim(-0.2, 1.2)
    axes[0].grid(True, alpha=0.3)
    
    # Plot 2: CIC Decimator Output
    axes[1].step(t_cic * 1e3, cic, color="#ff7f0e", linewidth=1.2, where="mid")
    axes[1].set_title("Stage 1: CIC Decimator Output (192 kHz, 24-bit Signed) [R=16, N=4]", fontsize=10, fontweight="bold")
    axes[1].set_ylabel("Amplitude")
    axes[1].grid(True, alpha=0.3)
    
    # Plot 3: Compensation FIR Output
    axes[2].plot(t_comp * 1e3, comp, color="#2ca02c", linewidth=1.5)
    axes[2].set_title("Stage 2: Compensation FIR Output (192 kHz, Equalized Treble)", fontsize=10, fontweight="bold")
    axes[2].set_ylabel("Amplitude")
    axes[2].grid(True, alpha=0.3)
    
    # Plot 4: Final 16-bit PCM Audio Output
    axes[3].plot(t_pcm * 1e3, pcm, color="#d62728", linewidth=2.0, marker="o", markersize=3, label="16-bit PCM (48 kHz)")
    axes[3].set_title("Stage 3 & 4: Final Reconstructed Audio Output (48 kHz, 16-bit PCM)", fontsize=10, fontweight="bold")
    axes[3].set_xlabel("Time (milliseconds)")
    axes[3].set_ylabel("16-bit PCM Amplitude")
    axes[3].grid(True, alpha=0.3)
    axes[3].legend(loc="upper right")
    
    plt.tight_layout()
    out_path = os.path.join(VEC, "audio_pipeline_waveforms.png")
    plt.savefig(out_path, dpi=150)
    print(f"[waveforms] Saved waveform image: {out_path}")

if __name__ == "__main__":
    generate_and_plot_waveforms()
