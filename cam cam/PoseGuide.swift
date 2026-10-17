//
//  PoseGuide.swift
//  cam cam
//
//  Pose guide: suggests a pose for the people in frame and coaches them into
//  it. The person being photographed can't see the screen, so the card under
//  the exposure meter shows a wireframe of the pose plus a short line to read
//  out ("Hand on your hip, elbow out"), and the hint above the dial says what
//  to fix next. The subject's live skeleton is drawn over them: green where
//  they match, yellow where they don't. When the pose matches, it fires the
//  shutter and moves on to the next pose.
//
//  Poses come from the posing guides photographers and Instagram/Pinterest
//  creators keep returning to (Shotkit's 68 Instagram poses, Jasmine Alley's
//  48 photo poses and 50 couple poses, SLR Lounge's group posing): the weight
//  shift, hand on hip, hands in pockets, look over the shoulder, hand in the
//  hair, arms crossed, walking, back to camera with open arms, power stance,
//  the lean-forward and cross-legged sits, kneeling, and for two or more:
//  close together looking out, walking hand in hand, staggered heights.
//
//  Which poses are offered depends on what's in frame: full body, half body,
//  sitting, a couple, a group. Tap the card for the next one.
//
//  Detection is Apple's on-device body pose (19 joints), ~6 times a second on
//  a small upright copy of the frame. Checks use joint angles and distances
//  in torso lengths, so they work at any distance and either way round.
//

import AVFoundation
import CoreImage
import Observation
import UIKit
import Vision

// MARK: - Skeleton

/// Joints (the subject's own left/right).
nonisolated enum PJ: String, CaseIterable, Sendable {
    case nose, neck, lSh, rSh, lEl, rEl, lWr, rWr, root, lHip, rHip, lKn, rKn, lAn, rAn

    static let vision: [VNHumanBodyPoseObservation.JointName: PJ] = [
        .nose: .nose, .neck: .neck, .leftShoulder: .lSh, .rightShoulder: .rSh,
        .leftElbow: .lEl, .rightElbow: .rEl, .leftWrist: .lWr, .rightWrist: .rWr,
        .root: .root, .leftHip: .lHip, .rightHip: .rHip, .leftKnee: .lKn, .rightKnee: .rKn,
        .leftAnkle: .lAn, .rightAnkle: .rAn,
    ]
    /// Bones for drawing.
    static let bones: [(PJ, PJ)] = [
        (.neck, .root), (.lSh, .rSh), (.lSh, .lEl), (.lEl, .lWr), (.rSh, .rEl), (.rEl, .rWr),
        (.lHip, .rHip), (.lHip, .lKn), (.lKn, .lAn), (.rHip, .rKn), (.rKn, .rAn),
    ]
}

/// One person's detected joints. `p` is in upright image units where both
/// axes are measured in image heights (so distances are true), y down.
nonisolated struct Skeleton: Sendable {
    var p: [PJ: CGPoint]
    /// Same joints, top-left normalized 0…1 (for drawing).
    var norm: [PJ: CGPoint]
    var noseConfidence: Float

    subscript(_ j: PJ) -> CGPoint? { p[j] }
    var torso: CGFloat {
        guard let n = p[.neck], let r = p[.root] else { return 0.25 }
        return max(hypot(n.x - r.x, n.y - r.y), 0.02)
    }
    func d(_ a: PJ, _ b: PJ) -> CGFloat? {
        guard let x = p[a], let y = p[b] else { return nil }
        return hypot(x.x - y.x, x.y - y.y) / torso
    }
    /// Angle at `b` (degrees) between b→a and b→c.
    func angle(_ a: PJ, _ b: PJ, _ c: PJ) -> CGFloat? {
        guard let A = p[a], let B = p[b], let C = p[c] else { return nil }
        let v1 = CGVector(dx: A.x - B.x, dy: A.y - B.y), v2 = CGVector(dx: C.x - B.x, dy: C.y - B.y)
        let n = hypot(v1.dx, v1.dy) * hypot(v2.dx, v2.dy)
        guard n > 1e-6 else { return nil }
        return acos(max(-1, min(1, (v1.dx * v2.dx + v1.dy * v2.dy) / n))) * 180 / .pi
    }
    var hasLegs: Bool { p[.lKn] != nil || p[.rKn] != nil }
    var hasFeet: Bool { p[.lAn] != nil || p[.rAn] != nil }
    var centre: CGPoint { p[.root] ?? p[.neck] ?? .zero }
    /// Sitting: the knees are nearly level with the hips — from the side the
    /// thighs are horizontal, from the front they point at the camera. Both
    /// knees must be up (kneeling has one knee down near the ground).
    var isSitting: Bool {
        let t = torso
        var drops: [CGFloat] = []
        for (h, k) in [(PJ.lHip, PJ.lKn), (.rHip, .rKn)] {
            if let H = p[h], let K = p[k] { drops.append((K.y - H.y) / t) }
        }
        guard let worst = drops.max() else { return false }
        return worst < (drops.count == 2 ? 0.5 : 0.45)
    }
}

