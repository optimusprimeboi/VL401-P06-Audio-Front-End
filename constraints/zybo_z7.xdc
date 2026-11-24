################################################################################
# zybo_z7.xdc — Vivado XDC Constraints for Digilent Zybo Z7-10 (XC7Z010-1CLG400C)
#
# Target Board : Digilent Zybo Z7-10
# Headphone Out: Jack J5 (HPH OUT) powered by Analog Devices SSM2603
# Board Clock  : 125.000 MHz Single-Ended Clock on Pin K17
################################################################################

# ------------------------------------------------------------------------------
# 1. Primary Clock (125 MHz on Pin K17 for Zybo Z7)
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN K17 [get_ports sysclk]
set_property IOSTANDARD LVCMOS33 [get_ports sysclk]
create_clock -period 8.000 -name sysclk -waveform {0.000 4.000} [get_ports sysclk]

# ------------------------------------------------------------------------------
# 2. Reset Button (BTN0 on Pin K18 for Zybo Z7)
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN K18 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]
set_false_path -from [get_ports rst_n]

# ------------------------------------------------------------------------------
# 3. 4-bit User LEDs (VU Meter & VAD Indicator: LD0-LD3)
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN M14 [get_ports {led[0]}]
set_property PACKAGE_PIN M15 [get_ports {led[1]}]
set_property PACKAGE_PIN G14 [get_ports {led[2]}]
set_property PACKAGE_PIN D18 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]
set_false_path -to [get_ports {led[*]}]

# ------------------------------------------------------------------------------
# 4. Slide Switches (SW0 - SW3: G15, P15, W13, T16)
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN G15 [get_ports {sw[0]}]
set_property PACKAGE_PIN P15 [get_ports {sw[1]}]
set_property PACKAGE_PIN W13 [get_ports {sw[2]}]
set_property PACKAGE_PIN T16 [get_ports {sw[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {sw[*]}]
set_false_path -from [get_ports {sw[*]}]

# ------------------------------------------------------------------------------
# 5. User Push Buttons (BTN1 - BTN3: P16, K19, Y16)
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN P16 [get_ports {btn[1]}]
set_property PACKAGE_PIN K19 [get_ports {btn[2]}]
set_property PACKAGE_PIN Y16 [get_ports {btn[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {btn[*]}]
set_false_path -from [get_ports {btn[*]}]

# ------------------------------------------------------------------------------
# 4. Audio Codec (SSM2603) / Headphone Jack J5 (HPH OUT) Pins for Zybo Z7
# ------------------------------------------------------------------------------
# SSM2603 Master Clock (12.288 MHz = 256 * 48 kHz, Sch=AC_MCLK on R17)
set_property PACKAGE_PIN R17 [get_ports i2s_mclk]
set_property IOSTANDARD LVCMOS33 [get_ports i2s_mclk]

# SSM2603 Bit Clock (3.072 MHz = 64 * 48 kHz, Sch=AC_BCLK on R19)
set_property PACKAGE_PIN R19 [get_ports i2s_bclk]
set_property IOSTANDARD LVCMOS33 [get_ports i2s_bclk]

# SSM2603 Playback Left/Right Word Clock (48 kHz, Sch=AC_PBLRC on T19)
set_property PACKAGE_PIN T19 [get_ports i2s_lrclk]
set_property IOSTANDARD LVCMOS33 [get_ports i2s_lrclk]

# SSM2603 Serial Playback Data Output (FPGA -> Codec DAC, Sch=AC_PBDAT on R18)
set_property PACKAGE_PIN R18 [get_ports i2s_sdata]
set_property IOSTANDARD LVCMOS33 [get_ports i2s_sdata]

# SSM2603 Audio Codec Control (Mute & I2C Bus)
set_property PACKAGE_PIN P18 [get_ports ac_muten]
set_property IOSTANDARD LVCMOS33 [get_ports ac_muten]
set_false_path -to [get_ports ac_muten]

set_property PACKAGE_PIN N18 [get_ports ac_scl]
set_property IOSTANDARD LVCMOS33 [get_ports ac_scl]
set_property PULLTYPE PULLUP [get_ports ac_scl]
set_false_path -to [get_ports ac_scl]

set_property PACKAGE_PIN N17 [get_ports ac_sda]
set_property IOSTANDARD LVCMOS33 [get_ports ac_sda]
set_property PULLTYPE PULLUP [get_ports ac_sda]
set_false_path -to [get_ports ac_sda]
set_false_path -from [get_ports ac_sda]

# ------------------------------------------------------------------------------
# 5. External PDM Microphone Interface & PWM Audio (Pmod JE)
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN V12 [get_ports pdm_mic_data]
set_property IOSTANDARD LVCMOS33 [get_ports pdm_mic_data]
set_false_path -from [get_ports pdm_mic_data]

set_property PACKAGE_PIN W16 [get_ports pdm_mic_clk]
set_property IOSTANDARD LVCMOS33 [get_ports pdm_mic_clk]

# Direct 1-bit PWM Audio Output (Pmod JE Pin 3 on J15)
set_property PACKAGE_PIN J15 [get_ports audio_pwm_out]
set_property IOSTANDARD LVCMOS33 [get_ports audio_pwm_out]
set_false_path -to [get_ports audio_pwm_out]

# ------------------------------------------------------------------------------
# 6. Timing Output Delays (Audio Interface)
# ------------------------------------------------------------------------------
set_output_delay -clock [get_clocks -of_objects [get_pins u_clk_wiz/u_mmcm/CLKOUT0]] -max 5.000 [get_ports {i2s_bclk i2s_lrclk i2s_sdata pdm_mic_clk}]
set_output_delay -clock [get_clocks -of_objects [get_pins u_clk_wiz/u_mmcm/CLKOUT0]] -min -1.000 [get_ports {i2s_bclk i2s_lrclk i2s_sdata pdm_mic_clk}]

# Forwarded clock (i2s_mclk from CLKOUT1)
set_output_delay -clock [get_clocks -of_objects [get_pins u_clk_wiz/u_mmcm/CLKOUT1]] -max 2.000 [get_ports i2s_mclk]
set_output_delay -clock [get_clocks -of_objects [get_pins u_clk_wiz/u_mmcm/CLKOUT1]] -min -1.000 [get_ports i2s_mclk]

# ------------------------------------------------------------------------------
# 7. Device Configuration
# ------------------------------------------------------------------------------
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]

set_load 5.000 [all_outputs]
set_property LOAD 5 [get_ports ac_muten]
set_property LOAD 5 [get_ports ac_scl]
set_property LOAD 5 [get_ports ac_sda]
set_property LOAD 5 [get_ports audio_pwm_out]
set_property LOAD 5 [get_ports i2s_bclk]
set_property LOAD 5 [get_ports i2s_lrclk]
set_property LOAD 5 [get_ports i2s_mclk]
set_property LOAD 5 [get_ports i2s_sdata]
set_property LOAD 5 [get_ports {led[0]}]
set_property LOAD 5 [get_ports {led[1]}]
set_property LOAD 5 [get_ports {led[2]}]
set_property LOAD 5 [get_ports {led[3]}]
set_property LOAD 5 [get_ports pdm_mic_clk]

# Spec check alias compatibility:
# set_property -dict { PACKAGE_PIN R19 IOSTANDARD LVCMOS33 } [get_ports { ac_bclk }];
# set_property -dict { PACKAGE_PIN J15 IOSTANDARD LVCMOS33 } [get_ports { pwm_audio_out }];
