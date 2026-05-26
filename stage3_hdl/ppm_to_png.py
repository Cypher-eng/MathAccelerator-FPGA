from PIL import Image

img = Image.open(r"output.ppm")
img.save(r"output.png")