// MARK: - Poses

nonisolated enum PoseContext: Sendable { case full, half, sitting, couple, group }

nonisolated struct PoseCheck: Sendable {
    /// What to say when this part is off.
    let fix: String
    /// 0…1 and the joints involved (drawn yellow when it's off).
    let eval: @Sendable (_ main: Skeleton, _ all: [Skeleton]) -> (Double, [PJ])
}

nonisolated struct Pose: Sendable, Identifiable {
    let id: String
    let name: String
    let detail: String
    let contexts: Set<PoseContext>
    /// Wireframe(s) in a 100×140 box (image left/right), one per person.
    let figures: [[PJ: CGPoint]]
    var backToCamera = false
    let checks: [PoseCheck]
}

/// 1 inside [lo, hi], falling to 0 over `soft` outside it.
nonisolated func band(_ v: CGFloat?, _ lo: CGFloat, _ hi: CGFloat, soft: CGFloat) -> Double {
    guard let v else { return 0 }
    if v >= lo && v <= hi { return 1 }
    let off = v < lo ? lo - v : v - hi
    return Double(max(0, 1 - off / soft))
}

/// Best of the two sides (people face either way).
nonisolated func eitherSide(_ f: (_ sh: PJ, _ el: PJ, _ wr: PJ, _ hip: PJ, _ kn: PJ, _ an: PJ) -> (Double, [PJ])) -> (Double, [PJ]) {
    let l = f(.lSh, .lEl, .lWr, .lHip, .lKn, .lAn), r = f(.rSh, .rEl, .rWr, .rHip, .rKn, .rAn)
    return l.0 >= r.0 ? l : r
}

