import Foundation
import simd

@main
struct CoreTests {
    static func main() {
        var suite = PhysicsBoundarySuite()
        suite.run("finite input and bounded particle/boat positions", suite.finiteInputAndBounds)
        suite.run("suspend and elapsed cap discard backlog", suite.suspendAndElapsedCapDiscardBacklog)
        suite.run("motion duration matches accepted fixed steps", suite.motionDurationMatchesAcceptedSteps)
        suite.run("ordered shake batch matches individual fixed steps", suite.orderedShakeBatchMatchesIndividualSteps)
        suite.run("particle count is conserved", suite.particleCountIsConserved)
        suite.run("rightward tilt moves liquid center right", suite.rightTiltMovesMassRight)
        suite.run("inversion moves liquid into upper half", suite.inversionMovesMassUp)
        suite.run("depth gravity changes average depth", suite.depthGravityChangesAverageDepth)
        suite.run("flat depth span survives and upright water level recovers", suite.flatDepthSpanAndUprightRecovery)
        suite.run("shake bubbles are bounded and expire", suite.shakeBubblesAreBoundedAndExpire)
        suite.run("energy damps after a shake", suite.energyDampsAfterShake)
        suite.run("boat submerges then re-floats after inversion", suite.boatSubmergesThenRefloats)
        suite.run("boat remains finite under stress", suite.boatRemainsFiniteUnderStress)
        suite.run("upper cohesion setting stays local under stress", suite.upperCohesionStaysLocal)
        suite.run("interface bubbles follow the surface without changing the liquid", suite.interfaceBubbleTracking)
        print("PASS: \(suite.passed) physics boundary checks")
    }
}

private struct PhysicsBoundarySuite {
    private(set) var passed = 0
    private func makeSimulation() -> LiquidSimulation {
        LiquidSimulation(cohesionStrength: ProcessInfo.processInfo.environment["SMALLWAVE_COHESION"] == "0" ? 0 : LiquidSimulation.defaultCohesionStrength,
                         interfaceBubbles: ProcessInfo.processInfo.environment["SMALLWAVE_BUBBLES"] != "0" && LiquidSimulation.defaultInterfaceBubbles)
    }

    mutating func run(_ name: String, _ test: () throws -> Void) {
        do {
            try test()
            passed += 1
            print("PASS: \(name)")
        } catch {
            fputs("FAIL: \(name) — \(error)\n", stderr)
            exit(1)
        }
    }

    func finiteInputAndBounds() throws {
        let simulation = makeSimulation()
        let originalCount = simulation.particles.count
        simulation.advance(elapsed: .nan, motion: MotionSample(gravity: SIMD3(.infinity, 0, 0), acceleration: SIMD3(.nan, 0, 0)))
        advance(simulation, seconds: 1.0, motion: MotionSample(gravity: SIMD3(.infinity, .nan, -.infinity), acceleration: SIMD3(.infinity, .nan, 0)))
        try assertFiniteAndBounded(simulation, label: "non-finite input")
        try require(simulation.particles.count == originalCount, "particle count changed after non-finite input: \(simulation.particles.count), expected \(originalCount)")
    }

    func suspendAndElapsedCapDiscardBacklog() throws {
        let simulation = makeSimulation()
        let normal = MotionSample()
        simulation.advance(elapsed: simulation.fixedStep * 0.75, motion: normal)
        simulation.suspend()
        let stepsBeforeHalfFrame = simulation.steps
        simulation.advance(elapsed: simulation.fixedStep * 0.75, motion: normal)
        try require(simulation.steps == stepsBeforeHalfFrame, "suspend retained a partial-frame backlog: before=\(stepsBeforeHalfFrame), after=\(simulation.steps)")

        let stepsBeforeLongPause = simulation.steps
        let timeBeforeLongPause = simulation.time
        simulation.advance(elapsed: 3_600, motion: normal)
        let stepDelta = simulation.steps - stepsBeforeLongPause
        let timeDelta = simulation.time - timeBeforeLongPause
        try require(stepDelta <= 6 && timeDelta <= simulation.fixedStep * 6.01, "long elapsed simulated too much suspended time: steps=\(stepDelta), time=\(timeDelta)")

        simulation.advance(elapsed: simulation.fixedStep * 0.75, motion: normal)
        simulation.reset()
        simulation.advance(elapsed: simulation.fixedStep * 0.75, motion: normal)
        try require(simulation.steps == 0 && simulation.time == 0, "reset retained a partial-frame backlog: steps=\(simulation.steps), time=\(simulation.time)")
    }

