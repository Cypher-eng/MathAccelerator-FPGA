#!/bin/bash
# run_fullres.sh - simulate the FULL 640x480 Newton frame.
# WARNING: pure-Verilog simulation of a full frame is SLOW (minutes to hours
# depending on your machine) because each pixel runs many 64-bit Newton steps.
# Use verify.sh (low-res, bit-exact) for day-to-day correctness checks.
# The full frame is what runs FAST on the actual FPGA.
set -e
iverilog -o sim.out tb_newton.v pixel_generator.v packer.v
vvp sim.out
python3 txt2png.py        # frame.txt -> output.png
echo "Done. See output.png"
