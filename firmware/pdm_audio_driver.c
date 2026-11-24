/**
 * @file pdm_audio_driver.c
 * @brief RV32 Firmware Driver Implementation for PDM-to-PCM Audio APB Peripheral
 */

#include "pdm_audio_driver.h"

// Hardware Register Access Macros
#define REG32(addr) (*(volatile uint32_t *)(addr))

static uint32_t s_base_addr = PDM_AUDIO_BASE_ADDR;
static vad_state_t s_vad_state = VAD_STATE_SILENCE;
static uint32_t s_hangover_counter = 0;
#define HANGOVER_FRAMES 10

void pdm_audio_init(const pdm_audio_config_t *config) {
    if (config != 0) {
        s_base_addr = config->base_addr;
    }
    
    // Assert soft reset
    REG32(s_base_addr + PDM_REG_CR) = PDM_CR_SOFT_RESET_BIT;
    
    // Configure default gain (0x1000 = 1.0)
    uint16_t gain = (config && config->digital_gain_q12) ? config->digital_gain_q12 : 0x1000U;
    REG32(s_base_addr + PDM_REG_GAIN) = gain;
    
    // Configure watermark
    uint8_t wm = (config && config->watermark_level) ? config->watermark_level : 16U;
    REG32(s_base_addr + PDM_REG_WATERMARK) = wm;
    
    // Configure VAD threshold
    uint16_t vad_th = (config && config->vad_threshold) ? config->vad_threshold : 0x0100U;
    REG32(s_base_addr + PDM_REG_VAD_THRESH) = vad_th;
    
    // Build Control Register Value
    uint32_t cr = PDM_CR_ENABLE_BIT | PDM_CR_IRQ_EN_BIT;
    if (config && config->bypass_mode)      cr |= PDM_CR_BYPASS_BIT;
    if (config && config->use_paper_filter) cr |= PDM_CR_USE_PAPER_BIT;
    if (config && config->use_folded_hb2)   cr |= PDM_CR_USE_FOLDED_BIT;
    
    REG32(s_base_addr + PDM_REG_CR) = cr;
    s_vad_state = VAD_STATE_SILENCE;
    s_hangover_counter = 0;
}

void pdm_audio_enable(bool enable) {
    uint32_t cr = REG32(s_base_addr + PDM_REG_CR);
    if (enable) cr |= PDM_CR_ENABLE_BIT;
    else        cr &= ~PDM_CR_ENABLE_BIT;
    REG32(s_base_addr + PDM_REG_CR) = cr;
}

void pdm_audio_set_gain(float gain_float) {
    if (gain_float < 0.0f) gain_float = 0.0f;
    if (gain_float > 7.99f) gain_float = 7.99f;
    uint16_t q12 = (uint16_t)(gain_float * 4096.0f);
    REG32(s_base_addr + PDM_REG_GAIN) = q12;
}

void pdm_audio_set_bypass(bool bypass) {
    uint32_t cr = REG32(s_base_addr + PDM_REG_CR);
    if (bypass) cr |= PDM_CR_BYPASS_BIT;
    else        cr &= ~PDM_CR_BYPASS_BIT;
    REG32(s_base_addr + PDM_REG_CR) = cr;
}

void pdm_audio_set_filter_mode(bool use_paper, bool use_folded) {
    uint32_t cr = REG32(s_base_addr + PDM_REG_CR);
    if (use_paper)  cr |= PDM_CR_USE_PAPER_BIT;
    else            cr &= ~PDM_CR_USE_PAPER_BIT;
    if (use_folded) cr |= PDM_CR_USE_FOLDED_BIT;
    else            cr &= ~PDM_CR_USE_FOLDED_BIT;
    REG32(s_base_addr + PDM_REG_CR) = cr;
}

void pdm_audio_set_watermark(uint8_t watermark) {
    REG32(s_base_addr + PDM_REG_WATERMARK) = (uint32_t)watermark;
}

uint8_t pdm_audio_get_fifo_level(void) {
    uint32_t sr = REG32(s_base_addr + PDM_REG_SR);
    return (uint8_t)((sr & PDM_SR_FIFO_LEVEL_MASK) >> PDM_SR_FIFO_LEVEL_POS);
}

bool pdm_audio_is_fifo_empty(void) {
    return (REG32(s_base_addr + PDM_REG_SR) & PDM_SR_FIFO_EMPTY_BIT) != 0;
}

int16_t pdm_audio_read_sample(void) {
    // Reading DATA register returns 16-bit PCM and pops FIFO entry
    return (int16_t)(REG32(s_base_addr + PDM_REG_DATA) & 0xFFFFU);
}

uint32_t pdm_audio_read_block(int16_t *dest, uint32_t max_samples) {
    uint32_t count = 0;
    while (count < max_samples && !pdm_audio_is_fifo_empty()) {
        dest[count++] = pdm_audio_read_sample();
    }
    return count;
}

uint16_t pdm_audio_get_hw_rms(void) {
    return (uint16_t)(REG32(s_base_addr + PDM_REG_RMS) & 0xFFFFU);
}

bool pdm_audio_get_hw_vad(void) {
    return (REG32(s_base_addr + PDM_REG_SR) & PDM_SR_VAD_ACTIVE_BIT) != 0;
}

// Fast integer square root using binary search / bit-by-bit method
uint32_t isqrt32(uint32_t val) {
    uint32_t res = 0;
    uint32_t bit = 1UL << 30; // Second-to-top bit
    
    while (bit > val) bit >>= 2;
    
    while (bit != 0) {
        if (val >= res + bit) {
            val -= res + bit;
            res = (res >> 1) + bit;
        } else {
            res >>= 1;
        }
        bit >>= 2;
    }
    return res;
}

uint16_t pdm_compute_rms(const int16_t *samples, uint32_t count) {
    if (count == 0) return 0;
    uint64_t sum_sq = 0;
    for (uint32_t i = 0; i < count; i++) {
        int32_t s = (int32_t)samples[i];
        sum_sq += (uint64_t)(s * s);
    }
    uint32_t mean_sq = (uint32_t)(sum_sq / count);
    return (uint16_t)isqrt32(mean_sq);
}

vad_state_t pdm_vad_process(uint16_t rms_val, uint16_t onset_thresh, uint16_t offset_thresh) {
    switch (s_vad_state) {
        case VAD_STATE_SILENCE:
            if (rms_val >= onset_thresh) {
                s_vad_state = VAD_STATE_SPEECH_ONSET;
            }
            break;
            
        case VAD_STATE_SPEECH_ONSET:
            if (rms_val >= onset_thresh) {
                s_vad_state = VAD_STATE_SPEECH_ACTIVE;
            } else {
                s_vad_state = VAD_STATE_SILENCE;
            }
            break;
            
        case VAD_STATE_SPEECH_ACTIVE:
            if (rms_val < offset_thresh) {
                s_vad_state = VAD_STATE_HANGOVER;
                s_hangover_counter = HANGOVER_FRAMES;
            }
            break;
            
        case VAD_STATE_HANGOVER:
            if (rms_val >= onset_thresh) {
                s_vad_state = VAD_STATE_SPEECH_ACTIVE;
            } else if (s_hangover_counter > 0) {
                s_hangover_counter--;
            } else {
                s_vad_state = VAD_STATE_SILENCE;
            }
            break;
            
        default:
            s_vad_state = VAD_STATE_SILENCE;
            break;
    }
    return s_vad_state;
}
