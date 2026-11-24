/**
 * @file pdm_audio_driver.h
 * @brief RV32 Firmware Driver for PDM-to-PCM Audio Front End APB Peripheral
 * @author Senior FPGA / DSP / RTL Systems Architect
 */

#ifndef PDM_AUDIO_DRIVER_H
#define PDM_AUDIO_DRIVER_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Base address on APB bus (customizable per SoC memory map)
#ifndef PDM_AUDIO_BASE_ADDR
#define PDM_AUDIO_BASE_ADDR 0x40002000UL
#endif

// Register Offsets
#define PDM_REG_CR         0x00U  // Control Register
#define PDM_REG_SR         0x04U  // Status Register
#define PDM_REG_GAIN       0x08U  // Digital Gain Register (Q4.12)
#define PDM_REG_DATA       0x0CU  // PCM FIFO Data Register (Read Pops)
#define PDM_REG_WATERMARK  0x10U  // FIFO Watermark Threshold Register
#define PDM_REG_RMS        0x14U  // Hardware RMS Energy Register
#define PDM_REG_VAD_THRESH 0x18U  // Hardware VAD Threshold Register

// Control Register Bit Masks
#define PDM_CR_ENABLE_BIT      (1U << 0)
#define PDM_CR_SOFT_RESET_BIT  (1U << 1)
#define PDM_CR_BYPASS_BIT      (1U << 2)
#define PDM_CR_IRQ_EN_BIT      (1U << 3)
#define PDM_CR_USE_PAPER_BIT   (1U << 4)
#define PDM_CR_USE_FOLDED_BIT  (1U << 5)

// Status Register Bit Masks
#define PDM_SR_FIFO_EMPTY_BIT  (1U << 0)
#define PDM_SR_FIFO_FULL_BIT   (1U << 1)
#define PDM_SR_OVERFLOW_BIT    (1U << 2)
#define PDM_SR_VAD_ACTIVE_BIT  (1U << 3)
#define PDM_SR_FIFO_LEVEL_MASK (0x7FU << 8)
#define PDM_SR_FIFO_LEVEL_POS  (8U)

// VAD State Machine States
typedef enum {
    VAD_STATE_SILENCE = 0,
    VAD_STATE_SPEECH_ONSET,
    VAD_STATE_SPEECH_ACTIVE,
    VAD_STATE_HANGOVER
} vad_state_t;

// PDM Audio Device Configuration Structure
typedef struct {
    uint32_t base_addr;
    uint16_t digital_gain_q12; // 0x1000 = 1.0x
    uint8_t  watermark_level;  // 1 to 64
    uint16_t vad_threshold;
    bool     bypass_mode;
    bool     use_paper_filter;
    bool     use_folded_hb2;
} pdm_audio_config_t;

// API Functions
void     pdm_audio_init(const pdm_audio_config_t *config);
void     pdm_audio_enable(bool enable);
void     pdm_audio_set_gain(float gain_float);
void     pdm_audio_set_bypass(bool bypass);
void     pdm_audio_set_filter_mode(bool use_paper, bool use_folded);
void     pdm_audio_set_watermark(uint8_t watermark);
uint8_t  pdm_audio_get_fifo_level(void);
bool     pdm_audio_is_fifo_empty(void);
int16_t  pdm_audio_read_sample(void);
uint32_t pdm_audio_read_block(int16_t *dest, uint32_t max_samples);
uint16_t pdm_audio_get_hw_rms(void);
bool     pdm_audio_get_hw_vad(void);

// Fast integer square root for RV32
uint32_t isqrt32(uint32_t val);

// Software RMS & VAD Processor
uint16_t pdm_compute_rms(const int16_t *samples, uint32_t count);
vad_state_t pdm_vad_process(uint16_t rms_val, uint16_t onset_thresh, uint16_t offset_thresh);

#ifdef __cplusplus
}
#endif

#endif // PDM_AUDIO_DRIVER_H
