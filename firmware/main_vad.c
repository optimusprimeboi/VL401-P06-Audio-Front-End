/**
 * @file main_vad.c
 * @brief Main Application: RV32 Voice Activity Detection & Audio VU Meter
 */

#include "pdm_audio_driver.h"

#define FRAME_SIZE 128
static int16_t audio_buffer[FRAME_SIZE];

// Simulated GPIO LED register address on FPGA SoC
#define GPIO_LEDS (*(volatile uint32_t *)(0x40001000UL))

void pdm_audio_isr(void) {
    // Watermark IRQ Service Routine
    uint32_t samples_read = pdm_audio_read_block(audio_buffer, FRAME_SIZE);
    if (samples_read == FRAME_SIZE) {
        // Calculate software RMS
        uint16_t rms = pdm_compute_rms(audio_buffer, FRAME_SIZE);
        
        // VAD decision
        vad_state_t vad = pdm_vad_process(rms, 1200, 600);
        
        // Map RMS level to 7-bit logarithmic VU meter
        uint8_t vu = 0;
        if (rms > 16384)      vu = 0x7F;
        else if (rms > 8192)  vu = 0x3F;
        else if (rms > 4096)  vu = 0x1F;
        else if (rms > 2048)  vu = 0x0F;
        else if (rms > 1024)  vu = 0x07;
        else if (rms > 512)   vu = 0x03;
        else if (rms > 256)   vu = 0x01;
        
        // Bit 7 is VAD detection LED
        uint8_t vad_led = (vad == VAD_STATE_SPEECH_ACTIVE || vad == VAD_STATE_HANGOVER) ? 0x80 : 0x00;
        
        GPIO_LEDS = (uint32_t)(vad_led | vu);
    }
}

int main(void) {
    pdm_audio_config_t config = {
        .base_addr        = PDM_AUDIO_BASE_ADDR,
        .digital_gain_q12 = 0x1000, // 1.0x gain
        .watermark_level  = 32,     // Fire IRQ every 32 samples (~0.67 ms)
        .vad_threshold    = 0x0150,
        .bypass_mode      = false,
        .use_paper_filter = false,  // Use primary 9-tap filter
        .use_folded_hb2   = false   // Use parallel U3 Graph filter
    };
    
    pdm_audio_init(&config);
    
    // Enable system interrupts
    // asm volatile("csrsi mstatus, 0x8"); // Enable MIE on RV32
    
    while (1) {
        // Background polling loop if interrupts not mapped
        if (pdm_audio_get_fifo_level() >= 32) {
            pdm_audio_isr();
        }
    }
    
    return 0;
}
