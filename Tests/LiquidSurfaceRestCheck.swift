import Foundation
import simd

@main
struct LiquidSurfaceRestCheck {
    static func main() {
        var suite = Suite()
        suite.run("quiet liquid settles into the reconstruction filter", suite.quietLiquidSettles)
        suite.run("acceleration, energy, and rotation prevent settling", suite.busySignalsPreventSettling)
        suite.run("a new shake releases the filter promptly", suite.shakeReleasesPromptly)
        suite.run("zero elapsed pause preserves state", suite.zeroElapsedPreservesState)
        suite.run("reset and invalid inputs return finite defaults", suite.resetAndInvalidInputs)
        suite.run("gravity sets a finite perpendicular filter orientation", suite.orientationParameters)
        suite.run("coherence rejects detached, moving, and invalid bulk", suite.coherenceGate)
        suite.run("30/10 Hz quiet time follows elapsed time and long gaps reset", suite.elapsedTimeBehavior)
        print("PASS: \(suite.passed) liquid-surface rest checks")
    }
}

private struct Suite {
    private(set) var passed = 0
    private let dt: Float = 1 / 120
    private let calmGravity = SIMD3<Float>(0, -1, 0)

    mutating func run(_ name: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS: \(name)") }
        catch { fputs("FAIL: \(name) — \(error)\n", stderr); exit(1) }
    }

    func quietLiquidSettles() throws {
        var state = LiquidSurfaceRestState()
        advance(&state, seconds: 1.6)
        try require(state.strength > 0.4 && state.strength < 0.6, "quiet response: \(state.strength)")
        try require(isValid(state.parameters), "quiet parameters: \(state.parameters)")
    }

    func busySignalsPreventSettling() throws {
        for signal in [BusySignal.acceleration, .energy, .rotation] {
            var state = LiquidSurfaceRestState()
            switch signal {
            case .acceleration: advance(&state, seconds: 1.8, acceleration: 0.06)
            case .energy: advance(&state, seconds: 1.8, energy: 0.13)
            case .rotation:
                for index in 0..<216 {
                    let gravity = index.isMultiple(of: 2) ? calmGravity : SIMD3<Float>(0.6, -0.8, 0)
                    state.update(elapsed: dt, gravity: gravity, maximumAcceleration: 0, energy: 0, coherentBulk: true)
                }
            }
            try require(state.strength == 0, "\(signal) enabled filter: \(state.strength)")
        }
    }

    func shakeReleasesPromptly() throws {
        var state = LiquidSurfaceRestState()
        advance(&state, seconds: 2)
        let before = state.strength
        for _ in 0..<3 {
            state.update(elapsed: dt, gravity: calmGravity, maximumAcceleration: 0.5, energy: 0, coherentBulk: true)
        }
        try require(before > 0.5 && state.strength < before * 0.3, "shake release: \(before), \(state.strength)")
    }

    func zeroElapsedPreservesState() throws {
        var state = LiquidSurfaceRestState()
        advance(&state, seconds: 1.6)
        let strength = state.strength, parameters = state.parameters
        state.update(elapsed: 0, gravity: SIMD3(Float.nan, 0, 0),
                     maximumAcceleration: Float.nan, energy: Float.nan, coherentBulk: false)
        try require(state.strength == strength && state.parameters == parameters, "elapsed zero changed pause")
    }

    func resetAndInvalidInputs() throws {
        var state = LiquidSurfaceRestState()
        advance(&state, seconds: 1.6)
        state.reset()
        try require(state.strength == 0 && state.parameters == SIMD4<Float>(1, 0, 1, 0), "explicit reset")
        advance(&state, seconds: 1.6)
        state.update(elapsed: dt, gravity: SIMD3(Float.nan, 0, 0), maximumAcceleration: 0, energy: 0, coherentBulk: true)
        try require(state.strength == 0 && state.parameters == SIMD4<Float>(1, 0, 1, 0), "invalid reset")
    }

    func orientationParameters() throws {
        var state = LiquidSurfaceRestState()
        state.update(elapsed: dt, gravity: SIMD3(0.6, -0.8, 0), maximumAcceleration: 0, energy: 0, coherentBulk: true)
        let parameters = state.parameters
        try require(isValid(parameters) && abs(parameters.x - 0.8) < 0.0001 && abs(parameters.y - 0.6) < 0.0001,
                    "orientation: \(parameters)")
    }

