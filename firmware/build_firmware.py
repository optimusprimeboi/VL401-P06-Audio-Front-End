"""
Firmware Assembler for RV32I Soft Core
Generates exact 32-bit RISC-V binary machine code.
"""

import os

def r_type(funct7, rs2, rs1, funct3, rd, opcode=0x33):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def i_type(imm, rs1, funct3, rd, opcode=0x13):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode

def s_type(imm, rs2, rs1, funct3, opcode=0x23):
    imm11_5 = (imm >> 5) & 0x7F
    imm4_0  = imm & 0x1F
    return (imm11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (imm4_0 << 7) | opcode

def b_type(imm, rs1, rs2, funct3, opcode=0x63):
    b12   = (imm >> 12) & 0x1
    b10_5 = (imm >> 5) & 0x3F
    b4_1  = (imm >> 1) & 0xF
    b11   = (imm >> 11) & 0x1
    return (b12 << 31) | (b10_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (b4_1 << 8) | (b11 << 7) | opcode

def u_type(imm, rd, opcode=0x37):
    return (imm & 0xFFFFF000) | (rd << 7) | opcode

def j_type(imm, rd, opcode=0x6F):
    j20   = (imm >> 20) & 0x1
    j10_1 = (imm >> 1) & 0x3FF
    j11   = (imm >> 11) & 0x1
    j19_12= (imm >> 12) & 0xFF
    return (j20 << 31) | (j10_1 << 21) | (j11 << 20) | (j19_12 << 12) | (rd << 7) | opcode

# Registers:
# x1: APB Audio Base (0x40000000)
# x2: GPIO LEDs Base (0x40001000)
# x3: Count (0..64)
# x4: Accumulator sum of absolute audio values
# x5: Sample / scratch
# x6: Computed RMS / Average Level
# x7: LED pattern
# x8: VAD Threshold (600)

instructions = [
    # 0x00: lui x1, 0x40000           (APB Base: 0x40000000)
    u_type(0x40000000, 1, 0x37),
    # 0x04: lui x2, 0x40001           (GPIO Base: 0x40001000)
    u_type(0x40001000, 2, 0x37),
    # 0x08: addi x8, x0, 600          (VAD Threshold = 600)
    i_type(600, 0, 0x0, 8, 0x13),
    
    # LOOP_START:
    # 0x0C: addi x3, x0, 0            (count = 0)
    i_type(0, 0, 0x0, 3, 0x13),
    # 0x10: addi x4, x0, 0            (sum = 0)
    i_type(0, 0, 0x0, 4, 0x13),

    # SAMPLE_WAIT:
    # 0x14: lw x5, 8(x1)              (read STATUS)
    i_type(8, 1, 0x2, 5, 0x03),
    # 0x18: andi x5, x5, 1            (check fifo_empty)
    i_type(1, 5, 0x7, 5, 0x13),
    # 0x1C: bne x5, x0, -8            (if empty, wait at 0x14)
    b_type(-8, 5, 0, 0x1, 0x63),

    # 0x20: lw x5, 12(x1)             (read PCM_DATA)
    i_type(12, 1, 0x2, 5, 0x03),
    # 0x24: bge x5, x0, 8             (if x5 >= 0, skip negate -> jump to 0x2C)
    b_type(8, 5, 0, 0x5, 0x63),
    # 0x28: sub x5, x0, x5            (x5 = -x5, absolute value)
    r_type(0x20, 5, 0, 0x0, 5, 0x33),
    
    # 0x2C: add x4, x4, x5            (sum += abs(sample))
    r_type(0x00, 5, 4, 0x0, 4, 0x33),
    # 0x30: addi x3, x3, 1            (count++)
    i_type(1, 3, 0x0, 3, 0x13),
    # 0x34: addi x5, x0, 64           (window target = 64)
    i_type(64, 0, 0x0, 5, 0x13),
    # 0x38: blt x3, x5, -36           (if count < 64, loop back to 0x14)
    b_type(-36, 3, 5, 0x4, 0x63),

    # 0x3C: srai x6, x4, 6            (level = sum >> 6, funct7=0x20)
    i_type(0x400 | 6, 4, 0x5, 6, 0x13),
    # 0x40: sw x6, 32(x1)             (write REG_RMS_LEVEL at offset 0x20)
    s_type(32, 6, 1, 0x2, 0x23),

    # 0x44: slt x5, x8, x6            (vad = (threshold < level))
    r_type(0x00, 6, 8, 0x2, 5, 0x33),
    # 0x48: sw x5, 36(x1)             (write REG_VAD_STATUS at offset 0x24)
    s_type(36, 5, 1, 0x2, 0x23),

    # Compute LED VU Meter
    # 0x4C: addi x7, x0, 0            (leds = 0)
    i_type(0, 0, 0x0, 7, 0x13),
    # 0x50: addi x5, x0, 100          (level 1 threshold)
    i_type(100, 0, 0x0, 5, 0x13),
    # 0x54: blt x6, x5, 32            (if level < 100, jump to LED_STORE at 0x74)
    b_type(32, 6, 5, 0x4, 0x63),
    # 0x58: ori x7, x7, 1             (leds |= 0x1)
    i_type(1, 7, 0x6, 7, 0x13),
    # 0x5C: addi x5, x0, 300          (level 2 threshold)
    i_type(300, 0, 0x0, 5, 0x13),
    # 0x60: blt x6, x5, 20            (if level < 300, jump to LED_STORE at 0x74)
    b_type(20, 6, 5, 0x4, 0x63),
    # 0x64: ori x7, x7, 3             (leds |= 0x3)
    i_type(3, 7, 0x6, 7, 0x13),
    # 0x68: addi x5, x0, 700          (level 3 threshold)
    i_type(700, 0, 0x0, 5, 0x13),
    # 0x6C: blt x6, x5, 8             (if level < 700, jump to LED_STORE at 0x74)
    b_type(8, 6, 5, 0x4, 0x63),
    # 0x70: ori x7, x7, 12            (leds |= 0xF)
    i_type(12, 7, 0x6, 7, 0x13),

    # LED_STORE:
    # 0x74: sw x7, 0(x2)              (write GPIO_LEDS at 0x40001000)
    s_type(0, 7, 2, 0x2, 0x23),

    # 0x78: jal x0, -108              (jump back to LOOP_START at 0x0C)
    j_type(-108, 0, 0x6F)
]

out_dir = os.path.dirname(__file__)
hex_file = os.path.join(out_dir, "program.hex")
with open(hex_file, "w") as f:
    for word in instructions:
        f.write(f"{word:08x}\n")

# Copy program.hex to simulation and synthesis folders
copy_targets = [
    os.path.join(out_dir, "..", "sim", "program.hex"),
    os.path.join(out_dir, "..", "sim", "vectors", "program.hex"),
    os.path.join(out_dir, "..", "program.hex")
]
for dst in copy_targets:
    try:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "w") as f:
            for word in instructions:
                f.write(f"{word:08x}\n")
    except Exception as e:
        print(f"Notice: could not copy to {dst}: {e}")

print(f"Firmware built successfully! {len(instructions)} instructions -> {hex_file}")
