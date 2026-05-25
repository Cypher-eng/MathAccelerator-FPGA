#!/bin/bash
# verify.sh - Stage 3 correctness check at low resolution (fast).
#
# Pure-Verilog simulation of a full 640x480 frame is very slow (each pixel runs
# many 64-bit Newton steps). So we verify CORRECTNESS on a small crop of the
# SAME complex-plane window, and trust that the identical logic scales to full
# resolution on real hardware (where it is fast).
#
# It builds a 40x30 version, simulates it, and diffs against the Python golden
# model. A clean run prints "BIT-EXACT MATCH".
set -e

RES_W=40
RES_H=30
# Q12 per-pixel steps for the 4.0 x 3.0 window at this resolution
DRE=$(python3 -c "print(round(4.0*4096/($RES_W-1)))")
DIM=$(python3 -c "print(round(3.0*4096/($RES_H-1)))")

echo "[1/4] Generating low-res golden model ($RES_W x $RES_H)..."
python3 golden_lowres_gen.py $RES_W $RES_H

echo "[2/4] Building low-res Verilog..."
sed -e "s/localparam X_SIZE = 640;/localparam X_SIZE = $RES_W;/" \
    -e "s/localparam Y_SIZE = 480;/localparam Y_SIZE = $RES_H;/" \
    -e "s/localparam signed \[31:0\] DRE      = 26;/localparam signed [31:0] DRE      = $DRE;/" \
    -e "s/localparam signed \[31:0\] DIM      = 26;/localparam signed [31:0] DIM      = $DIM;/" \
    pixel_generator.v > pg_lowres.v
sed -e 's/tb_newton/tbv/' -e "s/640\*480/$RES_W*$RES_H/" tb_newton.v > tbv.v
iverilog -o simv.out tbv.v pg_lowres.v packer.v

echo "[3/4] Simulating..."
vvp simv.out

echo "[4/4] Comparing Verilog output to golden model..."
python3 diff_frames.py frame.txt golden_lowres.txt
