#!/usr/bin/env bash
set -e

rm -f simv_board *board*.txt *board*.png

echo "[1/3] Build board-interface simulation"
iverilog -g2012 -o simv_board tb_stage4_board.v pixel_generator_4.v packer.v

echo "[2/3] Default window"
python3 golden_param.py 48 36 -8192 -6144 26 30 golden_board_default.txt
vvp simv_board +ZR0=-8192 +ZI0=-6144 +STEP=26 +MAXIT=30
mv verilog_board_out.txt verilog_board_default.txt
python3 diff_frames.py golden_board_default.txt verilog_board_default.txt
python3 txt2png.py verilog_board_default.txt 48 36 verilog_board_default.png

echo "[3/3] Zoomed window"
python3 golden_param.py 48 36 -820 -820 13 30 golden_board_zoom.txt
vvp simv_board +ZR0=-820 +ZI0=-820 +STEP=13 +MAXIT=30
mv verilog_board_out.txt verilog_board_zoom.txt
python3 diff_frames.py golden_board_zoom.txt verilog_board_zoom.txt
python3 txt2png.py verilog_board_zoom.txt 48 36 verilog_board_zoom.png

echo "Board-interface Stage 4 simulation complete."
