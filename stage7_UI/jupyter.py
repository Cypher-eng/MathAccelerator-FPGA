# Import the PYNQ Overlay class
from pynq import Overlay

# Change the file name to the actual .bit file name
overlay = Overlay("newton_fractal.bit")

# Checking the exact name of the pixel generator IP
print(overlay.ip_dict.keys())

# Connect to the pixel generator IP
pixgen = overlay.pixel_generator_0

# Register addresses (each register is 4 bytes apart, since they are 32-bit registers)
# 0x00 -> regfile[0] -> ZR0
# 0x04 -> regfile[1] -> ZI0
# 0x08 -> regfile[2] -> STEP
# 0x0C -> regfile[3] -> MAXIT
ZR0_ADDR   = 0x00
ZI0_ADDR   = 0x04
STEP_ADDR  = 0x08
MAXIT_ADDR = 0x0C

# Convert signed Python integers into 32-bit unsigned values because ZR0 and ZI0 can be negative
def to_u32(value):
    return value & 0xFFFFFFFF


# Convert 32-bit unsigned values back into signed Python integers
# for reading back negative register values
def from_u32(value):
    if value & 0x80000000:
        return value - 0x100000000
    return value


# Write all zoom/pan/maximum iteration registers to the FPGA
def write_view(zr0, zi0, step, maxit):
    # Write starting real coordinate
    pixgen.write(ZR0_ADDR, to_u32(zr0))

    # Write starting imaginary coordinate
    pixgen.write(ZI0_ADDR, to_u32(zi0))

    # Write pixel step size, controls zoom
    pixgen.write(STEP_ADDR, to_u32(step))

    # Write maximum iteration count
    pixgen.write(MAXIT_ADDR, to_u32(maxit))


# Read back the current register values (for debugging)
def read_view():
    zr0   = from_u32(pixgen.read(ZR0_ADDR))
    zi0   = from_u32(pixgen.read(ZI0_ADDR))
    step  = from_u32(pixgen.read(STEP_ADDR))
    maxit = pixgen.read(MAXIT_ADDR) & 0x3F

    print("ZR0   =", zr0)
    print("ZI0   =", zi0)
    print("STEP  =", step)
    print("MAXIT =", maxit)


# Screen size used by Verilog
X_SIZE = 640
Y_SIZE = 480

# Default register values from Verilog
DEFAULT_ZR0 = -8192
DEFAULT_ZI0 = -6144
DEFAULT_STEP = 26
DEFAULT_MAXIT = 30

# Writing new register values to the FPGA
write_view(
    zr0=DEFAULT_ZR0,
    zi0=DEFAULT_ZI0,
    step=DEFAULT_STEP,
    maxit=DEFAULT_MAXIT
)


# Check the values were written correctly
read_view()


# Set the fractal view using intuitive zoom/pan values instead of raw register values
# zoom: 1.0 = default zoom, 2.0 = 2x zoom in, 0.5 = 2x zoom out
# pan_x: horizontal shift, positive = move view to the right
# pan_y: vertical shift, positive = move view upward
# pan = 1 means shifting the view by one pixel
# maxit: maximum Newton iterations
def set_view(zoom=1.0, pan_x=0, pan_y=0, maxit=30):

    # Convert zoom into STEP
    # Bigger zoom means smaller step
    step = int(round(DEFAULT_STEP / zoom))

    # Prevent step becoming 0
    if step < 1:
        step = 1

    # Find the default centre of the image in Q12
    centre_r = DEFAULT_ZR0 + (X_SIZE // 2) * DEFAULT_STEP
    centre_i = DEFAULT_ZI0 + (Y_SIZE // 2) * DEFAULT_STEP

    # Apply pan by adjusting centre coordinate
    centre_r = centre_r + pan_x * step
    centre_i = centre_i + pan_y * step

    # Calculate the new top-left coordinate
    zr0 = centre_r - (X_SIZE // 2) * step
    zi0 = centre_i - (Y_SIZE // 2) * step

    # To make sure we write integers to the registers
    zr0 = int(round(zr0))
    zi0 = int(round(zi0))
    step = int(step)
    maxit = int(maxit)

    write_view(zr0, zi0, step, maxit)

    read_view()


# Slider controls for Jupyter Notebook UI
import ipywidgets as widgets
from IPython.display import display

zoom_slider = widgets.FloatSlider(
    value=1.0,
    min=0.5,
    max=20.0,
    step=0.1,
    description='Zoom',
    continuous_update=False
)

pan_x_slider = widgets.IntSlider(
    value=0,
    min=-320,
    max=320,
    step=1,
    description='Pan X',
    continuous_update=False
)

pan_y_slider = widgets.IntSlider(
    value=0,
    min=-240,
    max=240,
    step=1,
    description='Pan Y',
    continuous_update=False
)

maxit_slider = widgets.IntSlider(
    value=DEFAULT_MAXIT,
    min=1,
    max=63,
    step=1,
    description='Max Iter',
    continuous_update=False
)

apply_button = widgets.Button(description="Apply View")
reset_button = widgets.Button(description="Reset View")

output = widgets.Output()


def apply_view(button):
    with output:
        output.clear_output()

        set_view(
            zoom=zoom_slider.value,
            pan_x=pan_x_slider.value,
            pan_y=pan_y_slider.value,
            maxit=maxit_slider.value
        )


def reset_view(button):
    zoom_slider.value = 1.0
    pan_x_slider.value = 0
    pan_y_slider.value = 0
    maxit_slider.value = DEFAULT_MAXIT

    with output:
        output.clear_output()

        set_view(
            zoom=1.0,
            pan_x=0,
            pan_y=0,
            maxit=DEFAULT_MAXIT
        )


apply_button.on_click(apply_view)
reset_button.on_click(reset_view)

display(
    zoom_slider,
    pan_x_slider,
    pan_y_slider,
    maxit_slider,
    widgets.HBox([apply_button, reset_button]),
    output
)