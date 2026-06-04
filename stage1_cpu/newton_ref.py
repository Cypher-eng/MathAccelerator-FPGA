#!/usr/bin/env python3
# newton_ref.py  -  Stage 1: golden reference + (slow) Python benchmark.
# Two jobs:
#   1. GOLDEN MODEL: the trusted "correct" image. This is used to compare with the verilog
#      implementation to check accuracy
#   2. A benchmark data point that shows why Python is NOT a fair CPU
#      baseline (it's much slower than C++), which is why we use C++ as the benchmark
import time
import numpy as np
from PIL import Image

WIDTH, HEIGHT = 640, 480
MAX_ITER = 30
TOL = 1e-3
RE_MIN, RE_MAX = -2.0, 2.0
IM_MIN, IM_MAX = -1.5, 1.5

ROOTS = [complex(1, 0),
         complex(-0.5,  0.8660254),
         complex(-0.5, -0.8660254)]
COL = np.array([[230, 57, 70], [42, 157, 143], [69, 123, 157]], dtype=np.float64)

img = np.zeros((HEIGHT, WIDTH, 3), dtype=np.uint8)
total_iters = 0

t0 = time.perf_counter()
for py in range(HEIGHT):
    for px in range(WIDTH):
        zr = RE_MIN + (RE_MAX - RE_MIN) * px / (WIDTH - 1)
        zi = IM_MIN + (IM_MAX - IM_MIN) * py / (HEIGHT - 1)
        z = complex(zr, zi)
        which = -1
        for it in range(MAX_ITER):
            total_iters += 1
            z2 = z * z
            fp = 3 * z2
            if abs(fp) < 1e-12:
                break
            z = z - (z2 * z - 1) / fp
            for k, r in enumerate(ROOTS):
                if abs(z - r) < TOL:
                    which = k
                    break
            if which >= 0:
                break
        if which < 0:
            img[py, px] = (0, 0, 0)
        else:
            shade = max(0.25, 1.0 - it / MAX_ITER)
            img[py, px] = (COL[which] * shade).astype(np.uint8)
secs = time.perf_counter() - t0

Image.fromarray(img).save("newton_ref.png")

pixels = WIDTH * HEIGHT
print("Python reference (single frame)")
print(f"Resolution      : {WIDTH} x {HEIGHT}  ({pixels} pixels)")
print(f"Time for 1 frame: {secs*1000:.1f} ms")
print(f"Frame rate      : {1/secs:.3f} FPS")
print(f"Pixel rate      : {pixels/secs/1e6:.3f} Mpixels/s")
print(f"Total Newton its: {total_iters}")
print(f"Iteration rate  : {total_iters/secs/1e6:.3f} Mit/s")
