#!/usr/bin/env python3
import sys
from PIL import Image

if len(sys.argv) != 5:
    print('usage: txt2png.py IN W H OUT')
    sys.exit(1)

inp, w, h, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
pix = []
with open(inp) as f:
    for line in f:
        s = line.strip()
        if s:
            pix.append(tuple(map(int, s.split())))
if len(pix) != w * h:
    raise SystemExit('expected %d pixels, got %d' % (w * h, len(pix)))
img = Image.new('RGB', (w, h))
img.putdata(pix)
img.save(out)
