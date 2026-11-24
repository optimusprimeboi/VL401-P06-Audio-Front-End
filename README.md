# VL401: RTL Design & Verification — Final Course Submission
## Project P06: PDM-to-PCM Audio Front End for MEMS Microphones
**Institution:** School of Computing and Electrical Engineering (SCEE), IIT Mandi  
**Instructor:** Dr. Bikram Paul | **Semester:** Odd Semester 2026  
**Group 06:**
* **Sarthak Kharwar** (Roll No: `B24498`)
* **Avanish Patel** (Roll No: `B24478`)

**Target Hardware:** Digilent Zybo Z7-10 (`XC7Z010CLG400-1`)  
**Audio Output:** Analog Devices SSM2603 Audio Codec (3.5mm Headphone Jack J5 `HPH OUT`)  
**Input:** 3.072 MHz 1-bit PDM stream $\longrightarrow$ **Output:** 48 kHz 16-bit Hi-Fi PCM Audio

---

## 1. Directory Structure & Organization

The submission package is structured into standard industrial electronic design automation (EDA) folders:

```
VL401_Group06_P06_Submission/
├── rtl/                        # Synthesizable Verilog RTL source files
│   ├── cic_decimator.v         # 4-stage CIC Decimator (R=16, N=4, multiplierless 24-bit)
│   ├── cic_compensation_fir.v  # 9-tap Remez Droop Compensation FIR (192 kHz)
│   ├── paper_dolecek_compensation.v # IEEE 2005 Research Paper Filter (2 adders, 0 mults)
│   ├── halfband_stage1.v       # 11-tap Half-Band Decimator 1 (192 kHz -> 96 kHz)
│   ├── halfband_stage2.v       # 23-tap Half-Band Decimator 2 (96 kHz -> 48 kHz, Parallel)
│   ├── halfband_fir_folded.v   # Folded Hand-HLS Architecture (Single Shared MAC ALU)
│   ├── mcm_hb2_naive.v         # Baseline CSD Multiplier Block (15 adders)
│   ├── mcm_hb2_cse.v           # Common Subexpression Elimination MCM (8 adders)
│   ├── mcm_hb2_graph_u3.v      # U3 Difference Graph Optimal MCM (7 adders, 53.3% savings)
│   ├── saturation_unit.v       # ESPRESSO/BDD-minimized 24-bit to 16-bit Saturation Unit
│   ├── pcm_fifo.v              # 64/128-word circular PCM FIFO with Watermark & Overflow IRQ
│   ├── vad_engine.v            # Real-time Hardware RMS Power Computer & VAD FSM
│   ├── apb_pdm_top.v           # AMBA APB3 Slave Bus Interface for Gain/Bypass/Status
│   ├── rv32i_core.v            # Embedded 32-bit RISC-V Soft Core (executes DSP firmware)
│   ├── bram_pdm_player.v       # On-chip PDM stream player (440 Hz pure tone & multi-tone)
│   ├── i2s_transmitter.v       # Standard Philips I2S Audio Master Controller
│   ├── pwm_audio_dac.v         # 1-bit Delta-Sigma PWM DAC for secondary speaker output
│   ├── pdm_top.v               # Top-level Audio Pipeline Integration Subsystem
│   ├── include/                # Header files
│   │   └── filter_coeffs.vh    # Quantized 16-bit signed filter coefficients
│   └── zybo/                   # Board Support Package for Digilent Zybo Z7-10
│       ├── zybo_clock_wiz.v    # 7-Series MMCM primitive (125 MHz -> 49.152 MHz / 12.288 MHz)
│       ├── ssm2603_i2c_init.v  # Autonomous 50 kHz I2C master initializing SSM2603 codec
│       └── zybo_z7_top.v       # Board Top-Level (debouncers, volume FSM, LEDs, pins)
│
├── tb/                         # Simulation Testbenches
│   ├── tb_pdm_top.sv           # Comprehensive SystemVerilog self-checking testbench
│   ├── tb_cic_decimator.v      # Dedicated CIC module testbench
│   ├── tb_top_system.v         # Behavioral system testbench with waveform probes
│   ├── sim_top_system.py       # Bit-exact Python test harness verifying RTL equivalence
│   ├── sim_cic.py              # Python-driven CIC unit test
│   ├── sim_comp_fir.py         # Python-driven FIR unit test
│   ├── sim_halfband.py         # Python-driven Half-Band unit test
│   └── sim_rv32i.py            # Python RV32I instruction set verification
│
├── golden/                     # Python Golden Reference Models & DSP Design
│   ├── filter_design.py        # Remez equiripple and half-band coefficient generator
│   ├── sdm_golden_pipeline.py  # Bit-accurate floating/fixed-point decimation simulator
│   ├── mcm_and_saturation_optimizer.py # U3 graph generator & ESPRESSO logic minimizer
│   ├── espresso_bdd_analysis.py# 2-level boolean reduction for saturation unit
│   ├── verify_rtl_equivalence.py # Automated L_inf cross-check (RTL vs Python model)
│   ├── snr_test.py             # Audio band THD+N and ENOB calculator (SNR > 72 dB)
│   ├── chain.py                # End-to-end decimation chain model
│   ├── cic_model.py            # Hogenauer integer bit-growth model
│   └── pdm_gen.py              # 1st-order Sigma-Delta modulator test generator
│
├── firmware/                   # Embedded RISC-V Software
│   ├── audio_dsp.c             # C source code: RMS level & Voice Activity Detection (VAD)
│   ├── main_vad.c              # Standalone VAD algorithm demo
│   ├── pdm_audio_driver.c/.h   # Low-level hardware drivers for APB audio registers
│   ├── build_firmware.py       # Python script assembling C firmware into program.hex
│   └── program.hex             # Assembled 32-bit RISC-V machine instructions
│
├── formal/                     # Formal Verification (SymbiYosys & SVA Assertions)
│   ├── fifo_safety.sby         # SymbiYosys proof configuration for FIFO safety
│   ├── fifo_safety.sv          # SVA: Proves AG(!(full & wr_en)) and count <= 128
│   ├── pipeline_liveness.sby   # SymbiYosys proof configuration for sample liveness
│   ├── pipeline_liveness.sv    # SVA: Proves AG(pdm_tick -> AF[1:16] pcm_valid)
│   └── pdm_properties.sv       # Comprehensive temporal logic properties
│
├── constraints/                # Physical Constraints
│   └── zybo_z7.xdc             # Complete Master XDC for Digilent Zybo Z7-10 (125 MHz clock)
│
├── bitstream/                  # Pre-compiled, Silicon-Verified Hardware Binaries
│   ├── zybo_z7_top.bit         # Ready-to-program bitstream for Zybo Z7-10
│   └── zybo_z7_audio.xsa       # Hardware handoff platform for Vitis/embedded software
│
├── docs/                       # Course project deliverables and technical reports
│   ├── Project_P6_Deliverables_Report.md
│   └── Weekly_Report_Lab_PDM_to_PCM.md
├── VL401_P06.pdf               # Complete 22-Page Final Project Academic Report (PDF)
├── VL401_G06_P06.pdf           # Primary Report Deliverable (Group 06)
├── build_project.tcl           # Automated Vivado project generator and bitstream builder
├── pdm_stimulus_words.hex      # 192,000-bit pre-recorded test audio stream
└── program.hex                 # Compiled RISC-V firmware ROM
```

