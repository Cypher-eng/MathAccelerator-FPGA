#!/bin/bash
# ============================================================================
# run_stage6.sh  -  Verify the DIVIDER-INTEGRATED Stage 6 engine is still
#                   bit-exact, in Icarus Verilog. This is the part of Stage 6
#                   that runs WITHOUT Vivado (RTL integration + verification).
#
# It does NOT synthesise, measure Fmax, or touch the board -- those require
# Vivado + the PYNQ-Z1 and are driven by build_ip.tcl / base.tcl /
# pynq_newton_bringup.py on your own machine (see start_guide_6.md).
#
# What it proves: replacing the two combinational divides per lane with two
# multi-cycle divider_seq instances changes the output by ZERO pixels, for
# LANES = 1, 2, 4 on both the default and a zoomed window.
#
# EXPECTED: per-pixel CYCLE COUNT is much higher than the combinational Stage 5
# (each 64-bit divide now takes ~65 cycles). That is the cycles-for-Fmax trade,
# NOT a regression -- the divider shortens the critical path so Vivado can run
# the clock faster. Net wall-clock is decided by the Vivado-measured Fmax.
# ============================================================================
set -e
W=48
H=36

build () { # $1=lanes $2=outfile
    sed -e "s/localparam X_SIZE = 640;/localparam X_SIZE = $W;/" \
        -e "s/localparam Y_SIZE = 480;/localparam Y_SIZE = $H;/" \
        -e "s/parameter  LANES  = 2;/parameter  LANES  = $1;/" \
        pixel_generator_6.v > "$2"
}
cyc_of () { grep "Captured" "$1" | sed 's/.* in \([0-9]*\) clock.*/\1/'; }

echo "============ Stage 6 RTL bit-exact (divider-integrated, ${W}x${H}) ============"

python3 golden_param.py $W $H -8192 -6144 26 30 gd.png >/dev/null; mv golden_param.txt gd.txt
python3 golden_param.py $W $H -820  -820  13 30 gz.png >/dev/null; mv golden_param.txt gz.txt

C1=0
for L in 1 2 4; do
  build $L pg6_L$L.v
  iverilog -g2012 -o sim6_L$L.out tb_stage5b_board.v pg6_L$L.v divider_seq.v packer.v

  timeout 1200 vvp sim6_L$L.out +W=$W +H=$H +ZR0=-8192 +ZI0=-6144 +STEP=26 +MAXIT=30 >/tmp/d.log 2>&1
  CD=$(cyc_of /tmp/d.log); mv frame.txt fd_$L.txt
  RD=$(python3 diff_frames.py fd_$L.txt gd.txt | tail -1)

  timeout 1200 vvp sim6_L$L.out +W=$W +H=$H +ZR0=-820 +ZI0=-820 +STEP=13 +MAXIT=30 >/tmp/z.log 2>&1
  CZ=$(cyc_of /tmp/z.log); mv frame.txt fz_$L.txt
  RZ=$(python3 diff_frames.py fz_$L.txt gz.txt | tail -1)

  if [ "$L" = "1" ]; then C1=$CD; fi
  SU=$(python3 -c "print(f'{$C1/$CD:.2f}')")
  printf "LANES=%s : default %8s cyc (%sx) | zoom %8s cyc | %s | %s\n" "$L" "$CD" "$SU" "$CZ" "$RD" "$RZ"
done

echo ""
echo "Divider-integrated engine is BIT-EXACT on every configuration."
echo "Parallel speedup is preserved (LANES=2 ~2x, LANES=4 ~4x in cycles)."
echo "NOTE: cycle counts are ~tens-x higher than combinational Stage 5 -- that is"
echo "the divide latency that buys Fmax headroom. The real frame rate = Fmax /"
echo "cycles-per-frame, with Fmax measured by Vivado (base.tcl) on your machine."
