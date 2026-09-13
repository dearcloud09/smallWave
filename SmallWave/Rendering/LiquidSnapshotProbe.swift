import Foundation
import simd

/// Developer-only, bounded local state capture for reproducing a rendered wall.
/// It is instantiated only from a validated launch argument on iOS.
final class LiquidSnapshotProbe {
    struct Particle: Codable { let position: [Float]; let velocity: [Float] }
    struct Bubble: Codable { let position: [Float]; let radius: Float; let life: Float }
    struct Boat: Codable {
        let position: [Float]; let velocity: [Float]; let angle: Float
        let angularVelocity: Float; let immersion: Float
    }
    /// Exact final render inputs, expressed without UIKit/Metal types so the probe stays core-testable.
    struct RenderState: Codable, Equatable {
        let viewport: [Float]
        let movement: [Float]
        let color: [Float]
        let optics: [Float]
        let miniatureArt: [Float]
        let boat: [Float]
        let targetPixelWidth: Int
        let targetPixelHeight: Int
    }
    struct Snapshot: Codable {
        let targetSeconds: Double
        let elapsedSeconds: Double
        let simulationTime: Float
        let energy: Float
        let particles: [Particle]
        let bubbles: [Bubble]
        let boat: Boat
        let gravity: [Float]
        let safeAcceleration: [Float]
        let screenRotation: Float
        let surfaceFilter: [Float]
        let renderState: RenderState
    }
    struct Bounds: Codable { let halfWidth: Float; let halfHeight: Float; let halfDepth: Float }
    private struct Configuration {
        let spacing: Float
        let smoothingRadius: Float
        let bounds: Bounds
    }
    struct Report: Codable {
        let schemaVersion: Int
        let captureID: String
        let appBuild: String?
        let durationSeconds: Double
        let spacing: Float
        let smoothingRadius: Float
        let bounds: Bounds
        let snapshots: [Snapshot]
    }

    static let outputFilename = "smallwave-wall-capture.json"
    private static let targets: [Double] = [0, 2.5, 5, 7.5, 10, 12.5, 15, 17.5, 20]

    private let captureID: String
    private let outputURL: URL
    private let appBuild: String?
    private let duration: Double
    private let writer = DispatchQueue(label: "dev.smallwave.wall-snapshot", qos: .utility)
    private let lock = NSLock()
    private var startedAt: TimeInterval?
    private var nextTarget = 0
    private var snapshots: [Snapshot] = []
    private var configuration: Configuration?
    private var closed = false

    static func captureID(from arguments: [String]) -> String? {
        let prefix = "--smallwave-wall-capture="
        guard let argument = arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let value = String(argument.dropFirst(prefix.count))
        return value.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil ? value : nil
    }

    init(captureID: String, outputURL: URL, appBuild: String?, duration: Double = 20) {
        self.captureID = captureID
        self.outputURL = outputURL
        self.appBuild = appBuild
        self.duration = duration.isFinite && duration > 0 ? duration : 20
    }

    /// Called only from accepted live render frames, after simulation advance and filter selection.
    func record(now: TimeInterval, simulation: LiquidSimulation, motion: MotionSample,
                screenRotation: Float, surfaceFilter: SIMD4<Float>,
                renderState: @autoclosure () -> RenderState) {
        guard now.isFinite else { return }
        lock.lock()
        if closed { lock.unlock(); return }
        if startedAt == nil {
            startedAt = now
            configuration = Configuration(spacing: simulation.spacing, smoothingRadius: simulation.smoothingRadius,
                                          bounds: Bounds(halfWidth: simulation.halfWidth, halfHeight: simulation.halfHeight,
                                                         halfDepth: simulation.halfDepth))
            scheduleDeadline()
        }
        let elapsed = max(0, now - (startedAt ?? now))
        guard elapsed <= duration + 0.20 else { lock.unlock(); finish(); return }
        guard let targetIndex = Self.targets.indices.last(where: { $0 >= nextTarget && Self.targets[$0] <= elapsed }) else {
            lock.unlock(); return
        }
        // A resume/frame gap has no historical scene state. Skip missed targets rather
        // than relabeling the current state as several old frames.
        let target = Self.targets[targetIndex]
        guard let snapshot = Self.snapshot(target: target, elapsed: elapsed, simulation: simulation,
                                           motion: motion, screenRotation: screenRotation,
                                           surfaceFilter: surfaceFilter, renderState: renderState()) else { lock.unlock(); return }
        snapshots.append(snapshot)
        nextTarget = targetIndex + 1
        let shouldFinish = nextTarget == Self.targets.count
        lock.unlock()
        if shouldFinish { finish() }
    }

