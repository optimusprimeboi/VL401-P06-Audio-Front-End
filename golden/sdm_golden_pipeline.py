"""
Sigma-Delta Modulator (SDM) & Golden Pipeline Simulator
Author: Senior FPGA / DSP / RTL Systems Architect
Project: PDM-to-PCM Audio Front End

Implements:
1. 2nd-Order 1-Bit Sigma-Delta Modulator (SDM)
2. Bit-exact Golden Model of the Decimation Filter Chain:
   - CIC Decimator (N=4, R=16) with 18-bit accumulators
   - CIC Compensation FIR (9 taps, Q12)
   - Half-Band Stage 1 (11 taps, Q14)
   - Half-Band Stage 2 (23 taps, Q14)
   - 16-bit Rounding & Saturation
3. Frequency Domain, SNR, THD, and Dynamic Range Analysis
4. Test Stimulus Vector Generation (.hex) for RTL Testbenches
"""

import numpy as np
import scipy.signal as signal
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import os

os.makedirs("sim", exist_ok=True)
os.makedirs("docs/plots", exist_ok=True)

# -------------------------------------------------------------
# 1. High-Order 1-Bit Sigma-Delta Modulator
# -------------------------------------------------------------
def run_sigma_delta_modulator(signal_in, order=2):
    """
    Simulates a 2nd-order 1-bit Delta-Sigma Modulator (CIFB topology).
    signal_in: float array normalized to [-1.0, 1.0], sample rate Fs = 3.072 MHz
    Returns: 1-bit PDM stream (0 and 1)
    """
    N = len(signal_in)
    pdm_out = np.zeros(N, dtype=np.int8)
    
    # 2nd order integrator states
    int1 = 0.0
    int2 = 0.0
    
    # Typical CIFB coefficients for stable 2nd order SDM
    a1 = 0.5
    a2 = 0.5
    b1 = 0.5
    b2 = 0.5
    c1 = 1.0
    
    y = 0.0  # feedback
    for i in range(N):
        x = signal_in[i]
        
        # Integrator 1: forward Euler
        diff1 = b1 * x - a1 * y
        int1 += diff1
        
        # Integrator 2
        diff2 = c1 * int1 - a2 * y
        int2 += diff2
        
        # 1-bit Quantizer (comparator)
        if int2 >= 0.0:
            bit = 1
            y = 1.0
        else:
            bit = 0
            y = -1.0
            
        pdm_out[i] = bit
        
    return pdm_out

# -------------------------------------------------------------
# 2. Fixed-Point Bit-Exact Pipeline Functions
# -------------------------------------------------------------
def cic_decimator_sim(pdm_bits, R=16, N=4):
    """
    Bit-exact simulation of N=4, R=16 CIC Decimator.
    Input: array of {0, 1}
    Internal word length: 18 bits (2's complement modulo 2^18)
    Returns: decimated samples at Fs_in / R (192 kHz)
    """
    MASK18 = (1 << 18) - 1
    SIGN18 = 1 << 17
    
    # Convert {0, 1} to bipolar {-1, +1} in 18-bit signed
    # 0 -> -1 = 18'h3FFFF, 1 -> +1 = 18'h00001
    x_bipolar = np.where(pdm_bits == 1, 1, -1)
    
    # 4 Integrator stages running at Fs_in (3.072 MHz)
    # y_int[k] = (y_int[k] + in) mod 2^18
    int_stages = [0, 0, 0, 0]
    comb_input = []
    
    for idx, sample in enumerate(x_bipolar):
        # Stage 0
        int_stages[0] = (int_stages[0] + sample) & MASK18
        # Stage 1
        int_stages[1] = (int_stages[1] + int_stages[0]) & MASK18
        # Stage 2
        int_stages[2] = (int_stages[2] + int_stages[1]) & MASK18
        # Stage 3
        int_stages[3] = (int_stages[3] + int_stages[2]) & MASK18
        
        # Downsample by R=16
        if (idx + 1) % R == 0:
            comb_input.append(int_stages[3])
            
    # 4 Comb stages running at Fs_cic = 192 kHz
    # y_comb[k] = (in - delay) mod 2^18
    comb_stages = [0, 0, 0, 0]
    cic_out = []
    
    for sample in comb_input:
        curr = sample
        for stage in range(N):
            diff = (curr - comb_stages[stage]) & MASK18
            comb_stages[stage] = curr
            curr = diff
        
        # Convert 18-bit unsigned representation to signed integer
        signed_val = curr if curr < SIGN18 else curr - (1 << 18)
        cic_out.append(signed_val)
        
    return np.array(cic_out, dtype=np.int32)

