//
//  ContactSheet.swift
//  cam cam
//
//  A developed roll as one contact print: frames laid out as strips of 35mm
//  film on white paper, with sprocket holes, frame numbers and the film's
//  name printed along the edge — like printing the negatives in a darkroom.
//

import UIKit
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ContactSheet {

    /// How a roll is developed (applied to every frame).
    enum Development: String, CaseIterable, Identifiable, Sendable {
        case normal, push1, push2, pull1, cross
        var id: String { rawValue }
        var title: String {
            switch self {
            case .normal: "Normal"
            case .push1: "Push +1"
            case .push2: "Push +2"
            case .pull1: "Pull −1"
            case .cross: "Cross-process"
            }
        }
        var detail: String {
            switch self {
            case .normal: "As shot"
            case .push1: "More contrast and grain, deeper blacks"
            case .push2: "Gritty, punchy, heavy grain"
            case .pull1: "Softer contrast, gentler highlights"
            case .cross: "Slide chemistry in negative developer: wild, saturated colour"
            }
        }
        /// Apply this development to a frame's recipe.
        func apply(to r: ShotRecipe) -> ShotRecipe {
            var r = r
            switch self {
            case .normal: break
            case .push1: r.pushPullEnabled = true; r.pushPull = min(3, (r.pushPullEnabled ? r.pushPull : 0) + 1)
            case .push2: r.pushPullEnabled = true; r.pushPull = min(3, (r.pushPullEnabled ? r.pushPull : 0) + 2)
            case .pull1: r.pushPullEnabled = true; r.pushPull = max(-2, (r.pushPullEnabled ? r.pushPull : 0) - 1)
            case .cross: r.crossProcessed = true
            }
            return r
        }
    }

    /// Render the sheet. `frames` are already-rendered images, in shot order.
    static func render(frames: [CGImage], film: String, date: Date) -> Data? {
        guard !frames.isEmpty else { return nil }
        let perRow = 6
        let cellW: CGFloat = 360, cellH: CGFloat = 240          // 3:2 frames
        let gap: CGFloat = 16, rebate: CGFloat = 46             // film edges top/bottom
        let rows = Int(ceil(Double(frames.count) / Double(perRow)))
        let margin: CGFloat = 80
        let stripW = CGFloat(perRow) * cellW + CGFloat(perRow + 1) * gap
        let stripH = cellH + rebate * 2
        let width = stripW + margin * 2
        let height = CGFloat(rows) * stripH + CGFloat(rows - 1) * 40 + margin * 2 + 90

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            let cg = ctx.cgContext
            // Paper
            UIColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: width, height: height))

            let edgeFont = UIFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
            let edgeColor = UIColor(red: 0.93, green: 0.55, blue: 0.20, alpha: 1)   // edge-print orange
            let filmName = film.uppercased()

            for row in 0..<rows {
                let y = margin + CGFloat(row) * (stripH + 40)
                // The strip of film
                UIColor(white: 0.06, alpha: 1).setFill()
                cg.fill(CGRect(x: margin, y: y, width: stripW, height: stripH))
                // Sprocket holes along both edges
                UIColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1).setFill()
                var hx = margin + 14
                while hx < margin + stripW - 20 {
                    cg.fill(CGRect(x: hx, y: y + 9, width: 14, height: 18).insetBy(dx: 0, dy: 0))
                    cg.fill(CGRect(x: hx, y: y + stripH - 27, width: 14, height: 18))
                    hx += 30
                }
                for col in 0..<perRow {
                    let i = row * perRow + col
                    guard i < frames.count else { break }
                    let fx = margin + gap + CGFloat(col) * (cellW + gap)
                    let rect = CGRect(x: fx, y: y + rebate, width: cellW, height: cellH)
                    drawAspectFill(frames[i], in: rect, cg: cg)
                    // Edge printing: film name on the top rebate, frame number on the bottom
                    let n = i + 1
                    let top = n % 2 == 1 ? "\(filmName)  ▸ \(n)" : "▸ \(n)A"
                    (top as NSString).draw(at: CGPoint(x: fx + 4, y: y + 28),
                                           withAttributes: [.font: edgeFont, .foregroundColor: edgeColor])
                    ("\(n)" as NSString).draw(at: CGPoint(x: fx + cellW / 2 - 6, y: y + rebate + cellH + 2),
                                              withAttributes: [.font: edgeFont, .foregroundColor: edgeColor])
                }
            }
            // Caption
            let caption = "\(film)  ·  \(frames.count) frames  ·  \(date.formatted(date: .abbreviated, time: .omitted))  ·  cam cam"
            (caption as NSString).draw(at: CGPoint(x: margin, y: height - margin - 30),
                                       withAttributes: [.font: UIFont.systemFont(ofSize: 22, weight: .medium),
                                                        .foregroundColor: UIColor(white: 0.25, alpha: 1)])
        }
        return image.jpegData(compressionQuality: 0.9)
    }

    private static func drawAspectFill(_ img: CGImage, in rect: CGRect, cg: CGContext) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let s = max(rect.width / iw, rect.height / ih)
        let w = iw * s, h = ih * s
        cg.saveGState()
        cg.clip(to: rect)
        // UIKit context is flipped; draw the CGImage upright.
        cg.translateBy(x: 0, y: rect.midY * 2)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(img, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
        cg.restoreGState()
    }

    /// Downscaled, upright thumbnail of an encoded photo (for the sheet).
    static func thumbnail(_ data: Data, maxSize: Int = 720) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
        ] as CFDictionary)
    }
}
