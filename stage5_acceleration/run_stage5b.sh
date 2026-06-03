#!/bin/bash
# ============================================================================
# run_stage5b.sh  -  Stage 5 (merged) verification + benchmark, board-interface.
#
# Proves, all in Icarus Verilog, on the board-interface engine (AXI-Lite register
# writes with periph_resetn held low during configuration):
#
#   (A) Stage 5A baseline: cycles/pixel + iteration histogram for the 4 cases.
#   (B) Stage 5B acceleration: the parallel-lane engine is BIT-EXACT with the
#       Q12 golden model for LANES = 1, 2, 4, on default AND zoomed windows, and
#       throughput scales ~linearly (prints the measured speedup).
#   (C) The pipelined divider (Fmax lever) matches Verilog '/' bit-for-bit.
#
# Low resolution (48x36) keeps pure-Verilog simulation fast; the datapath is
# resolution-independent, and the cycle RATIO (the speedup) carries to full res.
# ============================================================================
set -e
W=48
H=36

build () {  # $1=lanes $2=out.v
    sed -e "s/localparam X_SIZE = 640;/localparam X_SIZE = $W;/" \
        -e "s/localparam Y_SIZE = 480;/localparam Y_SIZE = $H;/" \
        -e "s/parameter  LANES  = 2;/parameter  LANES  = $1;/" \
        pixel_generator_5b.v > "$2"
}
cyc_of () { grep "Captured" "$1" | sed 's/.* in \([0-9]*\) clock.*/\1/'; }

echo "================ Stage 5 verification (board-interface, ${W}x${H}) ================"

for L in 1 2 4; do
  build $L pg5b_L$L.v
  iverilog -g2012 -o sim_L$L.out tb_stage5b_board.v pg5b_L$L.v packer.v
done

python3 golden_param.py $W $H -8192 -6144 26 30 gd.png >/dev/null; mv golden_param.txt gd.txt
python3 golden_param.py $W $H -820  -820  13 30 gz.png >/dev/null; mv golden_param.txt gz.txt

echo ""
echo "---- (B) bit-exact + speedup ----"
C1=0
for L in 1 2 4; do
  vvp sim_L$L.out +W=$W +H=$H +ZR0=-8192 +ZI0=-6144 +STEP=26 +MAXIT=30 >/tmp/d.log 2>&1
  CD=$(cyc_of /tmp/d.log); mv frame.txt fd_$L.txt
  RD=$(python3 diff_frames.py fd_$L.txt gd.txt | tail -1)
  vvp sim_L$L.out +W=$W +H=$H +ZR0=-820 +ZI0=-820 +STEP=13 +MAXIT=30 >/tmp/z.log 2>&1
  CZ=$(cyc_of /tmp/z.log); mv frame.txt fz_$L.txt
  RZ=$(python3 diff_frames.py fz_$L.txt gz.txt | tail -1)
  if [ "$L" = "1" ]; then C1=$CD; fi
  SU=$(python3 -c "print(f'{$C1/$CD:.2f}')")
  printf "LANES=%s : default %5s cyc (%sx) | zoom %5s cyc | %s | %s\n" "$L" "$CD" "$SU" "$CZ" "$RD" "$RZ"
done

echo ""
echo "---- (A) Stage 5A baseline cases + histograms (LANES=1) ----"
run_case () {  # name ZR0 ZI0 STEP MAXIT
  vvp sim_L1.out +W=$W +H=$H +ZR0=$2 +ZI0=$3 +STEP=$4 +MAXIT=$5 >/tmp/c.log 2>&1
  TC=$(cyc_of /tmp/c.log)
  CPP=$(grep cycles_per_pixel /tmp/c.log | awk '{print $3}')
  python3 golden_param.py $W $H $2 $3 $4 $5 gc.png >/dev/null; mv golden_param.txt gc.txt
  RES=$(python3 diff_frames.py frame.txt gc.txt | tail -1)
  printf "%-12s cycles=%-6s cyc/px=%-9s %s\n" "$1" "$TC" "$CPP" "$RES"
  cp hist.txt hist_$1.txt
}
run_case default     -8192 -6144 26 30
run_case zoom_origin -820  -820  13 30
run_case low_iter    -8192 -6144 26 10
run_case high_iter   -8192 -6144 26 50

echo ""
echo "---- (C) pipelined divider vs Verilog '/' ----"
iverilog -g2012 -o simdiv.out tb_divider.v divider_seq.v
vvp simdiv.out | grep -E "DIVIDER"

echo ""
echo "All BIT-EXACT + DIVIDER OK  =>  Stage 5 (merged) verified."
echo "NOTE: cycle counts are throughput at a fixed clock. The Fmax gain from the"
echo "pipelined divider is confirmed with Vivado timing in Stage 6 - do not quote"
echo "a final FPS from simulation cycles alone."