    func particleCountIsConserved() throws {
        let simulation = makeSimulation()
        let originalCount = simulation.particles.count
        advance(simulation, seconds: 1.5, motion: MotionSample(gravity: SIMD3(0.72, -0.58, 0.22), acceleration: SIMD3(4, -3, 2)))
        try require(simulation.particles.count == originalCount, "particle count changed under stress: \(simulation.particles.count), expected \(originalCount)")
        try assertFiniteAndBounded(simulation, label: "particle conservation")
    }

    func motionDurationMatchesAcceptedSteps() throws {
        let simulation = makeSimulation()
        // Irregular render intervals exercise fractional steps, no-step draws,
        // rejected elapsed values and the bounded catch-up after a slow frame.
        let intervals: [Float] = [0.004, 0.017, 0.031, 0, .nan, -1, 0.007,
                                  0.034, 0.18, 0.002, 0.029, 0.036]
        for elapsed in intervals {
            let before = simulation.steps
            let duration = simulation.simulatedDuration(forElapsed: elapsed)
            try require(simulation.steps == before, "querying the duration advanced the simulation")
            simulation.advance(elapsed: elapsed, motion: MotionSample())
            let actual = Float(simulation.steps - before) * simulation.fixedStep
            try require(duration == actual, "motion duration \(duration) differed from actual \(actual) for elapsed \(elapsed)")
        }
        simulation.suspend()
        try require(simulation.simulatedDuration(forElapsed: simulation.fixedStep * 0.5) == 0,
                    "suspended remainder entered the next motion window")
    }

    func orderedShakeBatchMatchesIndividualSteps() throws {
        let batched = makeSimulation(), individual = makeSimulation(), averaged = makeSimulation()
        let positive = MotionSample(gravity: SIMD3(0, -1, 0), acceleration: SIMD3(3, 0, 0))
        let negative = MotionSample(gravity: SIMD3(0, -1, 0), acceleration: SIMD3(-3, 0, 0))
        let motions = [positive, positive, negative, negative]
        let elapsed = batched.fixedStep * Float(motions.count)
        try require(batched.stepPlan(forElapsed: elapsed).count == motions.count, "fixture needs four fixed steps")
        batched.advance(elapsed: elapsed, motion: MotionSample(), stepMotions: motions)
        for motion in motions { individual.advance(elapsed: individual.fixedStep, motion: motion) }
        averaged.advance(elapsed: elapsed, motion: MotionSample())
        var changedByOrder: Float = 0
        for index in batched.particles.indices {
            try require(batched.particles[index].position == individual.particles[index].position &&
                        batched.particles[index].velocity == individual.particles[index].velocity,
                        "batched motion differed from sequential physics at particle \(index)")
            changedByOrder = max(changedByOrder, simd_length(batched.particles[index].position - averaged.particles[index].position))
        }
        try require(changedByOrder > 0.0001, "opposite within-frame pulses collapsed into their zero average")
        print("METRIC: within-frame direction order displacement=\(changedByOrder)")
    }

    func rightTiltMovesMassRight() throws {
        let simulation = makeSimulation()
        let before = average(simulation.particles.map(\.position.x))
        advance(simulation, seconds: 1.6, motion: MotionSample(gravity: SIMD3(0.82, -0.57, 0), acceleration: .zero))
        let after = average(simulation.particles.map(\.position.x))
        try require(after > before + 0.025, "center x did not move right enough: before=\(before), after=\(after), delta=\(after - before)")
    }

    func inversionMovesMassUp() throws {
        let simulation = makeSimulation()
        let before = average(simulation.particles.map(\.position.y))
        advance(simulation, seconds: 1.8, motion: MotionSample(gravity: SIMD3(0, 1, 0), acceleration: .zero))
        let after = average(simulation.particles.map(\.position.y))
        try require(after > 0, "inversion did not move mass to upper half: before=\(before), after=\(after)")
    }

