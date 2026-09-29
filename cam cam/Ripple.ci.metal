//
//  Ripple.ci.metal
//  cam cam
//
//  Core Image warp kernel for the circuit-bent "signal ripple" glitch.
//  Shifts each output row horizontally by a continuous wave (two sine
//  octaves + per-row hash jitter), so the image ripples/tears organically
//  in a SINGLE GPU pass instead of dozens of stacked composites.
//
//  The `.ci.metal` filename suffix tells Xcode 15+ to auto-apply the
//  CIKernel compiler/linker flags (-fcikernel / -cikernel) — no manual
//  build-setting changes required. Requires the Metal Toolchain component
//  to be installed (see scripts/ensure-metal-toolchain — auto-mounted on
//  login so device/sim builds don't break after a reboot).
//

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>   // CIKernelMetalLib
using namespace metal;

extern "C" {

// CIWarpKernel: returns the SOURCE coordinate to sample for each
// destination pixel. Shifting the sampled x by -shift moves the row's
// content to the right by `shift`.
//
//   amp    : max horizontal shift in pixels (the "weirdness" amount)
//   freq1  : low-frequency wave count down the frame (broad ripple)
//   freq2  : high-frequency wave count (fine wobble)
//   phase  : random phase so each frame/shot differs
//   height : image height in pixels (to normalize y → 0..1)
float2 rippleWarp(coreimage::destination dest,
                  float amp, float freq1, float freq2,
                  float phase, float height) {
    float2 p = dest.coord();
    float y = (height > 0.0) ? (p.y / height) : 0.0;

    const float TAU = 6.28318530718;
    float wave = 0.7 * sin(y * freq1 * TAU + phase)
               + 0.3 * sin(y * freq2 * TAU + phase * 1.7);

    // Per-row pseudo-random jitter for an organic, signal-corruption feel.
    float jitter = fract(sin(y * 91.7 + phase) * 43758.5453) - 0.5;

    float shift = amp * (wave + 0.18 * jitter);
    return float2(p.x - shift, p.y);
}

} // extern "C"
