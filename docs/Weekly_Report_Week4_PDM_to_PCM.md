# Weekly Lab Report: Microphone Audio Processing on FPGA
**Course:** RTL Design and Verification  
**Project:** PDM-to-PCM Audio Front End & RISC-V Audio Subsystem  
**Target Hardware:** Digilent Zybo Z7-10 FPGA Board (`XC7Z010CLG400-1`)  
**Reporting Period:** Week 4  

---

## 1. Quick Recap: Where We Were After Week 3

In Week 3, we:
- Translated the algorithms from research papers into **13 synthesizable Verilog modules**.
- Explored architectural tradeoffs: **Folded (shared MAC)** vs **Parallel** half-band downsamplers, and three multiplierless FIR methods.
- Simulated the hardware modules against our Python Golden Model, confirming **zero mismatches** across 50,000+ audio samples.

In Week 4, our goal was to run the complete design through the real FPGA synthesis tool (**AMD Vivado 2025.2**), resolve all physical board constraints, and extract actual **hardware resource utilization** and **power consumption numbers**.

---

## 2. Milestone: Synthesis & Implementation Succeeded!

We ran full synthesis and implementation in **AMD Vivado 2025.2** targeting the **Digilent Zybo Z7-10** board.

Both Synthesis and Implementation finished with **zero errors** and received a **clean green checkmark** (`Implementation Complete`).

```
[Verilog RTL Sources] ──> [Vivado Synthesis: 0 Errors] ──> [Place & Route: 0 Errors] ──> [Bitstream Generated]
```

---

## 3. Real FPGA Hardware Utilization Results

Now that Vivado has physically mapped our Verilog circuits into the FPGA slices, we have the official hardware resource counts:

| FPGA Resource | Used by Our Design | Total Available on Chip | Utilization % | What This Means in Plain English |
|---|:---:|:---:|:---:|---|
| **Slice LUTs** (Logic Gates) | **2,799** | 17,600 | **15.90%** | Exceptional area efficiency. Our entire audio chain + 32-bit RISC-V CPU takes under 16% of the FPGA. |
| **Slice Registers** (Flip-Flops) | **3,042** | 35,200 | **8.64%** | Very small memory-element footprint. |
| **Block RAM** (Audio Buffers) | **8.5 tiles** | 60 | **14.17%** | Holds the stored speech audio and FIFO buffer with over 85% RAM to spare. |
| **DSP Slices** (Multipliers) | **21** | 80 | **26.25%** | Only 21 hardware multipliers used across the whole design. |
| **Bonded I/O Pins** | **14** | 100 | **14.00%** | Clock, LEDs, switches, headphone output, and microphone lines. |
| **Global Clock Buffers** (BUFG) | **3** | 32 | **9.38%** | Clean low-skew clock distribution for 125 MHz, 12.288 MHz, and 3.072 MHz. |

### Why these numbers are a major achievement:
1. **84% of the FPGA is free:** We didn't overcrowd the chip. The audio pipeline is compact, leaving plenty of space for future additions (like active noise cancellation or Bluetooth audio).
2. **DSP Budget Protected:** In a naive FIR design, multiplying 31 filter taps would require over 90 hardware multipliers, which would overflow the 80 DSPs available on the chip. By using our **Common Subexpression Elimination (CSE)** math and **Folded Half-Band architecture**, we fit everything inside just **21 DSPs**.

### Deliverable 3: Out-Of-Context Vivado Synthesis Benchmark (Folded vs. Parallel Half-Band)

To evaluate the architectural trade-off on real silicon, both half-band downsampling implementations were synthesized Out-Of-Context (OOC) in AMD Vivado 2025.2 targeting the Zybo Z7-10 (`xc7z010clg400-1`):

| Architecture | Verilog Module | Slice LUTs | Slice Registers (FFs) | DSP Slices (`DSP48E1`) | Throughput / Clock Cycles | Architectural Impact |
|---|---|:---:|:---:|:---:|:---:|---|
| **Folded Half-Band** | `hb_filter_folded.v` | **493** (468 logic) | **810** | **2 DSPs** | 9 cycles / sample | **77.8% DSP Savings** (conserves 14 DSPs across HB1 & HB2) |
| **Parallel Half-Band** | `hb_filter_parallel.v` | **260** | **770** | **9 DSPs** | 1 cycle / sample | Full unrolled direct-form (uses 18 DSPs total for 2 stages) |