    func depthGravityChangesAverageDepth() throws {
        let simulation = makeSimulation()
        let before = average(simulation.particles.map(\.position.z))
        advance(simulation, seconds: 1.2, motion: MotionSample(gravity: SIMD3(0, 0, 1), acceleration: .zero))
        let after = average(simulation.particles.map(\.position.z))
        try require(after > before + 0.015, "z gravity did not increase average depth: before=\(before), after=\(after), delta=\(after - before)")
    }

    func flatDepthSpanAndUprightRecovery() throws {
        let simulation = makeSimulation()
        let originalCount = simulation.particles.count
        let upright = MotionSample(gravity: SIMD3(0, -1, 0), acceleration: .zero)
        let flat = MotionSample(gravity: SIMD3(0, 0, -1), acceleration: .zero)

        // These are particle-distribution proxies, not a rendered waterline or an aesthetic assertion.
        advance(simulation, seconds: 4, motion: upright)
        let baselineY95 = quantile(simulation.particles.map(\.position.y), 0.95)
        advance(simulation, seconds: 4, motion: flat)
        let flatZ = simulation.particles.map(\.position.z)
        let flatDepthSpan = quantile(flatZ, 0.95) - quantile(flatZ, 0.05)
        try require(flatDepthSpan >= simulation.spacing * 0.7,
                    "flat gravity collapsed the 95% depth span: span=\(flatDepthSpan), spacing=\(simulation.spacing)")
        try require(simulation.particles.count == originalCount, "particle count changed while flat: \(simulation.particles.count), expected \(originalCount)")
        try assertFiniteAndBounded(simulation, label: "flat depth span")

        advance(simulation, seconds: 4, motion: upright)
        let returnY95 = quantile(simulation.particles.map(\.position.y), 0.95)
        let drift = abs(returnY95 - baselineY95)
        try require(drift <= simulation.spacing * 1.5,
                    "upright y95 did not recover after flat gravity: baseline=\(baselineY95), return=\(returnY95), drift=\(drift)")
        try require(simulation.particles.count == originalCount, "particle count changed after upright recovery: \(simulation.particles.count), expected \(originalCount)")
        try assertFiniteAndBounded(simulation, label: "upright recovery")
        print("METRIC: flat depth span=\(flatDepthSpan), upright y95 drift=\(drift)")
    }

    func shakeBubblesAreBoundedAndExpire() throws {
        let simulation = makeSimulation()
        advance(simulation, seconds: 1.0, motion: MotionSample(gravity: SIMD3(0, -1, 0), acceleration: SIMD3(7, 2, -3)))
        let peak = simulation.bubbles.count
        try require(peak > 0, "shake created no bubbles")
        try require(peak <= 36, "bubble cap exceeded: \(peak)")
        try assertFiniteAndBounded(simulation, label: "bubble shake")
        advance(simulation, seconds: 4.5, motion: MotionSample())
        try require(simulation.bubbles.isEmpty, "bubbles did not expire after rest: remaining=\(simulation.bubbles.count), peak=\(peak)")
    }

    func energyDampsAfterShake() throws {
        let simulation = makeSimulation()
        advance(simulation, seconds: 1.0, motion: MotionSample(gravity: SIMD3(0.5, -0.86, 0), acceleration: SIMD3(6, -4, 2)))
        let peakEnergy = simulation.energy
        advance(simulation, seconds: 2.5, motion: MotionSample())
        let restingEnergy = simulation.energy
        try require(peakEnergy > 0.02, "shake did not create measurable energy: \(peakEnergy)")
        try require(restingEnergy < peakEnergy * 0.72, "energy did not damp enough: peak=\(peakEnergy), resting=\(restingEnergy)")
    }

