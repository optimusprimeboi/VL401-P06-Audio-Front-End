################################################################################
# build_project.tcl — Automated Vivado Project Generator & Bitstream Builder
# Target Board : Digilent Zybo Z7-10 (xc7z010clg400-1) / Zybo Z7-20 (xc7z020clg400-1)
# Project      : PDM-to-PCM Audio Front End
#
# Usage (Vivado Batch Mode):
#   vivado -mode batch -source build_project.tcl -tclargs xc7z010clg400-1
#   (or for Zybo Z7-20: vivado -mode batch -source build_project.tcl -tclargs xc7z020clg400-1)
#
# Usage (Vivado GUI Mode):
#   Open Vivado -> Tools -> Run Tcl Script -> select build_project.tcl
################################################################################

# ==============================================================================
# 1. Target Part & Project Configuration
# ==============================================================================
set DEFAULT_PART "xc7z010clg400-1"

# Check if target part passed as TCL command-line argument
if { $argc > 0 } {
    set TARGET_PART [lindex $argv 0]
} else {
    set TARGET_PART $DEFAULT_PART
}

set PROJ_NAME    "zybo_audio"
set PROJ_DIR     [file normalize "./vivado_project_audio"]
set BIT_DIR      [file normalize "./bitstream"]
set SCRIPT_DIR   [file normalize [file dirname [info script]]]

# Determine workspace root (either script directory or parent directory)
if {[file exists [file join $SCRIPT_DIR "rtl" "zybo_z7_top.v"]] || [file exists [file join $SCRIPT_DIR "rtl" "zybo" "zybo_z7_top.v"]]} {
    set ROOT_DIR $SCRIPT_DIR
} else {
    set ROOT_DIR [file normalize "$SCRIPT_DIR/../.."]
}

set RTL_DIR      [file normalize "$ROOT_DIR/rtl"]
set ZYBO_RTL_DIR [file normalize "$ROOT_DIR/rtl/zybo"]
set INC_DIR      [file normalize "$ROOT_DIR/rtl/include"]
if {[file exists [file join $ROOT_DIR "constraints" "zybo_z7.xdc"]]} {
    set XDC_FILE [file normalize "$ROOT_DIR/constraints/zybo_z7.xdc"]
} else {
    set XDC_FILE [file normalize "$ROOT_DIR/sim/zybo/zybo_z7.xdc"]
}
set SIM_DIR      [file normalize "$ROOT_DIR/sim"]

puts "========================================================================"
puts "  Automated Vivado Project Builder: PDM-to-PCM Audio Front End"
puts "  Target FPGA Part : $TARGET_PART"
puts "  Project Location : $PROJ_DIR"
puts "  Source Root      : $ROOT_DIR"
puts "========================================================================"

# Clean previous build artifacts if needed
file mkdir $PROJ_DIR
file mkdir $BIT_DIR

# ==============================================================================
# 2. Create Vivado Project
# ==============================================================================
create_project -name $PROJ_NAME -dir $PROJ_DIR -part $TARGET_PART -force

# Configure general project properties
set_property target_language Verilog [current_project]
set_property default_lib work [current_project]
set_property simulator_language Mixed [current_project]

# ==============================================================================
# 3. Add Verilog & SystemVerilog Design Sources
# ==============================================================================
puts "\n>>> Adding Design Sources..."

set rtl_source_files [list \
    [file join $RTL_DIR "cic_decimator.v"] \
    [file join $RTL_DIR "cic_compensation_fir.v"] \
    [file join $RTL_DIR "paper_dolecek_compensation.v"] \
    [file join $RTL_DIR "halfband_stage1.v"] \
    [file join $RTL_DIR "halfband_stage2.v"] \
    [file join $RTL_DIR "halfband_fir_folded.v"] \
    [file join $RTL_DIR "mcm_hb2_naive.v"] \
    [file join $RTL_DIR "mcm_hb2_cse.v"] \
    [file join $RTL_DIR "mcm_hb2_graph_u3.v"] \
    [file join $RTL_DIR "saturation_unit.v"] \
    [file join $RTL_DIR "pcm_fifo.v"] \
    [file join $RTL_DIR "vad_engine.v"] \
    [file join $RTL_DIR "apb_pdm_top.v"] \
    [file join $RTL_DIR "rv32i_core.v"] \
    [file join $RTL_DIR "bram_pdm_player.v"] \
    [file join $RTL_DIR "i2s_transmitter.v"] \
    [file join $RTL_DIR "pwm_audio_dac.v"] \
    [file join $RTL_DIR "pdm_top.v"] \
    [file join $ZYBO_RTL_DIR "zybo_clock_wiz.v"] \
    [file join $ZYBO_RTL_DIR "ssm2603_i2c_init.v"] \
    [file join $ZYBO_RTL_DIR "zybo_z7_top.v"] \
]

foreach f $rtl_source_files {
    if {[file exists $f]} {
        add_files -norecurse -fileset sources_1 [list $f]
        puts "  Added source: [file tail $f]"
    } else {
        puts "  ERROR: Source file missing: $f"
        error "Source file not found: $f"
    }
}

