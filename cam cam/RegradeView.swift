//
//  RegradeView.swift
//  cam cam
//
//  Change a shot's film look AFTER taking it. Every cam cam photo is saved as
//  original + a Photos edit carrying its ShotRecipe (see PhotoSaver), so here
//  we reopen the untouched original, preview any film live on the same dial
//  as the camera, and commit a new edit — or go back to the original.
//  Effects/grain/seed from the shot's recipe are kept; only the film changes.
//

import SwiftUI
import Photos
import CoreImage

struct RegradeView: View {
    let camera: CameraManager
    let customSimStore: CustomSimStore
    @Environment(\.dismiss) private var dismiss
    @State private var assetIDs: [String] = []
    @State private var loaded = false
    @State private var open: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let id = open {
                RegradeDetail(assetID: id, camera: camera, customSimStore: customSimStore,
                              onBack: { open = nil })
                    .transition(.move(edge: .trailing))
            } else {
                grid.transition(.move(edge: .leading))
            }
        }
        .animation(.snappy(duration: 0.3), value: open)
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Back to camera")
                Spacer()
                VStack(spacing: 1) {
                    Text("cam cam").font(.system(size: 17, weight: .semibold))
                    Text("\(assetIDs.count) photos").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)

            if loaded && assetIDs.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "photo.stack").font(.system(size: 44)).foregroundStyle(.white.opacity(0.5))
                    Text("No cam cam photos yet").font(.title3.weight(.semibold))
                    Text("Every shot keeps its original, so you can change its film here later.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        ForEach(assetIDs, id: \.self) { id in
                            Button { open = id } label: { AssetThumb(assetID: id) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        _ = await PhotoSaver.authorize()
        defer { loaded = true }
        guard let album = PhotoSaver.albumIfExists() else { return }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let r = PHAsset.fetchAssets(in: album, options: opts)
        assetIDs = (0..<r.count).map { r.object(at: $0).localIdentifier }
    }
}

// MARK: - Thumbnail (with the film it was shot on)

private struct AssetThumb: View {
    let assetID: String
    @State private var image: UIImage?
    @State private var film: String?

    var body: some View {
        Color.white.opacity(0.06)
            .aspectRatio(1, contentMode: .fit)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .overlay(alignment: .bottomLeading) {
                if let film {
                    Text(film.uppercased())
                        .font(.system(size: 9, weight: .bold)).tracking(0.5)
                        .lineLimit(1)
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(5)
                }
            }
            .clipped()
            .task {
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
                else { return }
                let opts = PHImageRequestOptions()
                opts.deliveryMode = .opportunistic
                opts.isNetworkAccessAllowed = true
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 300, height: 300),
                                                      contentMode: .aspectFill, options: opts) { img, _ in
                    if let img { image = img }
                }
                film = await PhotoSaver.recipe(for: asset)?.displayName
            }
    }
}

// MARK: - Detail

private struct RegradeDetail: View {
    let assetID: String
    let camera: CameraManager
    let customSimStore: CustomSimStore
    var onBack: () -> Void

    @State private var original: CIImage?          // downscaled, upright, for previews
    @State private var originalUI: UIImage?
    @State private var preview: UIImage?
    @State private var oldRecipe: ShotRecipe?
    @State private var recipe = ShotRecipe()
    @State private var busy = false
    @State private var message: String?
    @State private var comparing = false
    @State private var tones = FilmToneStore.shared

    private var items: [ArcItem] {
        FilmSimulation.allCases.map(ArcItem.builtIn) + customSimStore.simulations.map(ArcItem.custom)
    }
    private var selectedKey: String {
        if let c = recipe.custom { return FavoritesStore.key(c) }
        return FavoritesStore.key(recipe.sim)
    }

    var body: some View {
        ZStack {
            // Photo, full bleed; hold to see the original.
            Group {
                if let shown = comparing ? originalUI : preview {
                    Image(uiImage: shown).resizable().scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in comparing = true }
                .onEnded { _ in comparing = false })
            .accessibilityLabel("Photo. Hold to see the original.")

            VStack(spacing: 0) {
                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("Back to photos")
                    Spacer()
                    Text(statusText)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14).frame(height: 32)
                        .glassEffect(.regular, in: Capsule())
                        .contentTransition(.opacity)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 16).padding(.top, 8)

                Spacer()

                if let message {
                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14).frame(minHeight: 34)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }

