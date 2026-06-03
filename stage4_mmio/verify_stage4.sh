#!/usr/bin/env bash
set -e
rm -f simv *.txt *.png

echo "[1/3] Build"
iverilog -g2012 -o simv tb_stage4.v pixel_generator_4.v

echo "[2/3] Default window"
python3 golden_param.py 48 36 -8192 -6144 26 30 golden_default.txt
vvp simv +ZR0=-8192 +ZI0=-6144 +STEP=26 +MAXIT=30
mv verilog_out.txt verilog_default.txt
python3 diff_frames.py golden_default.txt verilog_default.txt
python3 txt2png.py verilog_default.txt 48 36 verilog_default.png

echo "[3/3] Zoomed window"
python3 golden_param.py 48 36 -820 -820 13 30 golden_zoom.txt
vvp simv +ZR0=-820 +ZI0=-820 +STEP=13 +MAXIT=30
mv verilog_out.txt verilog_zoom.txt
python3 diff_frames.py golden_zoom.txt verilog_zoom.txt
python3 txt2png.py verilog_zoom.txt 48 36 verilog_zoom.png

echo "Stage 4 verification complete."
