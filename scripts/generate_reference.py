import numpy as np
from PIL import Image


WIDTH = 640
HEIGHT = 480
MAX_ITER = 30
EPS = 1e-4

X_MIN, X_MAX = -2.0, 2.0
Y_MIN, Y_MAX = -1.5, 1.5

ROOTS = np.array([
    1.0 + 0.0j,
    -0.5 + np.sqrt(3) / 2 * 1j,
    -0.5 - np.sqrt(3) / 2 * 1j,
])


def classify_root(z):
    distances = np.abs(z - ROOTS)
    root_id = int(np.argmin(distances))

    if distances[root_id] < EPS:
        return root_id

    return -1


def colour(root_id, iteration):
    if root_id < 0:
        return [0, 0, 0]

    brightness = int(255 * (1.0 - iteration / MAX_ITER))
    brightness = max(40, min(255, brightness))

    if root_id == 0:
        return [brightness, 0, 0]
    elif root_id == 1:
        return [0, brightness, 0]
    else:
        return [0, 0, brightness]


def main():
    image = np.zeros((HEIGHT, WIDTH, 3), dtype=np.uint8)
    root_map = np.full((HEIGHT, WIDTH), -1, dtype=np.int8)
    iter_map = np.zeros((HEIGHT, WIDTH), dtype=np.uint8)

    for py in range(HEIGHT):
        y = Y_MAX - py * (Y_MAX - Y_MIN) / (HEIGHT - 1)

        for px in range(WIDTH):
            x = X_MIN + px * (X_MAX - X_MIN) / (WIDTH - 1)
            z = x + 1j * y

            root_id = -1
            final_iter = MAX_ITER

            for i in range(MAX_ITER):
                if abs(z) < 1e-8:
                    break

                z = z - (z**3 - 1) / (3 * z**2)
                root_id = classify_root(z)

                if root_id >= 0:
                    final_iter = i
                    break

            root_map[py, px] = root_id
            iter_map[py, px] = final_iter
            image[py, px] = colour(root_id, final_iter)

    Image.fromarray(image).save("newton_reference.png")
    np.save("newton_root_map.npy", root_map)
    np.save("newton_iter_map.npy", iter_map)

    print("Saved:")
    print("  newton_reference.png")
    print("  newton_root_map.npy")
    print("  newton_iter_map.npy")


if __name__ == "__main__":
    main()
    