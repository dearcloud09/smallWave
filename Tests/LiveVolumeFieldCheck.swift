import Foundation
import Metal
import CryptoKit

private enum CheckError: Error { case invalid(String) }

@main private struct LiveVolumeFieldCheck {
    static let width = 256, height = 544, depth = 48
    static let fieldBytes = width * height * depth * 2
    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func half(_ data: Data, _ index: Int) -> Float {
        let offset = index * 2
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            Float(Float16(bitPattern: UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8))
        }
    }
    static func main() { do { try run() } catch { fputs("FAIL \(error)\n", stderr); exit(1) } }

    static func run() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let stateURL = root.appendingPathComponent(".build-cache/material-motion/000/state.json")
        let expectedURL = root.appendingPathComponent(".build-cache/fast-material/000/field.f16")
        let prepareURL = root.appendingPathComponent(".build-cache/fast-material/000/prepare.json")
        let metalURL = root.appendingPathComponent("SmallWave/Rendering/LiquidVolumeField.metal")
        let stateData = try Data(contentsOf: stateURL), expected = try Data(contentsOf: expectedURL)
        guard expected.count == fieldBytes,
              let state = try JSONSerialization.jsonObject(with: stateData) as? [String: Any],
              let particleRows = state["particles"] as? [[Double]],
              let bubbleRows = state["bubbles"] as? [[Double]],
              let spacing = state["spacing"] as? Double,
              let metal = String(data: try Data(contentsOf: metalURL), encoding: .utf8),
              let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw CheckError.invalid("frozen inputs or Metal unavailable")
        }
        let stateSHA = sha(stateData)
        let provenance: String
        if let manifest = try? JSONSerialization.jsonObject(with: Data(contentsOf: prepareURL)) as? [String: Any],
           let preparedStateSHA = manifest["stateSHA256"] as? String {
            guard preparedStateSHA == stateSHA else { throw CheckError.invalid("prepared field state provenance mismatch") }
            provenance = "prepare.json stateSHA256 matched"
        } else {
            provenance = "prepare.json unavailable"
        }
        let particles = try particleRows.map { row -> SIMD4<Float> in
            guard row.count == 3 else { throw CheckError.invalid("particle shape") }
            return SIMD4(Float(row[0]), Float(row[1]), Float(row[2]), Float(spacing) * 1.5)
        }
        let bubbles = try bubbleRows.map { row -> SIMD4<Float> in
            guard row.count == 4 else { throw CheckError.invalid("bubble shape") }
            return SIMD4(Float(row[0]), Float(row[1]), Float(row[2]), Float(row[3]))
        }
        let library = try device.makeLibrary(source: metal, options: nil)
        let live = try LiquidVolumeField(device: device, library: library)
        func inputBuffer(_ values: [SIMD4<Float>]) -> MTLBuffer? {
            guard !values.isEmpty else { return device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared) }
            return values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        }
        guard let particleBuffer = inputBuffer(particles), let bubbleBuffer = inputBuffer(bubbles),
              let fieldReadback = device.makeBuffer(length: fieldBytes, options: .storageModeShared),
              let boundsReadback = device.makeBuffer(length: 64 * 136 * 12 * 4, options: .storageModeShared),
              let command = queue.makeCommandBuffer() else { throw CheckError.invalid("GPU allocation") }
        try live.encode(commandBuffer: command, particles: particleBuffer, particleCount: particles.count,
                        bubbles: bubbleBuffer, bubbleCount: bubbles.count)
        guard let blit = command.makeBlitCommandEncoder() else { throw CheckError.invalid("blit encoder") }
        blit.copy(from: live.field, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOriginMake(0, 0, 0),
                  sourceSize: MTLSizeMake(width, height, depth), to: fieldReadback, destinationOffset: 0,
                  destinationBytesPerRow: width * 2, destinationBytesPerImage: width * height * 2)
        blit.copy(from: live.bounds, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOriginMake(0, 0, 0),
                  sourceSize: MTLSizeMake(64, 136, 12), to: boundsReadback, destinationOffset: 0,
                  destinationBytesPerRow: 64 * 4, destinationBytesPerImage: 64 * 136 * 4)
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed, command.error == nil else { throw CheckError.invalid("GPU command failed") }
        let actual = Data(bytes: fieldReadback.contents(), count: fieldBytes)
        let actualBounds = Data(bytes: boundsReadback.contents(), count: 64 * 136 * 12 * 4)
        var maxError: Float = 0, sumError: Double = 0, signMismatch = 0
        var nearestMismatch: Float = .infinity, maxExpectedMismatchDistance: Float = 0, maxActualMismatchDistance: Float = 0, nonfinite = 0
        for i in 0..<(width * height * depth) {
            let a = half(actual, i), e = half(expected, i)
            if !a.isFinite || !e.isFinite { nonfinite += 1; continue }
            let error = abs(a - e); maxError = max(maxError, error); sumError += Double(error)
            if (a >= 0.6) != (e >= 0.6) {
                signMismatch += 1
                nearestMismatch = min(nearestMismatch, abs(e - 0.6))
                maxExpectedMismatchDistance = max(maxExpectedMismatchDistance, abs(e - 0.6))
                maxActualMismatchDistance = max(maxActualMismatchDistance, abs(a - 0.6))
            }
        }
        var boundsFailures = 0, boundsExactMismatch = 0, boundsNonfinite = 0
        for bz in 0..<12 { for by in 0..<136 { for bx in 0..<64 {
            var lo = Float.infinity, hi = -Float.infinity
            for z in 0..<5 { for y in 0..<5 { for x in 0..<5 {
                let sx = min(bx * 4 + x, width - 1), sy = min(by * 4 + y, height - 1), sz = min(bz * 4 + z, depth - 1)
                let value = half(actual, sx + width * (sy + height * sz)); lo = min(lo, value); hi = max(hi, value)
            } } }
            let offset = 2 * (bx + 64 * (by + 136 * bz))
            let gotLo = half(actualBounds, offset), gotHi = half(actualBounds, offset + 1)
            if !gotLo.isFinite || !gotHi.isFinite { boundsNonfinite += 1 }
            if gotLo > lo || gotHi < hi { boundsFailures += 1 }
            if gotLo != lo || gotHi != hi { boundsExactMismatch += 1 }
        } } }
        let count = Double(width * height * depth)
        let mismatchGuard = max(maxExpectedMismatchDistance, maxActualMismatchDistance) <= maxError
        let comparisonPass = mismatchGuard && nonfinite == 0 && boundsNonfinite == 0 && boundsFailures == 0 && boundsExactMismatch == 0
        let label = comparisonPass ? "PASS" : "FAIL"
        print("\(label) provenance=\(provenance) field maxAbs=\(maxError) meanAbs=\(sumError/count) isoMismatches=\(signMismatch) nearestExpectedDistanceTo0.6=\(nearestMismatch.isFinite ? nearestMismatch : -1) maxExpectedDistanceTo0.6=\(maxExpectedMismatchDistance) maxActualDistanceTo0.6=\(maxActualMismatchDistance) mismatchGuard=\(mismatchGuard) nonfinite=\(nonfinite) boundsFailures=\(boundsFailures) boundsExactMismatch=\(boundsExactMismatch) boundsNonfinite=\(boundsNonfinite)")
        guard comparisonPass else { throw CheckError.invalid("field/bounds comparison") }
    }
}
