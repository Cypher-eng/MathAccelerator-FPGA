#!/usr/bin/env python3
# ============================================================================
# newton_fixed.py  -  Stage 2: the FIXED-POINT golden model.
#
# Why this file exists:
#   FPGAs have no cheap floating-point. The hardware must use plain integers,
#   scaled by a constant. This file is the EXACT integer algorithm the Verilog
#   will implement. We debug all the fixed-point pain here in Python (fast to
#   edit) so that Stage 3 Verilog is a near-mechanical translation.
#
# It does THREE jobs:
#   1. Produce a correct image using only integer math (proves Q12 is enough).
#   2. INSTRUMENT every intermediate value to measure the bit widths the
#      hardware registers actually need (so we don't guess and overflow).
#   3. Handle the f'(z) -> 0 singularity (the "black dots" near z=0).
#
# Fixed-point format: Q12  ->  a real value v is stored as the integer
#   V = round(v * SCALE),  where SCALE = 4096 = 2^12.
# Multiplying two Q12 numbers gives a Q24 number, so we shift right by 12
# (i.e. // SCALE) to get back to Q12.
# ============================================================================
import numpy as np
from PIL import Image

# ---- Parameters: keep IDENTICAL to newton_cpu.cpp for a fair comparison ----
WIDTH, HEIGHT = 640, 480
MAX_ITER = 30
SCALE = 4096                 # 2^12  -> Q12 fixed point
FRAC_BITS = 12

RE_MIN, RE_MAX = -2.0, 2.0
IM_MIN, IM_MAX = -1.5, 1.5

# Integer coordinate mapping (so the Verilog can reproduce it EXACTLY).
# Per-pixel step in Q12, and the top-left corner in Q12:
DRE = int(round((RE_MAX - RE_MIN) * SCALE / (WIDTH - 1)))   # Q12 step per x pixel
DIM = int(round((IM_MAX - IM_MIN) * SCALE / (HEIGHT - 1)))  # Q12 step per y pixel
ZR0 = int(round(RE_MIN * SCALE))                            # Q12 real at x=0
ZI0 = int(round(IM_MIN * SCALE))                            # Q12 imag at y=0

# Roots of z^3 = 1, in Q12
ROOTS_F = [(1.0, 0.0), (-0.5, 0.8660254), (-0.5, -0.8660254)]
ROOTS = [(int(round(r*SCALE)), int(round(i*SCALE))) for (r, i) in ROOTS_F]
COL = np.array([[230, 57, 70], [42, 157, 143], [69, 123, 157]], dtype=int)

# Convergence tolerance in Q12. We compare |z - root| component-wise.
# 1e-3 was the float tolerance; fixed point is coarser, so we loosen slightly.
TOL = int(round(0.03 * SCALE))      # 0.03 in Q12 ~= 122

# A guard for the singularity: if |f'|^2 (denom) is below this, z is too close
# to 0 where Newton is undefined -> stop and mark as non-converging.
DENOM_MIN = 1                        # in Q12; denom rounding to 0 means div-by-0

def tdiv(a, b):
    """Truncate toward zero, exactly like Verilog '/' and a hardware divider."""
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q

def mul(a, b):
    return tdiv(a * b, SCALE)

# ---- Instrumentation: track the largest magnitude each variable reaches ----
maxabs = {}
def track(name, val):
    v = abs(val)
    if v > maxabs.get(name, 0):
        maxabs[name] = v
    return val

img = np.zeros((HEIGHT, WIDTH, 3), dtype=np.uint8)
total_iters = 0
black_pixels = 0