**Key Takeaways:**
- **Silicon Area vs. DSP Trade-off:** Parallel half-band achieves single-cycle throughput and uses fewer LUTs (260 vs 493), but consumes 9 DSP slices per stage. On the Zybo Z7-10 with only 80 DSPs available, two parallel half-band stages would burn 22.5% of all DSP blocks.
- **Resource Selection:** Because our audio sample clock at 192 kHz gives 64 master clock cycles per sample (at 12.288 MHz), the Folded architecture's 9-cycle latency is completely imperceptible and well within timing budget. Selecting Folded Half-Band protects 14 DSP slices across the pipeline while maintaining identical 16-bit PCM fidelity.

---

## 4. Real FPGA Power Consumption Analysis

Vivado's thermal and power analyzer measured our implemented netlist:

| Power Category | Measured Value | Percentage | Notes |
|---|:---:|:---:|---|
| **Total On-Chip Power** | **0.182 W (182 mW)** | 100% | Ultra-low power consumption. |
| **Dynamic Power** | **0.102 W (102 mW)** | 56% | Active switching of filters, clocks, and CPU. |
| **Device Static Power** | **0.080 W (80 mW)** | 44% | Natural standby silicon leakage. |

### Thermal Performance:
- **Junction Temperature:** **27.1 °C** (Ambient room temperature is 25.0 °C).
- **Thermal Safety Margin:** **72.9 °C** remaining before hitting thermal limits.
- **Takeaway:** The chip barely warms up by **2.1 °C** during full audio processing! This proves our system is ideally suited for battery-powered, handheld smart microphones or portable recording equipment.

---

## 5. Engineering Problem-Solving During Vivado Setup

During the transition from simulation to Vivado implementation, we encountered and resolved two critical physical hardware issues:

### 1. Chip Package Pin Alignment
* **The Problem:** The initial project setup defaulted to a 225-pin package (`xc7z010iclg225`), causing Vivado to report that pins like `K17` (125 MHz clock) and `P16` (button) were invalid.
* **The Solution:** We updated the project settings to the correct **400-pin Zybo Z7 package (`xc7z010clg400-1`)** and verified all 14 pins against Digilent's official Master XDC schematic.

### 2. Block RAM Sizing & Cascade DRC Resolution
* **The Problem:** Trying to store 0.5 seconds of uncompressed PDM audio (1.5 million bits) in FPGA Block RAM required 48 BRAM blocks. Since the XC7Z010 chip only has 30 BRAM blocks total, Vivado attempted an illegal cascade configuration that failed DRC place checks (`[DRC REQP-1962]`).
* **The Solution:** 
  - We sized the onboard test audio stream to **192,000 bits (24,000 bytes)**, which represents 0.0625 seconds of speech audio.
  - At 48 kHz, this produces a continuous, seamless audio loop that needs **only 8.5 Block RAM tiles** (14% of the chip).
  - We updated the memory interface to clean synchronous Block RAM, completely eliminating the DRC error.

### 3. Dual Input Switcher on Switch 2 (`SW2`)
We added a multiplexer to the top module allowing instant switching during the live lab demo:
* **SW2 = DOWN (0):** Plays the pre-recorded speech clip stored in Block RAM (no physical mic needed).
* **SW2 = UP (1):** Streams live voice input from an external PDM microphone module plugged into Pmod header JE.

---

## 6. What We Completed in Week 4

1. ✅ **Successfully ran full Synthesis & Implementation** in AMD Vivado 2025.2 targeting the Zybo Z7-10 (`xc7z010clg400-1`).
2. ✅ **Extracted official hardware utilization figures:** 2,799 LUTs (15.9%), 3,042 FFs (8.6%), 21 DSPs (26.3%), 8.5 BRAMs (14.2%).
3. ✅ **Extracted official power analysis:** 182 mW total power (102 mW dynamic, 80 mW static) at 27.1 °C.
4. ✅ **Resolved physical package constraints & BRAM DRC checks.**
5. ✅ **Generated the FPGA bitstream** ready for hardware download.

---

## 7. Next Steps (Week 5: Board Demonstration)

1. Connect the physical Digilent Zybo Z7-10 board via micro-USB.
2. Open Vivado **Hardware Manager** and program the FPGA with our bitstream (`top.bit`).
3. Plug standard 3.5mm headphones into Pmod JA (Pin 1) to listen to the continuous, filtered audio playback.
4. Demonstrate real-time **Voice Activity Detection** and the **4-LED VU volume meter** driven by the RISC-V processor.
