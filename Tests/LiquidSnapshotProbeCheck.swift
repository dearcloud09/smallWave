import Foundation
import simd

@main
struct LiquidSnapshotProbeCheck {
    static func main() {
        do {
            try launchArgumentAndPath()
            try fixedScheduleAndFiniteJSON()
            try gapSkipsHistoricalBackfill()
            try invalidStateIsNotWritten()
            try pausedDeadlineWritesCapturedPrefix()
            print("PASS: 5 liquid snapshot probe checks")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    static func launchArgumentAndPath() throws {
        try require(LiquidSnapshotProbe.captureID(from: ["app"]) == nil, "normal launch enabled capture")
        try require(LiquidSnapshotProbe.captureID(from: ["--smallwave-wall-capture=wall_12-A"]) == "wall_12-A", "valid id")
        try require(LiquidSnapshotProbe.captureID(from: ["--smallwave-wall-capture=bad/path"]) == nil, "unsafe id")
        try require(LiquidSnapshotProbe.outputFilename == "smallwave-wall-capture.json", "output filename")
    }

    static func fixedScheduleAndFiniteJSON() throws {
        let url = outputURL("schedule")
        let probe = LiquidSnapshotProbe(captureID: "schedule", outputURL: url, appBuild: "42")
        let simulation = LiquidSimulation()
        for time in stride(from: 0.0, through: 20.0, by: 2.5) {
            probe.record(now: time, simulation: simulation, motion: MotionSample(), screenRotation: 0,
                         surfaceFilter: SIMD4(1, 0, 1, 0), renderState: fixture())
        }
        let report = try waitForReport(at: url)
        try require(report.captureID == "schedule" && report.appBuild == "42", "metadata")
        try require(report.snapshots.count == 9, "snapshot count \(report.snapshots.count)")
        try require(report.snapshots.map(\.targetSeconds) == [0, 2.5, 5, 7.5, 10, 12.5, 15, 17.5, 20], "targets")
        try require(report.snapshots.allSatisfy { $0.scalars.allSatisfy(\.isFinite) }, "nonfinite JSON")
        try require(report.snapshots[0].renderState == fixture(), "render state")
    }

    static func gapSkipsHistoricalBackfill() throws {
        let url = outputURL("gap")
        let probe = LiquidSnapshotProbe(captureID: "gap", outputURL: url, appBuild: nil)
        let simulation = LiquidSimulation()
        probe.record(now: 0, simulation: simulation, motion: MotionSample(), screenRotation: 0,
                     surfaceFilter: SIMD4(1, 0, 1, 0), renderState: fixture())
        probe.record(now: 15, simulation: simulation, motion: MotionSample(), screenRotation: 0,
                     surfaceFilter: SIMD4(1, 0, 1, 0), renderState: fixture())
        probe.finish()
        let report = try waitForReport(at: url)
        try require(report.snapshots.map(\.targetSeconds) == [0, 15], "gap targets \(report.snapshots.map(\.targetSeconds))")
        try require(report.snapshots[1].elapsedSeconds == 15, "gap elapsed \(report.snapshots[1].elapsedSeconds)")
    }

    static func invalidStateIsNotWritten() throws {
        let url = outputURL("invalid")
        let probe = LiquidSnapshotProbe(captureID: "invalid", outputURL: url, appBuild: nil, duration: 0.01)
        probe.record(now: 0, simulation: LiquidSimulation(), motion: MotionSample(), screenRotation: .nan,
                     surfaceFilter: SIMD4(1, 0, 1, 0), renderState: fixture())
        probe.finish()
        Thread.sleep(forTimeInterval: 0.05)
        try require(!FileManager.default.fileExists(atPath: url.path), "invalid snapshot wrote JSON")
    }

    static func pausedDeadlineWritesCapturedPrefix() throws {
        let url = outputURL("deadline")
        let probe = LiquidSnapshotProbe(captureID: "deadline", outputURL: url, appBuild: nil, duration: 0.01)
        probe.record(now: 10, simulation: LiquidSimulation(), motion: MotionSample(), screenRotation: 0,
                     surfaceFilter: SIMD4(1, 0, 1, 0), renderState: fixture())
        let report = try waitForReport(at: url)
        try require(report.snapshots.count == 1 && report.snapshots[0].targetSeconds == 0, "deadline prefix")
    }

    private static func outputURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("smallwave-snapshot-\(name)-\(UUID().uuidString).json")
    }
    private static func fixture() -> LiquidSnapshotProbe.RenderState {
        LiquidSnapshotProbe.RenderState(viewport: [1, 2.12, 4.25, 0.5], movement: [0, -1, 0, 0.3],
                                        color: [0.0001, 0.16, 0.45, 0], optics: [1.46, 1.333, 0.3, 0],
                                        miniatureArt: [0, 0.75, 0.4, 1.2], boat: [0.1, -0.2, 0.3, 0],
                                        targetPixelWidth: 1206, targetPixelHeight: 2557)
    }
    private static func waitForReport(at url: URL) throws -> TestReport {
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: url), let report = try? JSONDecoder().decode(TestReport.self, from: data) { return report }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw Failure("timed out waiting for \(url.lastPathComponent)")
    }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message) }
    }

    private struct TestReport: Decodable {
        let captureID: String
        let appBuild: String?
        let snapshots: [TestSnapshot]
    }
    private struct TestSnapshot: Decodable {
        let targetSeconds: Double
        let elapsedSeconds: Double
        let simulationTime: Float
        let energy: Float
        let screenRotation: Float
        let gravity: [Float]
        let safeAcceleration: [Float]
        let surfaceFilter: [Float]
        let particles: [TestParticle]
        let bubbles: [TestBubble]
        let boat: TestBoat
        let renderState: LiquidSnapshotProbe.RenderState
        var scalars: [Double] {
            var values = [targetSeconds, elapsedSeconds, Double(simulationTime), Double(energy), Double(screenRotation)]
            values += gravity.map(Double.init)
            values += safeAcceleration.map(Double.init)
            values += surfaceFilter.map(Double.init)
            for particle in particles { values += particle.position.map(Double.init); values += particle.velocity.map(Double.init) }
            for bubble in bubbles { values += bubble.position.map(Double.init); values += [Double(bubble.radius), Double(bubble.life)] }
            values += boat.position.map(Double.init)
            values += boat.velocity.map(Double.init)
            values += [Double(boat.angle), Double(boat.angularVelocity), Double(boat.immersion)]
            values += renderState.viewport.map(Double.init)
            values += renderState.movement.map(Double.init)
            values += renderState.color.map(Double.init)
            values += renderState.optics.map(Double.init)
            values += renderState.miniatureArt.map(Double.init)
            values += renderState.boat.map(Double.init)
            values += [Double(renderState.targetPixelWidth), Double(renderState.targetPixelHeight)]
            return values
        }
    }
    private struct TestParticle: Decodable { let position: [Float]; let velocity: [Float] }
    private struct TestBubble: Decodable { let position: [Float]; let radius: Float; let life: Float }
    private struct TestBoat: Decodable { let position: [Float]; let velocity: [Float]; let angle: Float; let angularVelocity: Float; let immersion: Float }
    private struct Failure: Error, CustomStringConvertible { let description: String; init(_ description: String) { self.description = description } }
}
