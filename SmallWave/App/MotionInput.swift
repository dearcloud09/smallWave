import Foundation
import Combine
import CoreMotion
import simd

final class MotionInput: ObservableObject {
    @Published private(set) var unavailable = false
    private let manager = CMMotionManager()
    private let historyLock = NSLock()
    private let updateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "smallwave.motion-input"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()
    private var history = MotionInputHistory()
    private var updateGeneration = 0

    func samples(for plan: LiquidStepPlan, at timestamp: TimeInterval) -> [MotionSample] {
        historyLock.lock()
        defer { historyLock.unlock() }
        return history.samples(for: plan, at: timestamp)
    }

    var diagnostics: MotionInputHistory.Diagnostics {
        historyLock.lock()
        defer { historyLock.unlock() }
        return history.diagnostics
    }

    func start() {
        guard !manager.isDeviceMotionActive else { return }
        guard manager.isDeviceMotionAvailable else { unavailable = true; return }
        unavailable = false
        manager.deviceMotionUpdateInterval = 1 / 100
        historyLock.lock()
        history.reset()
        updateGeneration += 1
        let generation = updateGeneration
        historyLock.unlock()
        // Keep the 100 Hz callback off the main queue. Rendering drains its bounded history.
        manager.startDeviceMotionUpdates(to: updateQueue) { [weak self] motion, _ in
            guard let motion else { return }
            self?.record(motion, generation: generation)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        historyLock.lock()
        history.reset()
        updateGeneration += 1
        historyLock.unlock()
    }

    /// Call when rendering pauses but device-motion collection remains active.
    func discardPending() {
        historyLock.lock()
        history.discardPending(at: ProcessInfo.processInfo.systemUptime)
        historyLock.unlock()
    }

    deinit { manager.stopDeviceMotionUpdates() }

    private func record(_ motion: CMDeviceMotion, generation: Int) {
        let gravity = SIMD3(Float(motion.gravity.x), Float(motion.gravity.y), Float(motion.gravity.z))
        let acceleration = SIMD3(Float(motion.userAcceleration.x), Float(motion.userAcceleration.y),
                                 Float(motion.userAcceleration.z))
        historyLock.lock()
        guard generation == updateGeneration else {
            historyLock.unlock()
            return
        }
        history.append(gravity: gravity, acceleration: acceleration, timestamp: motion.timestamp,
                       receivedAt: ProcessInfo.processInfo.systemUptime)
        historyLock.unlock()
    }
}
