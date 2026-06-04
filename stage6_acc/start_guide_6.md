# start_guide_6 — Stage 6: Build, Timing & Deployment

Stage 6 takes the verified Stage 5 design onto real hardware. It has two halves, and this guide is explicit about which is which:

| Half | Where it runs | Status |
|------|---------------|--------|
| **A. Divider integration + bit-exact re-verify** | Icarus Verilog (done here) | ✅ **done & verified** |
| **B. Vivado synth/timing/bitstream + PYNQ bring-up** | **your Vivado machine + the PYNQ-Z1** | 📦 scripts ready, **you run them** |

> **Honesty note (read this before the viva).** Half B was **not** run in the dev environment — it has no Vivado and no board. So there is **no Fmax number, no utilisation report, and no bitstream** in this package, and none is invented. Every hardware figure must come out of *your* Vivado run and *your* board. What *is* proven here is that the divider-integrated RTL produces a **bit-exact** frame, so when you synthesise it you are synthesising a known-correct design.

---

## Half A — what was done and verified (RTL)

The Stage 5 engine used Verilog's combinational `/` for the two Newton-step divides per lane. A ~57-by-41-bit combinational divide is the **longest path in the design** and is the most likely thing to fail timing in Vivado. Stage 6 replaces it.

**What changed:** `pixel_generator_6.v` gives every lane **two `divider_seq` instances** (one for the real part, one for the imaginary part, sharing the real denominator). The per-lane FSM grew from 3 states to 5:

```
S_INIT  load pixel coordinate
S_CALC  compute & LATCH denom, numr, numi (zr/zi stable); if denom==0 -> black
S_DIV   pulse start once; STALL until both dividers assert done; latch quotients
S_UPD   z <- z - quotient; test convergence / iteration cap
S_DONE  hold colour, wait for the packer handshake
```

Latching the divide inputs in `S_CALC` is what makes it correct — the divider sees stable operands for its whole multi-cycle run.

**Verified (Icarus), bit-exact vs the Q12 golden model, both windows:**

```
LANES=1 : default   487296 cyc (1.00x) | zoom  1111560 cyc | BIT-EXACT | BIT-EXACT
LANES=2 : default   243649 cyc (2.00x) | zoom   559350 cyc | BIT-EXACT | BIT-EXACT
LANES=4 : default   121827 cyc (4.00x) | zoom   282413 cyc | BIT-EXACT | BIT-EXACT
```

Two things to say about this:

1. **0 mismatches everywhere.** Swapping the combinational divide for the multi-cycle divider changed the output by exactly zero pixels. The parallel speedup is also preserved (2 lanes ≈ 2.00×, 4 lanes ≈ 4.00× in cycles).
2. **Cycle count is ~47× higher than combinational Stage 5** (e.g. LANES=2 default: 243 649 vs 5 185 cycles). This is **expected and is the whole point**: each 64-bit divide now takes ~65 cycles instead of being "free" in one cycle. You are trading *cycles* for a *shorter critical path*, which lets the clock run faster. The net wall-clock result is **Fmax ÷ cycles-per-frame**, and Fmax only comes from Vivado.

> Design choice you must make in Half B: if Vivado shows the **combinational** Stage 5 design already meets timing at your target clock with margin, you may prefer it (far fewer cycles). The multi-cycle divider is the insurance for when the combinational divide **fails** timing. Decide with the timing report, not a guess. Both engines are bit-exact, so either is safe functionally.

Reproduce Half A any time:

```bash
cd stage6_vivado
./run_stage6.sh
```

---

## Half B — run on your Vivado machine + PYNQ-Z1

### Step 0 — lay out the files

```
stage6_vivado/
  rtl/
    pixel_generator_6.v      # copy here for the IP packager
    divider_seq.v
    packer.v
  build_ip.tcl
  base.tcl
  pynq_newton_bringup.py
```

```bash
mkdir -p rtl
cp pixel_generator_6.v divider_seq.v packer.v rtl/
```

Pick the LANES value before packaging by editing `parameter LANES = 2;` in `rtl/pixel_generator_6.v`. **Start with LANES = 2** (smaller, easier timing). Only try 4 if the utilisation report has room.

### Step 1 — package the IP

```bash
vivado -mode batch -source build_ip.tcl
```

Produces `ip_repo/pixel_generator`. It infers the AXI-Lite slave (`s_axi_lite`) and AXI-Stream master (`out_stream`) so the block design auto-connects them.

### Step 2 — build the block design + bitstream

```bash
vivado -mode batch -source base.tcl
```

This wires Zynq PS → AXI-Lite → pixel_generator, pixel_generator → VDMA (S2MM) → DDR, runs synthesis + implementation, and writes the bitstream. **Adjust the board preset** at the top of `base.tcl` to your exact PYNQ-Z1 board files if Vivado complains.

### Step 3 — record the REAL numbers (this is your Stage 6 result)

`base.tcl` writes two reports into `vivado_build/`:

- **`timing_summary.rpt`** → find **WNS** (Worst Negative Slack) at the 10 ns (100 MHz) target.
  - WNS ≥ 0 → timing **met** at 100 MHz.
  - **Fmax ≈ 1000 / (10 − WNS)** MHz. (e.g. WNS = +2 ns → Fmax ≈ 125 MHz; WNS = −3 ns → you did **not** meet 100 MHz, see "timing closure" below.)
- **`utilization.rpt`** → record **LUT, FF, DSP, BRAM** counts. Note how LANES = 2 vs 4 changes DSP/LUT — that is your area/throughput trade-off table for the report.

Write these into your report **as measured** — they are the figures the whole project has been deferring to.

### Step 4 — deploy on the board

`base.tcl` copies `newton.bit` + `newton.hwh` to `vivado_build/overlay/`. Put **both** (same basename) on the PYNQ-Z1 next to `pynq_newton_bringup.py`, then in a Jupyter notebook:

```python
%run pynq_newton_bringup.py
```

It loads the overlay, writes ZR0/ZI0/STEP/MAXIT over AXI-Lite, captures a frame from DDR via the VDMA, saves `fpga_frame.png`, and runs the CPU-vs-FPGA benchmark.

> Check `ol.ip_dict.keys()` and fix the block names (`pixgen`, `vdma`) in the script to whatever `base.tcl` actually produced. The AXI-Lite register offsets are `0x00/0x04/0x08/0x0C` for ZR0/ZI0/STEP/MAXIT.

### Step 5 — the headline comparison (Stage 7 hand-off)

The script prints FPGA FPS, ARM-CPU FPS, and the speedup. For the **official** CPU figure use the **C++ −O2** build from Stage 1 (9.1 FPS on the dev machine; re-measure on the board's ARM core for a fair same-silicon number), not the NumPy reference in the script. Keep the comparison honest:

- same **resolution**, same **MAX_ITER**, same **window**;
- report **latency, FPS, Mpixels/s, Mit/s**;
- **Mit/s** (total iterations ÷ time) is the fairest cross-platform metric.

---

## If timing does NOT close (WNS < 0 at 100 MHz)

This is the realistic Stage 6 risk and you have a clear ladder:

1. **You're already on the multi-cycle divider** — good, the combinational divide is out of the path. Re-check what the new worst path is in `timing_summary.rpt`.
2. **Lower the target clock.** Drop FCLK_CLK0 (e.g. 100 → 75 MHz) in the PS config and rebuild. A met 75 MHz beats a failed 100 MHz. Frame rate = (met Fmax) ÷ cycles/frame.
3. **Reduce LANES** (4 → 2 → 1). Fewer parallel engines = less congestion and shorter paths.
4. **Pipeline the multiplier chain** (z², z³, numerators) by adding register stages in `S_CALC` — the 64-bit multiplies are the next-longest paths after the divide.
5. Re-run `./run_stage6.sh` after any RTL change to confirm it is **still bit-exact** before re-synthesising.

---

## Files in this stage (`stage6_vivado/`)

| File | Role | Ran here? |
|------|------|-----------|
| `pixel_generator_6.v` | **Divider-integrated engine.** 5-state lane FSM, two `divider_seq` per lane, latched divide inputs. Bit-exact verified. | ✅ verified |
| `divider_seq.v` | Multi-cycle signed divider (truncates toward zero, identical to `/`). | ✅ verified |
| `tb_stage5b_board.v` | Board-interface testbench (AXI-Lite writes, `periph_resetn` timing, capture, cycle count, histogram). | ✅ used |
| `run_stage6.sh` | Re-verifies the integrated engine bit-exact (LANES 1/2/4, two windows). | ✅ runs |
| `golden_param.py`, `diff_frames.py`, `txt2png.py`, `packer.v` | Golden model, comparator, renderer, packer. | ✅ used |
| `build_ip.tcl` | Packages the engine as a Vivado IP (infers AXI interfaces). | 📦 **run on Vivado** |
| `base.tcl` | Builds the PS+VDMA+HDMI block design, synth/impl, bitstream, dumps timing+utilisation. | 📦 **run on Vivado** |
| `pynq_newton_bringup.py` | Loads overlay, configures MMIO, captures a frame, CPU-vs-FPGA benchmark. | 📦 **run on the board** |

---

## One-paragraph status for the report

> Stage 6 replaces the combinational Newton divide with a multi-cycle pipelined divider (`divider_seq`) integrated into each lane via a 5-state FSM that latches the divide operands and stalls until the quotients are ready. The divider-integrated engine is **bit-exact** against the Q12 golden model for LANES = 1/2/4 on both default and zoomed windows, and preserves the parallel speedup (≈2× and ≈4× in cycles). Per-pixel cycle count rises ~47× — the expected latency-for-Fmax trade, since the long combinational divide is removed from the critical path. The Vivado IP-packaging and block-design scripts (`build_ip.tcl`, `base.tcl`) and the PYNQ bring-up + benchmark (`pynq_newton_bringup.py`) are provided to synthesise the design, **measure Fmax and resource utilisation**, generate the bitstream, and run the on-board ARM-CPU-vs-FPGA comparison — the figures that finalise the project.
