//
//  RegradeView.swift
//  cam cam
//
//  Change a shot's film look AFTER taking it. Every cam cam photo is saved as
//  original + a Photos edit carrying its ShotRecipe (see PhotoSaver), so here
//  we reopen the untouched original, preview any sim live, and commit a new
//  edit — or revert to the original. Effects/grain/seed from the shot's
//  recipe are kept; only the sim changes.
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

    var body: some View {
        NavigationStack {
            Group {
                if loaded && assetIDs.isEmpty {
                    ContentUnavailableView(
                        "No cam cam shots yet", systemImage: "photo.stack",
                        description: Text("New photos land in the cam cam album with their film look attached — you can re-grade them here."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 2)], spacing: 2) {
                            ForEach(assetIDs, id: \.self) { id in
                                NavigationLink(value: id) { AssetThumb(assetID: id) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Re-grade")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                RegradeDetail(assetID: id, camera: camera, customSimStore: customSimStore)
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
        .preferredColorScheme(.dark)
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

// MARK: - Thumbnail

private struct AssetThumb: View {
    let assetID: String
    @State private var image: UIImage?

    var body: some View {
        Color.white.opacity(0.06)
            .aspectRatio(1, contentMode: .fit)
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
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
            }
    }
}

// MARK: - Detail

private struct RegradeDetail: View {
    let assetID: String
    let camera: CameraManager
    let customSimStore: CustomSimStore

    @State private var original: CIImage?          // downscaled, upright, for previews
    @State private var preview: UIImage?
    @State private var oldRecipe: ShotRecipe?
    @State private var recipe = ShotRecipe()
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(oldRecipe.map { "Shot with \($0.displayName)" } ?? "No cam cam look on this photo yet")
                .font(.system(size: 12)).foregroundStyle(.secondary)

            simStrip

            if let message {
                Text(message).font(.system(size: 12, weight: .medium)).foregroundStyle(.yellow)
            }

            HStack(spacing: 12) {
                Button { Task { await revert() } } label: {
                    Label("Original", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { Task { await apply() } } label: {
                    Label("Apply \(recipe.displayName)", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow).foregroundStyle(.black)
                .disabled(recipe == oldRecipe)
            }
            .disabled(busy)
            .padding(.horizontal)
        }
        .padding(.vertical)
        .navigationTitle("Change look")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if busy { ProgressView("Rendering full resolution…").padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .task { await loadOriginal() }
        .onChange(of: recipe) { renderPreview() }
    }

    private var simStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FilmSimulation.allCases) { sim in
                    chip(sim.label, active: recipe.custom == nil && recipe.sim == sim, tint: .yellow) {
                        recipe.sim = sim; recipe.custom = nil
                    }
                }
                ForEach(customSimStore.simulations) { sim in
                    chip(sim.name, active: recipe.custom?.id == sim.id, tint: sim.lutFilename == nil ? .cyan : .orange) {
                        recipe.custom = sim; recipe.sim = .none
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func chip(_ title: String, active: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: active ? .bold : .regular))
                .foregroundStyle(active ? .black : .white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(active ? tint : Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
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
        let scale = min(1, 1400 / max(upright.extent.width, upright.extent.height))
        original = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
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
            message = "Now \(r.displayName) — revertible in Photos"
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
            message = "Reverted to the original"
        } catch {
            message = error.localizedDescription
        }
    }
}
