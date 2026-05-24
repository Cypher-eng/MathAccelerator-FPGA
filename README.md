**Real time Newton Fractal Accelerator on PYNQ-Z1**

## Development Log

We began by defining the mathematical direction of the accelerator. The project will focus on a real-time Newton fractal visualisation implemented on the PYNQ-Z1 FPGA. Instead of using only the traditional Mandelbrot or Julia escape-time recurrence, we selected Newton's method applied to the complex polynomial `f(z) = z^3 - 1`. This gives the accelerator a different mathematical structure: each pixel is treated as an initial complex value `z0`, and the hardware will iterate Newton's method to determine which root the point converges to.

The selected Newton iteration is:

```text
z_{n+1} = z_n - (z_n^3 - 1) / (3z_n^2)
```

Equivalently, this is Newton's method applied to:

```text
f(z) = z^3 - 1
```

with derivative:

```text
f'(z) = 3z^2
```

The three expected roots of `z^3 - 1 = 0` are:

```text
root 0 = 1 + 0i
root 1 = -1/2 + sqrt(3)/2 i
root 2 = -1/2 - sqrt(3)/2 i
```

The planned visualisation will colour each pixel according to the root it converges to. The brightness of the colour will represent the number of iterations required for convergence. This allows the image to show both the convergence basin of each root and the complex fractal boundary between different basins.

The first implementation target is to build a reliable software reference before moving to hardware. A floating-point Python model will be used as the golden reference for correctness checking. This model should generate the expected Newton fractal image, as well as a root-classification map and an iteration-count map. These outputs will later be compared against the fixed-point and FPGA-generated results.

Fixed-point arithmetic was identified as the main numerical design challenge. Since the FPGA implementation cannot rely on Python-style floating-point computation, the next step is to reproduce the same Newton iteration using fixed-point arithmetic in software. This will allow us to evaluate the effects of word length, fractional precision, rounding, and overflow before implementing the Verilog modules.

The hardware design will be divided into small, testable modules rather than implemented as one large block. The proposed module structure is:

- `complex_mul.v` for fixed-point complex multiplication
- `complex_div.v` for fixed-point complex division
- `newton_core.v` for the Newton iteration state machine
- an updated `pixel_generator.v` to connect the Newton core to the video stream pipeline

The Newton core will take the mapped complex coordinate of each pixel as input and produce a root identifier and iteration count as output. These values will then be converted into RGB pixel data. Runtime parameters such as maximum iteration count, centre position, zoom level, and convergence threshold will eventually be controlled through AXI-Lite/MMIO registers from the PYNQ processor.

At this stage, the full Vivado overlay will not be modified immediately. The immediate priority is to validate the mathematical model, generate a correct software reference image, and choose a suitable fixed-point representation. Once the single-pixel Newton core has been verified in simulation, it will be integrated with the raster pixel generator and then connected to the AXI Stream video interface.

The short-term implementation plan is:

1. Implement a floating-point Python Newton fractal reference.
2. Save the generated image, root-classification map, and iteration-count map.
3. Implement a fixed-point Python version to estimate FPGA numerical behaviour.
4. Compare floating-point and fixed-point outputs to select a suitable word length.
5. Implement and test fixed-point complex multiplication and division in Verilog.
6. Build and simulate a single-pixel `newton_core` state machine.
7. Integrate the Newton core into the pixel generator after simulation passes.
8. Use the PYNQ video pipeline to display the Newton fractal in real time.

This log records the transition from a general mathematical accelerator concept to a Newton-method-based fractal accelerator. The main technical focus is now on fixed-point complex arithmetic, convergence classification, hardware resource usage, and real-time video generation on the PYNQ-Z1 FPGA.

# Newton Fractal Accelerator — Stage 0 & Stage 1 Guide

This is your hands-on guide for the first two stages. Everything here has been
test-run and produces images. Do these on **your own laptop** — no FPGA board
needed yet.

---

## The big picture: where does each thing run?

There are **three** places code can run. Keep them straight and the whole
project makes sense:

1. **Your laptop CPU** (fast x86, ~3 GHz). Used during development to write the
   algorithm, make the golden reference image, and get a rough CPU benchmark.
