# cam cam

An iOS camera app with two shooting modes: the **iPhone camera** with a deep film-simulation pipeline, and a **Sony a7R III remote** that drives the camera over WiFi and pulls shots straight to your phone.

> Personal / proprietary project. Built for my own shooting workflow.

---

## Modes

### 📷 CameraView — iPhone camera
A manual-feeling camera with a live film-sim preview and a large library of looks.

- **50+ built-in film simulations** — Leica, Fujifilm (Provia/Velvia/Classic Chrome/Eterna…), Kodak (Portra/Ektar/Gold…), Cinestill, slide, instant, B&W, and stylized stocks.
- **Custom sims** — build your own looks in the editor (contrast, saturation, temp/tint, curves, grain…).
- **LUT import** — drop in any `.cube` 3D LUT via the Files app; it applies live and saves with the shot.
- **Circuit-bent effects** — `Bent` / `Bent++`: thermal false-color palettes with a grain-driven signal-ripple glitch (single-pass Metal warp kernel, composite fallback).
- **DigiCam** — early-2000s CCD look with a quality slider (Off / 5–20) and an optional scanline "lines" toggle.
- **Film-effect stack** — halation, channel crosstalk, highlight rolloff, anamorphic flares, light leaks, scratches, push/pull, context-aware grain.
- Portrait depth blur, long exposure, burst, double-exposure masking, RAW.
- Category tabs in the sim strip (Built-in / Custom / LUTs) so the list stays navigable.

### 🎞 SonyView — Sony a7R III WiFi remote
Controls a Sony a7R III over its Camera Remote API and transfers shots to the phone.

- Live view stream with the same film-sim pipeline applied in real time.
- **Physical-shutter auto-transfer** — shots taken on the body (or via the app) are caught through `getEvent v1.8`'s `takePicture` slot and pulled down automatically.
- **Serial download queue** — burst/rapid shooting queues postview pulls one at a time so the live stream never chokes; on-screen "N queued" badge.
- **Per-shot sim snapshot** — each queued photo is processed with the sim that was active when *that* shutter fired, so you can keep changing looks while the queue drains.
- **EXIF-preserving saves** — camera/lens/exposure/date/GPS carried through even on sim-rendered shots.
- Stream watchdog with reconnect escalation + full session reset for dropouts.
- Volume buttons cycle film sims; rotation-lock defaults on; iPhone capture session pauses to save battery.

---

## Requirements

- Xcode (matching the current iOS SDK) with the **Metal Toolchain** component installed
  (`xcodebuild -downloadComponent MetalToolchain`) — required to compile `Ripple.ci.metal`.
- An iOS device for camera features (the simulator has no camera).
- For Sony mode: an a7R III on firmware exposing the Camera Remote API, joined to the phone's WiFi.

`scripts/ensure-metal-toolchain.sh` re-mounts the Metal toolchain on login (it can unmount on reboot in recent Xcode betas).

## Project layout

| File | Purpose |
|------|---------|
| `cam cam/CameraView.swift` | iPhone camera, film-sim pipeline, effects, UI |
| `cam cam/SonyConnector.swift` | Sony Camera Remote API client, live view, download queue |
| `cam cam/SonyView.swift` | Sony mode UI |
| `cam cam/LUTManager.swift` | `.cube` LUT import / parse / apply |
| `cam cam/Ripple.ci.metal` | Metal warp kernel for the circuit-bent ripple |

## Notes

- The film-sim pipeline runs in Core Image; the per-frame path is `nonisolated` so it can run off the video-data callback thread.
- Circuit-bent glitch intensity is driven by the grain slider; context-aware grain toggles the "wild" per-frame color/light drift.
