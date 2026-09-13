import Foundation
import simd

/// Offline reconstruction comparison over the preserved 12 s rest snapshot.
@main
struct RestSurfaceKernelProbe {
    private static let snapshotURL = URL(fileURLWithPath: ".build-cache/rest-surface-20260912/snapshot-12s.json")

    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 2 else { fatalError("usage: rest-surface-kernel-probe output-directory") }
        let output = URL(fileURLWithPath: args[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: snapshotURL))
        let particles = snapshot.particles.map { SIMD3($0.position[0], $0.position[1], $0.position[2]) }
        let radius: Float = 0.098 * 1.5
        let baseline = profile(particles: particles, stretch: 1, radius: radius, mirrors: false)
        let candidates = [1, 2, 3].map { stretch -> Result in
            let surface = stretch == 1 ? baseline : profile(particles: particles, stretch: Float(stretch), radius: radius, mirrors: true)
            let occupancy = occupancyArea(particles: particles, stretch: Float(stretch), radius: radius, mirrors: stretch > 1)
            return Result(stretch: stretch, mirrorWalls: stretch > 1, surface: surface,
                          occupancyArea: occupancy, occupancyDeltaFromS1: occupancy - occupancyArea(particles: particles, stretch: 1, radius: radius, mirrors: false))
        }
        for result in candidates {
            try writeCSV(result.surface.points, to: output.appendingPathComponent("surface-s\(result.stretch).csv"))
        }
        try write(Report(snapshot: snapshotURL.path, particleCount: particles.count, radius: radius,
                         densityThreshold: 0.6, occupancyGrid: [101, 213], results: candidates,
                         limitation: "CPU z=0 raw kernel cross-section only. S>1 uses virtual side-wall mirror kernels for support, not added visible liquid. This is a calm-state reconstruction comparison, not a rendered or splash-state result."),
                  to: output.appendingPathComponent("summary.json"))
    }

    private static func profile(particles: [SIMD3<Float>], stretch: Float, radius: Float, mirrors: Bool) -> Surface {
        let points = (0...80).map { index -> Point in
            let x = -0.8 + Float(index) * 0.02
            var high: Float = 2.12
            var highDensity = density(particles, at: SIMD3(x, high, 0), stretch: stretch, radius: radius, mirrors: mirrors)
            var y = high - radius * 0.25
            var crossing: Float?
            while y >= -2.12 {
                let below = density(particles, at: SIMD3(x, y, 0), stretch: stretch, radius: radius, mirrors: mirrors)
                if highDensity < 0.6 && below >= 0.6 {
                    var above = high, belowY = y
                    for _ in 0..<18 {
                        let middle = (above + belowY) * 0.5
                        if density(particles, at: SIMD3(x, middle, 0), stretch: stretch, radius: radius, mirrors: mirrors) >= 0.6 { belowY = middle }
                        else { above = middle }
                    }
                    crossing = (above + belowY) * 0.5
                    break
                }
                high = y; highDensity = below; y -= radius * 0.25
            }
            return Point(x: x, height: crossing)
        }
        let heights = points.compactMap(\.height)
        let mean = heights.reduce(0, +) / Float(max(1, heights.count))
        let rms = sqrt(heights.reduce(Float(0)) { $0 + pow($1 - mean, 2) } / Float(max(1, heights.count)))
        return Surface(points: points, mean: mean, rms: rms,
                       peakToPeak: (heights.max() ?? mean) - (heights.min() ?? mean), crossings: heights.count)
    }

    private static func occupancyArea(particles: [SIMD3<Float>], stretch: Float, radius: Float, mirrors: Bool) -> Float {
        let nx = 101, ny = 213
        let dx = Float(2) / Float(nx - 1), dy = Float(4.24) / Float(ny - 1)
        var occupied = 0
        for iy in 0..<ny {
            let y = -2.12 + Float(iy) * dy
            for ix in 0..<nx {
                let x = -1 + Float(ix) * dx
                if density(particles, at: SIMD3(x, y, 0), stretch: stretch, radius: radius, mirrors: mirrors) >= 0.6 { occupied += 1 }
            }
        }
        return Float(occupied) * dx * dy
    }

    private static func density(_ particles: [SIMD3<Float>], at point: SIMD3<Float>, stretch: Float,
                                radius: Float, mirrors: Bool) -> Float {
        var result: Float = 0
        func add(_ particle: SIMD3<Float>) {
            let dx = (point.x - particle.x) / (radius * stretch)
            let dy = (point.y - particle.y) / radius
            let dz = (point.z - particle.z) / radius
            let q = 1 - dx * dx - dy * dy - dz * dz
            if q > 0 { result += q * q * q / stretch }
        }
        for particle in particles {
            add(particle)
            if mirrors {
                add(SIMD3(-2 - particle.x, particle.y, particle.z))
                add(SIMD3(2 - particle.x, particle.y, particle.z))
            }
        }
        return result
    }

    private static func writeCSV(_ points: [Point], to url: URL) throws {
        let rows = ["x,surfaceY"] + points.map { point in
            let height = point.height.map { String($0) } ?? ""
            return "\(point.x),\(height)"
        }
        try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private struct Snapshot: Codable { var particles: [Particle] }
    private struct Particle: Codable { var position: [Float] }
    private struct Point: Codable { var x: Float; var height: Float? }
    private struct Surface: Codable { var points: [Point]; var mean, rms, peakToPeak: Float; var crossings: Int }
    private struct Result: Codable { var stretch: Int; var mirrorWalls: Bool; var surface: Surface; var occupancyArea, occupancyDeltaFromS1: Float }
    private struct Report: Codable { var snapshot: String; var particleCount: Int; var radius, densityThreshold: Float; var occupancyGrid: [Int]; var results: [Result]; var limitation: String }
}