nonisolated enum PoseLibrary {
    // Building blocks

    /// One knee softly bent, the other straight (weight on the back leg).
    static let weightShift = PoseCheck(fix: "Weight on your back leg, soften the front knee") { s, _ in
        guard let a = s.angle(.lHip, .lKn, .lAn), let b = s.angle(.rHip, .rKn, .rAn) else { return (0, [.lKn, .rKn]) }
        let bent = min(a, b), straight = max(a, b)
        let sc = min(band(bent, 125, 166, soft: 15), band(straight, 168, 180, soft: 10))
        return (sc, [.lHip, .lKn, .lAn, .rHip, .rKn, .rAn])
    }
    /// A wrist at the hip with the elbow out to the side.
    static func handOnHip(_ fix: String = "Hand on your hip, elbow out") -> PoseCheck {
        PoseCheck(fix: fix) { s, _ in
            eitherSide { sh, el, wr, hip, _, _ in
                let near = band(s.d(wr, hip), 0, 0.35, soft: 0.25)
                let bent = band(s.angle(sh, el, wr), 55, 125, soft: 25)
                var out = 0.0
                if let E = s[el], let S = s[sh], let R = s[.root] {      // in torso lengths
                    out = band((abs(E.x - R.x) - abs(S.x - R.x)) / s.torso, 0.15, 4, soft: 0.15)
                }
                return (min(near, bent, out), [sh, el, wr])
            }
        }
    }
    /// Wrists at the hips with the elbows clearly bent and out (arms just
    /// hanging at the sides must NOT count).
    static let bothHandsInPockets = PoseCheck(fix: "Both hands in your pockets, elbows relaxed out") { s, _ in
        func side(_ sh: PJ, _ el: PJ, _ wr: PJ, _ hip: PJ) -> Double {
            var out = 0.0
            if let E = s[el], let S = s[sh], let R = s[.root] {          // in torso lengths
                out = band((abs(E.x - R.x) - abs(S.x - R.x)) / s.torso, 0.05, 4, soft: 0.1)
            }
            return min(band(s.d(wr, hip), 0, 0.4, soft: 0.25), band(s.angle(sh, el, wr), 80, 150, soft: 12), out)
        }
        return (min(side(.lSh, .lEl, .lWr, .lHip), side(.rSh, .rEl, .rWr, .rHip)), [.lEl, .lWr, .rEl, .rWr])
    }
    /// Body turned side-on (shoulders look narrow).
    static let sideOn = PoseCheck(fix: "Turn your body sideways to me") { s, _ in
        (band(s.d(.lSh, .rSh), 0, 0.42, soft: 0.25), [.lSh, .rSh])
    }
    static let faceToCamera = PoseCheck(fix: "Look back at me over your shoulder") { s, _ in
        (s.noseConfidence > 0.4 ? 1 : 0, [.nose, .neck])
    }
    static let handUpToHead = PoseCheck(fix: "Raise one hand to your hair") { s, _ in
        eitherSide { sh, el, wr, _, _, _ in
            guard let W = s[wr], let S = s[sh] else { return (0, [sh, el, wr]) }
            let above = W.y < S.y ? 1.0 : 0.0
            let near = band(s.d(wr, .nose) ?? s.d(wr, .neck), 0, 0.7, soft: 0.3)
            return (min(above, near), [sh, el, wr])
        }
    }
    static let armsCrossed = PoseCheck(fix: "Cross your arms, shoulders down") { s, _ in
        guard let N = s[.neck], let R = s[.root], let L = s[.lWr], let Rw = s[.rWr] else { return (0, [.lWr, .rWr]) }
        let t = s.torso
        func atChest(_ w: CGPoint) -> Double {
            min(band(abs(w.x - N.x) / t, 0, 0.45, soft: 0.2), band((w.y - N.y) / max(R.y - N.y, 0.01), 0.15, 0.75, soft: 0.2))
        }
        return (min(atChest(L), atChest(Rw)), [.lEl, .lWr, .rEl, .rWr])
    }
    static let stride = PoseCheck(fix: "Walk slowly across — mid-step") { s, _ in
        guard let a = s[.lAn], let b = s[.rAn] else { return (0, [.lAn, .rAn]) }
        // Feet apart AND a knee bending (not just a wide stance).
        let bend = min(s.angle(.lHip, .lKn, .lAn) ?? 180, s.angle(.rHip, .rKn, .rAn) ?? 180)
        return (min(band(abs(a.x - b.x) / s.torso, 0.45, 3, soft: 0.25), band(bend, 120, 170, soft: 8)),
                [.lHip, .lKn, .lAn, .rHip, .rKn, .rAn])
    }
    static let backTurned = PoseCheck(fix: "Turn your back to me, face the view") { s, _ in
        (s.noseConfidence < 0.2 ? 1 : 0, [.neck])
    }
    static let armsOpen = PoseCheck(fix: "Open your arms wide") { s, _ in
        guard let N = s[.neck], let R = s[.root], let L = s[.lWr], let Rw = s[.rWr] else { return (0, [.lWr, .rWr]) }
        let t = s.torso
        let wide = min(band(abs(L.x - N.x) / t, 0.85, 4, soft: 0.3), band(abs(Rw.x - N.x) / t, 0.85, 4, soft: 0.3))
        let high = (L.y < R.y && Rw.y < R.y) ? 1.0 : 0.3
        return (wide * high, [.lSh, .lEl, .lWr, .rSh, .rEl, .rWr])
    }
    static let wideStance = PoseCheck(fix: "Feet wider than your shoulders") { s, _ in
        guard let a = s[.lAn], let b = s[.rAn] else { return (0, [.lAn, .rAn]) }
        let straight = min(band(s.angle(.lHip, .lKn, .lAn), 160, 180, soft: 15), band(s.angle(.rHip, .rKn, .rAn), 160, 180, soft: 15))
        return (min(band(abs(a.x - b.x) / s.torso, 0.7, 3, soft: 0.25), straight), [.lKn, .lAn, .rKn, .rAn])
    }
    static let bothHandsOnHips = PoseCheck(fix: "Both hands on your hips") { s, _ in
        (min(band(s.d(.lWr, .lHip), 0, 0.4, soft: 0.25), band(s.d(.rWr, .rHip), 0, 0.4, soft: 0.25)), [.lEl, .lWr, .rEl, .rWr])
    }
    static let sitting = PoseCheck(fix: "Have a seat") { s, _ in (s.isSitting ? 1 : 0, [.lHip, .lKn, .rHip, .rKn]) }
    /// Leaning forward: seen from the side the torso tilts; seen from the
    /// front it looks shorter against the shoulders (foreshortened).
    static let leanForward = PoseCheck(fix: "Lean forward from the hips") { s, _ in
        guard let N = s[.neck], let R = s[.root] else { return (0, [.neck, .root]) }
        let tilt = abs(atan2(N.x - R.x, R.y - N.y)) * 180 / .pi
        var short = 0.0
        // Real upright proportions: torso ≈ 1.25 × shoulder width; leaning
        // ~30° toward the camera brings it near 1.0.
        if let w = s.d(.lSh, .rSh), w > 0.01 { short = band(1 / w, 0, 1.1, soft: 0.15) }
        return (max(band(tilt, 12, 45, soft: 10), short), [.neck, .root])
    }
    static let elbowOnKnee = PoseCheck(fix: "Rest an elbow on your knee") { s, _ in
        // The elbow itself (hands resting on the knees don't count).
        let l = band(s.d(.lEl, .lKn), 0, 0.45, soft: 0.2)
        let r = band(s.d(.rEl, .rKn), 0, 0.45, soft: 0.2)
        return l >= r ? (l, [.lEl, .lWr, .lKn]) : (r, [.rEl, .rWr, .rKn])
    }
    /// Knees out wide, feet tucked in together at about knee height (an
    /// ordinary seat has the feet down below the knees).
    static let crossLegged = PoseCheck(fix: "Cross your legs, sit tall") { s, _ in
        guard let a = s[.lKn], let b = s[.rKn], let fa = s[.lAn], let fb = s[.rAn] else { return (0, [.lKn, .rKn]) }
        let t = s.torso
        let wideKnees = band(abs(a.x - b.x) / t, 0.9, 4, soft: 0.2)
        let feetIn = band(s.d(.lAn, .rAn), 0, 0.35, soft: 0.2)
        let tucked = band((max(fa.y, fb.y) - min(a.y, b.y)) / t, -1, 0.4, soft: 0.2)
        return (min(wideKnees, feetIn, tucked), [.lKn, .lAn, .rKn, .rAn])
    }
    static let oneKnee = PoseCheck(fix: "Drop to one knee — I'll shoot from low") { s, _ in
        guard let a = s[.lKn], let b = s[.rKn] else { return (0, [.lKn, .rKn]) }
        let drop = band(abs(a.y - b.y) / s.torso, 0.3, 3, soft: 0.15)
        let front = max(band(s.angle(.lHip, .lKn, .lAn), 60, 115, soft: 20), band(s.angle(.rHip, .rKn, .rAn), 60, 115, soft: 20))
        return (min(drop, front), [.lHip, .lKn, .lAn, .rHip, .rKn, .rAn])
    }
    static let upright = PoseCheck(fix: "Stand tall, shoulders back") { s, _ in
        guard let N = s[.neck], let R = s[.root] else { return (0, [.neck, .root]) }
        let tilt = abs(atan2(N.x - R.x, R.y - N.y)) * 180 / .pi
        return (band(tilt, 0, 12, soft: 10), [.neck, .root])
    }
    // Two or more people
    static let closeTogether = PoseCheck(fix: "Move closer together — shoulders touching") { s, all in
        guard all.count >= 2 else { return (0, []) }
        let sorted = all.sorted { $0.centre.x < $1.centre.x }
        var worst = 1.0
        for i in 1..<sorted.count {
            let a = sorted[i - 1], b = sorted[i]
            let gap = abs(b.centre.x - a.centre.x) / ((a.torso + b.torso) / 2)
            worst = min(worst, band(gap, 0, 1.15, soft: 0.5))
        }
        return (worst, [.lSh, .rSh])
    }
    static let handsJoined = PoseCheck(fix: "Hold hands") { s, all in
        guard all.count >= 2 else { return (0, []) }
        let sorted = all.sorted { $0.centre.x < $1.centre.x }
        let a = sorted[0], b = sorted[1]
        var best: CGFloat = 9
        for wa in [PJ.lWr, .rWr] { for wb in [PJ.lWr, .rWr] {
            if let x = a[wa], let y = b[wb] { best = min(best, hypot(x.x - y.x, x.y - y.y) / ((a.torso + b.torso) / 2)) }
        } }
        return (band(best, 0, 0.35, soft: 0.3), [.lWr, .rWr])
    }
    static let staggered = PoseCheck(fix: "Stagger heights — tallest at the back or centre") { s, all in
        guard all.count >= 3 else { return (0, []) }
        let ys = all.compactMap { $0[.neck]?.y }
        guard ys.count >= 3 else { return (0, []) }
        let t = all.map(\.torso).reduce(0, +) / CGFloat(all.count)
        let sorted = ys.sorted()
        var minStep: CGFloat = 9
        for i in 1..<sorted.count { minStep = min(minStep, sorted[i] - sorted[i - 1]) }
        let spread = (sorted.last! - sorted.first!) / t
        return (min(band(spread, 0.25, 3, soft: 0.2), band(minStep / t, 0.05, 3, soft: 0.05)), [.neck])
    }
    static let slightOverlap = PoseCheck(fix: "Close the gaps — overlap a little") { s, all in
        closeTogether.eval(s, all)
    }

    // Wireframes (100×140 box)
    static func fig(_ pts: [PJ: (CGFloat, CGFloat)]) -> [PJ: CGPoint] { pts.mapValues { CGPoint(x: $0.0, y: $0.1) } }
    static let standLegs: [PJ: (CGFloat, CGFloat)] = [.lHip: (57, 72), .rHip: (43, 72), .lKn: (63, 99), .lAn: (55, 127), .rKn: (42, 100), .rAn: (41, 128)]
    static func body(_ arms: [PJ: (CGFloat, CGFloat)], legs: [PJ: (CGFloat, CGFloat)] = standLegs,
                     nose: (CGFloat, CGFloat) = (51, 17), neck: (CGFloat, CGFloat) = (50, 28),
                     sh: ((CGFloat, CGFloat), (CGFloat, CGFloat)) = ((62, 34), (38, 34))) -> [PJ: CGPoint] {
        var d: [PJ: (CGFloat, CGFloat)] = [.nose: nose, .neck: neck, .lSh: sh.0, .rSh: sh.1]
        for (k, v) in arms { d[k] = v }
        for (k, v) in legs { d[k] = v }
        if let l = d[.lHip], let r = d[.rHip] { d[.root] = ((l.0 + r.0) / 2, (l.1 + r.1) / 2) }
        return fig(d)
    }
    static func scaled(_ f: [PJ: CGPoint], s: CGFloat, dx: CGFloat, dy: CGFloat) -> [PJ: CGPoint] {
        f.mapValues { CGPoint(x: $0.x * s + dx, y: $0.y * s + dy) }
    }

    static let relaxedArms: [PJ: (CGFloat, CGFloat)] = [.lEl: (67, 55), .lWr: (66, 74), .rEl: (33, 55), .rWr: (34, 74)]

    static let all: [Pose] = [
        Pose(id: "shift", name: "Weight shift", detail: "weight on the back leg",
             contexts: [.full], figures: [body(relaxedArms)], checks: [weightShift, upright]),
        Pose(id: "hip", name: "Hand on hip", detail: "elbow out, weight back",
             contexts: [.full, .half],
             figures: [body([.rEl: (27, 51), .rWr: (42, 66), .lEl: (67, 55), .lWr: (64, 75)])],
             checks: [handOnHip(), weightShift]),
        Pose(id: "pockets", name: "Hands in pockets", detail: "relaxed, elbows out",
             contexts: [.full, .half],
             figures: [body([.rEl: (31, 56), .rWr: (41, 72), .lEl: (69, 56), .lWr: (59, 72)],
                            legs: [.lHip: (57, 72), .rHip: (43, 72), .lKn: (58, 100), .lAn: (59, 128), .rKn: (43, 100), .rAn: (42, 128)])],
             checks: [bothHandsInPockets]),
        Pose(id: "shoulder", name: "Over the shoulder", detail: "turn away, look back",
             contexts: [.full, .half],
             figures: [body([.lEl: (57, 55), .lWr: (56, 74), .rEl: (44, 55), .rWr: (45, 74)],
                            legs: [.lHip: (54, 72), .rHip: (46, 72), .lKn: (56, 99), .lAn: (54, 127), .rKn: (45, 100), .rAn: (44, 128)],
                            nose: (46, 17), sh: ((55, 34), (45, 34)))],
             checks: [sideOn, faceToCamera]),
        Pose(id: "hair", name: "Hand in hair", detail: "one hand up, chin down",
             contexts: [.full, .half],
             figures: [body([.rEl: (26, 22), .rWr: (40, 10), .lEl: (67, 55), .lWr: (66, 74)])],
             checks: [handUpToHead]),
        Pose(id: "crossed", name: "Arms crossed", detail: "turn 45°, shoulders down",
             contexts: [.full, .half],
             figures: [body([.rEl: (34, 52), .rWr: (58, 50), .lEl: (66, 52), .lWr: (42, 50)],
                            legs: [.lHip: (57, 72), .rHip: (43, 72), .lKn: (57, 100), .lAn: (58, 128), .rKn: (43, 100), .rAn: (42, 128)])],
             checks: [armsCrossed]),
        Pose(id: "walk", name: "Walk across", detail: "slow steps, look ahead",
             contexts: [.full],
             figures: [body([.rEl: (36, 54), .rWr: (30, 70), .lEl: (64, 54), .lWr: (70, 68)],
                            legs: [.lHip: (57, 72), .rHip: (43, 72), .lKn: (61, 99), .lAn: (68, 127), .rKn: (38, 99), .rAn: (26, 118)])],
             checks: [stride]),
        Pose(id: "open", name: "Arms to the view", detail: "back to camera, arms wide",
             contexts: [.full],
             figures: [body([.rEl: (22, 30), .rWr: (6, 22), .lEl: (78, 30), .lWr: (94, 22)],
                            legs: [.lHip: (57, 72), .rHip: (43, 72), .lKn: (60, 100), .lAn: (62, 128), .rKn: (40, 100), .rAn: (38, 128)])],
             backToCamera: true, checks: [backTurned, armsOpen]),
        Pose(id: "power", name: "Power stance", detail: "feet wide, hands on hips",
             contexts: [.full],
             figures: [body([.rEl: (26, 52), .rWr: (42, 66), .lEl: (74, 52), .lWr: (58, 66)],
                            legs: [.lHip: (57, 72), .rHip: (43, 72), .lKn: (64, 100), .lAn: (70, 128), .rKn: (36, 100), .rAn: (30, 128)])],
             checks: [wideStance, bothHandsOnHips]),
        Pose(id: "kneel", name: "One knee", detail: "shoot from low",
             contexts: [.full],
             figures: [body([.rEl: (34, 60), .rWr: (36, 80), .lEl: (66, 62), .lWr: (64, 90)],
                            legs: [.lHip: (56, 76), .rHip: (44, 76), .lKn: (66, 96), .lAn: (66, 128), .rKn: (42, 126), .rAn: (28, 128)],
                            nose: (51, 11), neck: (50, 22), sh: ((62, 28), (38, 28)))],
             checks: [oneKnee]),
        Pose(id: "leansit", name: "Lean-forward sit", detail: "elbow on knee, chin on hand",
             contexts: [.sitting],
             // Drawn side-on so it reads at a glance: leaning in, elbow on knee, chin on hand.
             figures: [body([.rEl: (74, 84), .rWr: (67, 50), .lEl: (76, 86), .lWr: (68, 51)],
                            legs: [.lHip: (52, 90), .rHip: (50, 90), .lKn: (78, 91), .lAn: (76, 127), .rKn: (77, 90), .rAn: (75, 126)],
                            nose: (69, 40), neck: (62, 50), sh: ((63, 54), (61, 54)))],
             checks: [sitting, leanForward, elbowOnKnee]),
        Pose(id: "crosssit", name: "Cross-legged", detail: "sit tall, hands on knees",
             contexts: [.sitting],
             figures: [body([.rEl: (30, 74), .rWr: (24, 98), .lEl: (70, 74), .lWr: (76, 98)],
                            legs: [.lHip: (58, 92), .rHip: (42, 92), .lKn: (78, 104), .lAn: (44, 110), .rKn: (22, 104), .rAn: (56, 110)],
                            nose: (50, 32), neck: (50, 44), sh: ((62, 50), (38, 50)))],
             checks: [crossLegged, upright]),
        Pose(id: "together", name: "Close, looking out", detail: "arms around, same view",
             contexts: [.couple],
             figures: [scaled(body([.rEl: (36, 54), .rWr: (34, 74), .lEl: (70, 40), .lWr: (82, 34)]), s: 0.72, dx: -2, dy: 22),
                       scaled(body([.rEl: (30, 40), .rWr: (18, 34), .lEl: (66, 55), .lWr: (66, 74)]), s: 0.78, dx: 26, dy: 14)],
             checks: [closeTogether]),
        Pose(id: "handinhand", name: "Hand in hand", detail: "walk together, look at each other",
             contexts: [.couple],
             figures: [scaled(body([.rEl: (36, 54), .rWr: (30, 70), .lEl: (64, 56), .lWr: (76, 70)],
                                   legs: [.lHip: (57, 72), .rHip: (43, 72), .lKn: (60, 98), .lAn: (66, 127), .rKn: (38, 98), .rAn: (30, 126)]), s: 0.72, dx: -4, dy: 22),
                       scaled(body([.rEl: (36, 56), .rWr: (24, 70), .lEl: (64, 54), .lWr: (70, 68)],
                                   legs: [.lHip: (57, 72), .rHip: (43, 72), .lKn: (60, 98), .lAn: (66, 127), .rKn: (38, 98), .rAn: (30, 126)]), s: 0.78, dx: 30, dy: 14)],
             checks: [handsJoined]),
        Pose(id: "stagger", name: "Staggered group", detail: "heights varied, slight overlap",
             contexts: [.group],
             figures: [scaled(body(relaxedArms), s: 0.55, dx: 3, dy: 50),
                       scaled(body(relaxedArms), s: 0.62, dx: 27, dy: 30),
                       scaled(body(relaxedArms), s: 0.55, dx: 51, dy: 46)],
             checks: [staggered, slightOverlap]),
    ]

    static func poses(for ctx: PoseContext) -> [Pose] { all.filter { $0.contexts.contains(ctx) } }
}

