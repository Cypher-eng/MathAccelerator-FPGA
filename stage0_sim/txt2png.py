#!/usr/bin/env python3
# txt2png.py  -  Stage 0: turn the captured pixels into a viewable image.
# Reads frame.txt (one "R G B" line per pixel, raster order) -> output.png
from PIL import Image

W, H = 640, 480

img = Image.new("RGB", (W, H))
px = img.load()

with open("frame.txt") as f:
    i = 0
    for line in f:
        parts = line.split()
        if len(parts) != 3:
            continue
        def safe(v):                  # Verilog prints 'x'/'z' for undefined bits
            try:
                return int(v) & 0xFF  # keep 8 bits
            except ValueError:
                return 0              # treat undefined as black
        r, g, b = (safe(v) for v in parts)
        x = i % W
        y = i // W
        if y < H:
            px[x, y] = (r, g, b)
        i += 1

print(f"Read {i} pixels")
img.save("output.png")
print("Saved output.png")