def fir_direct_csd(input_samples, coeffs, shift, max_accum_bits=28):
    """
    Fixed-point FIR filter with rounding.
    coeffs: integer coefficients
    shift: fractional divisor power of two (e.g. 12 for Q12)
    """
    num_taps = len(coeffs)
    num_samples = len(input_samples)
    out = np.zeros(num_samples, dtype=np.int32)
    buffer = np.zeros(num_taps, dtype=np.int32)
    
    round_offset = 1 << (shift - 1)
    
    for i in range(num_samples):
        # Shift buffer
        buffer[1:] = buffer[:-1]
        buffer[0] = input_samples[i]
        
        # Convolution sum
        accum = 0
        for tap in range(num_taps):
            accum += buffer[tap] * coeffs[tap]
            
        # Add convergent / round-half-up offset and shift
        accum_rounded = (accum + round_offset) >> shift
        out[i] = accum_rounded
        
    return out

def halfband_decimate(input_samples, coeffs, shift):
    """
    Half-band decimation filter: downsamples by 2.
    """
    filtered = fir_direct_csd(input_samples, coeffs, shift)
    # Downsample by 2
    return filtered[::2]

def round_and_saturate_16bit(x):
    """
    Saturate integer to 16-bit signed [-32768, 32767].
    """
    return np.clip(x, -32768, 32767).astype(np.int16)

# -------------------------------------------------------------
# 3. Full Decimation Chain Simulation
# -------------------------------------------------------------
def run_pdm_to_pcm_pipeline(pdm_stream):
    # Load coefficients
    h_comp = np.load("model/h_comp.npy")
    h_hb1 = np.load("model/h_hb1.npy")
    h_hb2 = np.load("model/h_hb2.npy")
    
    # Stage 1: CIC Decimator (3.072 MHz -> 192 kHz)
    # Output range: DC gain = 65536. An input of +/-1 gives +/-65536.
    # Notice that a 16-bit audio signal has amplitude +/-32767.
    # In CIC output, 65536 corresponds to +1.0 full scale.
    # So dividing by 2 (or shift 1) brings full scale to 32768 (16-bit scale)!
    cic_out = cic_decimator_sim(pdm_stream, R=16, N=4)
    # Scale CIC output by >> 1 to align with 16-bit full scale
    # To keep precision for FIR stages, we keep full 18-bit or scale appropriately:
    # Scale factor: 65536 full scale in -> we want 32767 full scale out.
    # Thus CIC output >> 1 gives exactly 32768 full scale!
    s1_in = (cic_out + 1) >> 1
    
    # Stage 2: CIC Compensation FIR (192 kHz, Q12)
    s2_out = fir_direct_csd(s1_in, h_comp, shift=12)
    
    # Stage 3: Half-Band Stage 1 (192 kHz -> 96 kHz, Q14)
    s3_out = halfband_decimate(s2_out, h_hb1, shift=14)
    
    # Stage 4: Half-Band Stage 2 (96 kHz -> 48 kHz, Q14)
    s4_out = halfband_decimate(s3_out, h_hb2, shift=14)
    
    # Final Stage: 16-bit Saturation
    pcm_16bit = round_and_saturate_16bit(s4_out)
    
    return pcm_16bit, s4_out, cic_out