---

## 2. Quick-Start Guide

### Rebuilding the Vivado Project & Bitstream
To recreate the Vivado project from source and generate the bitstream:
```bash
# In AMD Vivado (Command Prompt or Batch Mode):
vivado -mode batch -source build_project.tcl -tclargs xc7z010clg400-1
```
The script will:
1. Create the `zybo_audio` project in `./vivado_project_audio/`.
2. Add all synthesizable RTL files, test memory hex files, and `zybo_z7.xdc`.
3. Run synthesis and implementation with timing closure ($49.152\text{ MHz}$).
4. Generate the bitstream into `bitstream/zybo_z7_top.bit`.

---

### Running Formal Verification (SymbiYosys)
```bash
# Run FIFO safety proof (Proves no overflow under bounded backpressure):
sby -f formal/fifo_safety.sby

# Run Decimation pipeline liveness proof (Proves bounded sample delivery):
sby -f formal/pipeline_liveness.sby
```

---

### Running Python Golden Models & Equivalency Checks
```bash
# Run golden decimation simulation and generate plots:
python golden/sdm_golden_pipeline.py

# Verify bit-accurate RTL equivalence against Python golden model:
python golden/verify_rtl_equivalence.py

# Run SNR and ENOB analysis:
python golden/snr_test.py
```

