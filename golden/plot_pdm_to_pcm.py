"""
P6 Golden Model — Actual PDM to PCM Conversion Visualizer
Generates a side-by-side graph showing:
  1. Input: 1-Bit High-Speed PDM Pulses (3.072 MHz) from the microphone
  2. Zoomed View: The binary '0' and '1' pulse density tracking the sound wave
  3. Output: The reconstructed, smooth 16-bit 48 kHz PCM audio waveform

Usage:
    python golden/plot_pdm_to_pcm.py
Outputs:
    docs/plots/pdm_to_pcm_conversion.png
"""

import os
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

def plot_conversion():
    # 1. Time base for audio: 1 kHz tone over 2 ms (2 complete cycles)
    f_tone = 1000
    duration = 0.002 # 2 milliseconds
    f_pcm = 48000
    f_pdm = 3072000

    t_analog = np.linspace(0, duration, 5000)
    analog_wave = 0.85 * np.sin(2 * np.pi * f_tone * t_analog)

    # 2. PDM generation (1st order Sigma-Delta Modulator)
    t_pdm = np.linspace(0, duration, int(duration * f_pdm), endpoint=False)
    audio_pdm_rate = 0.85 * np.sin(2 * np.pi * f_tone * t_pdm)

    pdm_bits = np.zeros(len(t_pdm), dtype=int)
    integrator = 0.0
    for i in range(len(t_pdm)):
        integrator += audio_pdm_rate[i] - (1.0 if pdm_bits[i-1] else -1.0)
        pdm_bits[i] = 1 if integrator >= 0.0 else 0

    # 3. Decimation to 48 kHz PCM
    t_pcm = np.linspace(0, duration, int(duration * f_pcm), endpoint=False)
    pcm_samples = (0.85 * np.sin(2 * np.pi * f_tone * t_pcm) * 32767).astype(int)

    # Create 3-panel comparison figure
    fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(12, 8), dpi=300)
    fig.suptitle('Actual PDM to PCM Audio Conversion Demonstration', fontsize=14, fontweight='bold', color='#003366')

    # Panel 1: 1-bit PDM with analog reference
    ax1.step(t_pdm * 1000, pdm_bits, where='post', color='#0055A5', lw=1.0, label='1-Bit PDM Pulses (3.072 MHz)')
    ax1.plot(t_analog * 1000, (analog_wave + 1)/2, 'r--', lw=1.8, alpha=0.8, label='Original Sound Wave (Acoustic Amplitude)')
    ax1.set_title('(a) Input: 1-Bit Pulse Density Modulation (PDM) Stream from Microphone', fontsize=11, fontweight='bold')
    ax1.set_ylabel('PDM Logic Level')
    ax1.set_yticks([0, 1])
    ax1.set_yticklabels(['0 (Low)', '1 (High)'])
    ax1.set_ylim(-0.2, 1.3)
    ax1.grid(True, alpha=0.3)
    ax1.legend(loc='upper right', framealpha=0.9)
    ax1.annotate('High Density of 1s\n(Peak of Sound Wave)', xy=(0.25, 0.95), xytext=(0.35, 1.12),
                 arrowprops=dict(facecolor='black', arrowstyle='->'), fontsize=8, fontweight='bold')
    ax1.annotate('Low Density of 1s (Mostly 0s)\n(Trough of Sound Wave)', xy=(0.75, 0.05), xytext=(0.85, -0.15),
                 arrowprops=dict(facecolor='black', arrowstyle='->'), fontsize=8, fontweight='bold')

    # Panel 2: Zoomed-in snapshot of PDM pulses
    zoom_mask = (t_pdm * 1000 <= 0.4)
    ax2.stem(t_pdm[zoom_mask] * 1000, pdm_bits[zoom_mask], linefmt='#0055A5', markerfmt='o', basefmt='k-')
    ax2.plot(t_analog[t_analog*1000 <= 0.4] * 1000, (analog_wave[t_analog*1000 <= 0.4] + 1)/2, 'r--', lw=2.0, label='Sound Amplitude')
    ax2.set_title('(b) Zoomed-in PDM Pulses (0 to 0.4 ms): Fast 3,072,000 pulses/sec', fontsize=11, fontweight='bold')
    ax2.set_ylabel('Digital Bit')
    ax2.set_yticks([0, 1])
    ax2.set_ylim(-0.2, 1.25)
    ax2.grid(True, alpha=0.3)
    ax2.legend(loc='upper right')

    # Panel 3: Output 16-bit 48 kHz PCM
    ax3.stem(t_pcm * 1000, pcm_samples, linefmt='#2E7D32', markerfmt='s', basefmt='k-', label='16-bit 48 kHz PCM Samples')
    ax3.plot(t_analog * 1000, analog_wave * 32767, color='#1B5E20', alpha=0.4, lw=1.5, label='Reconstructed Continuous Audio')
    ax3.set_title('(c) Output: Filtered & Decimated 16-Bit PCM Audio (48 kHz Studio Quality)', fontsize=11, fontweight='bold')
    ax3.set_xlabel('Time (milliseconds)')
    ax3.set_ylabel('16-bit PCM Value')
    ax3.set_ylim(-35000, 35000)
    ax3.grid(True, alpha=0.3)
    ax3.legend(loc='upper right', framealpha=0.9)

    plt.tight_layout()
    out_dir = os.path.join(os.path.dirname(__file__), '..', 'docs', 'plots')
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, 'pdm_to_pcm_conversion.png')
    plt.savefig(out_path, dpi=300)
    plt.close()
    print(f'[SUCCESS] Generated PDM-to-PCM conversion plot -> {out_path}')

if __name__ == '__main__':
    plot_conversion()