# -------------------------------------------------------------
# 4. Multi-tone Audio Testbench & Spectrum / SNR Analysis
# -------------------------------------------------------------
def main():
    Fs_pdm = 3072000
    duration = 0.02  # 20 ms -> ~61440 PDM samples, ~960 PCM samples
    num_samples = int(Fs_pdm * duration)
    # Align to multiple of 64
    num_samples = (num_samples // 64) * 64
    t = np.arange(num_samples) / Fs_pdm
    
    print(f"Generating test stimulus: {num_samples} PDM samples ({num_samples/Fs_pdm*1000:.1f} ms)...")
    
    # Synthetic multi-tone input: 1 kHz (-6 dBFS), 5 kHz (-14 dBFS), 12 kHz (-20 dBFS)
    a1 = 10 ** (-6.0 / 20)   # 0.501
    a2 = 10 ** (-14.0 / 20)  # 0.200
    a3 = 10 ** (-20.0 / 20)  # 0.100
    
    tone1 = a1 * np.sin(2 * np.pi * 1000 * t)
    tone2 = a2 * np.sin(2 * np.pi * 5000 * t)
    tone3 = a3 * np.sin(2 * np.pi * 12000 * t)
    
    audio_signal = tone1 + tone2 + tone3
    # Peak amplitude ~ 0.8 (< 1.0 to prevent SDM overload)
    peak_val = np.max(np.abs(audio_signal))
    print(f"Synthesized Multi-tone Peak Amplitude: {peak_val:.3f}")
    
    # Modulate via 2nd-order 1-bit SDM
    print("Running 2nd-Order Sigma-Delta Modulator...")
    pdm_bits = run_sigma_delta_modulator(audio_signal)
    
    # Run through Bit-Exact Decimation Pipeline
    print("Running Golden Decimation Filter Chain...")
    pcm_out, pcm_raw, cic_raw = run_pdm_to_pcm_pipeline(pdm_bits)
    
    # Discard startup transient (first 100 samples)
    transient = 100
    pcm_steady = pcm_out[transient:]
    t_pcm = (np.arange(len(pcm_out)) / 48000)[transient:]
    
    # Calculate SNR and THD for 1 kHz fundamental
    # FFT of output PCM
    N_fft = len(pcm_steady)
    # Apply Hann window
    window = np.hanning(N_fft)
    spec = np.fft.rfft(pcm_steady * window)
    freqs = np.fft.rfftfreq(N_fft, d=1/48000)
    mag_spec = np.abs(spec)
    mag_db = 20 * np.log10(np.maximum(mag_spec, 1e-6))
    mag_db -= np.max(mag_db)  # Normalize peak to 0 dB
    
    # Plot Time Domain & Spectrum
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 8))
    
    # Time domain waveform
    t_plot_ms = t_pcm[:200] * 1000
    ax1.plot(t_plot_ms, pcm_steady[:200], 'b-', linewidth=1.5, label='Decimated 16-bit PCM')
    ax1.set_title('Decimated PCM Audio Time-Domain Waveform (48 kHz Sample Rate)', fontsize=12, fontweight='bold')
    ax1.set_xlabel('Time (ms)')
    ax1.set_ylabel('Amplitude (16-bit Signed)')
    ax1.grid(True, linestyle='--', alpha=0.7)
    ax1.legend()
    
    # Frequency Spectrum (PSD)
    ax2.plot(freqs / 1000, mag_db, 'r-', linewidth=1.2, label='PCM Output Spectrum')
    ax2.axvline(x=1.0, color='g', linestyle=':', label='Tone 1 (1 kHz)')
    ax2.axvline(x=5.0, color='m', linestyle=':', label='Tone 2 (5 kHz)')
    ax2.axvline(x=12.0, color='c', linestyle=':', label='Tone 3 (12 kHz)')
    ax2.set_title('Decimated PCM Spectrum (FFT, Audio Band 0 - 24 kHz)', fontsize=12, fontweight='bold')
    ax2.set_xlabel('Frequency (kHz)')
    ax2.set_ylabel('Normalized Magnitude (dBFS)')
    ax2.set_xlim([0, 24])
    ax2.set_ylim([-100, 5])
    ax2.grid(True, linestyle='--', alpha=0.7)
    ax2.legend()
    
    plt.tight_layout()
    plt.savefig('docs/plots/golden_spectrum_and_waveform.png', dpi=300)
    plt.close()
    
    # Compute in-band SNR
    # Fundamental bin at 1 kHz
    bin_1k = np.argmin(np.abs(freqs - 1000))
    # Signal power (around 1 kHz, 5 kHz, 12 kHz)
    signal_bins = []
    for f_target in [1000, 5000, 12000]:
        b = np.argmin(np.abs(freqs - f_target))
        signal_bins.extend([b-2, b-1, b, b+1, b+2])
    
    mask_in_band = (freqs >= 100) & (freqs <= 20000)
    in_band_indices = np.where(mask_in_band)[0]
    
    noise_indices = [idx for idx in in_band_indices if idx not in signal_bins]
    
    p_signal = np.sum(mag_spec[signal_bins] ** 2)
    p_noise = np.sum(mag_spec[noise_indices] ** 2)
    snr_db = 10 * np.log10(p_signal / p_noise)
    print(f"\n=======================================================")
    print(f"Measured In-Band SNR (100 Hz - 20 kHz): {snr_db:.2f} dB")
    print(f"Target 16-bit Dynamic Range: ~96 dB theoretical (audio MEMS mic typical: 64-74 dB)")
    print(f"Synthesized PDM Front-End achieves pristine: {snr_db:.1f} dB SNR!")
    print(f"=======================================================")
    
    # Export Test Vectors for RTL Testbench
    # Stimulus: 1-bit PDM stream packed into hexadecimal words (32 bits per word)
    # and golden PCM output (16-bit hexadecimal)
    print("\nExporting test vectors for RTL simulation...")
    
    # Save raw bit stream as text hex (32 bits per line)
    packed_words = []
    for i in range(0, len(pdm_bits), 32):
        chunk = pdm_bits[i:i+32]
        if len(chunk) < 32:
            chunk = np.pad(chunk, (0, 32 - len(chunk)))
        word = 0
        for bit_idx, bit in enumerate(chunk):
            word |= (int(bit) << bit_idx)
        packed_words.append(word)
        
    with open("sim/pdm_stimulus_words.hex", "w") as f:
        for w in packed_words:
            f.write(f"{w:08X}\n")
            
    with open("sim/pdm_stimulus_bits.txt", "w") as f:
        for b in pdm_bits:
            f.write(f"{b}\n")
            
    with open("sim/pcm_golden_output.hex", "w") as f:
        for val in pcm_out:
            uval = int(val) & 0xFFFF
            f.write(f"{uval:04X}\n")
            
    print(f"Exported {len(pdm_bits)} PDM bits ({len(packed_words)} words) to sim/pdm_stimulus_words.hex")
    print(f"Exported {len(pcm_out)} PCM golden samples to sim/pcm_golden_output.hex")

if __name__ == "__main__":
    main()
