import Foundation
import simd
import CryptoKit

/// Frozen-source, offline side-wall recovery experiment. No renderer or device IO.
/// Usage: wall-column-probe frozen-source.swift new-output-directory [scenario]
@main struct WallColumnProbe {
    enum Failure: Error { case invalid(String) }
    static func vector(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }
    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func save(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .withoutOverwriting)
    }
    static func percentile(_ values: [Float], _ p: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Float(sorted.count - 1) * p))]
    }
    static func snapshot(_ simulation: LiquidSimulation, name: String, after: Float) -> [String: Any] {
        let particles = simulation.particles
        let central = particles.filter { abs($0.position.x) < 0.6 }
        let level = percentile(central.map { $0.position.y }, 0.98)
        let excessCutoff = level + simulation.spacing * 1.5
        func wall(_ sign: Float) -> [String: Any] {
            let edge = particles.filter { sign * $0.position.x > 0.90 }
            let high = edge.filter { $0.position.y > excessCutoff }
            let zs = high.map { $0.position.z }
            return ["count": edge.count, "aboveCentralBulkCount": high.count,
                    "maximumY": edge.map { $0.position.y }.max() ?? -simulation.halfHeight,
                    "maximumExcessHeight": max(0, (edge.map { $0.position.y }.max() ?? level) - level),
                    "aboveBulkMaximumSpeed": high.map { simd_length($0.velocity) }.max() ?? 0,
                    "aboveBulkZSpan": (zs.max() ?? 0) - (zs.min() ?? 0)]
        }
        let finite = particles.allSatisfy { p in
            (0..<3).allSatisfy { p.position[$0].isFinite && p.velocity[$0].isFinite }
        }
        let b = simulation.boat
        var summary: [String: Any] = ["scenario": name, "secondsAfterRelease": after,
            "time": simulation.time, "steps": simulation.steps, "particleCount": particles.count,
            "finite": finite, "energy": simulation.energy,
            "centerOfMass": vector(particles.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(particles.count)),
            "centralParticleCount": central.count, "centralY98": level, "excessCutoffY": excessCutoff,
            "maximumSpeed": particles.map { simd_length($0.velocity) }.max() ?? 0,
            "zSpan": (particles.map { $0.position.z }.max() ?? 0) - (particles.map { $0.position.z }.min() ?? 0),
            "left": wall(-1), "right": wall(1),
            "boat": ["position": vector(b.position), "velocity": vector(b.velocity), "angle": b.angle,
                     "angularVelocity": b.angularVelocity, "immersion": b.immersion]]
        #if WALL_COLUMN_DIAGNOSTICS
        summary["wallStageDiagnostics"] = simulation.wallStageDiagnostics
        #endif
        return ["summary": summary, "spacing": simulation.spacing, "renderRadius": simulation.spacing * 1.5,
                "particles": particles.map { ["position": vector($0.position), "velocity": vector($0.velocity)] },
                "bubbles": simulation.bubbles.map { ["position": vector($0.position), "velocity": vector($0.velocity),
                    "radius": $0.radius, "life": $0.life] as [String: Any] }]
    }
    static func advance(_ simulation: LiquidSimulation, seconds: Float, motion: MotionSample) {
        for _ in 0..<Int((seconds / simulation.fixedStep).rounded()) {
            simulation.advance(elapsed: simulation.fixedStep, motion: motion)
        }
    }
    static func run() throws {
        guard (3...4).contains(CommandLine.arguments.count) else { throw Failure.invalid("arguments") }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.invalid("output exists") }
        let standard = ["left-tilt", "right-tilt", "left-translation", "right-translation", "upright-control"]
        let names = standard + ["left-reduced-translation", "right-reduced-translation"]
        let selected = CommandLine.arguments.count == 4
            ? CommandLine.arguments[3].split(separator: ",").map(String.init) : standard
        guard selected.allSatisfy(names.contains) else { throw Failure.invalid("scenario") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sourceHash = sha(try Data(contentsOf: source))
        let probeHash = sha(try Data(contentsOf: URL(fileURLWithPath: "Studies/WallColumnProbe.swift")))
        var reports = [[String: Any]]()
        for name in selected {
            let simulation = LiquidSimulation()
            let initialCount = simulation.particles.count
            advance(simulation, seconds: 1.5, motion: MotionSample())
            let side: Float = name.hasPrefix("left") ? -1 : 1
            if name.hasSuffix("tilt") {
                advance(simulation, seconds: 2, motion: MotionSample(gravity: SIMD3(side, 0, 0)))
            } else if name.hasSuffix("translation") {
                // Inertial liquid force is opposite to handset userAcceleration.
                var input = MotionSample(acceleration: SIMD3(-side * 8, 0, 0))
                if name.contains("reduced") {
                    // Mirrors the app's clip-before-reduced-motion order.
                    input.acceleration = input.safeAcceleration * 0.2
                }
                advance(simulation, seconds: 0.75, motion: input)
            } else {
                advance(simulation, seconds: 2, motion: MotionSample())
            }
            var previous: Float = 0
            for time: Float in [0, 0.5, 2, 5] {
                advance(simulation, seconds: time - previous, motion: MotionSample())
                previous = time
                let state = snapshot(simulation, name: name, after: time)
                let summary = state["summary"] as! [String: Any]
                guard summary["finite"] as? Bool == true, simulation.particles.count == initialCount else {
                    throw Failure.invalid("nonfinite or particle count changed")
                }
                try save(state, to: output.appendingPathComponent("\(name)-\(time).json"))
                reports.append(summary)
                print("\(name) release=\(time)s energy=\(simulation.energy) left=\(summary["left"]!) right=\(summary["right"]!)")
                fflush(stdout)
                #if WALL_COLUMN_DIAGNOSTICS
                simulation.resetWallStageDiagnostics()
                #endif
            }
        }
        try save(["sourceSHA256": sourceHash, "probeSHA256": probeHash,
                  "fixedStep": 1.0 / 120, "initialUprightSeconds": 1.5, "tiltSeconds": 2,
                  "translationSeconds": 0.75, "translationAccelerationG": 8,
                  "reducedScenarioRule": "Clip raw acceleration using frozen source, then multiply by 0.2 before simulation.",
                  "scope": "Synthetic input, frozen source, full particle snapshots; no actual-phone claim.",
                  "runs": reports] as [String: Any], to: output.appendingPathComponent("report.json"))
    }
    static func main() { do { try run() } catch { fputs("FAIL wall-column probe: \(error)\n", stderr); exit(1) } }
}
