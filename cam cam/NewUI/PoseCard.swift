//
//  PoseCard.swift
//  cam cam
//
//  The Pose guide card under the exposure meter: the pose as a wireframe,
//  its name and a line to read out to the subject, which pose of how many,
//  and a ring that fills as they get into it. Tap for the next pose.
//

import SwiftUI

struct PoseCard: View {
    let pose: Pose
    let index: Int
    let count: Int
    let match: Double
    let matched: Bool
    var onNext: () -> Void

    var body: some View {
        Button(action: onNext) {
            VStack(spacing: 4) {
                HStack {
                    Text("POSE \(index + 1) / \(count)")
                        .font(.system(size: 9, weight: .bold)).tracking(1)
                        .foregroundStyle(.yellow)
                    Spacer()
                    ZStack {
                        Circle().stroke(.white.opacity(0.2), lineWidth: 2.5)
                        Circle().trim(from: 0, to: max(0.02, match))
                            .stroke(matched ? Color.green : Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 16, height: 16)
                    .animation(.easeOut(duration: 0.2), value: match)
                }
                PoseFigure(figures: pose.figures, back: pose.backToCamera)
                    .frame(width: 84, height: 118)
                Text(pose.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(pose.detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2).multilineTextAlignment(.center)
                    .frame(height: 26, alignment: .top)       // same height for every pose
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .frame(width: 118)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pose guide: \(pose.name), \(pose.detail). Pose \(index + 1) of \(count).")
        .accessibilityHint("Double-tap for the next pose")
    }
}

/// Wireframe(s) of a pose: bones, a head, and yellow dots on the joints that
/// make the pose (elbows, wrists, knees).
struct PoseFigure: View {
    let figures: [[PJ: CGPoint]]
    var back = false

    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 100, sy = size.height / 140
            let s = min(sx, sy)
            let ox = (size.width - 100 * s) / 2, oy = (size.height - 140 * s) / 2
            func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: ox + p.x * s, y: oy + p.y * s) }
            let lw = max(1.5, 2.6 * s * (figures.count > 1 ? 0.8 : 1))
            for f in figures {
                for (a, b) in PJ.bones {
                    guard let p = f[a], let q = f[b] else { continue }
                    var path = Path(); path.move(to: pt(p)); path.addLine(to: pt(q))
                    ctx.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
                }
                if let n = f[.nose], let neck = f[.neck] {
                    let c = pt(n)
                    let r = max(3, hypot(n.x - neck.x, n.y - neck.y) * s * 0.75)
                    let head = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                    if back { ctx.fill(head, with: .color(.white.opacity(0.85))) }
                    else { ctx.stroke(head, with: .color(.white), lineWidth: lw) }
                }
                for j in [PJ.lEl, .rEl, .lWr, .rWr, .lKn, .rKn] {
                    guard let p = f[j] else { continue }
                    let c = pt(p), r = lw * 0.9
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.yellow))
                }
            }
        }
    }
}
