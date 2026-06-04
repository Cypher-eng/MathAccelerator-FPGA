#!/usr/bin/env python3
# ============================================================================
# pynq_newton_bringup.py  -  Run ON THE PYNQ-Z1 BOARD (NOT in the dev container).
#
# Loads the Stage 6 overlay, configures the Newton pixel_generator over its
# AXI-Lite MMIO registers, captures a frame from DDR via the VDMA, displays it,
# and benchmarks the on-board ARM CPU vs the FPGA under identical settings.
#
# Copy newton.bit + newton.hwh (from base.tcl's vivado_build/overlay/) next to
# this file on the board, then run inside a Jupyter notebook or:  python3 this.py
#
# NOTE: every measured number (FPGA frame time, FPS, the speedup vs CPU) is
# produced by THIS run on real hardware. Nothing is pre-filled here.
# ============================================================================
import time
import numpy as np

# --- These imports only exist on the PYNQ board ---
from pynq import Overlay, allocate

# ---------------------------------------------------------------------------
# 1. Load the overlay
# ---------------------------------------------------------------------------
ol = Overlay("newton.bit")          # expects newton.hwh alongside
print("Overlay loaded. IP blocks:")
print(ol.ip_dict.keys())

# Names below depend on what base.tcl produced; adjust to match ol.ip_dict.
# Typical names: 'pixgen' (our IP, AXI-Lite control) and 'vdma'.
pixgen = ol.pixgen          # AXI-Lite control of the Newton core
vdma   = ol.axi_vdma_0 if hasattr(ol, "axi_vdma_0") else ol.vdma

W, H = 640, 480

# ---------------------------------------------------------------------------
# 2. Q12 helpers + register map  (regfile[0..3] = ZR0, ZI0, STEP, MAXIT)
#    Byte offsets: index << 2  -> 0x00, 0x04, 0x08, 0x0C
# ---------------------------------------------------------------------------
SCALE = 4096
def q12(x):                       # real -> Q12, written as unsigned 32-bit
    return int(round(x * SCALE)) & 0xFFFFFFFF

REG_ZR0, REG_ZI0, REG_STEP, REG_MAXIT = 0x00, 0x04, 0x08, 0x0C

def configure(centre_re, centre_im, span_re, max_iter):
    """Set the viewing window the same way the golden model / Stage 4 do."""
    step = span_re / W                       # complex distance per pixel
    zr0  = centre_re - (W / 2) * step
    zi0  = centre_im - (H / 2) * step
    pixgen.write(REG_ZR0,  q12(zr0))
    pixgen.write(REG_ZI0,  q12(zi0))
    pixgen.write(REG_STEP, q12(step))
    pixgen.write(REG_MAXIT, int(max_iter) & 0xFFFFFFFF)
    return zr0, zi0, step

# ---------------------------------------------------------------------------
# 3. VDMA frame buffer (S2MM: stream -> DDR)
# ---------------------------------------------------------------------------
# 24-bit RGB packed as the packer emits; capture as bytes then unpack.
framebuffer = allocate(shape=(H, W, 3), dtype=np.uint8)

def capture_fpga_frame():
    vdma.readchannel.start()
    frame = vdma.readchannel.readframe()
    np.copyto(framebuffer, frame)
    vdma.readchannel.stop()
    return np.array(framebuffer)

# ---------------------------------------------------------------------------
# 4. Default window: configure, capture, display
# ---------------------------------------------------------------------------
configure(centre_re=0.0, centre_im=0.0, span_re=4.0, max_iter=30)
img = capture_fpga_frame()

try:
    from PIL import Image
    Image.fromarray(img).save("fpga_frame.png")
    print("Saved fpga_frame.png")
except Exception as e:
    print("PIL not available, skipping save:", e)

# ---------------------------------------------------------------------------
# 5. Benchmark: FPGA frame time
# ---------------------------------------------------------------------------
N = 30
t0 = time.perf_counter()
for _ in range(N):
    _ = capture_fpga_frame()
t1 = time.perf_counter()
fpga_ms  = (t1 - t0) / N * 1000.0
fpga_fps = 1000.0 / fpga_ms
print(f"[FPGA]  {fpga_ms:.3f} ms/frame   {fpga_fps:.2f} FPS")

# ---------------------------------------------------------------------------
# 6. Benchmark: on-board ARM CPU, SAME resolution / window / MAX_ITER
#    (NumPy reference; use the C++ build for the official -O2 figure.)
# ---------------------------------------------------------------------------
def cpu_newton_fps(span=4.0, max_iter=30, reps=3):
    step = span / W
    re0  = -(W/2)*step
    im0  = -(H/2)*step
    xs = re0 + step*np.arange(W)
    ys = im0 + step*np.arange(H)
    ZR, ZI = np.meshgrid(xs, ys)
    best = 1e9
    for _ in range(reps):
        t0 = time.perf_counter()
        zr = ZR.copy(); zi = ZI.copy()
        for _ in range(max_iter):
            zr2 = zr*zr - zi*zi
            zi2 = 2*zr*zi
            # f = z^3 - 1 ; f' = 3 z^2
            fr = zr2*zr - zi2*zi - 1.0
            fi = zr2*zi + zi2*zr
            fpr = 3*zr2; fpi = 3*zi2
            den = fpr*fpr + fpi*fpi
            den[den == 0] = 1e-12
            dr = (fr*fpr + fi*fpi)/den
            di = (fi*fpr - fr*fpi)/den
            zr = zr - dr; zi = zi - di
        t1 = time.perf_counter()
        best = min(best, t1 - t0)
    return 1000.0*best, 1000.0/(1000.0*best)

cpu_ms, cpu_fps = cpu_newton_fps()
print(f"[ARM CPU] {cpu_ms:.3f} ms/frame   {cpu_fps:.2f} FPS   (NumPy; use C++ -O2 for the report)")

# ---------------------------------------------------------------------------
# 7. The headline number (only valid now, on real hardware)
# ---------------------------------------------------------------------------
print("====================================================")
print(f"FPGA  : {fpga_fps:6.2f} FPS")
print(f"ARM   : {cpu_fps:6.2f} FPS")
print(f"Speedup (FPGA / ARM) = {fpga_fps/cpu_fps:.1f} x   <-- the real, on-board figure")
print("Iterations/s (Mit/s) is the fairest metric: total_iters / time.")
print("====================================================")

del framebuffer