    private func scheduleDeadline() {
        writer.asyncAfter(deadline: .now() + duration + 0.20) { [weak self] in self?.finish() }
    }

    /// The deadline may fire while rendering is paused; it writes only copies already taken.
    func finish() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let copied = snapshots
        let configuration = configuration
        lock.unlock()
        writer.async { [captureID, outputURL, appBuild, duration, copied, configuration] in
            guard let configuration,
                  let report = Self.report(captureID: captureID, appBuild: appBuild, duration: duration,
                                           configuration: configuration, snapshots: copied),
                  let data = try? JSONEncoder.wallCapture.encode(report) else { return }
            do { try data.write(to: outputURL, options: .atomic) } catch { /* Capture failure must not affect rendering. */ }
        }
    }

    private static func report(captureID: String, appBuild: String?, duration: Double,
                               configuration: Configuration, snapshots: [Snapshot]) -> Report? {
        guard !snapshots.isEmpty, snapshots.allSatisfy(valid), configuration.spacing.isFinite,
              configuration.smoothingRadius.isFinite,
              [configuration.bounds.halfWidth, configuration.bounds.halfHeight, configuration.bounds.halfDepth].allSatisfy(\.isFinite) else { return nil }
        return Report(schemaVersion: 2, captureID: captureID, appBuild: appBuild, durationSeconds: duration,
                      spacing: configuration.spacing, smoothingRadius: configuration.smoothingRadius,
                      bounds: configuration.bounds, snapshots: snapshots)
    }

    private static func snapshot(target: Double, elapsed: Double, simulation: LiquidSimulation,
                                 motion: MotionSample, screenRotation: Float,
                                 surfaceFilter: SIMD4<Float>, renderState: RenderState) -> Snapshot? {
        let particles = simulation.particles.map { Particle(position: array($0.position), velocity: array($0.velocity)) }
        let bubbles = simulation.bubbles.map { Bubble(position: array($0.position), radius: $0.radius, life: $0.life) }
        let boat = Boat(position: array(simulation.boat.position), velocity: array(simulation.boat.velocity),
                        angle: simulation.boat.angle, angularVelocity: simulation.boat.angularVelocity,
                        immersion: simulation.boat.immersion)
        let snapshot = Snapshot(targetSeconds: target, elapsedSeconds: elapsed, simulationTime: simulation.time,
                                energy: simulation.energy, particles: particles, bubbles: bubbles, boat: boat,
                                gravity: array(motion.gravity), safeAcceleration: array(motion.safeAcceleration),
                                screenRotation: screenRotation, surfaceFilter: [surfaceFilter.x, surfaceFilter.y, surfaceFilter.z, surfaceFilter.w],
                                renderState: renderState)
        return valid(snapshot) ? snapshot : nil
    }

    private static func array(_ value: SIMD3<Float>) -> [Float] { [value.x, value.y, value.z] }
    private static func valid(_ snapshot: Snapshot) -> Bool {
        let scalars = [snapshot.targetSeconds, snapshot.elapsedSeconds, Double(snapshot.simulationTime), Double(snapshot.energy),
                       Double(snapshot.screenRotation)] + snapshot.gravity.map(Double.init) + snapshot.safeAcceleration.map(Double.init)
            + snapshot.surfaceFilter.map(Double.init)
        return scalars.allSatisfy { $0.isFinite }
            && snapshot.particles.allSatisfy { ($0.position + $0.velocity).allSatisfy(\.isFinite) }
            && snapshot.bubbles.allSatisfy { ($0.position + [$0.radius, $0.life]).allSatisfy(\.isFinite) }
            && (snapshot.boat.position + snapshot.boat.velocity + [snapshot.boat.angle, snapshot.boat.angularVelocity, snapshot.boat.immersion]).allSatisfy(\.isFinite)
            && [snapshot.renderState.viewport, snapshot.renderState.movement, snapshot.renderState.color,
                snapshot.renderState.optics, snapshot.renderState.miniatureArt, snapshot.renderState.boat]
                .allSatisfy { $0.count == 4 && $0.allSatisfy(\.isFinite) }
            && snapshot.renderState.targetPixelWidth > 0 && snapshot.renderState.targetPixelHeight > 0
    }
}

private extension JSONEncoder {
    static var wallCapture: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
