#!/usr/bin/env python3
import sys

def read(path):
    out = []
    with open(path) as f:
        for line in f:
            s = line.strip()
            if s:
                out.append(tuple(map(int, s.split())))
    return out

def main():
    if len(sys.argv) != 3:
        print('usage: diff_frames.py GOLDEN VERILOG')
        sys.exit(1)
    a = read(sys.argv[1])
    b = read(sys.argv[2])
    if len(a) != len(b):
        print('length mismatch: golden=%d verilog=%d' % (len(a), len(b)))
        sys.exit(1)
    mism = 0
    first = []
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            mism += 1
            if len(first) < 10:
                first.append((i, x, y))
    print('compared %d pixels, mismatches: %d' % (len(a), mism))
    for i, x, y in first:
        print('pixel %d: golden=%s verilog=%s' % (i, x, y))
    if mism == 0:
        print('*** BIT-EXACT MATCH ***')
    else:
        sys.exit(1)

if __name__ == '__main__':
    main()
