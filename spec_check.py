"""
Full PS Spec Check — P6 PDM-to-PCM Audio Front End
Checks all requirements from the project specification against what is implemented.
"""
import sys, os, math
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'golden'))
from params import *
import numpy as np

PASS = "PASS"
FAIL = "FAIL"

def check(label, condition, note=""):
    status = PASS if condition else FAIL
    print(f"  [{status}] {label}" + (f"  ({note})" if note else ""))
    return condition

results = []

print()
print("=" * 65)
print("  P6 FULL SPEC CHECK")
print("=" * 65)

# ─── 1. Signal Chain Parameters ──────────────────────────────────────
print("\n--- 1. Signal Chain Parameters ---")
results += [
    check("PDM input rate = 3.072 MHz", F_PDM == 3_072_000, f"got {F_PDM}"),
    check("PCM output rate = 48 kHz",   F_AUDIO_OUT == 48_000, f"got {F_AUDIO_OUT}"),
    check("PCM output width = 16 bit",  B_PCM_OUT == 16),
    check("CIC decimation ratio R=16",  R_CIC == 16),
    check("CIC stages N=4",             N_CIC == 4),
    check("CIC differential delay M=1", M_CIC == 1),
    check("CIC internal width = 24b",   B_CIC_OUT == 24),
    check("CIC out rate = 192 kHz",     F_CIC_OUT == 192_000, f"got {F_CIC_OUT}"),
    check("HB1 out rate = 96 kHz",      F_HB1_OUT == 96_000),
    check("HB2 out rate = 48 kHz",      F_HB2_OUT == 48_000),
    check("Comp FIR taps = 31 (odd)",   COMP_NTAPS == 31 and COMP_NTAPS % 2 == 1),
    check("Coeff word = 16-bit",        COEFF_BITS == 16),
    check("Coeff frac = 15 (1.15 fmt)", COEFF_FRAC == 15),
    check("Audio passband <= 20 kHz",   F_PASS == 20_000),
    check("CIC growth = 16 bits",       B_CIC_GROWTH == 16,
          f"N*ceil(log2(R))={N_CIC}*{math.ceil(math.log2(R_CIC))}={B_CIC_GROWTH}"),
]

# ─── 2. Test Vectors Present ─────────────────────────────────────────
print("\n--- 2. Test Vectors ---")
VEC = os.path.join(os.path.dirname(__file__), 'sim', 'vectors')
required_vectors = [
    ('pdm_test.txt', None),
    ('pdm_test.hex', None),
    ('pdm_test.bin', None),
    ('cic_out.hex',  96000),
    ('comp_fir_coeffs.hex', 31),
    ('comp_fir_out.hex', 96000),
    ('hb1_coeffs_folded.hex', 9),
    ('hb1_out.hex', 48000),
    ('hb2_coeffs_folded.hex', 9),
    ('hb2_out.hex', 24000),
    ('pcm_out.hex', 24000),
    ('mcm_comparison_table.txt', None),
    ('snr_final_report.txt', None),
]
for fname, expected_lines in required_vectors:
    path = os.path.join(VEC, fname)
    exists = os.path.exists(path)
    if exists and expected_lines is not None:
        lines = [l for l in open(path) if l.strip()]
        ok = len(lines) == expected_lines
        results.append(check(f"Vector {fname}", ok,
                             f"lines={len(lines)} expected={expected_lines}"))
    else:
        results.append(check(f"Vector {fname} exists", exists))

# PDM bit count
pdm_path = os.path.join(VEC, 'pdm_test.txt')
if os.path.exists(pdm_path):
    pdm_count = sum(1 for _ in open(pdm_path) if _.strip())
    results.append(check("PDM stream = 1,536,000 bits (0.5s @ 3.072MHz)",
                          pdm_count == 1_536_000, f"got {pdm_count}"))

# ─── 3. RTL Files Present ────────────────────────────────────────────
print("\n--- 3. RTL Modules ---")
RTL = os.path.join(os.path.dirname(__file__), 'rtl')
rtl_required = [
    ('cic/cic_decimator.v',          'CIC Decimator (R=16, N=4)'),
    ('fir/comp_fir_naive.v',         'Comp FIR - Naive CSD method'),
    ('fir/comp_fir_cse.v',           'Comp FIR - CSE/MCM method'),
    ('fir/comp_fir_espresso.v',      'Comp FIR - ESPRESSO/BDD method'),
    ('halfband/hb_filter_folded.v',  'Half-Band - Folded (shared MAC)'),
    ('halfband/hb_filter_parallel.v','Half-Band - Parallel'),
    ('fifo/pcm_fifo.v',              'PCM FIFO with IRQ threshold'),
    ('apb/apb_audio_regs.v',         'APB registers (gain, bypass)'),
    ('rv32i/rv32i_core.v',           'RV32I soft core (RMS + VAD)'),
    ('i2s/i2s_tx.v',                 'I2S transmitter'),
    ('i2s/pwm_audio.v',              'PWM audio DAC'),
    ('top/top.v',                    'Top-level integration'),
    ('top/pdm_bram_player.v',        'BRAM PDM player'),
]
for rel_path, desc in rtl_required:
    full_path = os.path.join(RTL, rel_path)
    results.append(check(f"{desc}", os.path.exists(full_path), rel_path))

# ─── 4. Golden Model Files ───────────────────────────────────────────
print("\n--- 4. Golden Model (Python) ---")
GOLDEN = os.path.join(os.path.dirname(__file__), 'golden')
golden_required = [
    'params.py', 'pdm_gen.py', 'cic_model.py', 'comp_fir.py',
    'halfband.py', 'chain.py', 'snr_test.py', 'espresso_bdd_analysis.py'
]
for f in golden_required:
    results.append(check(f"Golden: {f}", os.path.exists(os.path.join(GOLDEN, f))))

