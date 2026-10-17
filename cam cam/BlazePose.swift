//
//  BlazePose.swift
//  cam cam
//
//  Google MediaPipe's BlazePose landmarker (Apache-2.0; SDK + model fetched
//  by scripts/fetch-models.sh), combined with Apple's body pose:
//
//   • Apple Vision stays the first pass (Neural Engine, several people,
//     no extra cost) and decides who's in frame;
//   • BlazePose adds what Vision doesn't have — heels, toes and finger tips
//     (33 points vs 19) — for the main subject, a few times a second, and
//     fills in ankles/wrists Vision missed.
//
//  Without the SDK (a fresh clone that hasn't run the script) this compiles
//  to nothing and the Pose guide uses Vision alone.
//

import CoreGraphics
import Foundation
#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision
import UIKit
#endif

nonisolated final class BlazePose: @unchecked Sendable {
    /// nil when the SDK or the model isn't bundled.
    static let shared: BlazePose? = BlazePose()

    #if canImport(MediaPipeTasksVision)
    private let landmarker: PoseLandmarker
    #endif
    private let lock = NSLock()

    private init?() {
        #if canImport(MediaPipeTasksVision)
        guard let path = Bundle.main.path(forResource: "pose_landmarker_full", ofType: "task") else { return nil }
        let o = PoseLandmarkerOptions()
        o.baseOptions.modelAssetPath = path
        o.runningMode = .image
        o.numPoses = 1
        o.minPoseDetectionConfidence = 0.5
        guard let lm = try? PoseLandmarker(options: o) else { return nil }
        landmarker = lm
        #else
        return nil
        #endif
    }

    /// The subject's extra joints, top-left normalised (x, y in 0…1), with
    /// visibility ≥ 0.5. BlazePose's left/right are the subject's own, like PJ.
    func detect(_ cg: CGImage) -> [PJ: CGPoint] {
        #if canImport(MediaPipeTasksVision)
        lock.lock(); defer { lock.unlock() }
        guard let img = try? MPImage(uiImage: UIImage(cgImage: cg)),
              let r = try? landmarker.detect(image: img), let lms = r.landmarks.first else { return [:] }
        let map: [Int: PJ] = [15: .lWr, 16: .rWr, 19: .lIdx, 20: .rIdx, 27: .lAn, 28: .rAn,
                              29: .lHeel, 30: .rHeel, 31: .lToe, 32: .rToe]
        var out: [PJ: CGPoint] = [:]
        for (i, j) in map where i < lms.count {
            let l = lms[i]
            if (l.visibility?.floatValue ?? 1) >= 0.5 { out[j] = CGPoint(x: CGFloat(l.x), y: CGFloat(l.y)) }
        }
        return out
        #else
        return [:]
        #endif
    }
}
