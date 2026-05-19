//
//  SonyView.swift
//  cam cam
//
//  Sony camera connection — looks and feels like the phone camera view.
//  When connected the live viewfinder fills the screen with the same
//  bottom controls as CameraView, but the zoom-preset row is replaced by
//  live Sony camera data (SS / ISO / aperture / EV comp).
//

import SwiftUI
import Photos

struct SonyView: View {
    @State private var sony = SonyConnector()
    @Bindable var camera: CameraManager

    @State private var showSavedToast: Bool = false
    @State private var recentPhotos: [UIImage] = []
    /// Wraps a UIImage so `.sheet(item:)` can drive presentation atomically —
    /// nil means no sheet, non-nil means show the wrapped image.
    private struct PhotoToView: Identifiable {
        let id = UUID()
        let image: UIImage
    }
    @State private var selectedPhoto: PhotoToView? = nil

    // View menu / display
    @State private var showViewMenu = false
    @State private var cleanMode = false
    @State private var showGrid = false
    /// When true, the SonyView UI ignores device tilt: icons stay put and the
    /// live view doesn't rotate. Persisted across app launches.
    @AppStorage("cc_sonyRotationLocked") private var rotationLocked: Bool = false
    /// When true, the diagnostic log overlay is visible. Useful since the
    /// phone is on the camera's WiFi and not reachable from Xcode.
    @State private var showDebugLog = false

    /// Identifies which setting picker (if any) is open. nil = none.
    enum SettingPicker: Identifiable {
        case shutterSpeed, iso, aperture, ev
        var id: Int { hashValue }
        var title: String {
            switch self {
            case .shutterSpeed: return "Shutter Speed"
            case .iso:          return "ISO"
            case .aperture:     return "Aperture"
            case .ev:           return "Exposure Comp."
            }
        }
    }
    @State private var openPicker: SettingPicker? = nil
    @State private var sectionDisplayExpanded = true
    @State private var sectionFilmEffectsExpanded = true
    @State private var sectionShootingExpanded = false

    // Custom film simulations (loaded from same UserDefaults as CameraView)
    @State private var customSimStore = CustomSimStore()

    // Icon rotation (same MotionManager used by CameraView)
    @State private var motion = MotionManager()

    // ── environment for dismissing the fullScreenCover
    @Environment(\.dismiss) private var dismiss

    /// True when iOS has rotated the interface to landscape (has natural
    /// hysteresis — flips only when iOS commits to a rotation, not on every
    /// tiny tilt the way motion.isLandscape does).
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isInterfaceLandscape: Bool { verticalSizeClass == .compact }

    /// motion.iconAngle when rotation is LOCKED (because iOS keeps the UI in
    /// portrait, we manually rotate icons/live view to follow gravity); 0 when
    /// rotation is UNLOCKED (because iOS auto-rotates the whole UI, so manual
    /// rotation would double up).
    private var effectiveAngle: Double {
        rotationLocked ? motion.iconAngle : 0
    }

