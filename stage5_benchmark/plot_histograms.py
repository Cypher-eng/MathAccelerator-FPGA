#!/usr/bin/env python3
import matplotlib.pyplot as plt
from pathlib import Path

cases = [
    ("default", "hist_default.txt"),
    ("zoom_origin", "hist_zoom_origin.txt"),
    ("low_iter", "hist_low_iter.txt"),
    ("high_iter", "hist_high_iter.txt"),
]

for name, path in cases:
    xs, ys = [], []
    with open(path) as f:
        for line in f:
            a, b = map(int, line.split())
            xs.append(a)
            ys.append(b)

    plt.figure(figsize=(8, 4.5))
    plt.bar(xs, ys)
    plt.xlabel("Newton iterations before output")
    plt.ylabel("Number of pixels")
    plt.title(f"Iteration histogram: {name}")
    plt.tight_layout()
    plt.savefig(f"hist_{name}.png", dpi=200)
    print(f"saved hist_{name}.png")