for py in range(HEIGHT):
    for px in range(WIDTH):
        # pixel -> complex coordinate in Q12, using ONLY integer math
        # (identical to what the Verilog will compute)
        zr = ZR0 + px * DRE
        zi = ZI0 + py * DIM

        which = -1
        it = 0
        for it in range(MAX_ITER):
            total_iters += 1
            # z^2  (Q12)
            zr2 = track('zr2', mul(zr, zr) - mul(zi, zi))
            zi2 = track('zi2', tdiv(2 * zr * zi, SCALE))
            # z^3 = z^2 * z  (Q12)
            zr3 = track('zr3', mul(zr2, zr) - mul(zi2, zi))
            zi3 = track('zi3', mul(zr2, zi) + mul(zi2, zr))
            # f = z^3 - 1   (1.0 == SCALE in Q12)
            fr = track('fr', zr3 - SCALE)
            fi = track('fi', zi3)
            # f' = 3 z^2
            fpr = track('fpr', 3 * zr2)
            fpi = track('fpi', 3 * zi2)
            # |f'|^2 (real, Q12) and f*conj(f') numerator (Q12)
            denom = track('denom', mul(fpr, fpr) + mul(fpi, fpi))
            if denom <= DENOM_MIN:
                break                      # singularity guard
            numr = track('numr', mul(fr, fpr) + mul(fi, fpi))
            numi = track('numi', mul(fi, fpr) - mul(fr, fpi))
            # divide:  ratio in Q12 = (num * SCALE) / denom
            dr = track('dr', tdiv(numr * SCALE, denom))
            di = track('di', tdiv(numi * SCALE, denom))
            # raw product width (this is the widest signal in hardware!)
            track('mul_product', numr * SCALE)
            track('z_times_z', zr * zr)
            # Newton update
            zr = track('zr', zr - dr)
            zi = track('zi', zi - di)
            # converged?
            for k, (rr, ri) in enumerate(ROOTS):
                if abs(zr - rr) < TOL and abs(zi - ri) < TOL:
                    which = k
                    break
            if which >= 0:
                break

        if which < 0:
            img[py, px] = (0, 0, 0)
            black_pixels += 1
        else:
            # Integer shading the hardware can do: shade in [64..256] (8.8-ish).
            # shade256 = max(64, 256 - it*256/MAX_ITER); color = COL*shade256 >> 8
            shade256 = 256 - (it * 256) // MAX_ITER
            if shade256 < 64:
                shade256 = 64
            r = (int(COL[which][0]) * shade256) >> 8
            g = (int(COL[which][1]) * shade256) >> 8
            b = (int(COL[which][2]) * shade256) >> 8
            img[py, px] = (r, g, b)

Image.fromarray(img).save("newton_fixed.png")

# ---- Report measured bit widths --------------------------------------------
def bits_signed(v):
    """Minimum signed bit width to hold values in [-v, v]."""
    if v == 0:
        return 1
    return int(np.ceil(np.log2(v + 1))) + 1   # +1 for sign

print("============ Stage 2: fixed-point (Q12, SCALE=4096) ============")
print(f"Image: {WIDTH}x{HEIGHT}, MAX_ITER={MAX_ITER}, TOL(Q12)={TOL}")
print(f"Non-converging (black) pixels: {black_pixels}")
print(f"Total Newton iterations: {total_iters}")
print()
print("Measured max |value| and required SIGNED bit width per signal:")
print(f"{'signal':<14}{'max_abs':>14}{'bits_needed':>14}")
order = ['zr', 'zi', 'zr2', 'zi2', 'zr3', 'zi3', 'fr', 'fi',
         'fpr', 'fpi', 'denom', 'numr', 'numi', 'dr', 'di',
         'z_times_z', 'mul_product']
for name in order:
    if name in maxabs:
        v = maxabs[name]
        print(f"{name:<14}{v:>14d}{bits_signed(v):>14d}")
print()
print("Design takeaways:")
print(" - 'z' values fit comfortably: pick a signed width with margin.")
print(" - 'mul_product' is the widest signal (raw a*b before >>12);")
print("   the hardware multiplier output must be this wide or you overflow.")
print(" - 'denom' can round to 0 near z=0 -> singularity guard prevents")
print("   a divide-by-zero; those pixels are the black dots.")