    /// Push our desired orientation mask to AppDelegate and ask iOS to apply
    /// it. Called when the view appears and whenever the lock toggles.
    private func applyOrientationLock() {
        let mask: UIInterfaceOrientationMask = rotationLocked ? .portrait : .all
        AppDelegate.orientationLock = mask
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if case .connected = sony.state {
                connectedView
            } else {
                setupView
            }

            // "Saved" toast
            if showSavedToast {
                VStack {
                    Spacer()
                    Text("Saved to Photos")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.green.opacity(0.85), in: Capsule())
                        .padding(.bottom, 60)
                }
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .ignoresSafeArea()
        .onAppear {
            motion.startUpdates()
            customSimStore.load()
            applyOrientationLock()
            sony.applySimClosure = { [weak camera] image, sim, custom in
                guard let camera else { return image }
                return camera.applySimAndGrainDirect(to: image, sim: sim, custom: custom)
            }
            sony.onPhotoProcessed = { processed in
                // Saving is handled inside SonyConnector.downloadAndProcess (with error logging).
                // This closure is UI-only: show the toast and update the thumbnail strip.
                withAnimation { showSavedToast = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { showSavedToast = false }
                }
                recentPhotos.insert(processed, at: 0)
                if recentPhotos.count > 12 { recentPhotos = Array(recentPhotos.prefix(12)) }
            }
        }
        .onDisappear {
            motion.stopUpdates()
            // Restore the app's default portrait lock when leaving SonyView so
            // CameraView (which assumes portrait) keeps working correctly.
            AppDelegate.orientationLock = .portrait
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            }
        }
        .onChange(of: rotationLocked) { _, _ in
            applyOrientationLock()
        }
        .sheet(item: $selectedPhoto) { wrapped in
            photoViewer(wrapped.image)
        }
        .sheet(item: $openPicker) { picker in
            settingPickerSheet(picker)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: camera.selectedSim) { _, sim in sony.selectedSim = sim }
        .onChange(of: camera.activeCustomSim) { _, custom in sony.activeCustomSim = custom }
    }

    // MARK: - Connected View (camera-style fullscreen)

    private var connectedView: some View {
        // CameraView pattern: outer GeometryReader gives us a known full-screen
        // frame; each visual layer applies .ignoresSafeArea() individually so it
        // extends edge-to-edge, while the controls VStack inside the ZStack does
        // NOT ignore safe area — meaning the top bar clears the notch/dynamic
        // island and the bottom strip stays above the home indicator in BOTH
        // portrait and landscape automatically.
        GeometryReader { geo in
            ZStack {
                // Black background fills behind everything
                Color.black.ignoresSafeArea()

                // Live viewfinder — Sony always streams a landscape (16:9) JPEG.
                // scaledToFit shows the WHOLE frame (no crop):
                //   • Portrait phone → landscape strip centered on screen
                //   • Landscape phone → fills screen edge-to-edge
                // rotationEffect spins the image to follow device orientation
                // so the camera's "up" stays at the top of the phone.
                if let frame = sony.liveViewImage {
                    // Dimension swap when phone is sideways: size the image's
                    // pre-rotation frame as H×W so that after the 90° rotation
                    // it occupies the screen's "landscape" rectangle. This makes
                    // a 16:9 image fill nearly the whole screen in landscape
                    // (instead of becoming a tiny strip), while staying as a
                    // strip in portrait — no crop in either case.
                    let isSideways = Int(effectiveAngle.rounded()) % 180 != 0
                    Image(uiImage: frame)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width:  isSideways ? geo.size.height : geo.size.width,
                            height: isSideways ? geo.size.width  : geo.size.height
                        )
                        .rotationEffect(.degrees(effectiveAngle))
                        .frame(width: geo.size.width, height: geo.size.height)
                        .ignoresSafeArea()
                } else {
                    // Loading state — fills full size so ZStack stays full-screen
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(.white.opacity(0.4))
                            .scaleEffect(0.9)
                        if !sony.liveViewStatus.isEmpty {
                            Text(sony.liveViewStatus)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        let recentLog = Array(sony.diagnosticLog.suffix(12))
                        if !recentLog.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(recentLog) { entry in
                                    Text(entry.text)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(entry.text.hasPrefix("❌") ? Color.red.opacity(0.7)
                                                       : entry.text.hasPrefix("⚠️") ? Color.orange.opacity(0.7)
                                                       : Color.white.opacity(0.3))
                                        .lineLimit(2)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, 6)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }

                // Grid overlay (full-bleed)
                if showGrid {
                    GridOverlay()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                // Tap-outside dismisses dropdown
                if showViewMenu {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.spring(duration: 0.25)) { showViewMenu = false } }
                }

                // On-device debug log overlay (toggle with long-press on info row)
                if showDebugLog {
                    debugLogOverlay
                        .transition(.opacity)
                }

                // Controls — INSIDE the ZStack so they respect the safe area
                // (no .ignoresSafeArea on this VStack or its parent).  In
                // landscape, SwiftUI auto-insets these away from the notch.
                VStack(spacing: 0) {
                    connectedTopBar
                        // Use the iOS interface orientation (not raw tilt) so
                        // the padding doesn't jitter when the user composes a
                        // slightly-tilted shot. Portrait needs ~80 pt to clear
                        // the dynamic island; landscape only needs ~16 pt.
                        .padding(.top, isInterfaceLandscape ? 16 : 80)

                    if showViewMenu {
                        viewMenuDropdown
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Spacer()

                    if !cleanMode {
                        VStack(spacing: 14) {
                            cameraInfoRow
                            filmSimRow
                            if !sony.shutterStatus.isEmpty {
                                Text(sony.shutterStatus)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(
                                        sony.shutterStatus.hasPrefix("❌")
                                            ? Color.red.opacity(0.85)
                                            : sony.shutterStatus.hasPrefix("✅")
                                                ? Color.green.opacity(0.85)
                                                : Color.white.opacity(0.55)
                                    )
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                                    .transition(.opacity)
                            }
                            sonyShutterRow
                                .padding(.bottom, 8)
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 16)
                        .background(
                            LinearGradient(
                                colors: [Color.black.opacity(0), Color.black.opacity(0.65)],
                                startPoint: .top, endPoint: .bottom
                            )
                            .allowsHitTesting(false)
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Connected top bar

    private var connectedTopBar: some View {
        HStack(spacing: 8) {
            // Disconnect button
            Button {
                sony.disconnect()
                recentPhotos.removeAll()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.7))
                    .iconRotation(effectiveAngle)
                    .padding(12)
            }
            .buttonStyle(.plain)

            Spacer()

            // Model name pill
            if case .connected(let model) = sony.state {
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text(model)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.5)))
            }

            // Active sim badge
            let simLabel: String = {
                if let c = camera.activeCustomSim { return c.name }
                return camera.selectedSim == .none ? "" : camera.selectedSim.label
            }()
            if !simLabel.isEmpty {
                Text(simLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Capsule().fill(Color.yellow))
            }

            // Clean mode toggle (eye)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { cleanMode.toggle() }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: cleanMode ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(cleanMode ? .black : .white)
                    .iconRotation(effectiveAngle)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Capsule()
                        .fill(cleanMode ? Color.white : Color.black.opacity(0.4))
                        .overlay(Capsule().stroke(cleanMode ? Color.clear : Color.white.opacity(0.3), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)

            // Rotation lock — freezes UI orientation regardless of how the
            // phone is held. When ON, effectiveAngle returns 0 so icons and
            // the live view stop spinning.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { rotationLocked.toggle() }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: rotationLocked ? "lock.rotation" : "lock.rotation.open")
                    .font(.system(size: 12))
                    .foregroundStyle(rotationLocked ? .black : .white)
                    .iconRotation(effectiveAngle)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Capsule()
                        .fill(rotationLocked ? Color.yellow : Color.black.opacity(0.4))
                        .overlay(Capsule().stroke(rotationLocked ? Color.clear : Color.white.opacity(0.3), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)

            // View menu chevron
            Button {
                withAnimation(.spring(duration: 0.25)) { showViewMenu.toggle() }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12))
                        .iconRotation(effectiveAngle)
                    Image(systemName: showViewMenu ? "chevron.up" : "chevron.down").font(.system(size: 9))
                        .iconRotation(effectiveAngle)
                }
                .foregroundStyle(showViewMenu ? .yellow : .white)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Capsule()
                    .fill(showViewMenu ? Color.yellow.opacity(0.2) : Color.black.opacity(0.4))
                    .overlay(Capsule().stroke(showViewMenu ? .yellow : Color.white.opacity(0.3), lineWidth: 1))
                )
            }
            .buttonStyle(.plain)

            // Auto-save toggle
            Button {
                sony.autoSave.toggle()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: sony.autoSave ? "square.and.arrow.down.fill" : "square.and.arrow.down")
                    .font(.system(size: 13))
                    .foregroundStyle(sony.autoSave ? .black : .white)
                    .iconRotation(effectiveAngle)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(sony.autoSave ? Color.yellow : Color.white.opacity(0.18))
                        .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1)))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
        }
    }

    // MARK: - View menu dropdown

    private var viewMenuDropdown: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {

                // DISPLAY
                VStack(alignment: .leading, spacing: 8) {
                    sonyMenuSectionHeader("DISPLAY", isExpanded: $sectionDisplayExpanded)
                    if sectionDisplayExpanded {
                        HStack(spacing: 10) {
                            sonyMenuToggle(icon: "grid",                 title: "Grid",  isOn: $showGrid)
                            sonyMenuToggle(icon: "eye.slash",            title: "Clean", isOn: $cleanMode)
                            sonyMenuToggle(icon: "hand.point.left.fill", title: "Lefty", isOn: $camera.shutterOnLeft)
                        }
                        .padding(.bottom, 6)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                Divider().background(Color.white.opacity(0.2))

                // FILM EFFECTS — all active (applied to every Sony shot via applySimAndGrainDirect)
                VStack(alignment: .leading, spacing: 8) {
                    sonyMenuSectionHeader("FILM EFFECTS", isExpanded: $sectionFilmEffectsExpanded)
                    if sectionFilmEffectsExpanded {
                        HStack(spacing: 8) {
                            sonyMenuToggle(icon: "drop.fill",         title: "Halation",  isOn: $camera.halationEnabled)
                            sonyMenuToggle(icon: "paintpalette",      title: "Crosstalk", isOn: $camera.crosstalkEnabled)
                            sonyMenuToggle(icon: "waveform",          title: "Rolloff",   isOn: $camera.rolloffEnabled)
                        }
                        HStack(spacing: 8) {
                            sonyMenuToggle(icon: "aqi.medium",        title: "Flares",       isOn: $camera.anamorphicFlareEnabled)
                            sonyMenuToggle(icon: "light.beacon.max",  title: "Light Leaks",  isOn: $camera.lightArtifactsEnabled)
                            sonyMenuToggle(icon: "line.diagonal",     title: "Scratches",    isOn: $camera.filmScratchesEnabled)
                        }
                        HStack(spacing: 8) {
                            sonyMenuToggle(icon: "dice",              title: "Randomize",    isOn: $camera.filmRandomizationEnabled)
                        }
                        // Grain
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Button {
                                    camera.grainEnabled.toggle()
                                    if !camera.grainEnabled { camera.contextAwareGrainEnabled = false }
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: camera.grainEnabled
                                              ? "circle.grid.3x3.fill" : "circle.grid.3x3")
                                            .font(.system(size: 12))
                                        Text("Grain")
                                            .font(.system(size: 12, weight: camera.grainEnabled ? .bold : .regular))
                                    }
                                    .foregroundStyle(camera.grainEnabled ? .yellow : .white)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(camera.grainEnabled
                                        ? Color.yellow.opacity(0.2) : Color.white.opacity(0.1)))
                                }
                                .buttonStyle(.plain)

                                if camera.grainEnabled {
                                    Button {
                                        camera.contextAwareGrainEnabled.toggle()
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: camera.contextAwareGrainEnabled
                                                  ? "waveform.badge.magnifyingglass" : "waveform")
                                                .font(.system(size: 12))
                                            Text("Smart")
                                                .font(.system(size: 12, weight: camera.contextAwareGrainEnabled ? .bold : .regular))
                                        }
                                        .foregroundStyle(camera.contextAwareGrainEnabled ? .yellow : .white)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Capsule().fill(camera.contextAwareGrainEnabled
                                            ? Color.yellow.opacity(0.2) : Color.white.opacity(0.1)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            if camera.grainEnabled {
                                HStack(spacing: 8) {
                                    Image(systemName: "circle.grid.3x3")
                                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                                    Slider(value: $camera.grainAmount, in: 0...0.5).tint(.yellow)
                                    Image(systemName: "circle.grid.3x3.fill")
                                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        // Push / Pull
                        VStack(alignment: .leading, spacing: 6) {
                            let ppLabel: String = {
                                if camera.pushPullAmount == 0 { return "Push / Pull" }
                                return camera.pushPullAmount > 0
                                    ? "Push +\(String(format: "%.0f", camera.pushPullAmount))"
                                    : "Pull \(String(format: "%.0f", camera.pushPullAmount))"
                            }()
                            Button {
                                camera.pushPullEnabled.toggle()
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.arrow.down.circle").font(.system(size: 12))
                                    Text(ppLabel).font(.system(size: 12, weight: camera.pushPullEnabled ? .bold : .regular))
                                }
                                .foregroundStyle(camera.pushPullEnabled ? .yellow : .white)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(camera.pushPullEnabled ? Color.yellow.opacity(0.2) : Color.white.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                            if camera.pushPullEnabled {
                                HStack(spacing: 8) {
                                    Text("Pull").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                                    Slider(value: $camera.pushPullAmount, in: -2...3, step: 1).tint(.yellow)
                                    Text("Push").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .padding(.bottom, 6)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                Divider().background(Color.white.opacity(0.2))

                // SHOOTING — phone-camera features, greyed out
                VStack(alignment: .leading, spacing: 8) {
                    sonyMenuSectionHeader("SHOOTING (Phone only)", isExpanded: $sectionShootingExpanded)
                    if sectionShootingExpanded {
                        HStack(spacing: 10) {
                            sonyMenuToggle(icon: "bolt.circle",          title: "Burst",    isOn: .constant(false))
                            sonyMenuToggle(icon: "person.fill",          title: "Portrait", isOn: .constant(false))
                            sonyMenuToggle(icon: "leaf.fill",            title: "Macro",    isOn: .constant(false))
                        }
                        HStack(spacing: 10) {
                            sonyMenuToggle(icon: "rectangle.stack",      title: "1-Lens",   isOn: .constant(false))
                        }
                        .padding(.bottom, 6)
                    }
                }
                .opacity(0.35)
                .allowsHitTesting(false)

                Divider().background(Color.white.opacity(0.2))

                // Done — closes the Sony view entirely
                Button {
                    withAnimation(.spring(duration: 0.25)) { showViewMenu = false }
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle").font(.system(size: 13))
                        Text("Done").font(.system(size: 13, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: 380)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.88))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    // MARK: - Menu helpers (mirrors CameraView style)

    private func sonyMenuSectionHeader(_ title: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 180 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded.wrappedValue)
            }
            .padding(.top, 4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sonyMenuToggle(icon: String, title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(.system(size: 12, weight: isOn.wrappedValue ? .bold : .regular))
            }
            .foregroundStyle(isOn.wrappedValue ? .yellow : .white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(isOn.wrappedValue ? Color.yellow.opacity(0.2) : Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Camera info row (replaces zoom presets)

    private var cameraInfoRow: some View {
        HStack(spacing: 0) {
            Spacer()
            // Each cell is tappable — opens a picker for that setting.
            Button { openPicker = .shutterSpeed } label: {
                cameraInfoCell(
                    top: sony.sonyShutterSpeed.isEmpty ? "—" : sony.sonyShutterSpeed,
                    bottom: "SS"
                )
                .iconRotation(effectiveAngle)
            }.buttonStyle(.plain)
            Spacer()
            Button { openPicker = .iso } label: {
                cameraInfoCell(
                    top: sony.sonyISO.isEmpty ? "—" : sony.sonyISO,
                    bottom: "ISO"
                )
                .iconRotation(effectiveAngle)
            }.buttonStyle(.plain)
            Spacer()
            Button { openPicker = .aperture } label: {
                cameraInfoCell(
                    top: sony.sonyAperture.isEmpty ? "—" : "f/\(sony.sonyAperture)",
                    bottom: "APT"
                )
                .iconRotation(effectiveAngle)
            }.buttonStyle(.plain)
            Spacer()
            Button { openPicker = .ev } label: {
                cameraInfoCell(
                    top: sony.sonyEVComp == 0
                        ? "±0" : String(format: "%+.1f", sony.sonyEVComp),
                    bottom: "EV"
                )
                .iconRotation(effectiveAngle)
            }.buttonStyle(.plain)
            Spacer()
            cameraInfoCell(
                top: "\(sony.processedCount)",
                bottom: "SHOTS"
            )
            .iconRotation(effectiveAngle)
            // Long-press the SHOTS cell to toggle the debug log overlay.
            // Other cells (SS/ISO/APT/EV) are used for adjustment now.
            .onLongPressGesture(minimumDuration: 0.5) {
                withAnimation { showDebugLog.toggle() }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            Spacer()
        }
    }

    private func cameraInfoCell(top: String, bottom: String) -> some View {
        VStack(spacing: 2) {
            Text(top)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(bottom)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(width: 58, height: 54)
        .background(
            Circle()
                .fill(Color.black.opacity(0.5))
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        )
    }

    // MARK: - Film sim strip

    private var filmSimRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // Built-in sims
                ForEach(FilmSimulation.allCases) { sim in
                    let isActive = camera.selectedSim == sim && camera.activeCustomSim == nil
                    Button {
                        camera.selectedSim = sim
                        camera.activeCustomSim = nil
                        customSimStore.activeCustomSimID = nil
                        sony.selectedSim = sim
                        sony.activeCustomSim = nil
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(sim.label)
                            .font(.system(size: 13, weight: isActive ? .bold : .regular))
                            .foregroundStyle(isActive ? .black : .white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(isActive ? Color.yellow : Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                }

                // Divider before custom sims
                if !customSimStore.simulations.isEmpty {
                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 1, height: 24)
                }

                // Custom sims
                ForEach(customSimStore.simulations) { sim in
                    let isActive = customSimStore.activeCustomSimID == sim.id
                    Button {
                        customSimStore.activeCustomSimID = sim.id
                        camera.activeCustomSim = sim
                        camera.selectedSim = .none
                        sony.activeCustomSim = sim
                        sony.selectedSim = .none
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "paintbrush.fill")
                                .font(.system(size: 9))
                            Text(sim.name)
                                .font(.system(size: 13, weight: isActive ? .bold : .regular))
                        }
                        .foregroundStyle(isActive ? .black : .cyan)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(isActive ? Color.cyan : Color.cyan.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Shutter row

    // MARK: - Setting Picker Sheet

    @ViewBuilder
    private func settingPickerSheet(_ picker: SettingPicker) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(picker.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button { openPicker = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // EV uses a +/- stepper; others use a scrollable list of candidates.
            if picker == .ev {
                evPickerContent
            } else {
                candidateList(for: picker)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    private func candidateList(for picker: SettingPicker) -> some View {
        let (current, candidates, setter): (String, [String], (String) -> Void) = {
            switch picker {
            case .shutterSpeed:
                return (sony.sonyShutterSpeed, sony.shutterSpeedCandidates, sony.setShutterSpeed)
            case .iso:
                return (sony.sonyISO, sony.isoCandidates, sony.setIso)
            case .aperture:
                return (sony.sonyAperture, sony.apertureCandidates, sony.setAperture)
            case .ev:
                return ("", [], { _ in })  // handled separately
            }
        }()
        return ScrollView {
            LazyVStack(spacing: 0) {
                if candidates.isEmpty {
                    Text("No candidates reported by camera.\nThe value may be auto-controlled in this mode.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(40)
                } else {
                    ForEach(candidates, id: \.self) { val in
                        let isActive = val == current
                            || val.replacingOccurrences(of: "ISO ", with: "") == current
                        Button {
                            setter(val)
                            openPicker = nil
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            HStack {
                                Text(val)
                                    .font(.system(size: 16, weight: isActive ? .bold : .regular,
                                                  design: .monospaced))
                                    .foregroundStyle(isActive ? .yellow : .white)
                                Spacer()
                                if isActive {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.yellow)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .background(isActive ? Color.yellow.opacity(0.12) : Color.clear)
                        }
                        .buttonStyle(.plain)
                        Divider().background(Color.white.opacity(0.08))
                    }
                }
            }
        }
    }

    private var evPickerContent: some View {
        VStack(spacing: 24) {
            // Big readout
            Text(sony.sonyEVComp == 0 ? "±0.0" : String(format: "%+.1f EV", sony.sonyEVComp))
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .foregroundStyle(.yellow)
                .padding(.top, 12)

            HStack(spacing: 16) {
                Button {
                    let next = max(sony.evMin, sony.evRawValue - max(1, sony.evStep))
                    sony.setExposureComp(next)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .disabled(sony.evRawValue <= sony.evMin)

                Button {
                    sony.setExposureComp(0)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text("0")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 56, height: 56)
                        .background(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1.5))
                }
                .buttonStyle(.plain)

                Button {
                    let next = min(sony.evMax, sony.evRawValue + max(1, sony.evStep))
                    sony.setExposureComp(next)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .disabled(sony.evRawValue >= sony.evMax)
            }
            Text("Range: \(Float(sony.evMin)/3.0, specifier: "%+.1f") to \(Float(sony.evMax)/3.0, specifier: "%+.1f")")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
    }

    // MARK: - Debug log overlay

    /// Floating, scrollable view of sony.diagnosticLog. Toggled by long-pressing
    /// the camera info row. Visible on-device so debugging works even when the
    /// phone is on the camera's WiFi (no Xcode console).
    private var debugLogOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Text("DEBUG LOG (\(sony.diagnosticLog.count))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.yellow)
                Spacer()
                Button {
                    sony.diagnosticLog.removeAll()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text("CLEAR")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                Button {
                    withAnimation { showDebugLog = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.black.opacity(0.85))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(sony.diagnosticLog) { entry in
                            Text(entry.text)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(
                                    entry.text.hasPrefix("❌") ? Color.red.opacity(0.9)
                                  : entry.text.hasPrefix("⚠️") ? Color.orange.opacity(0.9)
                                  : entry.text.hasPrefix("✅") || entry.text.hasPrefix("💾") ? Color.green.opacity(0.9)
                                  : Color.white.opacity(0.75)
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 1)
                                .id(entry.id)
                        }
                    }
                }
                .onChange(of: sony.diagnosticLog.count) { _, _ in
                    if let last = sony.diagnosticLog.last?.id {
                        withAnimation(.linear(duration: 0.15)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            .background(Color.black.opacity(0.78))
        }
        .frame(maxWidth: .infinity, maxHeight: 360)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.5), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, isInterfaceLandscape ? 56 : 140)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var sonyShutterRow: some View {
        // Use iOS interface orientation, NOT raw motion.isLandscape — the
        // motion flag flips on small tilts (any time |gx| > |gy|, ~45°),
        // which was causing the shutter and thumbnail to swap places when
        // the user composed slightly-tilted shots. verticalSizeClass only
        // changes when iOS commits to a true landscape rotation.
        let isLandscapeMode = isInterfaceLandscape

        // Compute alignments
        let shutterAlignment: Alignment = {
            if isLandscapeMode { return .trailing }
            return camera.shutterOnLeft ? .leading : .center
        }()
        let evAlignment: Alignment = {
            if isLandscapeMode { return .center }
            return camera.shutterOnLeft ? .center : .leading
        }()
        let thumbAlignment: Alignment = isLandscapeMode ? .leading : .trailing

        return ZStack {
            sonyShutterButton
                .frame(maxWidth: .infinity, alignment: shutterAlignment)
                .padding(.leading, shutterAlignment == .leading ? 8 : 0)
                .padding(.trailing, shutterAlignment == .trailing ? 8 : 0)
                .animation(.easeInOut(duration: 0.25), value: shutterAlignment)

            ExposureMeterBar(evValue: sony.sonyEVComp, bias: 0)
                .frame(width: 64, height: 64)
                .frame(maxWidth: .infinity, alignment: evAlignment)
                .padding(.leading, evAlignment == .leading ? 8 : 0)
                .animation(.easeInOut(duration: 0.25), value: evAlignment)

            // Recent photos thumbnail / placeholder
            Group {
                if let last = recentPhotos.first {
                    Image(uiImage: last)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.3), lineWidth: 1))
                        .onTapGesture {
                            selectedPhoto = PhotoToView(image: last)
                        }
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 1))
                        .frame(width: 54, height: 54)
                }
            }
            .iconRotation(effectiveAngle)
            .frame(maxWidth: .infinity, alignment: thumbAlignment)
            .padding(.leading, thumbAlignment == .leading ? 12 : 0)
            .padding(.trailing, thumbAlignment == .trailing ? 12 : 0)
            .animation(.easeInOut(duration: 0.25), value: thumbAlignment)
        }
        .frame(height: 84)
    }

    private var sonyShutterButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            sony.triggerShutter()
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.5), lineWidth: 3)
                    .frame(width: 84, height: 84)
                Circle()
                    .fill(Color.white)
                    .frame(width: 70, height: 70)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Setup view (not connected)

    private var setupView: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                    connectionSection
                    instructionsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.on.rectangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sony Camera")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Text("Camera Remote API")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(statusColor.opacity(0.4), lineWidth: 4).scaleEffect(1.4))
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }

    private var statusColor: Color {
        switch sony.state {
        case .connected:    return .green
        case .searching:    return .yellow
        case .error:        return .red
        case .disconnected: return .gray
        }
    }

    // MARK: - Connection section

    private var connectionSection: some View {
        VStack(spacing: 14) {
            // Status card
            VStack(spacing: 8) {
                switch sony.state {
                case .disconnected:
                    Label("Not connected", systemImage: "wifi.slash")
                        .foregroundStyle(.white.opacity(0.6))
                case .searching:
                    VStack(spacing: 8) {
                        HStack(spacing: 10) {
                            ProgressView().tint(.yellow)
                            Text("Searching for camera…")
                                .foregroundStyle(.yellow)
                        }
                        if !sony.diagnosticLog.isEmpty {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(sony.diagnosticLog) { entry in
                                            Text(entry.text)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.white.opacity(0.5))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .id(entry.id)
                                        }
                                    }
                                }
                                .frame(maxHeight: 90)
                                .onChange(of: sony.diagnosticLog.count) { _, _ in
                                    if let lastID = sony.diagnosticLog.last?.id {
                                        withAnimation(.linear(duration: 0.15)) {
                                            proxy.scrollTo(lastID, anchor: .bottom)
                                        }
                                    }
                                }
                            }
                        }
                    }
                case .connected(let model):
                    Label(model, systemImage: "camera.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 15, weight: .semibold))
                case .error(let msg):
                    VStack(spacing: 10) {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 13))
                        if !sony.diagnosticLog.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(sony.diagnosticLog.suffix(6))) { entry in
                                    Text(entry.text)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.45))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14).padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(statusColor.opacity(0.3), lineWidth: 1))
            )

            // Manual IP field
            if case .connected = sony.state { } else {
                HStack(spacing: 8) {
                    Image(systemName: "network")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
                    TextField("Camera IP (e.g. http://192.168.122.1:10000)", text: $sony.manualIP)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
            }

            // Connect / Cancel button
            if case .searching = sony.state {
                Button { sony.disconnect() } label: {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    sony.selectedSim = camera.selectedSim
                    sony.activeCustomSim = camera.activeCustomSim
                    sony.connect()
                } label: {
                    Label("Connect to Camera", systemImage: "wifi")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.yellow))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Instructions

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("HOW TO CONNECT")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
                .padding(.bottom, 12)
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(idx + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.yellow.opacity(0.85)))
                    Text(step)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, idx < steps.count - 1 ? 14 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }

    private let steps = [
        "On your Sony camera: Menu → Network → Ctrl w/ Smartphone → Connection → Connect.",
        "On your iPhone: Settings → WiFi → connect to the camera's network (e.g. DIRECT-xxxx:ILCE-7RM3).",
        "Allow Local Network access if iOS asks — or enable it in Settings → Privacy → Local Network.",
        "Come back here and tap Connect. The app searches automatically.",
        "Take photos on the camera. Each shot is downloaded, your film sim applied, and saved to Photos."
    ]

    // MARK: - Photo viewer sheet

    private func photoViewer(_ photo: UIImage) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: photo)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    Button { selectedPhoto = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(16)
                    }
                }
                Spacer()
                Button {
                    PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest.creationRequestForAsset(from: photo)
                    }
                } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.down.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .background(Capsule().fill(Color.yellow))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 40)
            }
        }
    }
}
