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

}}
