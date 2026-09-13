import Foundation

struct FrameTimingSample {
    var acceptedAt: TimeInterval
    var interval: TimeInterval?
    var simulatedDuration: TimeInterval
    var drawableWait: TimeInterval
    var providerCPU: TimeInterval
    var simulationCPU: TimeInterval
    var encodingCPU: TimeInterval
}

/// Opt-in, bounded aggregate timing capture. It never records per-frame data to disk.
final class FrameTimingProbe {
    private static let maximumSamples = 1_200

    private struct GPUResult {
        var execution: TimeInterval?
        var submitToCompletion: TimeInterval?
    }

    private let outputURL: URL
    private let duration: TimeInterval
    private let captureID: String
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "smallwave.frame-timing-probe", qos: .utility)
    private var startedAt: TimeInterval?
    private var deadline: TimeInterval?
    private var samples: [FrameTimingSample] = []
    private var gpu: [Int: GPUResult] = [:]
    private var nextFrameID = 0
    private var motionSession: [String: Double]?
    private var cpuClosed = false
    private var finalized = false
    private var closeScheduled = false
    private var writeScheduled = false

    init(outputURL: URL, duration: TimeInterval = 20, captureID: String = UUID().uuidString) {
        self.outputURL = outputURL
        self.duration = duration.isFinite && duration > 0 ? duration : 20
        self.captureID = captureID
    }

    /// Returns an id only for an accepted CPU sample. Call `recordGPU` asynchronously.
    func record(_ sample: FrameTimingSample, motionSnapshot: [String: Double]? = nil) -> Int? {
        guard sample.acceptedAt.isFinite else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard !cpuClosed else { return nil }
        if startedAt == nil {
            startedAt = sample.acceptedAt
            deadline = sample.acceptedAt + duration
            scheduleCloseLocked(after: duration)
        }
        guard let deadline, sample.acceptedAt <= deadline else {
            closeCPUCollectionLocked()
            return nil
        }
        guard samples.count < Self.maximumSamples else { return nil }
        let frameID = nextFrameID
        nextFrameID += 1
        samples.append(sample)
        if let validSnapshot = validatedMotionSnapshot(motionSnapshot) { motionSession = validSnapshot }
        return frameID
    }

    /// Ignore unknown, duplicate, or post-cutoff GPU completions.
    func recordGPU(frameID: Int, execution: TimeInterval?, submitToCompletion: TimeInterval) {
        guard frameID >= 0, submitToCompletion.isFinite, submitToCompletion >= 0 else { return }
        let validExecution = execution.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        lock.lock()
        defer { lock.unlock() }
        guard !finalized, frameID < nextFrameID, gpu[frameID] == nil else { return }
        gpu[frameID] = GPUResult(execution: validExecution, submitToCompletion: submitToCompletion)
    }

    private func scheduleWriteLocked(after delay: TimeInterval) {
        guard !writeScheduled else { return }
        writeScheduled = true
        writer.asyncAfter(deadline: .now() + delay) { [weak self] in self?.closeAndWrite() }
    }

    private func scheduleCloseLocked(after delay: TimeInterval) {
        guard !closeScheduled else { return }
        closeScheduled = true
        writer.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.closeCPUCollectionLocked()
            self.lock.unlock()
        }
    }

    private func closeCPUCollectionLocked() {
        guard !cpuClosed else { return }
        cpuClosed = true
        scheduleWriteLocked(after: 0.5)
    }

    private func closeAndWrite() {
        let report: Report?
        lock.lock()
        cpuClosed = true
        finalized = true
        report = makeReportLocked()
        lock.unlock()
        guard let report else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: outputURL, options: .atomic)
        } catch {
            // Opt-in diagnostics must never affect rendering when storage is unavailable.
        }
    }

    private func makeReportLocked() -> Report? {
        guard !samples.isEmpty else { return nil }
        let timestamps = samples.map(\.acceptedAt)
        let span = (timestamps.max() ?? 0) - (timestamps.min() ?? 0)
        let intervals = samples.compactMap(\.interval)
        let eligible = samples.compactMap { sample -> FrameTimingSample? in
            guard let interval = sample.interval, interval.isFinite, interval >= 0, interval <= 0.25 else { return nil }
            return sample
        }
        let intervalSum = eligible.compactMap(\.interval).reduce(0, +)
        let simulatedSum = eligible.map(\.simulatedDuration).filter { $0.isFinite && $0 >= 0 }.reduce(0, +)
        let gpuResults = gpu.values
        // This paired value includes more than GPU queueing: command submission and
        // completion notification time can also contribute to it.
        let nonExecutionLatency = gpuResults.compactMap { result -> TimeInterval? in
            guard let execution = result.execution, let submit = result.submitToCompletion else { return nil }
            return max(0, submit - execution)
        }
        return Report(
            captureID: captureID,
            generatedAtUTC: ISO8601DateFormatter().string(from: Date()),
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            motionSession: motionSession,
            acceptedCount: samples.count,
            spanSeconds: span,
            acceptedHz: span > 0 ? Double(samples.count - 1) / span : nil,
            acceptedIntervals: stats(intervals),
            cpu: CPUReport(drawableWait: stats(samples.map(\.drawableWait)), provider: stats(samples.map(\.providerCPU)),
                           simulation: stats(samples.map(\.simulationCPU)), encoding: stats(samples.map(\.encodingCPU))),
            eligibleIntervalCount: eligible.count,
            simulatedToEligibleIntervalRatio: intervalSum > 0 ? simulatedSum / intervalSum : nil,
            over50msCount: intervals.filter { $0 > 0.05 }.count,
            over250msExcludedCount: intervals.filter { $0 > 0.25 }.count,
            gpu: GPUReport(execution: stats(gpuResults.compactMap(\.execution)),
                           submitToCompletion: stats(gpuResults.compactMap(\.submitToCompletion)),
                           nonExecutionLatency: stats(nonExecutionLatency),
                           incompleteCount: samples.count - gpu.count)
        )
    }

    private func stats(_ seconds: [TimeInterval]) -> Stats {
        let values = seconds.filter { $0.isFinite && $0 >= 0 }.map { $0 * 1_000 }.sorted()
        guard !values.isEmpty else { return Stats(count: 0, medianMs: nil, p95Ms: nil, maxMs: nil) }
        func percentile(_ fraction: Double) -> Double { values[Int((Double(values.count - 1) * fraction).rounded(.up))] }
        return Stats(count: values.count, medianMs: percentile(0.5), p95Ms: percentile(0.95), maxMs: values.last)
    }

    private func validatedMotionSnapshot(_ snapshot: [String: Double]?) -> [String: Double]? {
        guard let snapshot else { return nil }
        let allowed = Set(["receivedSamples", "maximumRawAccelerationG", "samplesAbove3G",
                           "maximumRotationRateRadPerSec", "maximumSampleAgeMs", "reducedMotion"])
        guard !snapshot.isEmpty, Set(snapshot.keys).isSubset(of: allowed),
              snapshot.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        if let reducedMotion = snapshot["reducedMotion"], reducedMotion != 0 && reducedMotion != 1 { return nil }
        return snapshot
    }

    private struct Report: Codable {
        var captureID: String
        var generatedAtUTC: String
        var appBuild: String?
        var motionSession: [String: Double]?
        var acceptedCount: Int
        var spanSeconds: TimeInterval
        var acceptedHz: Double?
        var acceptedIntervals: Stats
        var cpu: CPUReport
        var eligibleIntervalCount: Int
        var simulatedToEligibleIntervalRatio: Double?
        var over50msCount: Int
        var over250msExcludedCount: Int
        var gpu: GPUReport
    }
    private struct CPUReport: Codable { var drawableWait, provider, simulation, encoding: Stats }
    private struct GPUReport: Codable {
        var execution, submitToCompletion, nonExecutionLatency: Stats
        var incompleteCount: Int
    }
    private struct Stats: Codable { var count: Int; var medianMs, p95Ms, maxMs: Double? }
}