    func boatSubmergesThenRefloats() throws {
        let simulation = makeSimulation()
        let normal = MotionSample(gravity: SIMD3(0, -1, 0), acceleration: .zero)
        let inverted = MotionSample(gravity: SIMD3(0, 1, 0), acceleration: .zero)
        advance(simulation, seconds: 2.0, motion: normal)

        var peakInversionImmersion = simulation.boat.immersion
        for _ in 0..<Int((3.0 / simulation.fixedStep).rounded(.down)) {
            simulation.advance(elapsed: simulation.fixedStep, motion: inverted)
            peakInversionImmersion = max(peakInversionImmersion, simulation.boat.immersion)
        }

        advance(simulation, seconds: 4.0, motion: normal)
        let boat = simulation.boat
        let bottom = -simulation.halfHeight + 0.24
        let metrics = "peakImmersion=\(peakInversionImmersion), finalImmersion=\(boat.immersion), finalY=\(boat.position.y), bottom=\(bottom)"
        try require(peakInversionImmersion > boat.immersion + 0.05, "inversion did not create deeper intermediate immersion: \(metrics)")
        try require(boat.position.y > bottom + 0.12, "boat remained on or too near the bottom after normal rest: \(metrics)")
        try require(boat.immersion > 0.05 && boat.immersion < 0.95, "boat did not end in a nonzero surface-like immersion range: \(metrics)")
        print("METRIC: boat submerge/refloat \(metrics)")
    }

    func boatRemainsFiniteUnderStress() throws {
        let simulation = makeSimulation()
        for step in 0..<480 {
            let phase = Float(step) * 0.13
            let gravity = SIMD3<Float>(sin(phase) * 0.9, cos(phase) * 0.9, sin(phase * 0.47) * 0.8)
            let acceleration = SIMD3<Float>(cos(phase * 2.1) * 8, sin(phase * 1.7) * 7, cos(phase * 0.8) * 6)
            simulation.advance(elapsed: simulation.fixedStep, motion: MotionSample(gravity: gravity, acceleration: acceleration))
        }
        try assertFiniteAndBounded(simulation, label: "boat stress")
    }

    func upperCohesionStaysLocal() throws {
        let simulation = LiquidSimulation(cohesionStrength: 24)
        for step in 0..<480 {
            let phase = Float(step) * 0.17
            simulation.advance(elapsed: simulation.fixedStep,
                motion: MotionSample(gravity: SIMD3(sin(phase),cos(phase),sin(phase*0.4)),
                                     acceleration: SIMD3(cos(phase*2)*9,sin(phase*3)*8,cos(phase)*6)))
        }
        try assertFiniteAndBounded(simulation, label: "maximum cohesion stress")
        try require(simulation.maximumCohesionDisplacement > 0, "cohesion did not affect the stress run")
        try require(simulation.maximumCohesionDisplacement <= simulation.spacing * 0.04001,
                    "cohesion moved particles too far for the local neighbour approximation")
        print("METRIC: cohesion24 max step displacement=\(simulation.maximumCohesionDisplacement), scaled steps=\(simulation.cohesionClampCount)")
        simulation.reset()
        try require(simulation.maximumCohesionDisplacement == 0 && simulation.cohesionClampCount == 0,
                    "reset retained cohesion diagnostics")
    }

