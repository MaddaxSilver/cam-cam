# cam cam

A film camera for iPhone, and a Wi-Fi remote for a Sony a7R III that develops its shots the same way.

Every photo keeps its untouched original. The film look is saved as a Photos edit with its recipe, so a shot can be re-graded later.

---

## What it does

### Film looks
- **90+ looks.** They come from three sources:
  - film stocks measured with [spektrafilm](https://github.com/andreavolpato/spektrafilm) (Portra, Gold, Ektar, Vision3, Velvia, Provia and more);
  - stocks modelled in exposure by a small film engine (Superia, Tri-X);
  - hand-built and alternative-process looks (cyanotype, tintype, platinum and more), plus Styles.
- **Custom films, `.cube` LUT import, "New look from a photo".** That last one builds a LUT by matching a reference picture's colour statistics.
- **Scan stage after every look.** This is what a lab scanner does to a print:
  - floors the deep shadows, so a look can't crush gradation to black;
  - lifts the look's paper white back toward white;
  - puts back the original's fine local contrast.
- **Look volume.** Each film's strength is measured on a ColorChecker as mean ΔE, tone shift and saturation, and shown in the film library.
  - Photographic colour films louder than ΔE 12 are turned down to it automatically, like audio loudness normalisation.
  - *Look strength* turns any film down further.
- **Grain.** A physical grain model sized to the frame, so it looks the same at 12MP and 48MP.
  - It replaces the sensor's own noise at high ISO, rather than stacking on top of it.
  - It is optionally context-aware, adding more grain when there was less light.
- **Film effects:** halation, crosstalk, highlight rolloff, push/pull, development (agitated to stand), flares, light leaks, scratches and lens profiles. The lens profiles cover Takumar, Petzval, Pro-Mist, Sonnar, fisheye, tilt-shift and soap-bubble bokeh.

### iPhone camera
- **Multi-frame zoom.** Zoomed Max shots in good light take a quick burst and merge it. It uses Apple ProRAW frames, tone-matched to a normal photo, for real sensor detail, or processed frames otherwise.
- **Max:** 48MP on every shot. Zoomed, telephoto and ultra-wide photos are upscaled to 48MP before the film is applied, so the grain scale matches.
- **Natural:** 48MP ProRAW developed in the app, without Apple's local tone mapping.
- **RAW + film:** the film is developed from the DNG, keeping the highlight headroom the processed photo clips. The DNG is saved alongside the photo, either separately or as the same photo's RAW.
- **120mm** uses the physical telephoto, so iOS can't swap in a cropped main lens.
- **Smart exposure** meters the scene with saliency and compensates for each film's own brightness. *Apple auto* is Apple's exposure only.
- **Frame guide.** It suggests the framing for people, pets, objects and scenes, then zooms to it and fires when you line it up.
  - It reaches further outdoors than indoors.
  - *Scan* offers three numbered picks.
- **Pose guide.** Live body-pose coaching with a hands-free self-timer.
- Portrait depth blur, long exposure, burst, double exposure, Film Roll mode with contact sheets, Apple Watch remote.
- **Photos keep developing after you leave the app.** A Live Activity shows the progress in the Dynamic Island.

### Sony a7R III remote
- Live view over the Camera Remote API, with the film pipeline applied live.
- Shots taken in the app or on the body are pulled to the phone and developed with the film that was active when the shutter fired.
- Frame guide and Pose guide on the Sony's live view; a matched pose or a lined-up framing can fire the camera.

### Gallery
- Full-screen viewer with before/after comparison.
- Re-grade any shot from its original, and filter albums by film.
- Contact sheets, 4:5 export with a border, one-tap Instagram.

---

## Building

Requirements: Xcode 26 or later (iOS 26.2 SDK), and an iPhone. The simulator has no camera.

1. Open `cam cam.xcodeproj`.
2. Under *Signing & Capabilities* for the **cam cam** target, pick your own team and set a unique bundle identifier.
3. Build and run on a device.

**Before the first build, run `scripts/fetch-models.sh`.** It downloads what's too big for git:

- **MediaPipe Tasks Vision for iOS (Apache-2.0)**, about 1.2 GB unpacked into `Vendor/`, plus the BlazePose landmarker model. The project links it, so the build needs it.
  - The Pose guide uses it to add hands and feet (33 points) to Apple's body pose.
- **Depth Anything V2 Small (Apache-2.0)**, Apple's Core ML conversion, about 50 MB.
  - With it, Portrait works at 48MP on any lens: depth comes from the photo itself, fitted to the camera's depth when that exists.

The Core Image Metal kernels in `shaders/` are compiled ahead of time into `cam cam/*.metallib`, so normal builds don't need the Metal toolchain. After editing a shader, run:

```sh
scripts/build-shaders.sh
```

## Layout

| Path | What |
|------|------|
| `cam cam/CameraManager.swift` | Capture session, lenses, focus and exposure, photo pipeline, saving |
| `cam cam/CameraManager+Looks.swift` | Film looks, scan stage, grain, effects, loudness normalisation |
| `cam cam/FilmEngine.swift`, `Films/` | Exposure-modelled stocks; measured stock LUTs |
| `shaders/FilmProcess.ci.metal` | Film engine, grain, scan, print-process and halation kernels |
| `cam cam/LookVolume.swift` | Measures how strongly a look changes colour and tone |
| `cam cam/SmartExposure.swift` | Smart auto exposure |
| `cam cam/FrameAdvisor.swift`, `SceneFraming.swift` | Frame guide |
| `cam cam/PoseGuide.swift` | Pose guide |
| `cam cam/SonyConnector.swift`, `SonyView.swift`, `SonyGuides.swift` | Sony remote |
| `cam cam/PhotoSaver.swift`, `ShotRecipe.swift`, `RegradeView.swift` | Non-destructive saves, recipes, gallery |
| `cam cam/DevelopActivity.swift` | Background developing with a Live Activity |
| `training/` | Optional Mac-side training of the Frame guide's framing scorer |

### Debug harnesses

In Debug builds, these launch arguments run a test and print `[pipe]`, `[quality]` or `[volume]` lines:

| Argument | What it does |
|---|---|
| `-pipelineAudit` | Shots in several setups, measured rather than saved |
| `-resProbe` | Delivered resolution at each setting and zoom |
| `-teleAudit` | Main lens against the telephoto |
| `-qualityAudit <file> [-simsOnly \| -volumes \| -dumpSims]` | Every look on a photo: detail, tone range and volume |

## Credits

- Pose landmarks: MediaPipe BlazePose (Google), Apache-2.0.
- Portrait depth: Depth Anything V2 Small, Apache-2.0, via Apple's Core ML conversion.
- The measured film stocks are LUTs from **spektrafilm** by Andrea Volpato, licensed CC BY-SA 4.0. See `cam cam/Films/SPEKTRAFILM_LICENSE.txt`.
