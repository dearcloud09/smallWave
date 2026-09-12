import Foundation
import simd

@main
struct MotionInputCheck {
    static func main() {
        var suite = MotionInputSuite()
        suite.run("100 Hz constant input preserves signed integral at 30 Hz", suite.constantInputPreservesIntegral)
        suite.run("within-frame reversal keeps step order and net impulse", suite.reversalKeepsOrder)
        suite.run("3, 4, and 6 step plans honor remainder", suite.stepPlansHonorRemainder)
        suite.run("overlap prefix and raw 3g cap cannot amplify force", suite.overlapPrefixDoesNotAmplify)
        suite.run("stale, future, invalid, pause, and repeated requests are safe", suite.boundaryCases)
        suite.run("slow frame drops old input but retains recent window", suite.slowFrameUsesRecentWindow)
        suite.run("30/60 Hz jitter trace preserves ordered steps", suite.frameRateTraceIsInvariant)
        print("PASS: \(suite.passed) ordered motion-input checks")
    }
}

private struct MotionInputSuite {
    private(set) var passed = 0
    private let step: Float = 1 / 120

    mutating func run(_ name: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS: \(name)") }
        catch { fputs("FAIL: \(name) — \(error)\n", stderr); exit(1) }
    }

    func constantInputPreservesIntegral() throws {
        var history = MotionInputHistory()
        append(&history, at: 0, acceleration: SIMD3(2, 0, 0))
        _ = history.samples(for: plan(1), at: 0) // establish app-start boundary
        var nextSensor = 0.01
        var impulse: Float = 0
        for frame in 1...30 {
            let draw = Double(frame) / 30 + 0.004
            while nextSensor <= draw {
                append(&history, at: nextSensor, acceleration: SIMD3(2, 0, 0))
                nextSensor += 0.01
            }
            let values = history.samples(for: plan(4), at: draw)
            impulse += values.reduce(Float(0)) { $0 + $1.acceleration.x * step }
        }
        // Startup intentionally suppresses the first unfinished sensor interval;
        // after that, the 1 s trace may defer at most one 10 ms interval.
        try require(impulse >= 1.98 && impulse <= 2.0002, "100 Hz / 30 Hz integral changed: \(impulse)")
    }

    func reversalKeepsOrder() throws {
        var history = MotionInputHistory()
        append(&history, at: 0, acceleration: .zero)
        _ = history.samples(for: plan(1), at: 0)
        append(&history, at: 0.008, acceleration: SIMD3(3, 0, 0))
        append(&history, at: 0.016, acceleration: SIMD3(-3, 0, 0))
        append(&history, at: 0.024, acceleration: .zero)
        let values = history.samples(for: plan(4), at: 4.0 / 120)
        let impulse = values.reduce(Float(0)) { $0 + $1.acceleration.x * step }
        try require(values[1].acceleration.x > 0 && values[2].acceleration.x < 0,
                    "step order lost: \(values.map { $0.acceleration.x })")
        try require(abs(impulse) < 0.0002, "opposite pulse net changed: \(impulse)")
    }

    func stepPlansHonorRemainder() throws {
        for expectedCount in [3, 4, 6] {
            let elapsed = min(0.05, step * Float(expectedCount) + 0.0001)
            let simulation = LiquidSimulation()
            let actualPlan = simulation.stepPlan(forElapsed: elapsed)
            try require(actualPlan.count == expectedCount, "actual plan count \(actualPlan.count), expected \(expectedCount)")
            var history = MotionInputHistory()
            append(&history, at: 1, acceleration: SIMD3(2, 0, 0))
            _ = history.samples(for: plan(1), at: 1)
            let end = 1.08
            let start = end - Double(actualPlan.count) * Double(actualPlan.stepDuration)
            var sensor = start
            while sensor < end {
                append(&history, at: sensor, acceleration: SIMD3(2, 0, 0))
                sensor += 0.01
            }
            append(&history, at: end, acceleration: .zero)
            let values = history.samples(for: actualPlan, at: end + Double(actualPlan.remainder))
            try require(values.count == actualPlan.count, "wrong count \(values.count), expected \(actualPlan.count)")
            let impulse = values.reduce(Float(0)) { $0 + $1.acceleration.x * step }
            try require(abs(impulse - Float(end - start) * 2) < 0.0002,
                        "remainder shifted actual plan \(expectedCount): \(impulse)")
        }
    }

    func overlapPrefixDoesNotAmplify() throws {
        var history = MotionInputHistory()
        append(&history, at: 0, acceleration: .zero)
        _ = history.samples(for: plan(1), at: 0)
        append(&history, at: 0.03, acceleration: SIMD3(100, 0, 0)) // input cap is 3g
        append(&history, at: 0.04, acceleration: .zero)
        _ = history.samples(for: plan(4), at: 4.0 / 120) // consumes through 1/30
        let suffix = history.samples(for: plan(1), at: 0.04)[0]
        try require(abs(suffix.acceleration.x - 2.4) < 0.0002,
                    "partial prefix was renormalized: \(suffix.acceleration.x)")
        try require(simd_length(suffix.acceleration) <= 3.0001,
                    "raw 3g cap was amplified: \(suffix.acceleration)")
    }

