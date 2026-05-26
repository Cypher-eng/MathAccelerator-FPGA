#!/bin/bash
# run.sh - the whole Stage 0 simulation chain in one command.
# Usage:  ./run.sh
set -e

echo "[1/3] Compiling Verilog with Icarus Verilog (iverilog)..."
/c/iverilog/bin/iverilog -o sim.out tb_view.v pixel_generator.v packer.v

echo "[2/3] Running the compiled simulation (vvp)..."
/c/iverilog/bin/vvp sim.out

echo "[3/3] Converting captured pixels to an image (Python)..."
python txt2png.py

echo "Done. Open output.png to see the result."
