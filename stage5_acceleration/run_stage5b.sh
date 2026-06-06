#!/bin/bash
set -e

W=48
H=36

echo "================ Stage 5 verification (board-interface, ${W}x${H}) ================"

patch_golden () {
python3 - <<'PY'
from pathlib import Path
import re

p = Path("golden_param.py")
s = p.read_text()

s = s.replace("denom <= 1", "denom == 0")
s = s.replace("denom<=1", "denom==0")
s = s.replace("if denom <= 1:", "if denom == 0:")
s = s.replace("if denom<=1:", "if denom==0:")

p.write_text(s)
PY
}

build () {
python3 - "$1" "$2" "$W" "$H" <<'PY'
from pathlib import Path
import re
import sys

lanes = int(sys.argv[1])
out = Path(sys.argv[2])
W = int(sys.argv[3])
H = int(sys.argv[4])

s = Path("pixel_generator_5b.v").read_text()

s = re.sub(r"localparam\s+X_SIZE\s*=\s*\d+\s*;", f"localparam X_SIZE = {W};", s)
s = re.sub(r"localparam\s+Y_SIZE\s*=\s*\d+\s*;", f"localparam Y_SIZE = {H};", s)

s = re.sub(r"parameter\s+LANES\s*=\s*\d+\s*;", f"parameter  LANES  = {lanes};", s)

s = re.sub(
    r"input\s+\[AXI_LITE_ADDR_WIDTH-1:0\]\s+s_axi_lite_araddr",
    "input [7:0]     s_axi_lite_araddr",
    s
)
s = re.sub(
    r"input\s+\[AXI_LITE_ADDR_WIDTH-1:0\]\s+s_axi_lite_awaddr",
    "input [7:0]     s_axi_lite_awaddr",
    s
)

out.write_text(s)
print(f"built {out} with LANES={lanes}")
PY
}

cyc_of () {
    grep "Captured" "$1" | sed 's/.* in \([0-9]*\) clock.*/\1/'
}

patch_golden

rm -f sim_L*.out pg5b_L*.v fd_*.txt fz_*.txt gd.txt gz.txt gc.txt frame.txt hist.txt

for L in 1 2 4; do
    build $L pg5b_L$L.v
    iverilog -g2012 -o sim_L$L.out tb_stage5b_board.v pg5b_L$L.v packer.v
done

python3 golden_param.py $W $H -8192 -6144 26 30 gd.txt
python3 golden_param.py $W $H -820 -820 13 30 gz.txt

echo ""
echo "---- Generated LANES check ----"
grep -n "parameter  LANES" pg5b_L1.v pg5b_L2.v pg5b_L4.v

echo ""
echo "---- (B) bit-exact + speedup ----"
C1=0

for L in 1 2 4; do
    vvp sim_L$L.out +W=$W +H=$H +ZR0=-8192 +ZI0=-6144 +STEP=26 +MAXIT=30 >/tmp/d.log 2>&1
    CD=$(cyc_of /tmp/d.log)
    mv frame.txt fd_$L.txt
    RD=$(python3 diff_frames.py gd.txt fd_$L.txt | tail -1)

    vvp sim_L$L.out +W=$W +H=$H +ZR0=-820 +ZI0=-820 +STEP=13 +MAXIT=30 >/tmp/z.log 2>&1
    CZ=$(cyc_of /tmp/z.log)
    mv frame.txt fz_$L.txt
    RZ=$(python3 diff_frames.py gz.txt fz_$L.txt | tail -1)

    if [ "$L" = "1" ]; then C1=$CD; fi
    SU=$(python3 -c "print(f'{$C1/$CD:.2f}')")

    printf "LANES=%s : default %5s cyc (%sx) | zoom %5s cyc | %s | %s\n" "$L" "$CD" "$SU" "$CZ" "$RD" "$RZ"
done

echo ""
echo "---- (A) Stage 5A baseline cases + histograms (LANES=1) ----"

run_case () {
    name=$1
    zr0=$2
    zi0=$3
    step=$4
    maxit=$5

    vvp sim_L1.out +W=$W +H=$H +ZR0=$zr0 +ZI0=$zi0 +STEP=$step +MAXIT=$maxit >/tmp/c.log 2>&1
    TC=$(cyc_of /tmp/c.log)
    CPP=$(grep cycles_per_pixel /tmp/c.log | awk '{print $3}')

    python3 golden_param.py $W $H $zr0 $zi0 $step $maxit gc.txt
    RES=$(python3 diff_frames.py gc.txt frame.txt | tail -1)

    printf "%-12s cycles=%-6s cyc/px=%-9s %s\n" "$name" "$TC" "$CPP" "$RES"

    if [ -f hist.txt ]; then
        cp hist.txt hist_$name.txt
    fi
}

run_case default     -8192 -6144 26 30
run_case zoom_origin -820  -820  13 30
run_case low_iter    -8192 -6144 26 10
run_case high_iter   -8192 -6144 26 50

echo ""
echo "---- (C) pipelined divider vs Verilog '/' ----"

if [ -f tb_divider.v ]; then
    iverilog -g2012 -o simdiv.out tb_divider.v divider_seq.v
    vvp simdiv.out | grep -E "DIVIDER"
else
    echo "SKIPPED: tb_divider.v not found in this folder"
fi

echo ""
echo "Stage 5 lane verification finished."