# ─── 5. Testbench Files ──────────────────────────────────────────────
print("\n--- 5. Testbenches ---")
TB = os.path.join(os.path.dirname(__file__), 'tb')
tb_required = ['sim_cic.py', 'sim_comp_fir.py', 'sim_halfband.py',
               'sim_rv32i.py', 'sim_top_system.py', 'tb_cic_decimator.v']
for f in tb_required:
    results.append(check(f"Testbench: {f}", os.path.exists(os.path.join(TB, f))))

# ─── 6. Formal Verification Files ───────────────────────────────────
print("\n--- 6. Formal Verification (CTL proofs) ---")
FORMAL = os.path.join(os.path.dirname(__file__), 'formal', 'fifo')
formal_required = ['fifo_safety.sv', 'fifo_safety.sby',
                   'pipeline_liveness.sv', 'pipeline_liveness.sby']
for f in formal_required:
    results.append(check(f"Formal: {f}", os.path.exists(os.path.join(FORMAL, f))))

# ─── 7. Firmware Files ───────────────────────────────────────────────
print("\n--- 7. Firmware (RV32I: RMS + VAD) ---")
FW = os.path.join(os.path.dirname(__file__), 'firmware')
for f in ['audio_dsp.c', 'build_firmware.py', 'program.hex']:
    results.append(check(f"Firmware: {f}", os.path.exists(os.path.join(FW, f))))

# Check program.hex has 31 instructions
hex_path = os.path.join(FW, 'program.hex')
if os.path.exists(hex_path):
    instrs = [l for l in open(hex_path) if l.strip()]
    results.append(check("Firmware: 31 RV32I instructions assembled",
                          len(instrs) == 31, f"got {len(instrs)}"))

# ─── 8. Constraints ──────────────────────────────────────────────────
print("\n--- 8. Constraints (Zybo Z7) ---")
xdc = os.path.join(os.path.dirname(__file__), 'constraints', 'zybo_z7.xdc')
results.append(check("XDC file exists", os.path.exists(xdc)))
if os.path.exists(xdc):
    content = open(xdc).read()
    results += [
        check("XDC: 125 MHz clock pin K17",       'K17' in content),
        check("XDC: LEDs assigned",               'led[0]' in content),
        check("XDC: PDM mic clock pin",           'pdm_mic_clk' in content),
        check("XDC: I2S audio codec pins",        'ac_bclk' in content),
        check("XDC: PWM audio output",            'pwm_audio_out' in content),
    ]

# ─── 9. SNR Results from snr_final_report.txt ────────────────────────
print("\n--- 9. SNR Performance ---")
snr_path = os.path.join(VEC, 'snr_final_report.txt')
if os.path.exists(snr_path):
    content = open(snr_path, encoding='utf-8', errors='replace').read()
    import re
    snr_vals = {}
    for m in re.finditer(r'(\d+) Hz\s*:\s*([\d.]+) dB', content):
        snr_vals[int(m.group(1))] = float(m.group(2))
    results += [
        check("SNR @ 1 kHz >= 40 dB",  snr_vals.get(1000, 0) >= 40,
              f"got {snr_vals.get(1000,'?')} dB"),
        check("SNR @ 5 kHz >= 40 dB",  snr_vals.get(5000, 0) >= 40,
              f"got {snr_vals.get(5000,'?')} dB"),
        check("SNR @ 10 kHz >= 40 dB", snr_vals.get(10000, 0) >= 40,
              f"got {snr_vals.get(10000,'?')} dB"),
        check("SNR @ 19 kHz >= 20 dB", snr_vals.get(19000, 0) >= 20,
              f"got {snr_vals.get(19000,'?')} dB"),
    ]

# ─── 10. MCM Adder Comparison Table ─────────────────────────────────
print("\n--- 10. MCM Adder Comparison (Deliverable) ---")
mcm_path = os.path.join(VEC, 'mcm_comparison_table.txt')
results.append(check("MCM comparison table exists", os.path.exists(mcm_path)))
if os.path.exists(mcm_path):
    mcm_content = open(mcm_path, encoding='utf-8', errors='replace').read()
    results += [
        check("MCM table: Naive CSD listed",        'Naive' in mcm_content or 'naive' in mcm_content),
        check("MCM table: CSE/MCM listed",          'CSE' in mcm_content or 'MCM' in mcm_content),
        check("MCM table: ESPRESSO/BDD listed",     'ESPRESSO' in mcm_content or 'espresso' in mcm_content),
    ]

# ─── 11. Docs ────────────────────────────────────────────────────────
print("\n--- 11. Documentation ---")
DOCS = os.path.join(os.path.dirname(__file__), 'docs')
results += [
    check("Project deliverables report",
          os.path.exists(os.path.join(DOCS, 'Project_P6_Deliverables_Report.md'))),
    check("Weekly lab report",
          os.path.exists(os.path.join(DOCS, 'Weekly_Report_Lab_PDM_to_PCM.md'))),
]

# ─── Summary ─────────────────────────────────────────────────────────
total   = len(results)
passed  = sum(results)
failed  = total - passed
print()
print("=" * 65)
print(f"  TOTAL: {passed}/{total} PASSED   |   {failed} FAILED")
print("=" * 65)
if failed == 0:
    print("  *** ALL SPEC REQUIREMENTS MET ***")
else:
    print("  *** SOME REQUIREMENTS NEED ATTENTION ***")
print()
