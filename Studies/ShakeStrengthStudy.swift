import Foundation
import simd

private struct Run: Codable {
    let frequencyHz: Float
    let rawPeakG: Float
    let mode: String
    let inputPeakG: Float
    let inputPeakRatio: Float
    let comFundamental: Float
    let maximumSurfaceY: Float
    let maximumSpeed: Float
    let finalEnergy: Float
    let finite: Bool
    let particleCount: Int
}

private struct RunResult {
    let metrics: Run
    let snapshot: [String: Any]?
}

@main private struct ShakeStrengthStudy {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("usage: ShakeStrengthStudy output-directory")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let cases: [(Float, Float)] = [(1, 0.30), (2, 1.20), (3, 2.70)]
        var results: [Run] = []

        for (frequency, amplitude) in cases {
            for enhanced in [false, true] {
                let captured = frequency == 3
                let result = run(frequency: frequency, amplitude: amplitude, enhanced: enhanced, captureSnapshot: captured)
                results.append(result.metrics)
                if let snapshot = result.snapshot {
                    let name = enhanced ? "proposed-3hz-final.json" : "baseline-3hz-final.json"
                    try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
                        .write(to: output.appendingPathComponent(name))
                }
                print("\(result.metrics.mode) \(frequency)Hz input=\(result.metrics.inputPeakG) ratio=\(result.metrics.inputPeakRatio) com=\(result.metrics.comFundamental) top=\(result.metrics.maximumSurfaceY) speed=\(result.metrics.maximumSpeed) finite=\(result.metrics.finite)")
            }
        }

        let pairs = Dictionary(uniqueKeysWithValues: results.map { ("\($0.mode)-\($0.frequencyHz)", $0) })
        let comparisons: [[String: Any]] = cases.map { frequency, _ in
            let baseline = pairs["baseline-\(frequency)"]!
            let proposed = pairs["proposed-\(frequency)"]!
            return [
                "frequencyHz": frequency,
                "comFundamentalRatio": proposed.comFundamental / max(baseline.comFundamental, 0.000001),
                "maximumSurfaceYDelta": proposed.maximumSurfaceY - baseline.maximumSurfaceY,
                "maximumSpeedRatio": proposed.maximumSpeed / max(baseline.maximumSpeed, 0.000001)
            ]
        }
        let report: [String: Any] = [
            "fixedStepHz": 120,
            "settleSeconds": 1.5,
            "driveSeconds": 3.0,
            "comFundamentalWindow": ["startDriveSeconds": 1.0, "durationSeconds": 2.0, "sampleCount": 240],
            "nominalTranslationStrokeMeters": 0.075,
            "forceGain": 5.8,
            "maximumAccelerationG": MotionSample.maximumAccelerationG,
            "policy": "non-reduced motion uses a smooth 1x-to-3x input gain from 0.15g to 0.65g; reduced motion remains 0.2x",
            "runs": try JSONSerialization.jsonObject(with: JSONEncoder().encode(results)),
            "comparisons": comparisons,
            "note": "Synthetic fixed-tick solver comparison only. Desktop wall time is not phone performance and these metrics do not guarantee visible amplitude."
        ]
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try reportData.write(to: output.appendingPathComponent("summary.json"))
    }

    private static func run(frequency: Float, amplitude: Float, enhanced: Bool, captureSnapshot: Bool) -> RunResult {
        let simulation = LiquidSimulation()
        let settleSteps = 180
        let driveSteps = 360
        var cosSum: Float = 0
        var sinSum: Float = 0
        var samples = 0
        var maximumSurfaceY = -Float.greatestFiniteMagnitude
        var maximumSpeed: Float = 0
        var finite = true
        var inputPeak: Float = 0
        var lastRaw = SIMD3<Float>.zero
        var lastApplied = SIMD3<Float>.zero
        var lastSampleTime: Float = 0

        for step in 0..<(settleSteps + driveSteps) {
            let t = Float(step - settleSteps) * simulation.fixedStep
            let raw = step < settleSteps ? SIMD3<Float>.zero : SIMD3<Float>(sin(t * 2 * .pi * frequency) * amplitude, 0, 0)
            let mapped = enhanced ? MotionSample.mappedAcceleration(raw, reducedMotion: false) : raw
            let applied = MotionSample(acceleration: mapped).safeAcceleration
            inputPeak = max(inputPeak, simd_length(applied))
            lastRaw = raw
            lastApplied = applied
            lastSampleTime = Float(step) * simulation.fixedStep
            simulation.advance(elapsed: simulation.fixedStep, motion: MotionSample(acceleration: applied))

            var centerX: Float = 0
            for particle in simulation.particles {
                centerX += particle.position.x
                if step >= settleSteps {
                    maximumSurfaceY = max(maximumSurfaceY, particle.position.y)
                    maximumSpeed = max(maximumSpeed, simd_length(particle.velocity))
                }
                finite = finite && particle.position.x.isFinite && particle.position.y.isFinite && particle.position.z.isFinite && simd_length(particle.velocity).isFinite
            }
            // 240 ticks span 2 seconds: 2, 4, and 6 full cycles at 1, 2, and 3 Hz.
            if step >= settleSteps + 120 {
                let phase = t * 2 * .pi * frequency
                centerX /= Float(simulation.particles.count)
                cosSum += centerX * cos(phase)
                sinSum += centerX * sin(phase)
                samples += 1
            }
        }

        let fundamental = samples > 0 ? 2 / Float(samples) * sqrt(cosSum * cosSum + sinSum * sinSum) : 0
        let metrics = Run(
            frequencyHz: frequency,
            rawPeakG: amplitude,
            mode: enhanced ? "proposed" : "baseline",
            inputPeakG: inputPeak,
            inputPeakRatio: inputPeak / amplitude,
            comFundamental: fundamental,
            maximumSurfaceY: maximumSurfaceY,
            maximumSpeed: maximumSpeed,
            finalEnergy: simulation.energy,
            finite: finite,
            particleCount: simulation.particles.count
        )
        let snapshot: [String: Any]? = captureSnapshot ? [
            "particles": simulation.particles.map { ["position": [$0.position.x, $0.position.y, $0.position.z], "velocity": [$0.velocity.x, $0.velocity.y, $0.velocity.z]] },
            "bubbles": simulation.bubbles.map { ["position": [$0.position.x, $0.position.y, $0.position.z], "radius": $0.radius, "life": $0.life] },
            "renderRadius": simulation.spacing * 1.5,
            "summary": ["time": simulation.time, "energy": simulation.energy,
                        "boat": ["position": [simulation.boat.position.x, simulation.boat.position.y, simulation.boat.position.z],
                                 "velocity": [simulation.boat.velocity.x, simulation.boat.velocity.y, simulation.boat.velocity.z],
                                 "angle": simulation.boat.angle, "immersion": simulation.boat.immersion]],
            "gravity": [0, -1, 0], "surfaceFilter": [1, 0, 1, 0],
            "capture": ["timeSeconds": simulation.time, "input": "translation", "frequencyHz": frequency,
                        "rawPeakG": amplitude, "appliedPeakG": inputPeak,
                        "inputSampleTimeSeconds": lastSampleTime,
                        "instantaneousRawAccelerationG": lastRaw.x,
                        "rawAccelerationG": [lastRaw.x, lastRaw.y, lastRaw.z],
                        "appliedAccelerationG": [lastApplied.x, lastApplied.y, lastApplied.z],
                        "mode": enhanced ? "proposed" : "baseline"]
        ] : nil
        return RunResult(metrics: metrics, snapshot: snapshot)
    }
}
