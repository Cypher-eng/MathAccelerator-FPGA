# Stage 5 Guide — Acceleration on the Board-Interface Newton Engine (Merged)

This is the consolidated Stage 5. It merges two streams of work:

1. The team's **board-interface** Stage 4 design and the **Stage 5A** cycle/iteration
   baseline (AXI-Lite register writes, `periph_resetn` held low during MMIO
   configuration, packer-style AXI-Stream output).
2. The verified **Stage 5B acceleration** — a parallel multi-lane Newton engine
   and a pipelined divider — re-targeted onto that exact board interface and
   re-verified bit-exact.

Everything here was run in Icarus Verilog and verified bit-exact against the
Q12 Python golden model. The single rule of this project holds throughout: **no
speed or hardware claim is trusted unless the Verilog output is bit-exact
against the golden model.**

---

## 1. What Stage 5 delivers

Stage 5 has a measurement half (**5A**) and an acceleration half (**5B**), and
two independent acceleration levers whose benefits are measured in different
places:

| Part | What it does | Measured where |
|------|--------------|----------------|
| 5A | Cycle/pixel baseline + iteration histogram | iverilog (cycles) |
| 5B lever 1 — parallel lanes | raises throughput (pixels/clock) | **iverilog (cycles)** |
| 5B lever 2 — pipelined divider | raises clock frequency (Fmax) | **Vivado timing (Stage 6)** |

The headline result we can prove now is the **throughput** win from parallel
lanes (bit-exact, measured). The divider is delivered as a separately-verified
module ready to raise Fmax in Stage 6. Final wall-clock speedup =
(throughput gain, here) × (clock gain, Stage 6).

---

## 2. The board interface (preserved from the team's Stage 4)

The accelerated engine keeps the verified board interface exactly:

- Full **AXI-Lite** register file. Software writes the four parameters; the
  engine reads them.
- **AXI-Stream / packer** output (`out_stream_t*`).
- The critical bring-up timing: **`periph_resetn` is held LOW while the MMIO
  registers are written**, then released. This is what prevents the pixel-0/1
  bug where the engine starts on partially-configured registers.

Register map (unchanged from Stages 3–4):

| Register | Meaning |
|----------|---------|
| `regfile[0]` = ZR0 | top-left real coordinate (pan x), signed Q12 |
| `regfile[1]` = ZI0 | top-left imaginary coordinate (pan y), signed Q12 |
| `regfile[2]` = STEP | pixel spacing (zoom), signed Q12 — smaller = more zoom |
| `regfile[3]` = MAXIT | iteration depth, unsigned, hardware-clamped to ≤ 63 |

All-zero registers fall back to the verified Stage 3 default
(ZR0 = −8192, ZI0 = −6144, STEP = 26, MAXIT = 30), so the engine works with or
without software setup.

`tb_stage5b_board.v` reproduces this protocol: it releases AXI reset, writes the
four registers with an `axi_write()` task, **then** releases `periph_resetn`. RGB
is captured on `dut.valid_int && dut.ready` (the post-packer `tvalid/tready` do
not line up with `dut.r/g/b`).

---

## 3. Stage 5A — the pre-acceleration baseline

5A answers: *how hard is each pixel, and where is the work?* It runs four 48×36
cases on the single-lane (LANES = 1) engine and records cycles/pixel plus an
iteration histogram (via the `debug_iter` / `debug_iter_valid` probe).

```
default      cycles=10368  cyc/px=6.00   0 mismatches
zoom_origin  cycles=19290  cyc/px=11.16  0 mismatches
low_iter     cycles=10368  cyc/px=6.00   0 mismatches
high_iter    cycles=10368  cyc/px=6.00   0 mismatches
```

**Iteration histograms** (`stage5_histogram.png`, raw in `hist_*.txt`):

- **Default window**: every one of the 1728 pixels converges in exactly
  **3 iterations** — a single spike. This is why MAXIT 10/30/50 makes no
  difference for the default region: it has long since converged.
