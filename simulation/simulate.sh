#!/bin/bash

echo "Compiling..."
iverilog -o sim ../verilog/test_AXIS.v ../verilog/packer.v ../verilog/pixel_generator.v

echo "Simulating..."
vvp sim

echo "Moving VCD file..."
mv test.vcd ../simulation/test.vcd

echo "Generating image..."
cd ../simulation
python vcd_to_image.py

echo "Done - check simulation/output.png"