    func coherenceGate() throws {
        let stable = particles([0, 0.05, 0.1])
        try require(LiquidSurfaceRestState.isCoherentBulk(particles: stable, connectionRadius: 0.06), "connected bulk rejected")
        let candidates = [[1], [0, 2], [1]]
        try require(LiquidSurfaceRestState.isCoherentBulk(particles: stable, connectionRadius: 0.06,
                                                           neighbourCandidates: candidates),
                    "candidate branch rejected connected bulk")
        try require(!LiquidSurfaceRestState.isCoherentBulk(particles: particles([0, 0.05, 0.1, 0.5]), connectionRadius: 0.06), "detached singleton accepted")
        try require(!LiquidSurfaceRestState.isCoherentBulk(particles: particles([0, 0.05, 0.1, 0.5, 0.55]), connectionRadius: 0.06), "detached cluster accepted")
        try require(!LiquidSurfaceRestState.isCoherentBulk(particles: particles([0, 0.05, 0.1], fastAt: 2), connectionRadius: 0.06), "fast subgroup accepted")
        let detached = particles([0, 0.05, 0.1, 0.5])
        try require(!LiquidSurfaceRestState.isCoherentBulk(particles: detached, connectionRadius: 0.06,
                                                            neighbourCandidates: [[1], [0, 2], [1, 3], [2]]),
                    "stale candidate edge bypassed current distance")
        try require(!LiquidSurfaceRestState.isCoherentBulk(particles: stable, connectionRadius: 0.06,
                                                            neighbourCandidates: [[1], [0, 7], [1]]),
                    "invalid candidate index was accepted")
        let invalid = [LiquidParticle(position: SIMD3(Float.nan, 0, 0), previous: .zero)]
        try require(!LiquidSurfaceRestState.isCoherentBulk(particles: [], connectionRadius: 0.06) &&
                    !LiquidSurfaceRestState.isCoherentBulk(particles: stable, connectionRadius: 0) &&
                    !LiquidSurfaceRestState.isCoherentBulk(particles: invalid, connectionRadius: 0.06), "invalid bulk accepted")

        var state = LiquidSurfaceRestState()
        advance(&state, seconds: 2)
        state.update(elapsed: dt, gravity: calmGravity, maximumAcceleration: 0, energy: 0, coherentBulk: false)
        try require(state.strength == 0, "incoherent frame faded instead of failing closed")
    }

    func elapsedTimeBehavior() throws {
        var at30 = LiquidSurfaceRestState(), at10 = LiquidSurfaceRestState()
        advance(&at30, seconds: 3, elapsed: 1 / 30)
        advance(&at10, seconds: 3, elapsed: 1 / 10)
        try require(abs(at30.strength - at10.strength) < 0.01, "rate difference: \(at30.strength), \(at10.strength)")
        at30.update(elapsed: 0.251, gravity: calmGravity, maximumAcceleration: 0, energy: 0, coherentBulk: true)
        try require(at30.strength == 0 && at30.parameters == SIMD4<Float>(1, 0, 1, 0), "long gap did not reset")
    }

    private func advance(_ state: inout LiquidSurfaceRestState, seconds: Float, elapsed: Float? = nil,
                         acceleration: Float = 0, energy: Float = 0) {
        var remaining = seconds
        let increment = elapsed ?? dt
        while remaining > 0 {
            let duration = min(increment, remaining)
            state.update(elapsed: duration, gravity: calmGravity, maximumAcceleration: acceleration, energy: energy,
                         coherentBulk: true)
            remaining -= duration
        }
    }

    private func particles(_ x: [Float], fastAt: Int? = nil) -> [LiquidParticle] {
        x.enumerated().map { index, value in
            LiquidParticle(position: SIMD3(value, 0, 0), previous: SIMD3(value, 0, 0),
                           velocity: index == fastAt ? SIMD3(0.251, 0, 0) : .zero)
        }
    }

    private func isValid(_ value: SIMD4<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite &&
            abs(simd_length(SIMD2(value.x, value.y)) - 1) < 0.0001 && (1...3).contains(value.z) && (0...1).contains(value.w)
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message) }
    }
    private enum BusySignal: CustomStringConvertible {
        case acceleration, energy, rotation
        var description: String { switch self { case .acceleration: return "acceleration"; case .energy: return "energy"; case .rotation: return "rotation" } }
    }
    private struct Failure: Error, CustomStringConvertible { let description: String; init(_ description: String) { self.description = description } }
}
