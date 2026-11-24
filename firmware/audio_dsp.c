// =============================================================================
// File    : audio_dsp.c
// Project : P6 PDM-to-PCM Audio Front End
// Purpose : RV32I Embedded Firmware: RMS Audio Level & Voice Activity Detection
// =============================================================================

#include <stdint.h>

#define APB_AUDIO_BASE    0x40000000
#define REG_CTRL          (*(volatile uint32_t *)(APB_AUDIO_BASE + 0x00))
#define REG_GAIN          (*(volatile uint32_t *)(APB_AUDIO_BASE + 0x04))
#define REG_STATUS        (*(volatile uint32_t *)(APB_AUDIO_BASE + 0x08))
#define REG_PCM_DATA      (*(volatile int32_t  *)(APB_AUDIO_BASE + 0x0C))
#define REG_RMS_LEVEL     (*(volatile uint32_t *)(APB_AUDIO_BASE + 0x20))
#define REG_VAD_STATUS    (*(volatile uint32_t *)(APB_AUDIO_BASE + 0x24))

#define GPIO_LEDS         (*(volatile uint32_t *)(0x40001000))

#define WINDOW_SIZE       128
#define VAD_THRESHOLD     800  // Sensitivity threshold for voice detection

// Fast integer square root
uint32_t isqrt(uint32_t val) {
    uint32_t res = 0;
    uint32_t bit = 1u << 30; // Second-to-top bit set

    while (bit > val)
        bit >>= 2;

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

int main(void) {
    // Default audio front-end setup
    REG_GAIN = 0x80; // 1.0x gain

    while (1) {
        uint64_t sum_sq = 0;
        int count = 0;

        // Collect WINDOW_SIZE samples from PCM FIFO
        while (count < WINDOW_SIZE) {
            // Check if FIFO not empty (bit 0 of STATUS)
            if (!(REG_STATUS & 0x01)) {
                int16_t sample = (int16_t)REG_PCM_DATA;
                sum_sq += (int32_t)sample * (int32_t)sample;
                count++;
            }
        }

        // Calculate RMS: sqrt(sum_sq / WINDOW_SIZE)
        uint32_t mean_sq = (uint32_t)(sum_sq / WINDOW_SIZE);
        uint32_t rms = isqrt(mean_sq);

        // Update RMS register
        REG_RMS_LEVEL = rms;

        // Simple Voice Activity Detection (VAD)
        uint32_t vad = (rms >= VAD_THRESHOLD) ? 1 : 0;
        REG_VAD_STATUS = vad;

        // Drive 4-LED logarithmic VU meter on Zybo Z7
        uint32_t leds = 0;
        if (rms > 200)   leds |= 0x01;
        if (rms > 800)   leds |= 0x02;
        if (rms > 3200)  leds |= 0x04;
        if (rms > 12000) leds |= 0x08;

        GPIO_LEDS = leds;
    }

    return 0;
}
