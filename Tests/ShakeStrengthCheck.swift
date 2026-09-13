import Foundation
import simd

@main struct ShakeStrengthCheck {
    static func main() {
        func close(_ a: Float, _ b: Float) { precondition(abs(a-b) < 0.0002, "\(a) != \(b)") }
        close(simd_length(MotionSample.responsiveAcceleration(SIMD3(0.15,0,0))), 0.15)
        close(simd_length(MotionSample.responsiveAcceleration(SIMD3(0.65,0,0))), 1.95)
        close(simd_length(MotionSample.responsiveAcceleration(SIMD3(2.7,0,0))), 8.1)
        precondition(MotionSample.responsiveAcceleration(SIMD3(Float.nan,0,0)) == .zero)
        precondition(MotionSample.responsiveAcceleration(SIMD3(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, 0)) == .zero)
        let below = simd_length(MotionSample.responsiveAcceleration(SIMD3(0.1499, 0, 0)))
        let above = simd_length(MotionSample.responsiveAcceleration(SIMD3(0.1501, 0, 0)))
        precondition(above >= below && above - below < 0.001)
        let diagonal = SIMD3<Float>(0.4, -0.2, 0.1)
        let enhanced = MotionSample.responsiveAcceleration(diagonal)
        precondition(simd_dot(diagonal, enhanced) > 0)
        close(simd_length(simd_normalize(diagonal) - simd_normalize(enhanced)), 0)
        let raw = SIMD3<Float>(0.8, -0.4, 0.2)
        precondition(MotionSample.mappedAcceleration(raw, reducedMotion: true) == raw * 0.2)
        precondition(MotionSample.mappedAcceleration(raw, reducedMotion: false) == MotionSample.responsiveAcceleration(raw))
        // A rapid accessibility-mode change cannot retain an earlier gain.
        precondition(MotionSample.mappedAcceleration(raw, reducedMotion: true) != MotionSample.mappedAcceleration(raw, reducedMotion: false))
        let saturated = MotionSample(acceleration: MotionSample.responsiveAcceleration(SIMD3(12,0,0))).safeAcceleration
        precondition(simd_length(saturated) <= 12.0001)
        print("PASS shake strength: quiet exact, 3x vigorous, existing 12g cap")
    }
}
