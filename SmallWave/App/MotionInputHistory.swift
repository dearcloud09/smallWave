import Foundation
import simd

/// Preserves high-rate motion direction and timing for individual fixed steps.
struct MotionInputHistory {
    struct Diagnostics: Equatable {
        var receivedSamples = 0
        var lastSampleTimestamp: TimeInterval?
    }

    private struct Reading {
        var timestamp: TimeInterval
        var gravity: SIMD3<Float>
        var acceleration: SIMD3<Float>
    }

    private static let maximumReadings = 128
    private static let maximumDrainGap: TimeInterval = 0.25
    private static let gravityHold: TimeInterval = 0.5
    private static let accelerationHold: TimeInterval = 0.02

    private var readings: [Reading] = []
    private var lastRequestTimestamp: TimeInterval?
    private var consumedThrough: TimeInterval?
    // Resets retain gravity but cannot extend an old acceleration into a new window.
    private var accelerationResetTimestamp: TimeInterval?
    private(set) var diagnostics = Diagnostics()

    mutating func reset() {
        readings.removeAll(keepingCapacity: true)
        lastRequestTimestamp = nil
        consumedThrough = nil
        accelerationResetTimestamp = nil
        diagnostics = Diagnostics()
    }

    mutating func discardPending(at timestamp: TimeInterval) {
        guard timestamp.isFinite else { reset(); return }
        lastRequestTimestamp = timestamp
        consumedThrough = timestamp
        accelerationResetTimestamp = timestamp
        prune(before: timestamp)
    }

    mutating func append(gravity: SIMD3<Float>, acceleration: SIMD3<Float>, timestamp: TimeInterval,
                         receivedAt receiptTimestamp: TimeInterval) {
        guard timestamp.isFinite, receiptTimestamp.isFinite,
              timestamp <= receiptTimestamp + 0.05,
              isFinite(gravity), isFinite(acceleration) else { return }
        guard readings.last?.timestamp ?? -.infinity < timestamp else { return }
        readings.append(Reading(timestamp: timestamp, gravity: gravity,
                                acceleration: MotionSample(acceleration: acceleration).safeAcceleration))
        if readings.count > Self.maximumReadings { readings.removeFirst(readings.count - Self.maximumReadings) }
        diagnostics.receivedSamples += 1
        diagnostics.lastSampleTimestamp = timestamp
    }

    mutating func samples(for plan: LiquidStepPlan, at timestamp: TimeInterval) -> [MotionSample] {
        guard timestamp.isFinite, plan.count > 0, plan.stepDuration.isFinite, plan.stepDuration > 0,
              plan.remainder.isFinite, plan.remainder >= 0 else { return [] }
        guard lastRequestTimestamp.map({ timestamp > $0 }) ?? true else {
            return Array(repeating: MotionSample(), count: plan.count)
        }
        let end = timestamp - Double(plan.remainder)
        let start = end - Double(plan.count) * Double(plan.stepDuration)
        guard start.isFinite, end.isFinite, end >= start else { return [] }
        let latest = readings.last(where: { $0.timestamp <= end })
        let stale = latest.map { end - $0.timestamp > Self.gravityHold } ?? true
        let requestGap = lastRequestTimestamp.map { timestamp - $0 }
        lastRequestTimestamp = timestamp
        guard !stale, let latest else {
            consumedThrough = end; accelerationResetTimestamp = end; prune(before: end)
            return Array(repeating: MotionSample(), count: plan.count)
        }
        let baseline = consumedThrough == nil || (requestGap ?? .infinity) > Self.maximumDrainGap
        if baseline {
            consumedThrough = end; accelerationResetTimestamp = end; prune(before: end)
            return Array(repeating: MotionSample(gravity: latest.gravity), count: plan.count)
        }
        if let consumedThrough, start > consumedThrough {
            self.consumedThrough = start
            prune(before: start)
        }
        let lowerBound = max(start, consumedThrough ?? start)
        var result: [MotionSample] = []
        result.reserveCapacity(plan.count)
        for index in 0..<plan.count {
            let stepStart = start + Double(index) * Double(plan.stepDuration)
            let stepEnd = stepStart + Double(plan.stepDuration)
            let activeStart = max(stepStart, lowerBound)
            let gravity = average(from: stepStart, to: stepEnd, hold: Self.gravityHold, acceleration: false)
            let acceleration = activeStart < stepEnd
                ? average(from: activeStart, to: stepEnd, hold: Self.accelerationHold,
                          acceleration: true, denominator: stepEnd - stepStart) : nil
            result.append(MotionSample(gravity: gravity ?? latest.gravity, acceleration: acceleration ?? .zero))
        }
        consumedThrough = end
        prune(before: end)
        return result
    }

    private func average(from start: TimeInterval, to end: TimeInterval, hold: TimeInterval,
                         acceleration: Bool, denominator: TimeInterval? = nil) -> SIMD3<Float>? {
        guard end > start else { return nil }
        var total = SIMD3<Float>.zero
        var covered = false
        for (index, reading) in readings.enumerated() {
            if acceleration, let accelerationResetTimestamp, reading.timestamp <= accelerationResetTimestamp { continue }
            let next = index + 1 < readings.count ? readings[index + 1].timestamp : .infinity
            let intervalEnd = min(next, reading.timestamp + hold)
            let overlap = max(0, min(end, intervalEnd) - max(start, reading.timestamp))
            guard overlap > 0 else { continue }
            total += (acceleration ? reading.acceleration : reading.gravity) * Float(overlap)
            covered = true
        }
        let duration = denominator ?? (end - start)
        return covered && duration > 0 ? total / Float(duration) : nil
    }

    private mutating func prune(before timestamp: TimeInterval) {
        // Preserve the predecessor across fractional boundaries and all future readings.
        guard let retained = readings.last(where: { $0.timestamp <= timestamp }) else { return }
        readings.removeAll { $0.timestamp < retained.timestamp }
    }

    private func isFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }
}
