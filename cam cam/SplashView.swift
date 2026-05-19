import SwiftUI

struct SplashView: View {
    @State private var showCamera = false
    @State private var animationTask: Task<Void, Never>? = nil

    // Crisp tube — the actual neon line, near-white hot core
    @State private var logoOpacity: Double = 0
    @State private var logoScale: Double = 1.0

    // Tight halo — the red ring right around the tube (small blur, moderate opacity)
    @State private var haloOpacity: Double = 0
    @State private var haloBlur: Double = 4

    // Wide atmospheric bloom — very dim, just enough to feel like light in the room
    @State private var bloomOpacity: Double = 0
    @State private var bloomBlur: Double = 28

    @State private var vignetteOpacity: Double = 0

    var body: some View {
        if showCamera {
            CameraContentView()
        } else {
            GeometryReader { geo in
                ZStack {
                    Color.black.ignoresSafeArea()

                    // Wide bloom — very subtle, just ambient light in the air
                    logoImage(geo)
                        .blur(radius: bloomBlur)
                        .blendMode(.screen)
                        .opacity(bloomOpacity)
                        .scaleEffect(logoScale)

                    // Tight halo — the characteristic red ring of a neon tube
                    logoImage(geo)
                        .blur(radius: haloBlur)
                        .blendMode(.screen)
                        .opacity(haloOpacity)
                        .scaleEffect(logoScale)

                    // Crisp core — bright near-white tube, screen blend kills the JPEG black
                    logoImage(geo)
                        .blur(radius: 0.6)
                        .blendMode(.screen)
                        .opacity(logoOpacity)
                        .scaleEffect(logoScale)

                    Color.black
                        .ignoresSafeArea()
                        .opacity(vignetteOpacity)
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
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

    private func logoImage(_ geo: GeometryProxy) -> some View {
        Image("SplashLogo")
            .resizable()
            .scaledToFit()
            .frame(width: geo.size.width, height: geo.size.height)
    }

    // MARK: - Neon sign animation

    @MainActor
    private func runAnimation() async {
        func pause(_ seconds: Double) async -> Bool {
            do { try await Task.sleep(for: .seconds(seconds)); return true }
            catch { return false }
        }

        // ── Zap 1: first spark — tube tries to strike ──
        withAnimation(.linear(duration: 0.05)) {
            logoOpacity  = 0.7
            haloOpacity  = 0.45
            bloomOpacity = 0.12
        }
        guard await pause(0.07) else { return }

        // ── Off ──
        withAnimation(.linear(duration: 0.04)) {
            logoOpacity  = 0
            haloOpacity  = 0
            bloomOpacity = 0
        }
        guard await pause(0.08) else { return }

        // ── Zap 2: stronger, almost holds ──
        withAnimation(.linear(duration: 0.05)) {
            logoOpacity  = 0.85
            haloOpacity  = 0.55
            bloomOpacity = 0.16
        }
        guard await pause(0.09) else { return }

        // ── Drops to near-off ──
        withAnimation(.linear(duration: 0.04)) {
            logoOpacity  = 0.05
            haloOpacity  = 0.04
            bloomOpacity = 0.02
        }
        guard await pause(0.06) else { return }

        // ── Warming up — gas partially ionised, dim flicker ──
        withAnimation(.easeIn(duration: 0.18)) {
            logoOpacity  = 0.65
            haloOpacity  = 0.4
            haloBlur     = 5
            bloomOpacity = 0.12
            bloomBlur    = 32
        }
        guard await pause(0.14) else { return }

        // ── Mid-warmup stutter ──
        withAnimation(.linear(duration: 0.04)) {
            logoOpacity  = 0.25
            haloOpacity  = 0.15
            bloomOpacity = 0.04
        }
        guard await pause(0.05) else { return }

        // ── Catches — sign is fully on ──
        withAnimation(.easeOut(duration: 0.16)) {
            logoOpacity  = 1.0
            haloOpacity  = 0.6
            haloBlur     = 4
            bloomOpacity = 0.18
            bloomBlur    = 26
        }
        guard await pause(0.22) else { return }

        // ── Bloom settles outward (tube cools to stable temperature) ──
        withAnimation(.easeInOut(duration: 0.5)) {
            haloBlur     = 3.5
            bloomBlur    = 24
            bloomOpacity = 0.15
        }
        guard await pause(0.38) else { return }

        // ── Neon hum — two tiny dips in current ──
        withAnimation(.linear(duration: 0.05)) { logoOpacity = 0.91; haloOpacity = 0.52 }
        guard await pause(0.07) else { return }
        withAnimation(.linear(duration: 0.05)) { logoOpacity = 1.0;  haloOpacity = 0.6  }
        guard await pause(0.09) else { return }
        withAnimation(.linear(duration: 0.04)) { logoOpacity = 0.94 }
        guard await pause(0.05) else { return }
        withAnimation(.linear(duration: 0.04)) { logoOpacity = 1.0  }

        // ── Hold ──
        guard await pause(0.5) else { return }

        // ── Fade to black ──
        withAnimation(.easeIn(duration: 0.5)) { vignetteOpacity = 1.0 }
        guard await pause(0.55) else { return }

        showCamera = true
    }
}

#Preview {
    SplashView()
}
