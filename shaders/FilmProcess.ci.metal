//
//  FilmProcess.ci.metal
//  cam cam
//
//  Physically-modelled alternative-process prints (cyanotype, daguerreotype…).
//
//  The old versions were "greyscale + colour tint", which gets the colour
//  wrong in both directions: highlights came out tinted instead of paper
//  white, and the dye never changed character with density. A real print is
//  built in DENSITY:
//
//    1. Spectral sensitivity. Early processes saw mostly blue/UV, so the
//       scene's exposure is a weighted mix favouring blue (blue sky prints
//       light, red/foliage print dark). Weights are a parameter per process.
//    2. Characteristic curve. Scene log-exposure → print density through an
//       S-shaped curve (toe + shoulder), with the process's contrast.
//    3. Beer–Lambert colour. Output = paper × dye^(D/Dmax): each channel is
//       absorbed at its own rate, so Prussian blue goes from pale cyan in thin
//       areas to deep navy where dense — exactly how cyanotypes look — and the
//       highlights stay the colour of the paper.
//    4. Coating. Hand-coated sensitiser is uneven; a soft noise field nudges
//       the maximum density so large areas don't look digitally flat.
//
//  Compiled ahead of time by scripts/build-shaders.sh.
//

#include <CoreImage/CoreImage.h>

extern "C" { namespace coreimage {

static inline float3 srgbToLinear(float3 c) {
    c = max(c, float3(0.0));
    return select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= 0.04045);
}

static inline float3 linearToSrgb(float3 c) {
    c = max(c, float3(0.0));
    return select(1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, c * 12.92, c <= 0.0031308);
}

/// - weights:   spectral sensitivity (r, g, b), sums to ~1
/// - exposure:  stops of print exposure (+ = darker print)
/// - contrast:  slope of the characteristic curve
/// - dye:       linear RGB transmittance of the dye at maximum density
/// - paper:     linear RGB reflectance of the paper / plate base
/// - coating:   0…1, how uneven the hand-coated sensitiser is
float4 densityPrint(sample_t s, sample_t noise,
                    float3 weights, float exposure, float contrast,
                    float3 dye, float3 paper, float coating)
{
    float3 lin = srgbToLinear(s.rgb);
    // Scene exposure as this process "sees" it.
    float e = max(dot(lin, weights), 1e-5);
    // Log exposure over ~7.5 stops, anchored so scene white reaches the
    // paper and deep shadow reaches full density.
    float t = clamp((log2(e) + 7.0 - exposure) / 7.5, 0.0, 1.0);
    // S-curve (toe & shoulder): logistic around the midpoint.
    float k = contrast * 6.0;
    float lo = 1.0 / (1.0 + exp(k * 0.5));
    float hi = 1.0 / (1.0 + exp(-k * 0.5));
    float st = (1.0 / (1.0 + exp(-k * (t - 0.5))) - lo) / (hi - lo);
    // Positive print: bright scene → little density → paper shows.
    float density = 1.0 - st;
    // Uneven coating varies the reachable maximum density a little.
    density *= 1.0 + (noise.r - 0.5) * 2.0 * coating;
    float3 outLin = paper * pow(max(dye, float3(1e-4)), float3(clamp(density, 0.0, 1.2)));
    return float4(linearToSrgb(outLin), s.a);
}

// MARK: - Film grain
//
// Grain is silver/dye clumps: exposure varies a little from clump to clump.
// We vary exposure in STOPS (multiplicative, like density), with two noise
// scales (single grains + clumps). Visibility follows a film-like envelope:
// strongest in the mid-tones, gentler in deep shadow and bright highlight.
// `color` > 0 lets each dye layer vary a little on its own (colour film).
float4 filmGrain(sample_t s, sample_t fine, sample_t coarse, float amount, float color)
{
    float3 lin = srgbToLinear(s.rgb);
    float l = clamp(dot(s.rgb, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
    float env = pow(clamp(4.0 * l * (1.0 - l), 0.0, 1.0), 0.6) * 0.85 + 0.15;
    float n = (fine.r - 0.5) * 0.75 + (coarse.r - 0.5) * 0.55;
    float3 nc = float3(fine.r, fine.g, fine.b) - 0.5;
    float3 stops = (float3(n) * (1.0 - color) + nc * color) * amount * env * 2.0;
    return float4(linearToSrgb(lin * exp2(stops)), s.a);
}

// MARK: - Halation
//
// Bright light passes through the emulsion, reflects off the film base and
// re-exposes the red-sensitive layer: a red-orange glow around highlights
// only. Step 1 extracts highlight ENERGY (linear, above a threshold); it is
// then blurred at two radii outside the kernel; step 2 adds it back as light.
float4 halationExtract(sample_t s, float threshold)
{
    float3 lin = srgbToLinear(s.rgb);
    float l = dot(lin, float3(0.2126, 0.7152, 0.0722));
    float e = max(l - threshold, 0.0) / max(1.0 - threshold, 1e-3);
    return float4(e, e, e, 1.0);
}

float4 halationApply(sample_t s, sample_t energy, sample_t nearHalo, sample_t farHalo, float amount, float3 tint)
{
    float3 lin = srgbToLinear(s.rgb);
    // Tight core plus a wide skirt, like light scattering in the base —
    // but only the SPILL beyond the bright source, so large bright areas
    // don't get a warm cast, only their edges glow.
    float halo = nearHalo.r * 0.5 + farHalo.r * 0.5;
    float spill = max(halo - energy.r * 0.85, 0.0);
    lin += tint * spill * amount;
    return float4(linearToSrgb(lin), s.a);
}

}}
