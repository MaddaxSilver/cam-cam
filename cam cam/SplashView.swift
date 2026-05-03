import SwiftUI

struct SplashView: View {
    @State private var showCamera = false
    @State private var animationTask: Task<Void, Never>? = nil

    // Image
    @State private var logoOpacity: Double = 0
    @State private var logoScale: Double  = 1.08
    @State private var logoBlur: Double   = 6

    // White flash overlay
    @State private var flashOpacity: Double = 0

    // Vignette that closes in at the end
    @State private var vignetteOpacity: Double = 0

    var body: some View {
        if showCamera {
            CameraContentView()
                .transition(.opacity)
        } else {
            ZStack {
                Color.black.ignoresSafeArea()

                // Logo
                Image("SplashLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(72)
                    .opacity(logoOpacity)
                    .scaleEffect(logoScale)
                    .blur(radius: logoBlur)

                // Soft flash overlay
                Color.white
                    .ignoresSafeArea()
                    .opacity(flashOpacity)
                    .allowsHitTesting(false)

                // Black fade-out vignette at the end
                Color.black
                    .ignoresSafeArea()
                    .opacity(vignetteOpacity)
                    .allowsHitTesting(false)
            }
            .onAppear {
                guard animationTask == nil else { return }
                animationTask = Task { await runAnimation() }
            }
            .onDisappear {
                animationTask?.cancel()
                animationTask = nil
            }
        }
    }

    // MARK: - Animation sequence

    @MainActor
    private func runAnimation() async {
        // ── Single soft flash + logo fades in (0 → 0.25s) ──
        withAnimation(.easeOut(duration: 0.25)) {
            flashOpacity = 0.35
            logoOpacity  = 1.0
            logoScale    = 1.0
            logoBlur     = 0
        }

        // ── Flash gently fades out (0.25 → 0.55s) ──
        withAnimation(.easeIn(duration: 0.30).delay(0.25)) {
            flashOpacity = 0.0
        }

        // ── Settle (0.55 → 0.70s) ──
        withAnimation(.easeOut(duration: 0.15).delay(0.55)) {
            logoScale = 0.98
        }

        // ── Fade to black (1.10 → 1.55s) ──
        withAnimation(.easeIn(duration: 0.45).delay(1.10)) {
            vignetteOpacity = 1.0
        }

        // ── Switch to camera (1.60s) — cancellable sleep ──
        do {
            try await Task.sleep(for: .seconds(1.60))
        } catch {
            return  // task was cancelled (e.g. view disappeared)
        }
        withAnimation(.easeIn(duration: 0.2)) {
            showCamera = true
        }
    }
}

#Preview {
    SplashView()
}
