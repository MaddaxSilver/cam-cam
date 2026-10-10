//
//  CameraContentView.swift
//  cam cam
//
//  The main camera screen (SwiftUI).
//

import SwiftUI
@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos
import Observation
import CoreMotion
import MediaPlayer
import MetalKit
import UniformTypeIdentifiers
import CoreLocation

// MARK: - CameraContentView

struct CameraContentView: View {
    @State private var camera = CameraManager()
    @State private var motion = MotionManager()
    @State private var volumeObserver = VolumeButtonObserver()
    @State private var customSimStore = CustomSimStore()
    @State private var focusPoint: CGPoint?
    @State private var showFocusIndicator = false
    @State private var showViewMenu = false
    // showZoomSlider lives on camera so volume callbacks can check it
    @State private var zoomDebounceWork: DispatchWorkItem? = nil
    @State private var isDraggingZoom = false
    @State private var localZoom: Double = 1.0
    @State private var showCustomSimEditor = false
    @State private var showSonyView = false
    @State private var showRegrade = false
    @State private var showLibrary = false
    @State private var showRollSheet = false
    @State private var showSettings = false
    @State private var pinchBaseZoom: Double?
    @AppStorage("cc_classicUI") private var classicUI = false
    @AppStorage("cc_captureMode") private var captureModeRaw = CaptureMode.photo.rawValue
    @State private var roll = FilmRoll.shared
    @State private var showRollOptions = false
    @State private var router = LaunchRouter.shared
    @State private var geotag = LocationTagger.shared
    @State private var showLUTImporter = false

    /// Film-sim strip category filter. With many custom sims + LUTs the
    /// single horizontal scroll becomes a mess; these chips let you focus
    /// on one source at a time. "All" preserves the original behavior.
    /// Persisted across launches so you stay in whichever view you used last.
    @AppStorage("cc_simCategory") private var simCategoryRaw: String = SimCategory.all.rawValue
    private var simCategory: SimCategory {
        get { SimCategory(rawValue: simCategoryRaw) ?? .all }
    }
    private enum SimCategory: String, CaseIterable, Identifiable {
        case favorites, all, builtIn, custom, luts
        var id: String { rawValue }
        var label: String {
            switch self {
            case .favorites: return "Favorites"
            case .all:     return "All"
            case .builtIn: return "Built-in"
            case .custom:  return "Custom"
            case .luts:    return "LUTs"
            }
        }
        var icon: String {
            switch self {
            case .favorites: return "star.fill"
            case .all:     return "square.grid.2x2.fill"
            case .builtIn: return "film.fill"      // film reel
            case .custom:  return "wrench.fill"    // wrench for hand-tuned
            case .luts:    return "cube.fill"      // cube for 3D LUT
            }
        }
        var accent: Color {
            switch self {
            case .favorites: return Color(red: 1.0, green: 0.82, blue: 0.2)
            case .all:     return .white
            case .builtIn: return .yellow
            case .custom:  return .cyan
            case .luts:    return .orange
            }
        }
    }
    @State private var editingSim: CustomSimulation?
    @State private var favorites = FavoritesStore.shared
    @State private var shareItem: ShareItem? = nil
    @State private var exportingLUT = false
    @State private var sectionOverlaysExpanded = true
    @State private var sectionFilmEffectsExpanded = true
    @State private var sectionShootingExpanded = true
    @State private var sectionDoubleExpExpanded = true
    @State private var sectionQualityExpanded = true
    @State private var shutterPressTimer: Timer? = nil
    @State private var shutterIsHolding = false
    @State private var cleanMode = false
    @State private var recordingLocked = false
    @State private var recordingPendingLock = false
    @State private var startupBlackOpacity: Double = 1.0
    @State private var lockDragOffset: CGFloat = 0

