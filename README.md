**Real time Newton Fractal Accelerator on PYNQ-Z1**

## Development Log

We began by defining the mathematical direction of the accelerator. The project will focus on a real-time Newton fractal visualisation implemented on the PYNQ-Z1 FPGA. Instead of using only the traditional Mandelbrot or Julia escape-time recurrence, we selected Newton's method applied to the complex polynomial `f(z) = z^3 - 1`. This gives the accelerator a different mathematical structure: each pixel is treated as an initial complex value `z0`, and the hardware will iterate Newton's method to determine which root the point converges to.

The selected Newton iteration is:

```text
z_{n+1} = z_n - (z_n^3 - 1) / (3z_n^2)
```

Equivalently, this is Newton's method applied to:

```text
f(z) = z^3 - 1
```

with derivative:

```text
f'(z) = 3z^2
```

The three expected roots of `z^3 - 1 = 0` are:

```text
root 0 = 1 + 0i
root 1 = -1/2 + sqrt(3)/2 i
root 2 = -1/2 - sqrt(3)/2 i
```

The planned visualisation will colour each pixel according to the root it converges to. The brightness of the colour will represent the number of iterations required for convergence. This allows the image to show both the convergence basin of each root and the complex fractal boundary between different basins.

The first implementation target is to build a reliable software reference before moving to hardware. A floating-point Python model will be used as the golden reference for correctness checking. This model should generate the expected Newton fractal image, as well as a root-classification map and an iteration-count map. These outputs will later be compared against the fixed-point and FPGA-generated results.

Fixed-point arithmetic was identified as the main numerical design challenge. Since the FPGA implementation cannot rely on Python-style floating-point computation, the next step is to reproduce the same Newton iteration using fixed-point arithmetic in software. This will allow us to evaluate the effects of word length, fractional precision, rounding, and overflow before implementing the Verilog modules.

The hardware design will be divided into small, testable modules rather than implemented as one large block. The proposed module structure is:

- `complex_mul.v` for fixed-point complex multiplication
- `complex_div.v` for fixed-point complex division
- `newton_core.v` for the Newton iteration state machine
- an updated `pixel_generator.v` to connect the Newton core to the video stream pipeline

The Newton core will take the mapped complex coordinate of each pixel as input and produce a root identifier and iteration count as output. These values will then be converted into RGB pixel data. Runtime parameters such as maximum iteration count, centre position, zoom level, and convergence threshold will eventually be controlled through AXI-Lite/MMIO registers from the PYNQ processor.

At this stage, the full Vivado overlay will not be modified immediately. The immediate priority is to validate the mathematical model, generate a correct software reference image, and choose a suitable fixed-point representation. Once the single-pixel Newton core has been verified in simulation, it will be integrated with the raster pixel generator and then connected to the AXI Stream video interface.

The short-term implementation plan is:

1. Implement a floating-point Python Newton fractal reference.
2. Save the generated image, root-classification map, and iteration-count map.
3. Implement a fixed-point Python version to estimate FPGA numerical behaviour.
4. Compare floating-point and fixed-point outputs to select a suitable word length.
5. Implement and test fixed-point complex multiplication and division in Verilog.
6. Build and simulate a single-pixel `newton_core` state machine.
7. Integrate the Newton core into the pixel generator after simulation passes.
8. Use the PYNQ video pipeline to display the Newton fractal in real time.

This log records the transition from a general mathematical accelerator concept to a Newton-method-based fractal accelerator. The main technical focus is now on fixed-point complex arithmetic, convergence classification, hardware resource usage, and real-time video generation on the PYNQ-Z1 FPGA.

