import SwiftUI

struct SplashView: View {
    @State private var phase: SplashPhase = .idle
    @State private var showCamera = false

    // Image
    @State private var logoOpacity: Double = 0
    @State private var logoScale: Double  = 1.08
    @State private var logoBlur: Double   = 6

    // White flash overlay
    @State private var flashOpacity: Double = 0

    // Vignette that closes in at the end
    @State private var vignetteOpacity: Double = 0

    enum SplashPhase { case idle, running, done }

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
                    .padding(72)
                    .opacity(logoOpacity)
                    .scaleEffect(logoScale)
                    .blur(radius: logoBlur)

                // Hard white strobe layer
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
                guard phase == .idle else { return }
                phase = .running
                runAnimation()
            }
        }
    }

    // MARK: - Animation sequence

    private func runAnimation() {

        // ── Beat 1: Hard white flash + logo burns in (0 → 0.10s) ──
        withAnimation(.easeOut(duration: 0.10)) {
            flashOpacity = 1.0
            logoOpacity  = 1.0
            logoScale    = 1.0
            logoBlur     = 0
        }

        // ── Flash 1 fades (0.10 → 0.22s) ──
        withAnimation(.easeIn(duration: 0.12).delay(0.10)) {
            flashOpacity = 0.0
        }

        // ── Beat 2: Second strobe, dimmer (0.30 → 0.36s) ──
        withAnimation(.easeOut(duration: 0.06).delay(0.30)) {
            flashOpacity = 0.55
        }
        withAnimation(.easeIn(duration: 0.10).delay(0.36)) {
            flashOpacity = 0.0
        }

        // ── Beat 3: Very short ghost flash (0.52 → 0.56s) ──
        withAnimation(.easeOut(duration: 0.04).delay(0.52)) {
            flashOpacity = 0.25
        }
        withAnimation(.easeIn(duration: 0.08).delay(0.56)) {
            flashOpacity = 0.0
        }

        // ── Hold on logo, slight settle (0.64 → 0.80s) ──
        withAnimation(.easeOut(duration: 0.16).delay(0.64)) {
            logoScale = 0.98    // tiny settle-in — feels weighted
        }

        // ── Fade to black (1.10 → 1.55s) ──
        withAnimation(.easeIn(duration: 0.45).delay(1.10)) {
            vignetteOpacity = 1.0
        }

        // ── Switch to camera (1.60s) ──
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.60) {
            withAnimation(.easeIn(duration: 0.2)) {
                showCamera = true
            }
        }
    }
}

#Preview {
    SplashView()
}
