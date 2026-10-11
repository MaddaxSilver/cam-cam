//
//  MotionManager.swift
//  cam cam
//
//  Device-tilt tracking used to keep icons upright.
//

import SwiftUI
@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos
import Observation
import CoreMotion
import MediaPlayer
import MetalKit
import UniformTypeIdentifiers
import CoreLocation

// MARK: - MotionManager

@Observable final class MotionManager {
    var roll: Double = 0.0
    var pitch: Double = 0.0
    /// Snapped rotation angle for UI elements: 0, 90, -90, or 180
    var iconAngle: Double = 0.0
    var isLandscape: Bool = false
    /// Degrees the camera's horizon is tilted from level, accounting for the
    /// current device orientation. 0 = level. Use this for the LevelOverlay
    /// instead of raw `roll` (which only makes sense in portrait).
    var levelTilt: Double = 0.0
    @ObservationIgnored nonisolated(unsafe) var motionManager = CMMotionManager()

    func startUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 15.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion = motion else { return }
            self.roll = motion.attitude.roll * 180.0 / .pi
            self.pitch = motion.attitude.pitch * 180.0 / .pi

            // Determine device orientation from gravity
            let g = motion.gravity
            let newAngle: Double
            if abs(g.x) > abs(g.y) {
                // Landscape — negate to counter the tilt so text stays upright
                newAngle = g.x > 0 ? -90 : 90
            } else if g.y > 0.8 {
                // Upside down
                newAngle = 180
            } else {
                // Portrait (normal)
                newAngle = 0
            }
            let landscape = abs(g.x) > abs(g.y)

            // Compute orientation-aware level tilt from gravity. The screen's "down"
            // direction in device coords depends on current rotation:
            //   portrait → (0,-1)   landscape-left → (-1,0)
            //   upsideDown → (0,1)  landscape-right → (1,0)
            // Tilt = signed angle between screen-down and gravity (projected to XY).
            // Computed via the 2D cross/dot trick: angle = atan2(cross, dot).
            let tiltRad: Double
            switch newAngle {
            case 90:   tiltRad = atan2(-g.y, -g.x)       // landscape left
            case -90:  tiltRad = atan2(g.y, g.x)         // landscape right
            case 180:  tiltRad = atan2(-g.x, g.y)        // upside down
            default:   tiltRad = atan2(g.x, -g.y)        // portrait
            }
            let tiltDeg = tiltRad * 180.0 / .pi
            self.levelTilt = tiltDeg

            if newAngle != self.iconAngle {
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.iconAngle = newAngle
                    self.isLandscape = landscape
                }
            } else if landscape != self.isLandscape {
                self.isLandscape = landscape
            }
        }
    }

    func stopUpdates() {
        motionManager.stopDeviceMotionUpdates()
    }
}
