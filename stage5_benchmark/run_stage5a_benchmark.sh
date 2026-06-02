#!/usr/bin/env bash
set -e

rm -f simv_5a *.txt *.png log_*.txt

echo "[1/1] Build Stage 5A benchmark simulation"
iverilog -g2012 -o simv_5a tb_stage5_benchmark.v pixel_generator_5a.v packer.v

run_case () {
    name=$1
    zr0=$2
    zi0=$3
    step=$4
    maxit=$5

    echo ""
    echo "===== $name ====="
    echo "ZR0=$zr0 ZI0=$zi0 STEP=$step MAXIT=$maxit"

    python3 golden_param.py 48 36 "$zr0" "$zi0" "$step" "$maxit" "golden_${name}.txt"

    vvp simv_5a +ZR0="$zr0" +ZI0="$zi0" +STEP="$step" +MAXIT="$maxit" | tee "log_${name}.txt"

    mv verilog_board_out.txt "verilog_${name}.txt"

    python3 diff_frames.py "golden_${name}.txt" "verilog_${name}.txt"
    python3 txt2png.py "verilog_${name}.txt" 48 36 "verilog_${name}.png"
}

run_case default -8192 -6144 26 30
run_case zoom_origin -820 -820 13 30
run_case low_iter -8192 -6144 26 10
run_case high_iter -8192 -6144 26 50

echo ""
echo "Stage 5A benchmark complete."