    func interfaceBubbleTracking() throws {
        let old = LiquidSimulation(interfaceBubbles: false)
        let new = LiquidSimulation(interfaceBubbles: true)
        for simulation in [old,new] { advance(simulation, seconds: 3.5, motion: MotionSample()) }
        var oldCount = 0, oldNear = 0, newCount = 0, newNear = 0
        for step in 0..<240 {
            let t = Float(step) / 120
            let motion = MotionSample(acceleration: SIMD3(sin(t*18)*1.8,cos(t*14)*1.1,sin(t*10)*0.4))
            old.advance(elapsed: old.fixedStep, motion: motion)
            new.advance(elapsed: new.fixedStep, motion: motion)
            if step % 12 == 0 {
                oldCount += old.bubbles.count
                newCount += new.bubbles.count
                oldNear += old.bubbles.filter { (0.2...0.75).contains(old.density(at: $0.position)) }.count
                newNear += new.bubbles.filter { (0.2...0.75).contains(new.density(at: $0.position)) }.count
            }
        }
        let oldFraction = Float(oldNear) / Float(max(1,oldCount))
        let newFraction = Float(newNear) / Float(max(1,newCount))
        print("METRIC: surface-band bubble samples old=\(oldNear)/\(oldCount), new=\(newNear)/\(newCount)")
        try require(newCount > 30 && newFraction >= 0.6 && newFraction >= oldFraction + 0.15,
                    "surface tracking did not materially improve: old=\(oldFraction), new=\(newFraction)")
        try require(old.particles.map(\.position) == new.particles.map(\.position), "bubble update changed liquid positions")
        try require(old.boat.position == new.boat.position, "bubble update changed boat position")
        try assertFiniteAndBounded(new, label: "interface bubbles")
        for direction in [SIMD3<Float>(1,0,0),SIMD3<Float>(0,1,0)] {
            for _ in 0..<90 {
                let motion = MotionSample(gravity: direction)
                old.advance(elapsed: old.fixedStep, motion: motion)
                new.advance(elapsed: new.fixedStep, motion: motion)
            }
            let near = new.bubbles.filter { (0.2...0.75).contains(new.density(at: $0.position)) }.count
            print("METRIC: turned gravity=\(direction), surface band=\(near)/\(new.bubbles.count)")
            try assertFiniteAndBounded(new, label: "turned interface bubbles")
            try require(old.particles.map(\.position) == new.particles.map(\.position) && old.boat.position == new.boat.position,
                        "bubble tracking fed back into the liquid after rotation")
            // The acceleration grid must describe the corrected, current positions.
            // Compare it with the independent exhaustive density query at bubble
            // positions and a spread of interior/boundary particle positions.
            let probes = new.bubbles.map(\.position) + stride(from: 0, to: new.particles.count, by: 37).map { new.particles[$0].position }
            for point in probes {
                let fast = new.sampleFlow(at: point).density
                let exact = new.density(at: point)
                try require(abs(fast-exact) < 0.0001, "local flow grid omitted current particle contributions")
            }
        }
        advance(new, seconds: 4.5, motion: MotionSample())
        try require(new.bubbles.isEmpty, "interface bubbles did not expire after rest")
    }

    private func advance(_ simulation: LiquidSimulation, seconds: Float, motion: MotionSample) {
        let count = Int((seconds / simulation.fixedStep).rounded(.down))
        for _ in 0..<count {
            simulation.advance(elapsed: simulation.fixedStep, motion: motion)
        }
    }

    private func assertFiniteAndBounded(_ simulation: LiquidSimulation, label: String) throws {
        let particleLimit = SIMD3<Float>(simulation.halfWidth, simulation.halfHeight, simulation.halfDepth)
        for (index, particle) in simulation.particles.enumerated() {
            try require(isFinite(particle.position) && isFinite(particle.velocity), "\(label): non-finite particle at \(index): position=\(particle.position), velocity=\(particle.velocity)")
            try require(abs(particle.position.x) <= particleLimit.x && abs(particle.position.y) <= particleLimit.y && abs(particle.position.z) <= particleLimit.z, "\(label): particle out of container at \(index): \(particle.position)")
        }
        for (index, bubble) in simulation.bubbles.enumerated() {
            try require(isFinite(bubble.position) && isFinite(bubble.velocity) && bubble.life.isFinite, "\(label): non-finite bubble at \(index): position=\(bubble.position), velocity=\(bubble.velocity), life=\(bubble.life)")
            try require(abs(bubble.position.x) <= particleLimit.x && abs(bubble.position.y) <= particleLimit.y && abs(bubble.position.z) <= particleLimit.z, "\(label): bubble out of container at \(index): \(bubble.position)")
        }
        let boat = simulation.boat
        try require(isFinite(boat.position) && isFinite(boat.velocity) && boat.angle.isFinite && boat.angularVelocity.isFinite && boat.immersion.isFinite, "\(label): non-finite boat: position=\(boat.position), velocity=\(boat.velocity), angle=\(boat.angle), immersion=\(boat.immersion)")
        try require(abs(boat.position.x) <= simulation.halfWidth - 0.22 && abs(boat.position.y) <= simulation.halfHeight - 0.24 && abs(boat.position.z) <= simulation.halfDepth - 0.07, "\(label): boat out of container: \(boat.position)")
    }

    private func isFinite(_ value: SIMD3<Float>) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }
    private func average(_ values: [Float]) -> Float { values.reduce(0, +) / Float(values.count) }
    private func quantile(_ values: [Float], _ percentile: Float) -> Float {
        let sorted = values.sorted()
        return sorted[Int((Float(sorted.count - 1) * percentile).rounded())]
    }
    private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw TestFailure(message()) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