---

## 3. Hardware Interactive Demonstration Guide (Zybo Z7-10)

Plug standard $3.5\text{mm}$ stereo earphones into **Jack J5 (`HPH OUT`)**, connect the micro-USB cable to `PROG/UART J12`, and program `bitstream/zybo_z7_top.bit` using Vivado Hardware Manager.

### Control Mapping:
* **`SW0` (Play / Mute Guard)**:
  * **DOWN (0)**: Complete digital silence ($0\text{x}0000$), all 4 LEDs strictly OFF (`4'b0000`).
  * **UP (1)**: Audio playback active, discrete volume LED illuminates.
* **`SW3` (Filter Mode vs. Bypass)**:
  * **DOWN (0)**: **Decimated Hi-Fi Mode** (engages Remez FIR + Half-Band filters to produce smooth, clean $48\text{ kHz}$ PCM).
  * **UP (1)**: **Raw CIC Bypass Mode** (bypasses FIR filters, exposing raw $192\text{ kHz}$ harmonics and louder high-frequency sound).
* **`SW1` (Filter Selection)**:
  * Toggles between standard 9-Tap Remez FIR (0) and 3-Tap Dolecek IEEE 2005 Paper Filter (1).
* **`SW2` (Architecture Selection)**:
  * Toggles between Parallel U3 Graph MCM (0) and Folded Hand-HLS FIR (1).
* **`BTN1` / `BTN2` (Discrete Volume Down / Up)**:
  * **`BTN1`**: Decreases volume by stepping down gain. Active LED moves left.
  * **`BTN2`**: Increases volume by stepping up gain. Active LED moves right.
* **`BTN3` (Tone Selector)**:
  * Toggles between pure $440\text{ Hz}$ Concert Pitch A4 sine tone and $20\text{ ms}$ multi-frequency test tone.
* **`BTN0` (System Reset)**:
  * Active-high pushbutton reset.

### 4-Level Dot-Mode Volume Indicator:
* **Level 0 (Quiet, $-18\text{ dB}$)**: Only **`LD0`** is ON `[0001]`
* **Level 1 (Medium, $-8.5\text{ dB}$)**: Only **`LD1`** is ON `[0010]`
* **Level 2 (Normal, $0\text{ dB}$ default)**: Only **`LD2`** is ON `[0100]`
* **Level 3 (Loud, $+7\text{ dB}$)**: Only **`LD3`** is ON `[1000]`

---

## 4. Key Academic & Research Highlights

1. **Multiplierless Optimization**: The U3 difference graph MCM reduces constant multipliers for 31 symmetric taps from 15 to **7 adders ($53.3\%$ reduction)**.
2. **ESPRESSO Saturation Logic**: Minimized $24\text{-bit} \rightarrow 16\text{-bit}$ convergent rounding & saturation down to **10 slice LUTs**.
3. **Research Paper Deliverable**: Implemented the **Dolecek & Mitra (IEEE TCAS-II 2005) 3-tap compensation filter**, achieving an **$83.3\%$ adder reduction** and **$80.1\%$ LUT savings** over standard Remez designs.
4. **Silicon-Grade Clocking**: Uses Xilinx 7-Series `MMCME2_ADV` primitive with `ODDR` pad forwarding for sub-picosecond clock jitter on the SSM2603 audio DAC.
5. **Software/Hardware Co-Design**: Embedded 32-bit RISC-V soft core (`rv32i_core.v`) executing C firmware for windowed RMS power computation and Voice Activity Detection.