    var body: some View {
        @Bindable var camera = camera
        GeometryReader { geo in
            ZStack {
                // Camera layer
                cameraLayer
                    .ignoresSafeArea()
                    .gesture(
                        MagnifyGesture()
                            .onChanged { v in
                                if pinchBaseZoom == nil { pinchBaseZoom = camera.zoom }
                                let z = min(max((pinchBaseZoom ?? 1) * v.magnification, 0.5), camera.maxManualZoom)
                                camera.setZoom(CGFloat(z))
                            }
                            .onEnded { v in
                                let z = min(max((pinchBaseZoom ?? 1) * v.magnification, 0.5), camera.maxManualZoom)
                                camera.zoom = z
                                pinchBaseZoom = nil
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { camera.syncZoomState() }
                            }
                    )
                    .onTapGesture { location in
                        guard !camera.manualFocusEnabled else { return }
                        focusPoint = location
                        showFocusIndicator = true
                        // Convert to camera coordinates (0...1)
                        let camPoint = CGPoint(
                            x: location.y / geo.size.height,
                            y: 1.0 - location.x / geo.size.width
                        )
                        camera.tapToFocus(at: camPoint)
                        // Auto-hide after 1.8s
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            showFocusIndicator = false
                        }
                    }

                // Aspect ratio overlay
                AspectRatioOverlay(aspectRatio: camera.selectedAspectRatio, geoSize: geo.size, isLandscape: motion.isLandscape)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // Grid
                if camera.showGrid {
                    GridOverlay()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                // Level
                if camera.showLevel {
                    LevelOverlay(roll: motion.levelTilt)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                // Focus peaking
                if camera.showPeaking {
                    FocusPeakingView(camera: camera)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                // Exposure meter — floating top left, fixed size
                ExposureMeterBar(evValue: camera.evReading, bias: camera.exposureBias)
                    .iconRotation(motion.iconAngle)
                    .frame(width: 80, height: 80)
                    .position(x: 56, y: 100)
                    .allowsHitTesting(false)

                // Focus indicator (tap-to-focus square)
                if showFocusIndicator, let pt = focusPoint {
                    FocusIndicator(position: pt)
                        .allowsHitTesting(false)
                }

                // Live AF hunting indicator — pulsing ring at top-left while camera seeks focus
                if camera.isFocusing {
                    FocusHuntingIndicator()
                        .allowsHitTesting(false)
                }

                // Face-detected indicator — small icon when AF is steering toward a face
                if camera.faceDetected && !camera.manualFocusEnabled {
                    FaceDetectedBadge()
                        .allowsHitTesting(false)
                }

                // Save error toast — auto-dismisses
                if let msg = camera.saveErrorMessage {
                    VStack {
                        Spacer()
                        Text(msg)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.red.opacity(0.85), in: Capsule())
                            .padding(.bottom, 180)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    .allowsHitTesting(false)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            if camera.saveErrorMessage == msg {
                                withAnimation { camera.saveErrorMessage = nil }
                            }
                        }
                    }
                }

                // Camera interrupted (call / another app / Split View / heat)
                if let msg = camera.interruptionMessage {
                    ZStack {
                        Color.black.opacity(0.55).ignoresSafeArea()
                        VStack(spacing: 10) {
                            Image(systemName: "video.slash.fill").font(.system(size: 30))
                            Text(msg).font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                // Thermal throttle notice (live effects reduced; captures unaffected)
                if let warn = camera.thermalWarning {
                    VStack {
                        Label(warn, systemImage: "thermometer.high")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.orange.opacity(0.9), in: Capsule())
                            .padding(.top, 110)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }

                // Controls overlay — full width
                if classicUI {
                    VStack(spacing: 0) {
                        // Top bar — right-aligned content
                        topBar
                            .padding(.top, 60)

                        Spacer()

                        // Bottom controls — full width
                        bottomSection
                    }
                    .frame(maxWidth: .infinity)
                } else if cleanMode {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            shutterButton
                            Spacer()
                        }
                        .overlay(alignment: .trailing) {
                            Button { cleanMode = false } label: {
                                Image(systemName: "eye").font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white).frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: Circle())
                            .padding(.trailing, 32)
                            .accessibilityLabel("Show controls")
                        }
                        .padding(.bottom, 44)
                    }
                } else {
                    GlassChrome(camera: camera, customSimStore: customSimStore,
                                mode: Binding(get: { CaptureMode(rawValue: captureModeRaw) ?? .photo },
                                              set: { captureModeRaw = $0.rawValue }),
                                onSony: { showSonyView = true },
                                onLibrary: { showLibrary = true },
                                onRoll: { showRollSheet = true },
                                onSettings: { showSettings = true },
                                onAlbum: { showRegrade = true },
                                shutter: { shutterButton })
                }

                // Startup fade — hides orientation settle on first frame
                if startupBlackOpacity > 0 {
                    Color.black
                        .ignoresSafeArea()
                        .opacity(startupBlackOpacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        .fullScreenCover(isPresented: $showCustomSimEditor) {
            CustomSimEditorView(store: customSimStore, camera: camera)
        }
        .fullScreenCover(isPresented: $showSonyView) {
            SonyView(camera: camera)
                .preferredColorScheme(.dark)
        }
        .fullScreenCover(isPresented: $showRegrade) {
            RegradeView(camera: camera, customSimStore: customSimStore)
        }
        .confirmationDialog(roll.isLoaded ? "Roll · \(roll.shotCount) of \(roll.capacity) shot" : "Load a film roll",
                            isPresented: $showRollOptions, titleVisibility: .visible) {
            if roll.isLoaded {
                if roll.shotCount > 0 {
                    Button("Develop \(roll.shotCount) frame\(roll.shotCount == 1 ? "" : "s")") {
                        Task { await roll.develop() }
                    }
                }
                Button("Discard roll (deletes undeveloped frames)", role: .destructive) { roll.discard() }
            } else {
                Button("24 exposures") { roll.load(capacity: 24) }
                Button("36 exposures") { roll.load(capacity: 36) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(roll.isLoaded
                 ? "Frames stay hidden until developed. Developing saves them to the cam cam album."
                 : "Shoot blind: no reviewing until the roll is developed.")
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url]).presentationDetents([.medium, .large])
        }
        .overlay(alignment: .bottom) {
            if roll.developing {
                Label("Developing \(roll.developProgress)/\(roll.shotCount + roll.developProgress)…", systemImage: "film")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.black.opacity(0.75), in: Capsule())
                    .padding(.bottom, 200)
            } else if let msg = roll.message {
                Text(msg)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.black.opacity(0.75), in: Capsule())
                    .padding(.bottom, 200).padding(.horizontal, 24)
                    .task(id: msg) {
                        try? await Task.sleep(for: .seconds(3))
                        if roll.message == msg { roll.message = nil }
                    }
            }
        }
        .overlay(alignment: .top) {
            if exportingLUT {
                Label("Baking LUT…", systemImage: "cube.transparent")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.black.opacity(0.7), in: Capsule())
                    .offset(y: -44)
            }
        }
        .fileImporter(
            isPresented: $showLUTImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "cube") ?? .data,
                .data
            ],
            allowsMultipleSelection: false
        ) { result in
            handleLUTImport(result: result)
        }
        .sheet(isPresented: $showLibrary) {
            FilmLibrarySheet(camera: camera, customSimStore: customSimStore,
                             onExportLUT: { sim, custom, name in exportLUT(sim: sim, custom: custom, name: name) },
                             onEditFilms: { showCustomSimEditor = true },
                             onImportLUT: { showLUTImporter = true })
        }
        .sheet(isPresented: $showRollSheet) {
            RollSheet().presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSettings) {
            CamSettingsSheet(camera: camera,
                             onRegrade: { showRegrade = true },
                             onRoll: { showRollSheet = true },
                             onEditFilms: { showCustomSimEditor = true },
                             onImportLUT: { showLUTImporter = true },
                             classicUI: $classicUI, cleanMode: $cleanMode)
        }
        .onChange(of: motion.isLandscape) { _, newValue in
            camera.isLandscape = newValue
        }
        .onChange(of: motion.iconAngle) { _, newValue in
            camera.deviceAngle = newValue
        }
        .onChange(of: cleanMode) { _, isClean in
            if isClean && !camera.showZoomSlider {
                camera.showZoomSlider = true
                camera.syncZoomState()
            }
        }
        .onChange(of: camera.zoom) { _, newValue in
            // Volume buttons and presets write camera.zoom — sync to local slider
            if abs(newValue - localZoom) > 0.01 { localZoom = newValue }
        }
        .onChange(of: camera.showZoomSlider) { _, isShown in
            if isShown { localZoom = camera.zoom }
        }
        .onChange(of: router.request) { handleLaunchRequest() }
        .onAppear {
            handleLaunchRequest()
            // Fade out startup black so orientation is correct before anything is visible
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(.easeOut(duration: 0.3)) { startupBlackOpacity = 0 }
            }
            // Wire WatchConnector to this manager so Watch shutter messages route correctly
            WatchConnector.shared.camera = camera
            WatchConnector.shared.pushState()
            motion.startUpdates()
            LocationTagger.shared.start()   // geotag (no-op if the toggle is off)
            let evStep: Float = 0.33
            let opacityStep: Double = 0.1
            let triggerShutter = {
                guard !camera.isCapturing else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                if camera.doubleExposureEnabled && camera.firstExposurePreview == nil {
                    camera.captureDoubleExposureFirst()
                } else {
                    camera.capturePhoto()
                }
            }
            volumeObserver.onVolumeUp = {
                // Volume-shutter mode short-circuits everything else
                if camera.volumeShutterEnabled {
                    triggerShutter()
                    return
                }
                let bothActive = camera.showZoomSlider && camera.doubleExposureEnabled
                if camera.showZoomSlider && camera.volumeControlsEV {
                    // EV dial tapped — volume controls exposure
                    let newBias = min(camera.exposureBias + evStep, 3.0)
                    camera.setExposureBias(newBias)
                } else if bothActive && camera.volumeControlsBlend {
                    camera.doubleExposureOpacity = min(camera.doubleExposureOpacity + opacityStep, 1.0)
                } else if camera.showZoomSlider {
                    camera.stepManualZoom(up: true)
                } else if camera.doubleExposureEnabled {
                    camera.doubleExposureOpacity = min(camera.doubleExposureOpacity + opacityStep, 1.0)
                } else {
                    let newBias = min(camera.exposureBias + evStep, 3.0)
                    camera.setExposureBias(newBias)
                }
            }
            volumeObserver.onVolumeDown = {
                if camera.volumeShutterEnabled {
                    triggerShutter()
                    return
                }
                let bothActive = camera.showZoomSlider && camera.doubleExposureEnabled
                if camera.showZoomSlider && camera.volumeControlsEV {
                    let newBias = max(camera.exposureBias - evStep, -3.0)
                    camera.setExposureBias(newBias)
                } else if bothActive && camera.volumeControlsBlend {
                    camera.doubleExposureOpacity = max(camera.doubleExposureOpacity - opacityStep, 0.0)
                } else if camera.showZoomSlider {
                    camera.stepManualZoom(up: false)
                } else if camera.doubleExposureEnabled {
                    camera.doubleExposureOpacity = max(camera.doubleExposureOpacity - opacityStep, 0.0)
                } else {
                    let newBias = max(camera.exposureBias - evStep, -3.0)
                    camera.setExposureBias(newBias)
                }
            }
        }
        .onDisappear {
            motion.stopUpdates()
            shutterPressTimer?.invalidate()
            shutterPressTimer = nil
        }
    }

    // MARK: - Camera Layer

    @ViewBuilder
    private var cameraLayer: some View {
        if camera.isDenied {
            Color.black.overlay {
                VStack(spacing: 10) {
                    Image(systemName: "camera.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Camera access denied")
                        .foregroundStyle(.secondary)
                    Text("Enable in Settings > cam cam")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            CameraPreviewView(session: camera.session, camera: camera)
                .overlay {
                    // Live filtered preview — Metal-rendered, full GPU pipeline
                    // Always present when a sim is selected; Metal view shows nothing if no image
                    if camera.selectedSim != .none || camera.activeCustomSim != nil {
                        MetalFilteredPreview(camera: camera)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    // Overlay first exposure while framing second shot
                    if camera.doubleExposureEnabled, let preview = camera.firstExposurePreview {
                        GeometryReader { geo in
                            Image(decorative: preview, scale: 1.0)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .opacity(camera.doubleExposureOpacity)
                                .allowsHitTesting(false)

                            // Mask painter — only active when mask mode is on
                            if camera.doubleExposureMaskEnabled {
                                MaskOverlayView(camera: camera, geoSize: geo.size)
                            }
                        }
                    }
                }
        }
    }

    // MARK: - Top Bar

    @ViewBuilder private var topBar: some View {
        @Bindable var camera = camera
        ZStack(alignment: .topTrailing) {
            // Tap-outside overlay — dismisses dropdown when visible
            if showViewMenu {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.25)) { showViewMenu = false }
                    }
                    .ignoresSafeArea()
            }
        VStack(alignment: .trailing, spacing: 8) {
            // Top pill row — right-aligned (hidden in clean mode)
            if !cleanMode {
            HStack(spacing: 8) {
                Spacer()

                TopPill(
                    icon: "square.stack",
                    text: camera.doubleExposureEnabled ? "2X" : "1X",
                    isActive: camera.doubleExposureEnabled
                )
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    camera.doubleExposureEnabled.toggle()
                    if !camera.doubleExposureEnabled {
                        camera.firstExposureCIImage = nil
                        camera.firstExposurePreview = nil
                        camera.capturingFirstExposure = false
                        camera.pendingMask = nil
                        camera.doubleExposureMask = nil
                        camera.doubleExposureMaskEnabled = false
                        camera.volumeControlsBlend = false
                    }
                }

                TopPill(
                    text: camera.rawEnabled ? "RAW" : "JPEG",
                    isActive: camera.rawEnabled
                )
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    camera.rawEnabled.toggle()
                }

                TopPill(
                    icon: "timer",
                    text: camera.isLongExposure ? Self.durationLabel(camera.longExposureDuration) : "BULB",
                    isActive: camera.isLongExposure
                )
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    camera.isLongExposure.toggle()
                }

                TopPill(
                    icon: "viewfinder",
                    text: camera.manualFocusEnabled ? "MF" : "AF",
                    isActive: camera.manualFocusEnabled
                )
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    camera.setManualFocusEnabled(!camera.manualFocusEnabled)
                }

            }
            } // end if !cleanMode (top pill row)

            // View options button + dropdown
            HStack(spacing: 6) {
                Spacer()

                // Film roll counter — exposures left, like a film camera's window
                if roll.isLoaded {
                    Button { showRollOptions = true } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "film").font(.system(size: 8))
                            Text(roll.isFull ? "DEVELOP" : "\(roll.exposuresLeft) LEFT")
                                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Capsule().fill(roll.isFull ? Color.red : Color.orange))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                // Flash state pill — visible when flash is not off (hidden in clean mode)
                if camera.flashMode != .off && !cleanMode {
                    HStack(spacing: 3) {
                        Image(systemName: camera.flashMode == .auto ? "bolt.badge.automatic" : "bolt.fill")
                            .font(.system(size: 8))
                        Text(camera.flashLabel)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.yellow)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                // Blend % pill — visible when double exposure is active (hidden in clean mode)
                if camera.doubleExposureEnabled && !cleanMode {
                    let blendIsVolumeTarget = camera.volumeControlsBlend && camera.showZoomSlider && camera.doubleExposureEnabled
                    Button {
                        if camera.showZoomSlider && camera.doubleExposureEnabled {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                camera.volumeControlsBlend.toggle()
                                if camera.volumeControlsBlend { camera.volumeControlsEV = false }
                            }
                        }
                    } label: {
                        Text("BLEND \(Int(camera.doubleExposureOpacity * 100))%")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(blendIsVolumeTarget ? .black : .white)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(blendIsVolumeTarget ? Color.yellow : Color.black.opacity(0.4))
                                    .overlay(Capsule().stroke(blendIsVolumeTarget ? Color.clear : Color.white.opacity(0.3), lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                // Portrait mode pill (hidden in clean mode)
                if camera.portraitModeEnabled && !cleanMode {
                    HStack(spacing: 4) {
                        Image(systemName: "person.fill").font(.system(size: 10))
                        Text(String(format: "f/%.1f", camera.portraitFStop))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Capsule().fill(Color.yellow))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                // Clean mode pill — always visible
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { cleanMode.toggle() }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: cleanMode ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(cleanMode ? .black : .white)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(cleanMode ? Color.white : Color.black.opacity(0.4))
                                .overlay(Capsule().stroke(cleanMode ? Color.clear : Color.white.opacity(0.3), lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)

                if !cleanMode {
                // Volume-button shutter toggle — pill next to the dropdown
                Button {
                    camera.volumeShutterEnabled.toggle()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: camera.volumeShutterEnabled ? "speaker.wave.2.circle.fill" : "speaker.wave.2.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(camera.volumeShutterEnabled ? .black : .white)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(camera.volumeShutterEnabled ? Color.yellow : Color.black.opacity(0.4))
                                .overlay(Capsule().stroke(camera.volumeShutterEnabled ? Color.clear : Color.white.opacity(0.3), lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring(duration: 0.25)) { showViewMenu.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 11))
                        Text(camera.selectedAspectRatio.label).font(.system(size: 12, weight: .semibold))
                        Image(systemName: showViewMenu ? "chevron.up" : "chevron.down").font(.system(size: 9))
                    }
                    .foregroundStyle(showViewMenu ? .yellow : .white)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(showViewMenu ? Color.yellow.opacity(0.2) : Color.black.opacity(0.4))
                            .overlay(Capsule().stroke(showViewMenu ? .yellow : Color.white.opacity(0.3), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                } // end if !cleanMode (dropdown)
            }

            // Dropdown menu
            if showViewMenu {
                ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Aspect ratios
                    HStack(spacing: 6) {
                        ForEach(AspectRatio.allCases) { ratio in
                            let sel = camera.selectedAspectRatio == ratio
                            Button {
                                camera.selectedAspectRatio = ratio
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: {
                                Text(ratio.label)
                                    .font(.system(size: 12, weight: sel ? .bold : .regular))
                                    .foregroundStyle(sel ? .black : .white)
                                    .padding(.horizontal, 9).padding(.vertical, 6)
                                    .background(Capsule().fill(sel ? Color.white : Color.white.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 10)

                    Divider().background(Color.white.opacity(0.2))

                    // OVERLAYS section
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("OVERLAYS", isExpanded: $sectionOverlaysExpanded, accent: .cyan)
                        if sectionOverlaysExpanded {
                            HStack(spacing: 10) {
                                viewMenuToggle(icon: "grid", title: "Grid", isOn: $camera.showGrid)
                                viewMenuToggle(icon: "level", title: "Level", isOn: $camera.showLevel)
                                viewMenuToggle(icon: "eye", title: "Peaking", isOn: $camera.showPeaking)
                            }
                            .padding(.bottom, 6)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    Divider().background(Color.white.opacity(0.2))

                    // FILM EFFECTS section
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("FILM EFFECTS", isExpanded: $sectionFilmEffectsExpanded, accent: .purple)
                        if sectionFilmEffectsExpanded {
                            HStack(spacing: 8) {
                                // Halation = red bloom around highlights on film stock
                                viewMenuToggle(icon: "drop.fill", title: "Halation",
                                               isOn: $camera.halationEnabled, accent: .red)
                                // Crosstalk = channels bleeding into each other → purple
                                viewMenuToggle(icon: "paintpalette", title: "Crosstalk",
                                               isOn: $camera.crosstalkEnabled, accent: .purple)
                                // Rolloff = highlight shoulder → cool blue
                                viewMenuToggle(icon: "waveform", title: "Rolloff",
                                               isOn: $camera.rolloffEnabled, accent: .blue)
                            }
                            HStack(spacing: 8) {
                                // Anamorphic flares are classic cyan streaks
                                viewMenuToggle(icon: "aqi.medium", title: "Flares",
                                               isOn: $camera.anamorphicFlareEnabled, accent: .cyan)
                                // Light leaks = warm orange exposure
                                viewMenuToggle(icon: "light.beacon.max", title: "Light Leaks",
                                               isOn: $camera.lightArtifactsEnabled, accent: .orange)
                                // Scratches = chemical decay green tint
                                viewMenuToggle(icon: "line.diagonal", title: "Scratches",
                                               isOn: $camera.filmScratchesEnabled, accent: .green)
                            }
                            HStack(spacing: 8) {
                                // Randomize = chaos → pink
                                viewMenuToggle(icon: "dice", title: "Randomize",
                                               isOn: $camera.filmRandomizationEnabled, accent: .pink)
                            }
                            // DigiCam quality — only visible when DigiCam is the
                            // active sim. 5 = crustiest disposable, 20 = clean
                            // mid-2000s compact. Linear interpolation between.
                            if camera.selectedSim == .digiCam {
                                // Magenta accent — distinct from the rest of FILM EFFECTS
                                // (which use red/purple/blue/cyan/green/pink toggles)
                                // and signals "this is a digital glitch control, not film."
                                let digiAccent = Color(red: 1.0, green: 0.32, blue: 0.78)
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "camera.aperture")
                                            .font(.system(size: 12))
                                        Text(camera.digiCamQuality < 1
                                             ? "DigiCam Quality: Off"
                                             : "DigiCam Quality: \(Int(camera.digiCamQuality))")
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .foregroundStyle(camera.digiCamQuality < 1 ? .white.opacity(0.5) : digiAccent)
                                    HStack(spacing: 8) {
                                        Text("Off")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.5))
                                        Slider(
                                            value: Binding(
                                                get: { Double(camera.digiCamQuality) },
                                                set: { camera.digiCamQuality = Float($0) }
                                            ),
                                            in: 0...20,
                                            step: 1
                                        )
                                        .tint(digiAccent)
                                        Text("20")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.5))
                                    }
                                }
                                .padding(.vertical, 4)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            // Push / Pull
                            VStack(alignment: .leading, spacing: 6) {
                                let pushPullLabel: String = {
                                    if camera.pushPullAmount == 0 { return "Push / Pull" }
                                    if camera.pushPullAmount > 0 { return "Push +\(String(format: "%.0f", camera.pushPullAmount))" }
                                    return "Pull \(String(format: "%.0f", camera.pushPullAmount))"
                                }()
                                Button {
                                    camera.pushPullEnabled.toggle()
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.up.arrow.down.circle")
                                            .font(.system(size: 12))
                                        Text(pushPullLabel)
                                            .font(.system(size: 12, weight: camera.pushPullEnabled ? .bold : .regular))
                                    }
                                    .foregroundStyle(camera.pushPullEnabled ? .yellow : .white)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(camera.pushPullEnabled ? Color.yellow.opacity(0.2) : Color.white.opacity(0.1)))
                                }
                                .buttonStyle(.plain)
                                if camera.pushPullEnabled {
                                    HStack(spacing: 8) {
                                        Text("Pull")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.5))
                                        Slider(value: $camera.pushPullAmount, in: -2...3, step: 1)
                                            .tint(.yellow)
                                        Text("Push")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.white.opacity(0.5))
                                    }
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                            .padding(.bottom, 6)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    Divider().background(Color.white.opacity(0.2))

                    // SHOOTING section
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("SHOOTING", isExpanded: $sectionShootingExpanded, accent: .orange)
                        if sectionShootingExpanded {
                            HStack(spacing: 10) {
                                // Change any shot's look after the fact (original kept)
                                Button {
                                    showRegrade = true
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "wand.and.stars").font(.system(size: 12))
                                        Text("Re-grade").font(.system(size: 12, weight: .medium))
                                    }
                                    .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.2))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(Color(red: 1.0, green: 0.82, blue: 0.2).opacity(0.18)))
                                }
                                .buttonStyle(.plain)
                                viewMenuToggle(icon: "location.fill", title: "Geotag", isOn: $geotag.enabled, accent: .green)
                                // Film roll: shoot blind, develop later
                                Button {
                                    showRollOptions = true
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "film").font(.system(size: 12))
                                        Text(roll.isLoaded ? "\(roll.shotCount)/\(roll.capacity)" : "Roll")
                                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                                    }
                                    .foregroundStyle(roll.isLoaded ? .black : .white)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(roll.isLoaded ? Color.orange : Color.white.opacity(0.14)))
                                }
                                .buttonStyle(.plain)
                            }
                            HStack(spacing: 10) {
                                viewMenuToggle(icon: "bolt.circle", title: "Burst", isOn: $camera.burstMode)

                                // Portrait mode — shown whenever the session supports depth output.
                                // Dimmed (not hidden) when the current lens doesn't produce depth
                                // so the user can see it exists and knows to switch back to the
                                // main camera to use it.
                                if camera.portraitModeAvailable {
                                    viewMenuToggle(icon: "person.fill", title: "Portrait", isOn: $camera.portraitModeEnabled)
                                        .opacity(camera.currentDeviceSupportsDepth ? 1.0 : 0.4)
                                        .allowsHitTesting(camera.currentDeviceSupportsDepth)
                                }

                                // Macro mode — swaps to physical ultrawide for ~2cm focus distance
                                viewMenuToggle(icon: "leaf.fill", title: "Macro", isOn: $camera.macroModeEnabled)
                            }
                            HStack(spacing: 10) {
                                // Lefty mode — moves shutter cluster over to where the EV dial sits
                                viewMenuToggle(icon: "hand.point.left.fill", title: "Lefty", isOn: $camera.shutterOnLeft)
                                // Unified zoom — single virtual triple camera, no preset swaps
                                viewMenuToggle(icon: "rectangle.stack", title: "1-Lens", isOn: $camera.unifiedZoomMode)
                            }

                            Spacer().frame(height: 6)
                        }
                    }

                    // DOUBLE EXPOSURE section (only when active)
                    if camera.doubleExposureEnabled {
                        Divider().background(Color.white.opacity(0.2))
                        VStack(alignment: .leading, spacing: 8) {
                            sectionHeader("DOUBLE EXPOSURE MASK", isExpanded: $sectionDoubleExpExpanded, accent: .pink)
                            if sectionDoubleExpExpanded {
                                HStack(spacing: 10) {
                                    viewMenuToggle(icon: "paintbrush.fill", title: "Mask Mode", isOn: $camera.doubleExposureMaskEnabled)
                                }
                                if camera.doubleExposureMaskEnabled {
                                    maskBrushControls
                                        .padding(.bottom, 6)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                        }
                    }

                    Divider().background(Color.white.opacity(0.2))

                    // PHOTO QUALITY section
                    VStack(alignment: .leading, spacing: 6) {
                        sectionHeader("PHOTO QUALITY", isExpanded: $sectionQualityExpanded, accent: .mint)
                        if sectionQualityExpanded {
                            HStack(spacing: 6) {
                                ForEach(Array(["Speed", "Balanced", "Max"].enumerated()), id: \.offset) { idx, label in
                                    let sel = camera.photoQuality == idx
                                    Button {
                                        camera.photoQuality = idx
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    } label: {
                                        Text(label)
                                            .font(.system(size: 12, weight: sel ? .bold : .regular))
                                            .foregroundStyle(sel ? .black : .white)
                                            .padding(.horizontal, 9).padding(.vertical, 6)
                                            .background(Capsule().fill(sel ? Color.white : Color.white.opacity(0.12)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    Divider().background(Color.white.opacity(0.2))

                    // Sony camera connector
                    Button {
                        showSonyView = true
                        withAnimation(.spring(duration: 0.25)) { showViewMenu = false }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "camera.on.rectangle.fill")
                                .font(.system(size: 13))
                            Text("Sony Camera")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Image(systemName: "wifi")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.3))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .foregroundStyle(.yellow)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)

                    Divider().background(Color.white.opacity(0.2))

                    // Custom film editor
                    Button {
                        showCustomSimEditor = true
                        withAnimation(.spring(duration: 0.25)) { showViewMenu = false }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "paintbrush.pointed.fill")
                                .font(.system(size: 13))
                            Text("Custom Films")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("\(customSimStore.simulations.count)")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        .foregroundStyle(.cyan)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                } // end ScrollView content (VStack)
                .frame(maxHeight: 500)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.35)))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.trailing, 20)
        } // end ZStack
    }

    /// Format a long-exposure duration: whole seconds as "Xs", half-seconds as "X.5s".
    private static func durationLabel(_ s: Double) -> String {
        s.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0fs", s)
            : String(format: "%.1fs", s)
    }

    @ViewBuilder
    private var maskBrushControls: some View {
        @Bindable var camera = camera
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Brush Size")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("\(Int(camera.maskBrushSize))")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: $camera.maskBrushSize, in: 10...120, step: 5)
                .tint(.white)
            HStack(spacing: 8) {
                Button { camera.maskBrushOpacity = 1.0 } label: {
                    Label("Expose", systemImage: "plus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(camera.maskBrushOpacity > 0.5 ? Color.black : Color.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(camera.maskBrushOpacity > 0.5 ? Color.white : Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                Button { camera.maskBrushOpacity = 0.0 } label: {
                    Label("Erase", systemImage: "minus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(camera.maskBrushOpacity <= 0.5 ? Color.black : Color.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(camera.maskBrushOpacity <= 0.5 ? Color.white : Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    camera.doubleExposureMask = nil
                    camera.pendingMask = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red.opacity(0.9))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.red.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Handle a .cube LUT file selected via the fileImporter. Copies it to
    /// the app's LUT directory, validates it parses, creates a CustomSimulation
    /// entry referencing the file, and auto-selects it as the active sim.
    private func handleLUTImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let filename = try LUTManager.shared.importLUT(from: url)
                var sim = CustomSimulation()
                sim.name = filename
                    .replacingOccurrences(of: ".cube", with: "",
                                          options: String.CompareOptions.caseInsensitive)
                    .replacingOccurrences(of: "_", with: " ")
                sim.lutFilename = filename
                customSimStore.simulations.append(sim)
                customSimStore.save()
                customSimStore.activeCustomSimID = sim.id
                camera.activeCustomSim = sim
                camera.selectedSim = .none
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                // Show a brief save-error message if available; otherwise silent fail
                camera.saveErrorMessage = "LUT import failed: \(error.localizedDescription)"
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        case .failure:
            break   // user cancelled the picker
        }
    }

    /// Section-header pill. `accent` colors the title text + chevron so each
    /// section in the View menu reads as visually distinct at a glance —
    /// Display=cyan, Film Effects=purple, Shooting=orange, etc.
    private func sectionHeader(_ title: String, isExpanded: Binding<Bool>, accent: Color = .white) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 6) {
                // Small accent dot before the title — strong visual anchor
                // that survives even with the dim text below.
                Circle()
                    .fill(accent)
                    .frame(width: 5, height: 5)
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.85))
                    .tracking(0.6)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.5))
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 180 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded.wrappedValue)
            }
            .padding(.top, 4)
        }
        .buttonStyle(.plain)
    }

    /// Toggle pill. The `accent` param lets each toggle pick its own active
    /// color — e.g. halation=red (its on-film color), crosstalk=purple,
    /// scratches=green. Inactive state stays neutral white so the active
    /// ones really pop.
    @ViewBuilder
    private func viewMenuToggle(icon: String, title: String, isOn: Binding<Bool>, accent: Color = .yellow) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(.system(size: 12, weight: isOn.wrappedValue ? .bold : .regular))
            }
            .foregroundStyle(isOn.wrappedValue ? accent : .white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                Capsule().fill(isOn.wrappedValue ? accent.opacity(0.22) : Color.white.opacity(0.1))
            )
            .overlay(
                Capsule().stroke(isOn.wrappedValue ? accent.opacity(0.4) : Color.clear, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom Section

    private var bottomSection: some View {
        VStack(spacing: 16) {
            // MF focus slider — hidden in clean mode
            if camera.manualFocusEnabled && !cleanMode {
                HStack(spacing: 6) {
                    Text("Near")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                    Slider(
                        value: Binding(
                            get: { camera.manualFocusValue },
                            set: { camera.setManualFocus($0) }
                        ),
                        in: 0...1
                    )
                    .tint(.yellow)
                    Text("Far")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Zoom slider — hidden in clean mode
            if camera.showZoomSlider && !cleanMode {
                VStack(spacing: 6) {
                    // Show live localZoom during drag (no camera round-trip lag); fall back
                    // to camera.currentMM when idle so it matches the preset readouts exactly.
                    Text("\(isDraggingZoom ? Int(round(26.0 * localZoom)) : camera.currentMM)mm")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.yellow)

                    HStack(spacing: 8) {
                        Text("0.5x")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                        Slider(value: $localZoom, in: 0.5...camera.maxManualZoom) { editing in
                            isDraggingZoom = editing
                            if !editing { camera.zoom = localZoom }
                        }
                        .tint(.yellow)
                        .onChange(of: localZoom) { _, v in
                            if isDraggingZoom { camera.setZoom(CGFloat(v)) }
                        }
                        Text("\(Int(camera.maxManualZoom))x")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Portrait f-stop slider — hidden in clean mode
            if camera.portraitModeEnabled && !cleanMode {
                VStack(spacing: 4) {
                    HStack {
                        Image(systemName: "person.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.yellow)
                        Text("APERTURE")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.5))
                        Spacer()
                        Text(String(format: "f/%.1f", camera.portraitFStop))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.yellow)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(camera.portraitFStop) },
                            set: { v in
                                camera.portraitFStop = Float(v)
                                camera.pendingPortraitFStop = Float(v)
                            }
                        ),
                        in: 1.4...16.0,
                        step: 0.1
                    )
                    .tint(.yellow)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.5))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.25), lineWidth: 1))
                )
                .padding(.horizontal, 16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Focal length presets
            HStack(spacing: 18) {
                ForEach(Array(focalPresets.enumerated()), id: \.offset) { index, preset in
                    VStack(spacing: 2) {
                        Text("\(preset.mm == 50 && camera.currentMM == 55 ? 55 : preset.mm)")
                            .font(.system(size: 15, weight: camera.selectedFocalIndex == index ? .bold : .semibold, design: .rounded))
                        Text("mm")
                            .font(.system(size: 9))
                    }
                    .iconRotation(motion.iconAngle)
                    .foregroundStyle(camera.selectedFocalIndex == index ? .yellow : .white)
                    .frame(width: 54, height: 54)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.5))
                            .overlay(
                                Circle().stroke(
                                    camera.selectedFocalIndex == index ? Color.yellow : Color.white.opacity(0.3),
                                    lineWidth: camera.selectedFocalIndex == index ? 1.5 : 0.5
                                )
                            )
                    )
                    .onTapGesture(count: 2) {
                        if preset.mm == 50 {
                            let alreadyOnThisLens = camera.selectedFocalIndex == index
                            if alreadyOnThisLens {
                                // Toggle between 50mm and 55mm
                                let target = camera.currentMM == 55 ? 50.0 / 26.0 : 55.0 / 26.0
                                camera.sessionQueue.async {
                                    guard let device = camera.currentDevice else { return }
                                    camera.applyZoom(factor: CGFloat(target), on: device)
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    camera.syncZoomState()
                                }
                            } else {
                                // Switch to this lens first, then go to 55mm
                                camera.selectFocalPreset(index)
                                // Wait for lens swap to complete, then apply 55mm
                                camera.sessionQueue.async {
                                    guard let device = camera.currentDevice else { return }
                                    let factor55 = 55.0 / 26.0
                                    camera.applyZoom(factor: CGFloat(factor55), on: device)
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    camera.syncZoomState()
                                }
                            }
                        } else {
                            camera.selectFocalPreset(index)
                        }
                    }
                    .onTapGesture(count: 1) {
                        camera.selectFocalPreset(index)
                    }
                }

            }

            // Sim category chips + sim strip — hidden in clean mode.
            // The category row is only shown when there are customs/LUTs
            // (otherwise it's just clutter for the built-in-only case).
            if !cleanMode {
                let favBuiltIns = favorites.builtIns
                let favCustoms  = favorites.customs(in: customSimStore.simulations)
                let hasFavorites = !favBuiltIns.isEmpty || !favCustoms.isEmpty
                // Show category tabs once there's anything worth filtering.
                let hasCustomsOrLUTs = !customSimStore.simulations.isEmpty || hasFavorites
                let cat = (simCategory == .favorites && !hasFavorites) ? .all : simCategory
                // Partition the custom sims once so the strip doesn't re-walk twice.
                let customSims = customSimStore.simulations.filter { $0.lutFilename == nil }
                let lutSims    = customSimStore.simulations.filter { $0.lutFilename != nil }
                // What goes in the strip for the current category.
                let showBuiltIns = cat == .all || cat == .builtIn
                let showCustoms  = cat == .all || cat == .custom
                let showLUTs     = cat == .all || cat == .luts

                ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // ── Category tabs inline, same pill style as sims below.
                    // Icon + label, accent-colored when active. Followed by a
                    // thin divider so the sims feel like a separate visual
                    // group while still scrolling as one row.
                    if hasCustomsOrLUTs {
                        ForEach(SimCategory.allCases) { c in
                            let isActive = c == cat
                            let count: Int = {
                                switch c {
                                case .favorites: return favBuiltIns.count + favCustoms.count
                                case .all:     return FilmSimulation.allCases.count + customSimStore.simulations.count
                                case .builtIn: return FilmSimulation.allCases.count
                                case .custom:  return customSims.count
                                case .luts:    return lutSims.count
                                }
                            }()
                            if c == .all || count > 0 {
                                Button {
                                    simCategoryRaw = c.rawValue
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: c.icon)
                                            .font(.system(size: 10))
                                        Text(c.label)
                                            .font(.system(size: 13, weight: isActive ? .bold : .regular))
                                    }
                                    .foregroundStyle(isActive ? .black : c.accent)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule().fill(isActive ? c.accent : c.accent.opacity(0.15))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        // Thin divider between tabs and the sims that follow
                        Rectangle()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 1, height: 24)
                            .padding(.horizontal, 2)
                    }
                    // ★ Favorites — pinned sims first (All view) or alone (Favorites tab)
                    if hasFavorites && (cat == .all || cat == .favorites) {
                        ForEach(favBuiltIns) { sim in
                            builtInChip(sim, starred: true)
                        }
                        ForEach(favCustoms) { sim in
                            customChip(sim, starred: true)
                        }
                        if cat == .all {
                            Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 24)
                        }
                    }
                    // Built-in sims
                    if showBuiltIns {
                        ForEach(FilmSimulation.allCases) { sim in
                            builtInChip(sim, starred: favorites.isFavorite(FavoritesStore.key(sim)))
                        }
                    }

                    // Divider — only show in "All" view between built-ins and customs.
                    if cat == .all && hasCustomsOrLUTs {
                        Rectangle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 1, height: 24)
                    }

                    // Custom (param-based) sims
                    if showCustoms {
                        ForEach(customSims) { sim in
                            customChip(sim, starred: favorites.isFavorite(FavoritesStore.key(sim)))
                        }
                    }

                    // LUT-based sims
                    if showLUTs {
                        ForEach(lutSims) { sim in
                            customChip(sim, starred: favorites.isFavorite(FavoritesStore.key(sim)))
                        }
                    }

                    // Create custom sim button — only in All or Custom
                    if cat == .all || cat == .custom {
                        Button {
                            showCustomSimEditor = true
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 18))
                                .foregroundStyle(.cyan)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }

                    // Import LUT button — only in All or LUTs
                    if cat == .all || cat == .luts {
                        Button {
                            showLUTImporter = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus.square.dashed")
                                    .font(.system(size: 11))
                                Text("LUT")
                                    .font(.system(size: 13))
                            }
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().stroke(Color.orange.opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 32)
            }
            .padding(.horizontal, -32)
            } // end if !cleanMode (film sim strip)

            // Grain toggle + slider — hidden in clean mode
            if (camera.selectedSim != .none || customSimStore.activeCustomSimID != nil) && !cleanMode {
                HStack(spacing: 10) {
                    Button {
                        camera.grainEnabled.toggle()
                        // Context-aware requires grain to be on
                        if !camera.grainEnabled { camera.contextAwareGrainEnabled = false }
                    } label: {
                        Image(systemName: camera.grainEnabled ? "circle.grid.3x3.fill" : "circle.grid.3x3")
                            .font(.system(size: 16))
                            .iconRotation(motion.iconAngle)
                            .foregroundStyle(camera.grainEnabled ? .yellow : .white.opacity(0.6))
                    }
                    .buttonStyle(.plain)

                    if camera.grainEnabled {
                        Slider(value: $camera.grainAmount, in: 0...0.5)
                            .tint(.white)
                        Image(systemName: "circle.grid.3x3.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.6))

                        // Context-aware grain button — only active when grain is on.
                        // Repurposed per active sim:
                        //   • DigiCam → "lines" (CCD scanline overlay)
                        //   • Circuit-bent → "wild" (random light/color drift)
                        //   • everything else → context-aware grain (luma-scaled)
                        let isDigiCamActive = camera.selectedSim == .digiCam
                            && customSimStore.activeCustomSimID == nil
                        let ctxIcon: String = {
                            if isDigiCamActive {
                                return camera.contextAwareGrainEnabled ? "lines.measurement.horizontal" : "line.3.horizontal"
                            }
                            return camera.contextAwareGrainEnabled ? "waveform.badge.magnifyingglass" : "waveform"
                        }()
                        Button {
                            camera.contextAwareGrainEnabled.toggle()
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Image(systemName: ctxIcon)
                                .font(.system(size: 14))
                                .iconRotation(motion.iconAngle)
                                .foregroundStyle(camera.contextAwareGrainEnabled ? .yellow : .white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }

            // Long exposure controls — hidden in clean mode
            if camera.isLongExposure && !cleanMode {
                VStack(spacing: 10) {
                    // Mode toggle + duration label
                    HStack(spacing: 8) {
                        ForEach(LongExposureMode.allCases) { mode in
                            let selected = camera.longExposureMode == mode
                            Button {
                                camera.longExposureMode = mode
                            } label: {
                                Text(mode.label)
                                    .font(.system(size: 12, weight: selected ? .bold : .regular))
                                    .foregroundStyle(selected ? .black : .white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(selected ? Color.cyan : Color.white.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        Text(String(format: "%.1fs", camera.longExposureDuration))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.cyan)
                    }

                    // Duration slider
                    HStack(spacing: 8) {
                        Text("1s")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                        Slider(value: $camera.longExposureDuration, in: 1...30, step: 0.5)
                            .tint(.cyan)
                        Text("30s")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Shutter row: [EV dial] [flash] | shutter | [opacity dial or spacer]
            shutterRow
                .padding(.bottom, 30)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    // MARK: - Shutter Row

    private var shutterRow: some View {
        ZStack {
            // Shutter button — center by default, leading edge in lefty mode
            shutterButton
                .frame(maxWidth: .infinity, alignment: camera.shutterOnLeft ? .leading : .center)
                .animation(.easeInOut(duration: 0.25), value: camera.shutterOnLeft)

            // Zoom toggle button — sits 72pt right of center in both modes
            // (in lefty mode it ends up to the right of the EV dial which is at center).
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    camera.showZoomSlider.toggle()
                    if camera.showZoomSlider {
                        camera.syncZoomState()
                    } else {
                        camera.volumeControlsBlend = false
                        camera.volumeControlsEV = false
                    }
                }
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 13))
                    .iconRotation(motion.iconAngle)
                    .foregroundStyle(camera.showZoomSlider ? .black : .white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(camera.showZoomSlider ? Color.yellow : Color.white.opacity(0.18))
                            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .offset(x: 72)

            // EV dial — leading edge by default; slides to center in lefty mode
            // (where the shutter used to be).
            let evIsVolumeTarget = camera.volumeControlsEV && camera.showZoomSlider
            ExposureDial(
                value: Binding(
                    get: { camera.exposureBias },
                    set: { camera.setExposureBias($0) }
                ),
                range: -3.0...3.0
            )
            .frame(width: 72, height: 72)
            .overlay(
                Circle()
                    .stroke(Color.yellow, lineWidth: evIsVolumeTarget ? 2 : 0)
                    .frame(width: 74, height: 74)
                    .animation(.easeInOut(duration: 0.15), value: evIsVolumeTarget)
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    guard camera.showZoomSlider else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        camera.volumeControlsEV.toggle()
                        if camera.volumeControlsEV { camera.volumeControlsBlend = false }
                    }
                }
            )
            .frame(maxWidth: .infinity, alignment: camera.shutterOnLeft ? .center : .leading)
            .animation(.easeInOut(duration: 0.25), value: camera.shutterOnLeft)

            // Flash button — sits 72pt left of center in both modes
            // (in lefty mode it ends up to the left of the EV dial which is at center).
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                camera.toggleFlash()
            } label: {
                Image(systemName: camera.flashMode == .off ? "bolt.slash.fill" : (camera.flashMode == .on ? "bolt.fill" : "bolt.badge.automatic"))
                    .font(.system(size: 13))
                    .iconRotation(motion.iconAngle)
                    .foregroundStyle(camera.flashMode == .on ? .black : (camera.flashMode == .auto ? .black : .white))
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(camera.flashMode != .off ? Color.yellow : Color.white.opacity(0.18))
                            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .offset(x: -72)

            // Right side: recording lock / timer / flip
            HStack {
                Spacer()
                if camera.isRecording {
                    if shutterIsHolding && !recordingLocked {
                        // Slide-to-lock track
                        HStack(spacing: 6) {
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.12))
                                    .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                                    .frame(width: 52, height: 26)
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 20, height: 20)
                                    .offset(x: 3 + min(lockDragOffset / 65.0 * 29, 29))
                                    .animation(.interactiveSpring(), value: lockDragOffset)
                            }
                            Image(systemName: "lock.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(lockDragOffset > 25 ? 1.0 : 0.4))
                                .animation(.easeOut(duration: 0.1), value: lockDragOffset)
                        }
                        .iconRotation(motion.iconAngle)
                        .frame(width: 72, height: 72)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    } else if recordingLocked {
                        // Locked — show lock icon + tap hint
                        VStack(spacing: 3) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                            Text("tap to stop")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .iconRotation(motion.iconAngle)
                        .frame(width: 72, height: 72)
                        .transition(.opacity)
                    } else {
                        // Timer
                        let totalSecs = Int(camera.recordingDuration)
                        let mins = totalSecs / 60
                        let secs = totalSecs % 60
                        VStack(spacing: 2) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                            Text(String(format: "%d:%02d", mins, secs))
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                        }
                        .iconRotation(motion.iconAngle)
                        .frame(width: 72, height: 72)
                    }
                } else if camera.isBursting {
                    VStack(spacing: 2) {
                        Text("\(camera.burstCount)")
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundStyle(.yellow)
                        Text("shots")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .iconRotation(motion.iconAngle)
                    .frame(width: 72, height: 72)
                } else if !cleanMode {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        withAnimation(.easeInOut(duration: 0.3)) {
                            camera.flipCamera()
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                            .font(.system(size: 26))
                            .iconRotation(motion.iconAngle)
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(
                                Circle()
                                    .fill(Color.black.opacity(0.45))
                                    .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var shutterButton: some View {
        ZStack {
            Circle()
                .stroke(
                    camera.isRecording ? Color.red.opacity(0.8) :
                    camera.burstMode   ? Color.yellow.opacity(0.5) :
                                         Color.white.opacity(0.5),
                    lineWidth: 3
                )
                .frame(width: 84, height: 84)
            RoundedRectangle(cornerRadius: camera.isRecording ? 8 : 35)
                .fill(
                    camera.isRecording  ? Color.red :
                    camera.isBursting   ? Color.yellow :
                    camera.isCapturing  ? Color.gray :
                                          Color.white
                )
                .frame(
                    width:  camera.isRecording ? 28 : 70,
                    height: camera.isRecording ? 28 : 70
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: camera.isRecording)
                .animation(.easeInOut(duration: 0.12), value: camera.isCapturing)
            if camera.isCapturing && !camera.isBursting && !camera.isRecording {
                ProgressView().tint(.white)
            }
            if camera.doubleExposureEnabled && camera.firstExposurePreview != nil && !camera.isRecording {
                Text("2nd")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
            }
            if camera.burstMode && !camera.isBursting && !camera.isRecording {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.black.opacity(0.4))
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // Track rightward drag during recording to arm lock
                    if camera.isRecording && !recordingLocked {
                        lockDragOffset = max(0, value.translation.width)
                        if lockDragOffset >= 65 && !recordingPendingLock {
                            recordingPendingLock = true
                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        }
                        return
                    }
                    if recordingLocked { return }
                    guard shutterPressTimer == nil, !shutterIsHolding else { return }
                    shutterPressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                        shutterIsHolding = true
                        shutterPressTimer = nil
                        if camera.burstMode {
                            camera.startBurst()
                        } else {
                            camera.startRecording()
                        }
                    }
                }
                .onEnded { _ in
                    lockDragOffset = 0
                    // Finger lifted after dragging to lock threshold — commit lock, keep recording
                    if recordingPendingLock {
                        recordingLocked = true
                        recordingPendingLock = false
                        shutterIsHolding = false
                        return
                    }
                    // Tap while locked → stop recording
                    if recordingLocked {
                        camera.stopRecording()
                        recordingLocked = false
                        shutterIsHolding = false
                        shutterPressTimer?.invalidate()
                        shutterPressTimer = nil
                        return
                    }
                    if let t = shutterPressTimer {
                        t.invalidate()
                        shutterPressTimer = nil
                        shutterIsHolding = false
                        guard !camera.isCapturing else { return }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        if camera.doubleExposureEnabled && camera.firstExposurePreview == nil {
                            camera.captureDoubleExposureFirst()
                        } else {
                            camera.capturePhoto()
                        }
                    } else {
                        shutterIsHolding = false
                        if camera.burstMode {
                            camera.stopBurst()
                        } else if camera.isRecording {
                            camera.stopRecording()
                        }
                    }
                }
        )
        .disabled(camera.isCapturing && !camera.burstMode && !camera.isRecording)
    }


    // MARK: - Shortcuts / Action Button

    /// Apply an "Open cam cam" intent: pick the sim, then show/hide Sony mode.
    private func handleLaunchRequest() {
        guard let req = router.request else { return }
        router.request = nil
        if let id = req.customID, let sim = customSimStore.simulations.first(where: { $0.id == id }) {
            customSimStore.activeCustomSimID = sim.id
            camera.activeCustomSim = sim
            camera.selectedSim = .none
        } else if let sim = req.sim {
            camera.selectedSim = sim
            customSimStore.activeCustomSimID = nil
            camera.activeCustomSim = nil
        }
        switch req.mode {
        case .sony?: showSonyView = true
        case .iphone?: showSonyView = false
        case nil: break
        }
    }

    // MARK: - Sim chips (strip + favourites) with long-press actions

    @ViewBuilder
    private func builtInChip(_ sim: FilmSimulation, starred: Bool) -> some View {
        let isSelected = camera.selectedSim == sim && customSimStore.activeCustomSimID == nil
        Button {
            camera.selectedSim = sim
            customSimStore.activeCustomSimID = nil
            camera.activeCustomSim = nil
        } label: {
            HStack(spacing: 4) {
                if starred { Image(systemName: "star.fill").font(.system(size: 8)) }
                Text(sim.label).font(.system(size: 13, weight: isSelected ? .bold : .regular))
            }
            .foregroundStyle(isSelected ? .black : .white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(isSelected ? Color.yellow : Color.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .contextMenu {
            favoriteButton(FavoritesStore.key(sim))
            if sim != .none {
                Button { exportLUT(sim: sim, custom: nil, name: sim.label) } label: {
                    Label("Export as LUT (.cube)", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    @ViewBuilder
    private func customChip(_ sim: CustomSimulation, starred: Bool) -> some View {
        let isSelected = customSimStore.activeCustomSimID == sim.id
        let isLUT = sim.lutFilename != nil
        let tint: Color = isLUT ? .orange : .cyan
        Button {
            customSimStore.activeCustomSimID = sim.id
            camera.activeCustomSim = sim
            camera.selectedSim = .none
        } label: {
            HStack(spacing: 4) {
                Image(systemName: starred ? "star.fill" : (isLUT ? "cube.fill" : "paintbrush.fill"))
                    .font(.system(size: 9))
                Text(sim.name).font(.system(size: 13, weight: isSelected ? .bold : .regular))
            }
            .foregroundStyle(isSelected ? .black : tint)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(isSelected ? tint : tint.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .contextMenu {
            favoriteButton(FavoritesStore.key(sim))
            if let file = sim.lutFilename {
                Button { shareItem = ShareItem(url: LUTManager.shared.directory.appendingPathComponent(file)) } label: {
                    Label("Share .cube", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    LUTManager.shared.deleteLUT(filename: file)
                    let key = FavoritesStore.key(sim)
                    if favorites.isFavorite(key) { favorites.toggle(key) }
                    customSimStore.delete(sim)
                    if customSimStore.activeCustomSimID == sim.id { camera.activeCustomSim = nil }
                } label: { Label("Delete LUT", systemImage: "trash") }
            } else {
                Button { exportLUT(sim: .none, custom: sim, name: sim.name) } label: {
                    Label("Export as LUT (.cube)", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    @ViewBuilder
    private func favoriteButton(_ key: String) -> some View {
        let fav = favorites.isFavorite(key)
        Button {
            favorites.toggle(key)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Label(fav ? "Unpin from Favorites" : "Pin to Favorites", systemImage: fav ? "star.slash" : "star")
        }
    }

    /// Bake a sim's colour look into a 33³ .cube and offer it via the share
    /// sheet (AirDrop to the Mac → Lightroom/Resolve). Colour only: grain and
    /// spatial effects can't live in a LUT.
    private func exportLUT(sim: FilmSimulation, custom: CustomSimulation?, name: String) {
        guard !exportingLUT else { return }
        exportingLUT = true
        var recipe = ShotRecipe()
        recipe.sim = sim
        recipe.custom = custom
        recipe.digiCamQuality = camera.digiCamQuality
        nonisolated(unsafe) let cam = camera
        Task.detached(priority: .userInitiated) {
            let text = LUTExporter.cube(title: "cam cam - \(name)") {
                cam.renderLook($0, recipe: recipe, flatten: false)
            }
            let url = text.flatMap { try? LUTExporter.write($0, name: name) }
            await MainActor.run {
                exportingLUT = false
                if let url { shareItem = ShareItem(url: url) }
                else { camera.saveErrorMessage = "LUT export failed" }
            }
        }
    }

}

// MARK: - Top Pill

private struct TopPill: View {
    var icon: String? = nil
    var text: String
    var showChevron: Bool = false
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
            }
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(isActive ? .black : .white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(isActive ? Color.yellow : Color.black.opacity(0.5))
                .overlay(Capsule().stroke(isActive ? Color.yellow : Color.white.opacity(0.25), lineWidth: 1))
        )
        .animation(.easeInOut(duration: 0.18), value: isActive)
    }
}
