#!/bin/bash

echo "Compiling..."
/c/iverilog/bin/iverilog -o sim ../verilog/test_AXIS.v ../verilog/packer.v ../verilog/pixel_generator.v

echo "Simulating..."
/c/iverilog/bin/vvp sim

echo "Generating image..."
python vcd_to_image.py

echo "Done - check simulation/output.png"