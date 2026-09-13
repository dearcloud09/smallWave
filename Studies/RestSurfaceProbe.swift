import Foundation
import simd

/// Offline rest-state diagnostic. Compile with SmallWave/Core/LiquidSimulation.swift only.
@main
struct RestSurfaceProbe {
    private static let captureSeconds: [Int] = [2, 6, 12]

    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 || arguments.count == 4 else {
            fatalError("usage: rest-surface-probe output-directory source-sha256 [tilt-radians]")
        }
        let output = URL(fileURLWithPath: arguments[1])
        let sourceSHA = arguments[2]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let simulation = LiquidSimulation()
        let angle = arguments.count == 4 ? Float(arguments[3]) ?? .nan : 0
        guard angle.isFinite, abs(angle) <= .pi / 3 else { fatalError("invalid tilt") }
        let motion = MotionSample(gravity: SIMD3(sin(angle), -cos(angle), 0), acceleration: .zero)
        var summaries: [SnapshotSummary] = []
        let finalStep = captureSeconds.last! * 120
        for step in 1...finalStep {
            simulation.advance(elapsed: simulation.fixedStep, motion: motion)
            guard step % 120 == 0, captureSeconds.contains(step / 120) else { continue }
            let seconds = step / 120
            let surface = surfaceProfile(simulation)
            let snapshot = makeSnapshot(simulation, seconds: seconds, surface: surface, gravity: motion.gravity)
            try write(snapshot, to: output.appendingPathComponent("snapshot-\(seconds)s.json"))
            try writeCSV(surface, to: output.appendingPathComponent("surface-\(seconds)s.csv"))
            summaries.append(snapshot.summary)
            print("rest t=\(seconds)s surfaceRMS=\(snapshot.summary.surfaceRMS ?? .nan) bulkRMS=\(snapshot.summary.bulkRMSSpeed)")
        }
        let report = Report(
            sourceSHA256: sourceSHA,
            input: Input(gravity: vector(motion.gravity), acceleration: [0, 0, 0], fixedHz: 120),
            particleCount: simulation.particles.count,
            captures: summaries,
            surfaceMethod: "CPU raw-splat at z=0: sum(max(0,1-r²/R²)^3), R=spacing*1.5; scan from top and bisect density=0.6 crossing.",
            limitation: "This omits the GPU field's one-voxel filter and is a CPU raw-splat approximation, not a rendered surface measurement."
        )
        try write(report, to: output.appendingPathComponent("summary.json"))
    }

    private static func makeSnapshot(_ simulation: LiquidSimulation, seconds: Int,
                                     surface: [SurfacePoint], gravity: SIMD3<Float>) -> Snapshot {
        let particles = simulation.particles.map {
            Particle(position: vector($0.position), velocity: vector($0.velocity))
        }
        let speeds = simulation.particles.map { simd_length($0.velocity) }
        let bulkRMS = sqrt(speeds.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, speeds.count)))
        let heights = surface.compactMap(\.height)
        let mean = heights.isEmpty ? nil : heights.reduce(0, +) / Float(heights.count)
        let rms = mean.map { mean in sqrt(heights.reduce(Float(0)) { $0 + pow($1 - mean, 2) } / Float(heights.count)) }
        let peakToPeak = heights.isEmpty ? nil : (heights.max()! - heights.min()!)
        let summary = SnapshotSummary(seconds: seconds, energy: simulation.energy,
                                      boat: Boat(position: vector(simulation.boat.position), velocity: vector(simulation.boat.velocity),
                                                 angle: simulation.boat.angle, angularVelocity: simulation.boat.angularVelocity,
                                                 immersion: simulation.boat.immersion),
                                      bulkRMSSpeed: bulkRMS, surfaceRMS: rms, surfacePeakToPeak: peakToPeak,
                                      surfaceCrossingCount: heights.count)
        return Snapshot(summary: summary, particles: particles, gravity: vector(gravity))
    }

    private static func surfaceProfile(_ simulation: LiquidSimulation) -> [SurfacePoint] {
        let radius = simulation.spacing * 1.5
        let scanStep = simulation.spacing * 0.25
        return (0...80).map { index in
            let x = -0.8 + Float(index) * 0.02
            var above = simulation.halfHeight
            var densityAbove = density(simulation.particles, at: SIMD3(x, above, 0), radius: radius)
            var crossing: Float?
            var y = above - scanStep
            while y >= -simulation.halfHeight {
                let densityBelow = density(simulation.particles, at: SIMD3(x, y, 0), radius: radius)
                if densityAbove < 0.6 && densityBelow >= 0.6 {
                    var high = above, low = y
                    for _ in 0..<18 {
                        let middle = (high + low) * 0.5
                        if density(simulation.particles, at: SIMD3(x, middle, 0), radius: radius) >= 0.6 { low = middle }
                        else { high = middle }
                    }
                    crossing = (high + low) * 0.5
                    break
                }
                above = y; densityAbove = densityBelow; y -= scanStep
            }
            return SurfacePoint(x: x, height: crossing)
        }
    }

    private static func density(_ particles: [LiquidParticle], at point: SIMD3<Float>, radius: Float) -> Float {
        let radiusSquared = radius * radius
        return particles.reduce(Float(0)) { total, particle in
            let normalized = 1 - simd_length_squared(point - particle.position) / radiusSquared
            return total + (normalized > 0 ? normalized * normalized * normalized : 0)
        }
    }

    private static func writeCSV(_ surface: [SurfacePoint], to url: URL) throws {
        let rows = ["x,surfaceY"] + surface.map { point in
            let height = point.height.map { String($0) } ?? ""
            return "\(point.x),\(height)"
        }
        try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func vector(_ value: SIMD3<Float>) -> [Float] { [value.x, value.y, value.z] }

    private struct Particle: Codable { var position, velocity: [Float] }
    private struct Boat: Codable { var position, velocity: [Float]; var angle, angularVelocity, immersion: Float }
    private struct SurfacePoint: Codable { var x: Float; var height: Float? }
    private struct SnapshotSummary: Codable {
        var seconds: Int; var energy: Float; var boat: Boat; var bulkRMSSpeed: Float
        var surfaceRMS, surfacePeakToPeak: Float?; var surfaceCrossingCount: Int
    }
    private struct Snapshot: Codable { var summary: SnapshotSummary; var particles: [Particle]; var gravity: [Float] }
    private struct Input: Codable { var gravity, acceleration: [Float]; var fixedHz: Int }
    private struct Report: Codable {
        var sourceSHA256: String; var input: Input; var particleCount: Int; var captures: [SnapshotSummary]
        var surfaceMethod, limitation: String
    }
}