2. **The PYNQ board's ARM CPU** (Zynq "PS", dual-core ~650 MHz, much slower than
   your laptop). This is where the *official* CPU baseline runs at the end.
3. **The PYNQ board's FPGA fabric** (Zynq "PL", the programmable logic). This is
   where your Verilog accelerator actually runs.

**Vivado does NOT run hardware.** Vivado does two things only:
- **Simulation** — a software model of your Verilog. It tells you how many
  *clock cycles* a frame takes, so you can *estimate* FPS = clock_freq / cycles.
- **Synthesis + Implementation** — compiles your Verilog into a `.bit`
  *bitstream*. The `build_ip.tcl` / `base.tcl` scripts are just build automation
  that produces this file. The `.bit` then runs on the **physical board**.

So the real, fair comparison required by the project (requirement 2.4) is:

> **Board ARM CPU (C/C++/Cython)  vs  Board FPGA**, same resolution, same
> max-iterations, same complex-plane window.

The laptop benchmarks you make now are for *developing* and for sanity-checking;
the headline result in your report is the on-board comparison.

---

## What the benchmark metrics mean

A "benchmark" is just: fix the workload (resolution, max_iter, window), measure
time, and report rates. The useful numbers:

| Metric | Meaning | Why you care |
|---|---|---|
| **Latency** | time for ONE frame (ms) | how snappy it feels |
| **FPS** (frames/sec) = 1 / latency | how many full images per second | headline user-facing number; "real-time" ≈ 30–60 FPS |
| **Mpixels/s** = FPS × W × H | pixel throughput | resolution-independent comparison |
| **Mit/s** (million iterations/sec) | total Newton steps ÷ time | **fairest** cross-platform measure (see below) |

**Why iterations/sec is the fairest measure.** Each pixel needs a *different*
number of Newton steps — some converge in 3, some take all 30. The total amount
of real work is "total iterations", and that number is **identical** for the
same image regardless of language or hardware. Only the *speed* differs. So
comparing Mit/s compares raw compute fairly.

Example from the test runs (640×480, max_iter=30, total iterations =
**1,743,986** in every case):

| Implementation | Latency | FPS | Mit/s |
|---|---|---|---|
| Python | 3586 ms | 0.28 | 0.49 |
| C++ `-O0` (no optimisation) | 312 ms | 3.2 | 5.6 |
| C++ `-O2` (optimised) | 110 ms | 9.1 | 15.8 |

Two lessons:
1. **Python is ~30x slower than C++** → that's why the project bans Python as
   the baseline and requires C/C++/Cython. Python is only your *reference*.
2. **`-O2` is 3x faster than `-O0`** with identical code → always state your
   compiler flags in the report, or the comparison is meaningless / unfair.