- **Zoom-origin window**: iteration counts spread from **6 to 27**, peaking at 7
  (498 pixels) with a long tail. The boundary/origin region is genuinely harder
  and has an **unbalanced workload**.

This is the report-level finding: the cost is concentrated at basin boundaries,
which both motivates acceleration and explains why a workload-aware scheme
(adaptive iteration depth, tiling) would be the next conceptual step.

---

## 4. Stage 5B lever 1 — parallel lanes (`pixel_generator_5b.v`)

The engine instantiates `LANES` independent Newton engines (a `parameter`,
default 2). Pixels are partitioned by **residue class**: lane *g* handles every
pixel index *p* with `p % LANES == g`. So with 2 lanes, lane 0 computes pixels
0, 2, 4, … and lane 1 computes 1, 3, 5, …. Because neighbouring pixels are
independent, the lanes run **at the same time**.

An output FSM emits pixels in **round-robin** order (lane 0, 1, …, LANES−1, 0,
…), which is exactly raster scan order, so the packer/VDMA still receive a normal
top-to-bottom frame. To emit pixel *p* it waits for lane `p % LANES` to finish,
streams it, and tells that lane to jump ahead by LANES pixels (wrapping one row
when needed). Everything else — the Q12 datapath, the `denom==0` guard, the
convergence test, the colour/shade logic, the MMIO register map — is unchanged.

Because each lane does an equal *count* of pixels and the workload is balanced
across residue classes, total time ≈ total_work / LANES, giving near-linear
scaling.

**Measured (board-interface, 48×36, vs single lane):**

```
LANES=1 : default 10368 cyc (1.00x) | zoom 19290 cyc   BIT-EXACT (both)
LANES=2 : default  5185 cyc (2.00x) | zoom  9696 cyc   BIT-EXACT (both)
LANES=4 : default  2595 cyc (4.00x) | zoom  4895 cyc   BIT-EXACT (both)
```

Two things to note:

- **LANES = 1 reproduces the team's Stage 5A baseline** (10368 / 19290 cycles).
  That is the sanity check: the parallel framework collapses exactly to the
  single engine at one lane, so the 2× and 4× speedups are real.
- **Every configuration is bit-exact** with the golden model on both windows —
  the parallelism did not change a single pixel.

`stage5_speedup.png` plots cycles/pixel and the speedup curve.

---

## 5. Stage 5B lever 2 — the pipelined divider (`divider_seq.v`)

In Stages 3–5 the Newton step uses Verilog's combinational `/`. A ~57-by-41-bit
combinational divide is the longest logic path in the design and caps the clock
frequency. `divider_seq.v` is a multi-cycle **signed restoring divider** that
computes the *same* result — `trunc(numer/denom)` toward zero, matching the
golden model's `tdiv()` — but spreads it over WIDTH+1 cycles so each cycle's
logic is tiny and the clock can run faster.

Because it is numerically identical to `/`, swapping it in **keeps the frame
bit-exact**; it changes *when* the result appears, not *what* it is.
`tb_divider.v` proves this over 4000+ random and directed cases:

```
DIVIDER OK: all cases match Verilog / bit-exact (4000 random + directed)
```

**Integration recipe for Stage 6** (kept out of the headline engine so the
throughput result stays clean): in each lane's `S_ITER`, when `dr`/`di` are
needed, pulse the divider's `start`, move to a wait state, and stall until
`done`. Because `dr` and `di` share the same denominator, use two divider
instances or one used twice. Everything else is unchanged; the frame stays
bit-exact, Fmax rises.

---

## 6. The honest part: simulation vs the board

Cycle counts from iverilog are **throughput at a fixed clock**. They prove the
parallel engine produces a frame in ~LANES× fewer cycles and that the output is
correct. They do **not** give the clock frequency. The real wall-clock figure is:

```
FPGA frames/sec  =  Fmax  /  (cycles per frame)
```

