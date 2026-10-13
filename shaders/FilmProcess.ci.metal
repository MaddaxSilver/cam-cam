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
// Film grain, applied as exposure (stops) in linear light.
// fine / coarse / chroma: isotropic noise fields (blurred white noise,
// normalized, centred on 0.5, independent per channel) — round clumps, not
// an upscaled pixel grid. Mono grain = fine + coarse clumps. Colour grain is
// soft dye-cloud colour variation with zero luminance, only where the image
// has colour (black-and-white looks get none). Strength follows a print:
// most in the shadows and lower mid-tones, clean highlights.
float4 filmGrain(sample_t s, sample_t fine, sample_t coarse, sample_t chroma, float amount, float color, float clump)
{
    float3 lin = srgbToLinear(s.rgb);
    float l = clamp(dot(s.rgb, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
    // Strongest in the mid-tones; deep shadows near-clean like a print's
    // blacks (a big dark background got the heaviest grain and looked
    // noisy), highlights clean.
    float env = smoothstep(0.04, 0.32, l) * (1.0 - 0.85 * smoothstep(0.5, 0.95, l)) * 0.9 + 0.1;
    // Fields are stored at half spread (fits 8-bit preview textures): ×2.
    float n = ((fine.r - 0.5) * 0.8 + (coarse.r - 0.5) * clump) * 2.0;
    float3 nc = (chroma.rgb - 0.5) * 2.0;
    nc -= dot(nc, float3(0.2126, 0.7152, 0.0722));          // colour only, no brightness
    float sat = max(s.r, max(s.g, s.b)) - min(s.r, min(s.g, s.b));
    float cg = color * smoothstep(0.03, 0.18, sat);
    float3 stops = (float3(n) + nc * cg) * amount * env * 2.0;
    return float4(linearToSrgb(lin * exp2(stops)), s.a);
}

// Re-centre and re-scale a noise field: out = 0.5 + (in − mean) × gain.
float4 normalizeNoise(sample_t s, float mean, float gain)
{
    return float4(0.5 + (s.rgb - mean) * gain, 1.0);
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

// MARK: - Film engine (colour negative + print, and B&W)
//
// Film is modelled in exposure, not as a filter on the finished image:
//
//   1. Spectral sensitivity: a 3×3 matrix — how the film's three dye layers
//      see the scene (their sensitivities overlap differently from a sensor).
//   2. Exposure in stops around mid grey.
//   3. Each layer's characteristic curve: an S-curve with its own slope, a
//      toe (shadows) and a shoulder (highlights). Layers with different
//      slopes give film's colour crossover (e.g. cool shadows, warm
//      highlights) instead of one global tint.
//   4. Inter-layer (DIR coupler) effects: a 3×3 matrix on the layer
//      responses — film's saturation and hue rendering.
//   5. Print: a per-layer power curve whose exponent is solved on the CPU so
//      mid grey prints exactly at the stock's mid value (neutral by
//      construction; any cast is the stock's intent), between the print's
//      black (max density) and white (paper / base).
//   6. B&W: the layers are averaged and toned by the silver colour.
float4 filmEngine(sample_t s,
                  float3 s0, float3 s1, float3 s2, float exposure,
                  float3 slope, float3 speed, float toe, float shoulder,
                  float3 c0, float3 c1, float3 c2,
                  float3 printGamma, float3 black, float3 white,
                  float mono, float3 tone)
{
    float3 lin = srgbToLinear(s.rgb);
    float3 seen = float3(dot(s0, lin), dot(s1, lin), dot(s2, lin));
    float3 e = log2(max(seen, float3(1e-6)) / 0.18) + exposure;
    float3 x = e - speed;
    float3 k = select(slope * shoulder, slope * toe, x < 0.0);
    float3 n = 1.0 / (1.0 + exp(-k * x));
    n = clamp(float3(dot(c0, n), dot(c1, n), dot(c2, n)), float3(1e-6), float3(1.0));
    float3 outLin = black + (white - black) * pow(n, printGamma);
    if (mono > 0.5) {
        outLin = float3((outLin.r + outLin.g + outLin.b) / 3.0) * tone;
    }
    return float4(linearToSrgb(outLin), s.a);
}

// MARK: - Development (developer exhaustion / adjacency effects)
//
// Developer is used up where the film got a lot of light, and fresh developer
// diffuses in from darker neighbours. So development depends on the
// NEIGHBOURHOOD's exposure, not just the pixel's: large bright areas develop
// less (highlights compress and keep detail), and along a bright/dark edge the
// bright side gets fresh developer and develops more (edge "pop", Mackie
// lines) — film's natural local contrast. Stand development (no agitation)
// makes it strong; frequent agitation keeps it weak.
//   near, far: linear luminance blurred at a short and a long diffusion
//              distance (developer spreading during development).
//   strength:  0 = fully agitated (no effect) … 1 = stand development.
float4 filmDevelop(sample_t s, sample_t near, sample_t far, float strength)
{
    float3 lin = srgbToLinear(s.rgb);
    float exhaustion = 0.6 * near.r + 0.4 * far.r;
    float gain = pow((0.18 + 0.05) / (max(exhaustion, 0.0) + 0.05), 0.5 * strength);
    return float4(linearToSrgb(lin * clamp(gain, 0.35, 2.5)), s.a);
}

}}