(Note: your board's ARM CPU will be several times slower than these laptop
numbers. That's expected and is what makes beating it with the FPGA realistic.)

---

## STAGE 0 — Get the HDL→image simulation chain working

**Goal:** prove you can turn Verilog into a picture on your laptop, with no
board and no Vivado. This loop is what you'll use to debug every later stage.

### 0.1 Install the tools

- **Icarus Verilog** (`iverilog` + `vvp`): compiles & runs Verilog.
- **Python 3** with **Pillow**: turns captured pixels into a PNG.
- (Optional) **GTKWave**: views waveforms for debugging.

Commands:

```bash
# Ubuntu / WSL
sudo apt-get update && sudo apt-get install -y iverilog gtkwave
pip install pillow

# macOS (Homebrew)
brew install icarus-verilog gtkwave
pip3 install pillow

# Windows: install Icarus from https://bleyer.org/icarus/  (adds iverilog/vvp to PATH)
#          then:  pip install pillow
#          (WSL is honestly the smoother route on Windows)
```

Check it worked:
```bash
iverilog -V        # should print a version
```

### 0.2 The files (in the stage0_sim folder)

| File | Role |
|---|---|
| `pixel_generator.v` | **The DUT** (Device Under Test). The example logic shipped by the project. This is the ONLY file you replace when you build Newton. |
| `packer.v` | Packs 4×24-bit pixels into 3×32-bit words for the video DMA. You never edit this. |
| `tb_view.v` | **Testbench.** Makes the clock & reset, drives the DUT, and captures every pixel into `frame.txt`. It does not modify the DUT, it just "watches" it. |
| `txt2png.py` | Reads `frame.txt` → writes `output.png`. |
| `run.sh` | Runs the whole chain: compile → simulate → make image. |

### 0.3 Run it

```bash
cd stage0_sim
chmod +x run.sh
./run.sh
```

You should see `Captured a full frame: 307200 pixels` and get `output.png`:
a tiled colour gradient (the example's signature pattern; the tiling is 8-bit
wraparound). If you see that, **Stage 0 is done.**

### 0.4 The one gotcha (worth understanding)

The example computes `r = x + frame`, where `frame = regfile[0]`. In real
hardware your Python writes `regfile[0]`; in pure simulation nobody writes it, so
it is **undefined (`x`)** and the image comes out **black**. The testbench fixes
this with one line after reset:

```verilog
dut.regfile[0] = 32'd0;   // poke a known value, since no AXI write happens in sim
```

Lesson for later: **registers are undefined in simulation until you initialise
or write them.**

### 0.5 The mental model for the manual chain

```
 pixel_generator.v ─┐
 packer.v          ─┼─► iverilog ─► sim.out ─► vvp ─► frame.txt ─► txt2png.py ─► output.png
 tb_view.v         ─┘   (compile)              (run)  (pixels)     (Python)      (image)
```

When you move to Newton, only `pixel_generator.v` changes. The testbench will
need a small tweak (sample the pixel only when it's *actually finished*, because
each Newton pixel takes many clock cycles instead of 1) — we'll handle that in
Stage 3.

---

## STAGE 1 — Floating-point reference + CPU benchmark

**Goal:** (a) a trusted "correct" Newton image to check your hardware against
later, and (b) the C++ CPU baseline your FPGA must beat.

### 1.1 The files (in the stage1_cpu folder)

| File | Role |
|---|---|
| `newton_cpu.cpp` | **The CPU baseline.** Double-precision Newton fractal in C++. Writes `newton_cpu.ppm` and prints benchmark metrics. This is the "CPU-only alternative" of requirement 2.4. |
| `newton_ref.py` | **Golden reference.** Same algorithm in Python. Writes `newton_ref.png`. Slow on purpose — it shows why Python isn't a fair baseline, and it's your correctness oracle for the hardware later. |

### 1.2 Run the C++ benchmark

```bash
cd stage1_cpu
g++ -O2 -o newton_cpu newton_cpu.cpp     # -O2 = optimised. ALWAYS record this flag.
./newton_cpu
```

It prints latency / FPS / Mpixels/s / Mit/s and writes `newton_cpu.ppm`.
View the image:
```bash
python3 -c "from PIL import Image; Image.open('newton_cpu.ppm').save('newton_cpu.png')"
```

Try `-O0` too and watch the FPS drop ~3x — proof that you must report flags.

### 1.3 Run the Python reference

```bash
python3 newton_ref.py
```

Compare `newton_ref.png` and `newton_cpu.png` — they should look identical.
That confirms your two implementations agree (your correctness baseline).

### 1.4 Record your baseline (do this!)

Make a little table in your logbook with **your own laptop's** numbers:

```
Machine: <your CPU model>
Resolution: 640x480, max_iter=30, window [-2,2]x[-1.5,1.5]
Compiler flags: g++ -O2
                    latency      FPS     Mit/s
  C++  (-O2)        ___ ms       ___     ___
  C++  (-O0)        ___ ms       ___     ___
  Python (ref)      ___ ms       ___     ___
```

You'll later add two more rows: **board ARM CPU** and **board FPGA**. The FPGA
row beating the ARM row is your project's key result.

---

## What's next (Stage 2 preview)

Stage 2 converts `newton_ref.py` from floating-point to **fixed-point integers**
(scaled by a power of two, e.g. ×4096 = "Q12"). FPGAs don't do floating point
cheaply, so the hardware works in scaled integers. You debug the fixed-point
maths in Python first — once that image still looks right, you have a "golden
fixed-point model" to copy into Verilog in Stage 3.