- `cycles per frame` — measured here (≈ /LANES).
- `Fmax` — set by the longest path; lower with the combinational divide, higher
  with `divider_seq.v`. **This number comes from Vivado timing in Stage 6.**

So Stage 5 delivers the **throughput** half (measured, bit-exact) and the
**Fmax** half as a verified, ready-to-integrate module. **Do not quote a final
FPS or a "beats the CPU by N×" number until Stage 6 gives the measured Fmax** —
quoting simulation cycles as wall-clock time is the classic way these reports go
wrong.

---

## 7. How to run it

```bash
cd stage5_merged
chmod +x run_stage5b.sh
./run_stage5b.sh
```

You should see LANES = 1/2/4 all `*** BIT-EXACT MATCH ***` on both windows with
the measured speedups (≈1.00 / 2.00 / 4.00×), the four 5A baseline cases with
their cycles/pixel and histograms, and `DIVIDER OK`.

To change the lane count for synthesis, edit `parameter LANES = 2;` in
`pixel_generator_5b.v` (the script sed-overrides it for the sweep). On the real
board LANES is fixed at synthesis time; 2 is safe, 4 uses more DSP/logic — check
Vivado utilisation in Stage 6 before committing to 4.

---

## 8. Files in this stage

| File | Purpose |
|------|---------|
| `pixel_generator_5b.v` | **The IP.** Board-interface (AXI-Lite + packer) parallel `LANES`-wide Newton engine with round-robin raster output and the Stage 5A `debug_iter` probe. Carry this into Stage 6. |
| `divider_seq.v` | Fmax lever: multi-cycle signed divider, bit-identical to `/`. Drop-in for Stage 6 (see integration recipe). |
| `tb_stage5b_board.v` | Board-interface testbench: AXI-Lite register writes, `periph_resetn` timing, cycle count, frame capture, histogram. |
| `tb_divider.v` | Proves `divider_seq` matches `/` over 4000+ cases. |
| `run_stage5b.sh` | One command: 5A baselines + histograms, 5B bit-exact + speedup (LANES 1/2/4, two windows), divider check. |
| `golden_param.py` | Parameterised Q12 golden model (the correctness oracle). |
| `pixel_generator_4.v` | The board-interface Stage 4 design (LANES=1 reference / fallback). |
| `diff_frames.py`, `txt2png.py`, `packer.v` | Comparator, renderer, and the unchanged packer needed to simulate. |
| `stage5_speedup.png` | Cycles/pixel and speedup vs lane count. |
| `stage5_histogram.png` | Iteration histograms: default (single spike at 3) vs zoom-origin (spread 6–27). |
| `hist_*.txt` | Raw histogram data for the report table. |

---

## 9. Status & what's next

**Stage 5 is complete and verified.** Board-interface preserved; 5A baseline and
histograms reproduced and explained; 5B parallel engine gives a measured,
bit-exact ~LANES× throughput gain (2.00× at 2 lanes, ~4× at 4 lanes); the
pipelined divider is proven numerically identical to `/`, ready to raise Fmax.

**Next — Stage 6 (Vivado build + deploy):**
1. Integrate `divider_seq.v` into `pixel_generator_5b.v` (stall `S_ITER` until
   `done`) and re-verify bit-exact at low res.
2. Synthesise in Vivado; **read off the real Fmax** and DSP/LUT utilisation for
   the chosen LANES.
3. Generate the bitstream, load the overlay on the PYNQ-Z1, wire AXI-Stream to
   VDMA, capture a frame.
4. Run the **on-board ARM CPU vs FPGA benchmark** (same resolution, MAX_ITER and
   window) — this is where the real "beats the CPU by N×" number comes from.

> Reminder: the current design uses combinational integer division, which is the
> likely Vivado timing bottleneck. That is exactly why `divider_seq.v` was
> pre-built. Keep a backup of the verified `pixel_generator_4.v` /
> `pixel_generator_5b.v` before any change.
