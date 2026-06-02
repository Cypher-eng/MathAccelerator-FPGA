#!/usr/bin/env python3
import sys
from PIL import Image

SCALE = 4096
TOL = 123
ROOTS = [(4096, 0), (-2048, 3547), (-2048, -3547)]
COLS = [(230, 57, 70), (42, 157, 143), (69, 123, 157)]

def tdiv(a, b):
    q = abs(a) // abs(b)
    return -q if (a < 0) ^ (b < 0) else q

def mul(a, b):
    return tdiv(a * b, SCALE)

def root_id(zr, zi):
    for k, (rr, ri) in enumerate(ROOTS):
        dr = zr - rr
        di = zi - ri
        if dr * dr + di * di <= TOL * TOL:
            return k
    return 3

def colour(idx, it, maxit):
    if idx == 3:
        return (0, 0, 0)
    shade = max(64, 256 - tdiv(it * 256, maxit))
    c = COLS[idx]
    return tuple((v * shade) >> 8 for v in c)

def pixel(px, py, zr0, zi0, step, maxit):
    zr = zr0 + px * step
    zi = zi0 + py * step
    for it in range(maxit):
        zr2 = tdiv(zr * zr - zi * zi, SCALE)
        zi2 = tdiv(2 * zr * zi, SCALE)
        zr3 = tdiv(zr2 * zr - zi2 * zi, SCALE)
        zi3 = tdiv(zr2 * zi + zi2 * zr, SCALE)
        fr = zr3 - SCALE
        fi = zi3
        fpr = 3 * zr2
        fpi = 3 * zi2
        denom = fpr * fpr + fpi * fpi
        if denom == 0:
            return (0, 0, 0)
        numr = fr * fpr + fi * fpi
        numi = fi * fpr - fr * fpi
        nzr = zr - tdiv(numr * SCALE, denom)
        nzi = zi - tdiv(numi * SCALE, denom)
        rid = root_id(nzr, nzi)
        if rid != 3:
            return colour(rid, it, maxit)
        zr, zi = nzr, nzi
    return (0, 0, 0)

def main():
    if len(sys.argv) != 8:
        print('usage: golden_param.py W H ZR0 ZI0 STEP MAXIT OUT')
        sys.exit(1)
    w, h = int(sys.argv[1]), int(sys.argv[2])
    zr0, zi0, step = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
    maxit = int(sys.argv[6])
    out = sys.argv[7]
    pix = []
    with open(out, 'w') as f:
        for y in range(h):
            for x in range(w):
                rgb = pixel(x, y, zr0, zi0, step, maxit)
                pix.append(rgb)
                f.write('%d %d %d\n' % rgb)
    img = Image.new('RGB', (w, h))
    img.putdata(pix)
    img.save(out.rsplit('.', 1)[0] + '.png')

if __name__ == '__main__':
    main()