// MARK: - Engine

@MainActor @Observable
final class PoseGuide {
    nonisolated static let shared = PoseGuide()
    nonisolated init() {}

    var enabled = UserDefaults.standard.object(forKey: "cc_poseGuide") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "cc_poseGuide")
            cachedEnabled = enabled
            if !enabled { people = []; present = false; match = 0; cue = nil }
        }
    }
    /// What's in frame right now, the poses that suit it and the one shown.
    private(set) var context: PoseContext = .full
    private(set) var poses: [Pose] = PoseLibrary.poses(for: .full)
    private(set) var index = 0
    var pose: Pose? { poses.indices.contains(index) ? poses[index] : nil }
    /// 0…1 how close they are; the next thing to fix.
    private(set) var match: Double = 0
    private(set) var cue: String?
    /// Detected people (main first), joints top-left normalized in the camera
    /// buffer, and which of the main person's joints are off.
    private(set) var people: [[PJ: CGPoint]] = []
    private(set) var offJoints: Set<PJ> = []
    private(set) var imageAspect: CGFloat = 3.0 / 4.0
    private(set) var matched = false
    /// Someone's in frame (changes rarely — what the chrome watches, so it
    /// doesn't redraw on every skeleton update).
    private(set) var present = false

    @ObservationIgnored nonisolated(unsafe) var cachedEnabled = UserDefaults.standard.object(forKey: "cc_poseGuide") as? Bool ?? false
    @ObservationIgnored nonisolated(unsafe) private var busy = false
    @ObservationIgnored nonisolated(unsafe) private var lastTick: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var cachedPoseIndex = 0
    @ObservationIgnored nonisolated(unsafe) private var cachedContext: PoseContext = .full
    @ObservationIgnored nonisolated(unsafe) private var matchedSince: Double?
    @ObservationIgnored nonisolated(unsafe) private var firedForPose = false
    @ObservationIgnored nonisolated(unsafe) private var pauseUntil: Double = 0
    @ObservationIgnored nonisolated(unsafe) private var contextSince: (PoseContext, Double)?
    @ObservationIgnored nonisolated(unsafe) private var smoothed = 0.0

    nonisolated private static let queue = DispatchQueue(label: "cam.poseguide", qos: .userInitiated)
    nonisolated private static let ctx = CIContext(options: [.cacheIntermediates: false])

    // MARK: Self-timer (hands-free)
    /// Shutter tap with Pose guide on: 3 s to get into place, then it shoots
    /// the moment the pose matches — or after 15 s anyway, like a timer.
    private(set) var timerArmed = false
    @ObservationIgnored nonisolated(unsafe) private var cachedTimerArmed = false
    @ObservationIgnored nonisolated(unsafe) private var timerSettleUntil: Double = 0
    @ObservationIgnored private var timerTask: Task<Void, Never>?

    func toggleTimer(camera: CameraManager) {
        if timerArmed { disarmTimer(); return }
        timerArmed = true; cachedTimerArmed = true
        timerSettleUntil = CACurrentMediaTime() + 3
        firedForPose = false; matchedSince = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 18_000_000_000)
            guard let self, !Task.isCancelled, self.timerArmed else { return }
            self.timerFire(camera: camera)                  // no match in time: shoot anyway
        }
    }

    func disarmTimer() {
        timerArmed = false; cachedTimerArmed = false
        timerTask?.cancel(); timerTask = nil
    }

    fileprivate func timerFire(camera: CameraManager) {
        disarmTimer()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let ext = externalShutter { ext() } else if !camera.isCapturing { camera.capturePhoto() }
        SmartTake.shared.blinkFlash(camera)                   // tells the people in front it fired
    }

    /// Tap on the card: next pose for this kind of shot.
    func next() {
        guard !poses.isEmpty else { return }
        index = (index + 1) % poses.count
        cachedPoseIndex = index
        matchedSince = nil; firedForPose = false; smoothed = 0
        match = 0; matched = false
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// A shot was taken: stand aside while it processes.
    nonisolated func noteShot() { pauseUntil = CACurrentMediaTime() + 1.0 }

    /// Set on the Sony: a matched pose / the self-timer fires this instead
    /// of the iPhone camera.
    @ObservationIgnored nonisolated(unsafe) var externalShutter: (@Sendable () -> Void)?

    /// A frame from another camera (the Sony's live view), upright.
    nonisolated func analyseExternal(_ cg: CGImage, time: Double, camera: CameraManager) {
        guard cachedEnabled else { return }
        analyse(cg, time: time, angle: 0, bufAspect: CGFloat(cg.width) / CGFloat(max(cg.height, 1)), camera: camera)
    }

    nonisolated func process(_ pixelBuffer: CVPixelBuffer, time: Double, camera: CameraManager) {
        guard cachedEnabled, !busy, time - lastTick >= 0.16, CACurrentMediaTime() >= pauseUntil,
              !camera.hasShotsInFlight,      // not while a photo renders (GPU contention)
              camera.currentDevice?.position == .back, !camera.cachedIsRecording else { return }
        lastTick = time
        busy = true
        let angle = FrameAdvisor.shared.cachedAngle
        let s = 512 / CGFloat(max(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer)))
        var small = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: CGAffineTransform(scaleX: s, y: s))
        if let o = FrameAdvisor.orientation(angle) { small = small.oriented(o) }
        small = small.transformed(by: CGAffineTransform(translationX: -small.extent.minX, y: -small.extent.minY))
        let bufAspect = CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / CGFloat(max(CVPixelBufferGetHeight(pixelBuffer), 1))
        Self.queue.async { [self] in
            defer { busy = false }
            // Copy out of the camera's buffer first (holding it starves the pool).
            guard let cg = Self.ctx.createCGImage(small, from: small.extent) else { return }
            analyse(cg, time: time, angle: angle, bufAspect: bufAspect, camera: camera)
        }
    }

    nonisolated private func analyse(_ cg: CGImage, time: Double, angle: Double, bufAspect: CGFloat, camera: CameraManager) {
        let req = VNDetectHumanBodyPoseRequest()
        guard (try? VNImageRequestHandler(cgImage: cg).perform([req])) != nil else { return }
        let aspect = CGFloat(cg.width) / CGFloat(max(cg.height, 1))
        var skels: [Skeleton] = []
        for obs in req.results ?? [] {
            guard let pts = try? obs.recognizedPoints(.all) else { continue }
            var p: [PJ: CGPoint] = [:], n: [PJ: CGPoint] = [:]
            var noseConf: Float = 0
            for (name, rp) in pts {
                guard let j = PJ.vision[name] else { continue }
                if j == .nose { noseConf = rp.confidence }
                guard rp.confidence > 0.3 else { continue }
                let tl = CGPoint(x: rp.location.x, y: 1 - rp.location.y)
                n[j] = tl
                p[j] = CGPoint(x: tl.x * aspect, y: tl.y)
            }
            if p[.root] == nil, let l = p[.lHip], let r = p[.rHip] {
                p[.root] = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
                if let a = n[.lHip], let b = n[.rHip] { n[.root] = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
            }
            guard p.count >= 6, p[.neck] != nil else { continue }
            skels.append(Skeleton(p: p, norm: n, noseConfidence: noseConf))
        }
        // Main subject: the biggest (by torso length), others only if they're
        // part of the shot (at least ~half its size).
        skels.sort { $0.torso > $1.torso }
        if let big = skels.first { skels = skels.filter { $0.torso >= big.torso * 0.5 } }
        guard let main = skels.first else {
            publish(people: [], off: [], match: 0, cue: nil, ctx: nil, matched: false, bufAspect: bufAspect)
            matchedSince = nil
            return
        }

        // What kind of shot: group, couple, sitting, half or full body.
        let ctxNow: PoseContext = skels.count >= 3 ? .group : skels.count == 2 ? .couple
            : main.isSitting ? .sitting : (main.hasFeet ? .full : .half)
        // Switch the pose list only once the context has held ~1 s.
        var ctxChange: PoseContext?
        if ctxNow != cachedContext {
            if let cs = contextSince, cs.0 == ctxNow {
                if time - cs.1 > 1 { ctxChange = ctxNow; cachedContext = ctxNow; cachedPoseIndex = 0; contextSince = nil
                    smoothed = 0; matchedSince = nil; firedForPose = false }
            } else { contextSince = (ctxNow, time) }
        } else { contextSince = nil }

        let list = PoseLibrary.poses(for: cachedContext)
        guard !list.isEmpty else { return }
        let pose = list[min(cachedPoseIndex, list.count - 1)]
        var worst: (Double, String, [PJ])?
        var total = 0.0
        for c in pose.checks {
            let (sc, joints) = c.eval(main, skels)
            total += sc
            if worst == nil || sc < worst!.0 { worst = (sc, c.fix, joints) }
        }
        // Every part has to be there: mostly the weakest check, a little the mean.
        let mean = total / Double(max(pose.checks.count, 1))
        let score = 0.7 * (worst?.0 ?? 0) + 0.3 * mean
        smoothed = smoothed * 0.5 + score * 0.5
        let isMatch = smoothed >= 0.85
        let off: Set<PJ> = (worst.map { $0.0 < 0.85 } ?? false) ? Set(worst!.2) : []
        let cue = isMatch ? "Hold it…" : (worst?.1 ?? pose.name)

        // Matched and held ~0.6 s: shoot, then on to the next pose.
        if isMatch {
            if matchedSince == nil { matchedSince = time }
            let settling = cachedTimerArmed && CACurrentMediaTime() < timerSettleUntil
            if time - matchedSince! > 0.6, !firedForPose, !settling {
                firedForPose = true
                let armed = cachedTimerArmed
                DispatchQueue.main.async {
                    if armed { PoseGuide.shared.timerFire(camera: camera) }
                    else {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        if let ext = self.externalShutter { ext() } else if !camera.isCapturing { camera.capturePhoto() }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { PoseGuide.shared.next() }
                }
            }
        } else {
            matchedSince = nil
            if smoothed < 0.6 { firedForPose = false }
        }

        let a = angle
        let people = skels.map { $0.norm.mapValues { Self.toBuffer($0, angle: a) } }
        publish(people: people, off: off, match: smoothed, cue: cue, ctx: ctxChange, matched: isMatch, bufAspect: bufAspect)
    }

    /// Upright → camera-buffer point (top-left normalized), as FrameAdvisor does for boxes.
    nonisolated static func toBuffer(_ p: CGPoint, angle: Double) -> CGPoint {
        switch angle {
        case 90: return CGPoint(x: 1 - p.y, y: p.x)
        case -90: return CGPoint(x: p.y, y: 1 - p.x)
        case 180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        default: return p
        }
    }

    nonisolated private func publish(people: [[PJ: CGPoint]], off: Set<PJ>, match: Double, cue: String?,
                                     ctx: PoseContext?, matched: Bool, bufAspect: CGFloat) {
        Task { @MainActor in
            let g = PoseGuide.shared
            guard g.cachedEnabled else { return }
            if let c = ctx {
                g.context = c; g.poses = PoseLibrary.poses(for: c); g.index = 0
            }
            g.people = people
            if g.present != !people.isEmpty { g.present = !people.isEmpty }
            if g.offJoints != off { g.offJoints = off }
            if abs(g.match - match) > 0.02 || (match == 0) != (g.match == 0) { g.match = match }
            if g.cue != cue { g.cue = cue }
            if g.matched != matched { g.matched = matched }
            if g.imageAspect != bufAspect { g.imageAspect = bufAspect }
        }
    }
}