# Set include directory for coefficient header file (filter_coeffs.vh)
set_property include_dirs [list $INC_DIR] [current_fileset]
puts "  Configured Include Directory: $INC_DIR"

# Add BRAM stimulus memory file if present
set hex_file [file join $ROOT_DIR "pdm_stimulus_words.hex"]
if {![file exists $hex_file]} {
    set hex_file [file join $SIM_DIR "pdm_stimulus_words.hex"]
}
if {[file exists $hex_file]} {
    file copy -force $hex_file [file join $PROJ_DIR "pdm_stimulus_words.hex"]
    file copy -force $hex_file [file join $ROOT_DIR "pdm_stimulus_words.hex"]
    file copy -force $hex_file [file join $RTL_DIR "pdm_stimulus_words.hex"]
    add_files -norecurse -fileset sources_1 [list $hex_file]
    set_property file_type "Memory Initialization Files" [get_files [list $hex_file]]
    puts "  Added BRAM Hex Initialization: [file tail $hex_file]"
}

# Add RV32I firmware instruction memory file if present
set prog_hex [file join $ROOT_DIR "program.hex"]
if {[file exists $prog_hex]} {
    file copy -force $prog_hex [file join $PROJ_DIR "program.hex"]
    file copy -force $prog_hex [file join $RTL_DIR "program.hex"]
    add_files -norecurse -fileset sources_1 [list $prog_hex]
    set_property file_type "Memory Initialization Files" [get_files [list $prog_hex]]
    puts "  Added RV32I Firmware Hex: [file tail $prog_hex]"
}

# Set Top Module for Synthesis
set_property top zybo_z7_top [current_fileset]
update_compile_order -fileset sources_1

# Add Simulation Testbench and Set Simulation Top
set tb_file [file join $ROOT_DIR "tb" "tb_zybo_z7_top.v"]
if {[file exists $tb_file]} {
    add_files -norecurse -fileset sim_1 [list $tb_file]
    set_property top tb_zybo_z7_top [get_filesets sim_1]
    set_property top_lib xil_defaultlib [get_filesets sim_1]
    update_compile_order -fileset sim_1
    puts "  Configured Simulation Top: tb_zybo_z7_top"
}

# ==============================================================================
# 4. Add Constraints File
# ==============================================================================
puts "\n>>> Adding Timing & Board Constraints..."
if {[file exists $XDC_FILE]} {
    add_files -norecurse -fileset constrs_1 [list $XDC_FILE]
    puts "  Added XDC: [file tail $XDC_FILE]"
} else {
    puts "  ERROR: Constraints file not found: $XDC_FILE"
    error "Constraints file missing."
}

# ==============================================================================
# 5. Run Synthesis
# ==============================================================================
puts "\n========================================================================"
puts "  --- STEP 1/3: Launching Synthesis (synth_1)..."
puts "========================================================================"

# Enable flattened hierarchy rebuilding and avoid logic cross-boundary corruption
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.RESOURCE_SHARING off [get_runs synth_1]

launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthesis failed! Check synth_1 run log for details."
    exit 1
}
puts ">>> Synthesis completed successfully!"

# ==============================================================================
# 6. Run Implementation
# ==============================================================================
puts "\n========================================================================"
puts "  --- STEP 2/3: Launching Implementation (impl_1)..."
puts "========================================================================"

launch_runs impl_1 -jobs 4
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed! Check impl_1 run log for details."
    exit 1
}
puts ">>> Implementation completed successfully!"

# ==============================================================================
# 7. Check Timing Slack (WNS, WHS)
# ==============================================================================
puts "\n>>> Evaluating Timing Closure..."
open_run impl_1

set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]

puts "------------------------------------------------------------------------"
puts "  Worst Negative Slack (WNS) : $wns ns"
puts "  Worst Hold Slack     (WHS) : $whs ns"
puts "------------------------------------------------------------------------"

if { $wns < 0.0 } {
    puts "WARNING: Setup timing violation detected! WNS = $wns ns"
} else {
    puts ">>> TIMING MET: Positive timing slack on all endpoints."
}

# ==============================================================================
# 8. Generate Bitstream
# ==============================================================================
puts "\n========================================================================"
puts "  --- STEP 3/3: Generating FPGA Bitstream..."
puts "========================================================================"

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

# Copy generated bitstream to convenient top-level folder
set generated_bit [file join $PROJ_DIR "$PROJ_NAME.runs" "impl_1" "zybo_z7_top.bit"]
set target_bit    [file join $BIT_DIR "zybo_z7_top.bit"]

if {[file exists $generated_bit]} {
    file copy -force $generated_bit $target_bit
    puts "========================================================================"
    puts "  SUCCESS: Bitstream generated successfully!"
    puts "  Output Path: $target_bit"
    puts "========================================================================"
} else {
    puts "ERROR: Bitstream file not found at $generated_bit"
    exit 1
}

# Export hardware platform XSA for Vitis (if needed)
write_hw_platform -fixed -include_bit -force -file [file join $BIT_DIR "zybo_z7_audio.xsa"]
puts "  Hardware platform exported: [file join $BIT_DIR {zybo_z7_audio.xsa}]"

puts "\nProject build workflow completed cleanly."