                FilmArc(items: items, selectedKey: selectedKey,
                        onSelect: { item in
                            if let c = item.custom { recipe.custom = c; recipe.sim = .none }
                            else if let s = item.sim { recipe.sim = s; recipe.custom = nil }
                        },
                        onOpenLibrary: {})

                HStack(spacing: 12) {
                    Button { Task { await revert() } } label: {
                        Text("Original").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white).padding(.horizontal, 22).frame(height: 50)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .disabled(oldRecipe == nil)
                    .opacity(oldRecipe == nil ? 0.4 : 1)

                    Button { Task { await apply() } } label: {
                        Text(recipe == oldRecipe ? "Applied" : "Apply \(recipe.displayName)")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.black)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background(Capsule().fill(Color.yellow))
                    }
                    .buttonStyle(.plain)
                    .disabled(recipe == oldRecipe)
                    .opacity(recipe == oldRecipe ? 0.5 : 1)
                }
                .disabled(busy)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Color.black.ignoresSafeArea(edges: .bottom))
            }

            if busy {
                ProgressView("Rendering full resolution…")
                    .padding(18)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .animation(.snappy(duration: 0.2), value: message)
        .task { await loadOriginal() }
        .task { tones.ensure(items, camera: camera) }
        .onChange(of: recipe) { renderPreview() }
    }

    private var statusText: String {
        if comparing { return "Original" }
        if recipe == oldRecipe { return oldRecipe.map { "Shot on \($0.displayName)" } ?? "No look yet" }
        return "Preview · \(recipe.displayName)"
    }

    // MARK: Actions

    private func loadOriginal() async {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject,
              let input = await PhotoSaver.editingInput(for: asset),
              let url = input.fullSizeImageURL,
              let ci = CIImage(contentsOf: url)
        else { message = "Couldn't open this photo"; return }
        let o = (ci.properties[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
        let upright = ci.oriented(forExifOrientation: o)
        let scale = min(1, 1600 / max(upright.extent.width, upright.extent.height))
        let small = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        original = small
        if let cg = camera.ciContext.createCGImage(small, from: small.extent) { originalUI = UIImage(cgImage: cg) }
        if let adj = input.adjustmentData, adj.formatIdentifier == ShotRecipe.formatIdentifier {
            oldRecipe = ShotRecipe.decode(adj.data)
        } else {
            oldRecipe = nil
        }
        recipe = oldRecipe ?? ShotRecipe()
        renderPreview()
    }

    private func renderPreview() {
        guard let original else { return }
        let r = recipe
        nonisolated(unsafe) let cam = camera
        Task.detached(priority: .userInitiated) {
            let out = cam.renderLook(original, recipe: r, flatten: false).cropped(to: original.extent)
            guard let cg = cam.ciContext.createCGImage(out, from: out.extent) else { return }
            let img = UIImage(cgImage: cg)
            await MainActor.run { if r == recipe { preview = img } }
        }
    }

    private func apply() async {
        busy = true; defer { busy = false }
        let r = recipe
        nonisolated(unsafe) let cam = camera
        do {
            try await PhotoSaver.regrade(assetID: assetID, recipe: r) { data in
                guard let ci = CIImage(data: data) else { return nil }
                let o = (ci.properties[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
                let upright = ci.oriented(forExifOrientation: o)
                let out = cam.renderLook(upright, recipe: r, flatten: true).cropped(to: upright.extent)
                guard let cg = cam.ciContext.createCGImage(out, from: out.extent) else { return nil }
                return MetadataTools.jpeg(from: cg, metadataFrom: data, location: nil)
            }
            oldRecipe = r
            message = "Now \(r.displayName) — the original is kept"
        } catch {
            message = error.localizedDescription
        }
    }

    private func revert() async {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return }
        busy = true; defer { busy = false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).revertAssetContentToOriginal()
            }
            oldRecipe = nil
            recipe = ShotRecipe()
            message = "Back to the original"
        } catch {
            message = error.localizedDescription
        }
    }
}