    func boundaryCases() throws {
        var history = MotionInputHistory()
        append(&history, at: 2, acceleration: .zero)
        try require(history.samples(for: LiquidStepPlan(count: 0, stepDuration: step, remainder: 0), at: 2).isEmpty,
                    "invalid plan consumed history")
        let initial = history.samples(for: plan(1), at: 2)
        try require(nearlyEqual(initial[0].acceleration, .zero), "startup created impulse")
        append(&history, at: 2.2, acceleration: SIMD3(2, 0, 0))
        let beforeFuture = history.samples(for: plan(1), at: 2.01)
        try require(nearlyEqual(beforeFuture[0].acceleration, .zero), "future sample was used early")
        let repeated = history.samples(for: plan(1), at: 2.01)
        try require(nearlyEqual(repeated[0].acceleration, .zero), "repeated draw replayed input")
        history.discardPending(at: 2.2)
        let afterPause = history.samples(for: plan(1), at: 2.21)
        try require(nearlyEqual(afterPause[0].acceleration, .zero), "pause retained acceleration")
        let stale = history.samples(for: plan(1), at: 2.8)
        try require(nearlyEqual(stale[0].gravity, SIMD3(0, -1, 0)) && nearlyEqual(stale[0].acceleration, .zero),
                    "stale input survived")
    }

    func slowFrameUsesRecentWindow() throws {
        var history = MotionInputHistory()
        append(&history, at: 0, acceleration: .zero)
        _ = history.samples(for: plan(1), at: 0)
        append(&history, at: 0.01, acceleration: SIMD3(3, 0, 0))
        append(&history, at: 0.02, acceleration: .zero)
        append(&history, at: 0.16, acceleration: SIMD3(3, 0, 0))
        append(&history, at: 0.17, acceleration: .zero)
        let slow = history.samples(for: plan(6), at: 0.20) // window [0.15, 0.20]
        let impulse = slow.reduce(Float(0)) { $0 + $1.acceleration.x * step }
        try require(abs(impulse - 0.03) < 0.0002, "slow frame lost/replayed wrong input: \(impulse)")
        let next = history.samples(for: plan(1), at: 0.208)
        try require(nearlyEqual(next[0].acceleration, .zero), "old impulse replayed after slow frame")
    }

    func frameRateTraceIsInvariant() throws {
        let at30 = replay(Array(repeating: Float(1.0 / 30), count: 3))
        let at60 = replay(Array(repeating: Float(1.0 / 60), count: 6))
        var jitter: [Float] = []
        var total: Float = 0
        let jitterDuration: Float = 0.1001
        let pattern: [Float] = [0.016, 0.017, 0.034, 0.008]
        var patternIndex = 0
        while total + pattern[patternIndex] <= jitterDuration {
            let duration = pattern[patternIndex]
            jitter.append(duration); total += duration
            patternIndex = (patternIndex + 1) % pattern.count
        }
        if total < jitterDuration { jitter.append(jitterDuration - total) }
        let irregular = replay(jitter)
        try require(at30.count == at60.count && at60.count == irregular.count,
                    "fixed step count changed: \(at30.count), \(at60.count), \(irregular.count)")
        try require(at30.contains { $0.acceleration.x > 1 } && at30.contains { $0.acceleration.x < -1 },
                    "trace fixture did not exercise both shake directions")
        let absoluteImpulse = at30.reduce(Float(0)) { $0 + abs($1.acceleration.x) * step }
        try require(absoluteImpulse > 0.10, "trace fixture lost its nonzero agitation: \(absoluteImpulse)")
        for index in at30.indices {
            try require(nearlyEqual(at30[index].acceleration, at60[index].acceleration, tolerance: 0.0003) &&
                        nearlyEqual(at30[index].acceleration, irregular[index].acceleration, tolerance: 0.0003),
                        "frame schedule changed step \(index): \(at30[index].acceleration), \(at60[index].acceleration), \(irregular[index].acceleration)")
        }
    }

    private func replay(_ schedule: [Float]) -> [MotionSample] {
        var history = MotionInputHistory()
        let simulation = LiquidSimulation()
        append(&history, at: 0, acceleration: traceAcceleration(at: 0))
        _ = history.samples(for: plan(1), at: 0)
        var timestamp: Double = 0
        var nextSensor = 0.01
        var output: [MotionSample] = []
        for elapsed in schedule {
            timestamp += Double(elapsed)
            while nextSensor <= timestamp {
                append(&history, at: nextSensor, acceleration: traceAcceleration(at: nextSensor))
                nextSensor += 0.01
            }
            let actualPlan = simulation.stepPlan(forElapsed: elapsed)
            let values = history.samples(for: actualPlan, at: timestamp)
            output += values
            simulation.advance(elapsed: elapsed, motion: MotionSample(), stepMotions: values)
        }
        return output
    }

    private func traceAcceleration(at time: TimeInterval) -> SIMD3<Float> {
        if (0.02..<0.04).contains(time) { return SIMD3(3, 0, 0) }
        if (0.04..<0.06).contains(time) { return SIMD3(-3, 0, 0) }
        if (0.07..<0.09).contains(time) { return SIMD3(1.5, -0.5, 0.25) }
        return .zero
    }

    private func plan(_ count: Int, remainder: Float = 0) -> LiquidStepPlan {
        LiquidStepPlan(count: count, stepDuration: step, remainder: remainder)
    }

    private func append(_ history: inout MotionInputHistory, at timestamp: TimeInterval,
                        acceleration: SIMD3<Float>) {
        history.append(gravity: SIMD3(0, -1, 0), acceleration: acceleration, timestamp: timestamp,
                       receivedAt: timestamp)
    }

    private func nearlyEqual(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>, tolerance: Float = 0.0001) -> Bool {
        simd_length(lhs - rhs) <= tolerance
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }
}
