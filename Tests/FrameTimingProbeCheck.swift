import Foundation

@main
struct FrameTimingProbeCheck {
    static func main() throws {
        let url = URL(fileURLWithPath: "/private/tmp/frame-timing-probe-check.json")
        try? FileManager.default.removeItem(at: url)
        let probe = FrameTimingProbe(outputURL: url, duration: 0.03, captureID: "probe-check")
        let motionSnapshot = ["receivedSamples": 42.0, "maximumRawAccelerationG": 4.2,
                              "samplesAbove3G": 3.0, "maximumRotationRateRadPerSec": 5.1,
                              "maximumSampleAgeMs": 8.0, "reducedMotion": 0.0]
        let first = probe.record(FrameTimingSample(acceptedAt: 10, interval: nil, simulatedDuration: 0,
                                                   drawableWait: 0.001, providerCPU: 0.002, simulationCPU: 0.003, encodingCPU: 0.004),
                                 motionSnapshot: motionSnapshot)
        let second = probe.record(FrameTimingSample(acceptedAt: 10.02, interval: 0.02, simulatedDuration: 0.016,
                                                    drawableWait: 0.003, providerCPU: 0.004, simulationCPU: 0.005, encodingCPU: 0.006),
                                  motionSnapshot: ["unexpected": 1])
        let excluded = probe.record(FrameTimingSample(acceptedAt: 10.025, interval: 0.3, simulatedDuration: 0.05,
                                                      drawableWait: 0, providerCPU: 0, simulationCPU: 0, encodingCPU: 0),
                                    motionSnapshot: ["maximumRawAccelerationG": -1])
        let nonfinite = probe.record(FrameTimingSample(acceptedAt: 10.026, interval: 0.01, simulatedDuration: 0.008,
                                                       drawableWait: 0, providerCPU: 0, simulationCPU: 0, encodingCPU: 0),
                                     motionSnapshot: ["maximumRawAccelerationG": .nan, "maximumSampleAgeMs": .infinity])
        guard let first, let second, let excluded, let nonfinite else { throw Failure("accepted sample missing") }
        probe.recordGPU(frameID: first, execution: 0.007, submitToCompletion: 0.009)
        probe.recordGPU(frameID: first, execution: 0.1, submitToCompletion: 0.1) // duplicate ignored
        probe.recordGPU(frameID: 999, execution: 0.1, submitToCompletion: 0.1) // unknown ignored
        _ = excluded
        Thread.sleep(forTimeInterval: 0.06) // CPU collection is closed; GPU grace remains.
        probe.recordGPU(frameID: second, execution: 0.008, submitToCompletion: 0.011)
        probe.recordGPU(frameID: second, execution: 0.1, submitToCompletion: 0.1) // duplicate in grace ignored
        let data = try waitForJSON(at: url)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try require(json["captureID"] as? String == "probe-check", "capture id missing")
        try require(json["generatedAtUTC"] as? String != nil, "UTC generation time missing")
        let savedMotion = json["motionSession"] as? [String: Double]
        try require(savedMotion == motionSnapshot, "motion snapshot validation or retention failed")
        try require(json["acceptedCount"] as? Int == 4, "CPU bound/count failed")
        try require(json["eligibleIntervalCount"] as? Int == 2, "interval eligibility failed")
        try require(json["over250msExcludedCount"] as? Int == 1, "long interval exclusion failed")
        let intervalStats = json["acceptedIntervals"] as! [String: Any]
        try require(intervalStats["count"] as? Int == 3, "interval p95/max population failed")
        try require(abs((intervalStats["p95Ms"] as? Double ?? 0) - 300) < 0.0001 &&
                    abs((intervalStats["maxMs"] as? Double ?? 0) - 300) < 0.0001,
                    "interval millisecond percentile values failed")
        try require(abs((json["simulatedToEligibleIntervalRatio"] as? Double ?? 0) - 0.8) < 0.0001, "ratio failed")
        let gpu = json["gpu"] as! [String: Any]
        try require(gpu["incompleteCount"] as? Int == 2, "GPU grace or duplicate accounting failed")
        let paired = gpu["nonExecutionLatency"] as! [String: Any]
        try require(paired["count"] as? Int == 2, "paired non-execution latency missing")
        try require(abs((paired["maxMs"] as? Double ?? 0) - 3) < 0.0001 &&
                    abs((paired["medianMs"] as? Double ?? 0) - 3) < 0.0001,
                    "paired millisecond values failed")
        let secondWrite = probe.record(FrameTimingSample(acceptedAt: 11, interval: 0.01, simulatedDuration: 0.01,
                                                         drawableWait: 0, providerCPU: 0, simulationCPU: 0, encodingCPU: 0))
        try require(secondWrite == nil, "probe accepted post-cutoff record")
        let bytesBefore = try Data(contentsOf: url)
        probe.recordGPU(frameID: excluded, execution: 0.01, submitToCompletion: 0.02)
        probe.recordGPU(frameID: nonfinite, execution: 0.01, submitToCompletion: 0.02)
        Thread.sleep(forTimeInterval: 0.05)
        let bytesAfter = try Data(contentsOf: url)
        try require(bytesBefore == bytesAfter, "probe wrote more than once")

        let capURL = URL(fileURLWithPath: "/private/tmp/frame-timing-probe-cap-check.json")
        try? FileManager.default.removeItem(at: capURL)
        let capped = FrameTimingProbe(outputURL: capURL, duration: 5)
        for _ in 0..<1_200 {
            guard capped.record(FrameTimingSample(acceptedAt: 20, interval: 0.01, simulatedDuration: 0.01,
                                                  drawableWait: 0, providerCPU: 0, simulationCPU: 0, encodingCPU: 0)) != nil else {
                throw Failure("probe rejected before its CPU bound")
            }
        }
        try require(capped.record(FrameTimingSample(acceptedAt: 20, interval: 0.01, simulatedDuration: 0.01,
                                                    drawableWait: 0, providerCPU: 0, simulationCPU: 0, encodingCPU: 0)) == nil,
                    "1,201st CPU sample bypassed the bound")
        print("PASS: frame timing probe aggregation")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message) }
    }
    private static func waitForJSON(at url: URL) throws -> Data {
        for _ in 0..<30 {
            if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw Failure("timing report was not written")
    }
    private struct Failure: Error, CustomStringConvertible { var description: String; init(_ description: String) { self.description = description } }
}
