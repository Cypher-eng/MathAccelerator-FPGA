// ============================================================================
// newton_cpu.cpp  -  Stage 1: the CPU-only reference & benchmark.
//
// Requirement 2.4 of the project says your FPGA accelerator must beat a
// CPU-only implementation written in C/C++/Cython. THIS is that program.
//
// It computes the Newton fractal for f(z) = z^3 - 1 using double-precision
// floating point, writes a PPM image, and prints performance metrics.
//
// Build:  g++ -O2 -o newton_cpu newton_cpu.cpp
// Run:    ./newton_cpu
// ============================================================================
#include <iostream>
#include <fstream>
#include <complex>
#include <chrono>
#include <cmath>

using namespace std;
using namespace std::chrono;

// ---- Image + algorithm parameters (keep identical to your HW for a fair test)
const int    WIDTH    = 640;
const int    HEIGHT   = 480;
const int    MAX_ITER = 30;       // max Newton steps per pixel
const double TOL      = 1e-3;     // "close enough to a root" threshold

// The complex-plane window we look at
const double RE_MIN = -2.0, RE_MAX = 2.0;
const double IM_MIN = -1.5, IM_MAX = 1.5;

// The three roots of z^3 = 1
const complex<double> ROOTS[3] = {
    complex<double>( 1.0,        0.0),
    complex<double>(-0.5,  0.8660254),
    complex<double>(-0.5, -0.8660254)
};
// One colour per root (R,G,B)
const int COL[3][3] = {{230,57,70}, {42,157,143}, {69,123,157}};

int main() {
    // 'long long' so we can count total iterations without overflow
    long long total_iters = 0;

    // Allocate the image (R,G,B bytes)
    unsigned char* img = new unsigned char[WIDTH * HEIGHT * 3];

    auto start = high_resolution_clock::now();   // ---- start timing ----

    for (int py = 0; py < HEIGHT; ++py) {
        for (int px = 0; px < WIDTH; ++px) {
            // Map pixel -> point in the complex plane
            double zr = RE_MIN + (RE_MAX - RE_MIN) * px / (WIDTH  - 1);
            double zi = IM_MIN + (IM_MAX - IM_MIN) * py / (HEIGHT - 1);
            complex<double> z(zr, zi);

            int which = -1;     // which root we converged to (-1 = none)
            int it = 0;
            for (it = 0; it < MAX_ITER; ++it) {
                total_iters++;
                // Newton step: z = z - f(z)/f'(z),  f=z^3-1, f'=3z^2
                complex<double> z2 = z * z;
                complex<double> fp = 3.0 * z2;       // f'
                if (abs(fp) < 1e-12) break;          // avoid div-by-zero
                z = z - (z2 * z - 1.0) / fp;
                // converged?
                for (int k = 0; k < 3; ++k) {
                    if (abs(z - ROOTS[k]) < TOL) { which = k; break; }
                }
                if (which >= 0) break;
            }

            int idx = (py * WIDTH + px) * 3;
            if (which < 0) {                          // didn't converge -> black
                img[idx] = img[idx+1] = img[idx+2] = 0;
            } else {
                double shade = max(0.25, 1.0 - (double)it / MAX_ITER);
                img[idx]   = (unsigned char)(COL[which][0] * shade);
                img[idx+1] = (unsigned char)(COL[which][1] * shade);
                img[idx+2] = (unsigned char)(COL[which][2] * shade);
            }
        }
    }

    auto end = high_resolution_clock::now();     // ---- stop timing ----
    double secs = duration<double>(end - start).count();

    // ---- Write image as a PPM (simple, no libraries needed) --------------
    ofstream f("newton_cpu.ppm", ios::binary);
    f << "P6\n" << WIDTH << " " << HEIGHT << "\n255\n";
    f.write((char*)img, WIDTH * HEIGHT * 3);
    f.close();
    delete[] img;

    // ---- Report the benchmark metrics ------------------------------------
    long long pixels = (long long)WIDTH * HEIGHT;
    cout << "=========== CPU benchmark (single frame) ===========\n";
    cout << "Resolution      : " << WIDTH << " x " << HEIGHT
         << "  (" << pixels << " pixels)\n";
    cout << "Max iterations  : " << MAX_ITER << "\n";
    cout << "Time for 1 frame: " << secs * 1000.0 << " ms\n";
    cout << "Frame rate      : " << 1.0 / secs << " FPS\n";
    cout << "Pixel rate      : " << pixels / secs / 1e6 << " Mpixels/s\n";
    cout << "Total Newton its: " << total_iters << "\n";
    cout << "Iteration rate  : " << total_iters / secs / 1e6 << " Mit/s\n";
    cout << "(Mit/s = million Newton iterations per second)\n";
    return 0;
}
