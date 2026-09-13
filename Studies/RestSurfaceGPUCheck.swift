import Foundation
import MetalKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// A/B the same frozen particles through the native field and display pipeline.
/// Usage: rest-surface-gpu-check snapshot.json baseline-field.metal output-directory
@main struct RestSurfaceGPUCheck {
    enum Failure: Error { case invalid(String) }
    static let w = 256, h = 544, d = 48
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func png(_ texture: MTLTexture, _ url: URL) throws {
        let width = texture.width, height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info,
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        let sink = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(sink, image, nil)
        guard CGImageDestinationFinalize(sink) else { throw Failure.invalid("PNG") }
    }
    static func run() throws {
        let baselineOnly = CommandLine.arguments.last == "--baseline-only"
        guard CommandLine.arguments.count == (baselineOnly ? 5 : 4) else { throw Failure.invalid("arguments") }
        let snapshotData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let output = URL(fileURLWithPath: CommandLine.arguments[3])
        guard !FileManager.default.fileExists(atPath: output.path),
              let snapshot = try JSONSerialization.jsonObject(with: snapshotData) as? [String: Any],
              let rows = snapshot["particles"] as? [[String: [Double]]],
              let summary = snapshot["summary"] as? [String: Any],
              let boat = summary["boat"] as? [String: Any],
              let boatPosition = boat["position"] as? [Double], boatPosition.count == 3,
              let angle = boat["angle"] as? Double,
              let energy = summary["energy"] as? Double,
              let immersion = boat["immersion"] as? Double,
              let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure.invalid("frozen snapshot or Metal")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let particles = try rows.map { row -> SIMD4<Float> in
            guard let p = row["position"], p.count == 3, p.allSatisfy(\.isFinite) else { throw Failure.invalid("particle") }
            return SIMD4(Float(p[0]), Float(p[1]), Float(p[2]), 0.098 * 1.5)
        }
        let buffer = particles.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
        let bubbles = device.makeBuffer(length: 16, options: .storageModeShared)!
        let readback = device.makeBuffer(length: w * h * d * 2, options: .storageModeShared)!
        let boundsReadback = device.makeBuffer(length: 64 * 136 * 12 * 4, options: .storageModeShared)!
        let screenDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 1206, height: 2557, mipmapped: false)
        screenDescriptor.storageMode = .shared; screenDescriptor.usage = [.renderTarget, .shaderRead]
        let screen = device.makeTexture(descriptor: screenDescriptor)!
        let common = try String(contentsOfFile: "SmallWave/Rendering/LiquidShaders.metal", encoding: .utf8)
        let transport = try String(contentsOfFile: "SmallWave/Rendering/MobileVolumeOptics.metal", encoding: .utf8)
        let oldField = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        let newField = try String(contentsOfFile: "SmallWave/Rendering/LiquidVolumeField.metal", encoding: .utf8)
        let art = try loadArt(device: device, queue: queue)
        let gravityRows = snapshot["gravity"] as? [Double] ?? [0, -1, 0]
        guard gravityRows.count == 3 else { throw Failure.invalid("gravity") }
        let gravity = SIMD3<Float>(Float(gravityRows[0]), Float(gravityRows[1]), Float(gravityRows[2]))
        let tangent = simd_normalize(SIMD2(-gravity.y, gravity.x))
        var uniforms = OceanUniforms()
        uniforms.viewport = SIMD4(1, 2.12, 12, 0)
        uniforms.boat = SIMD4(Float(boatPosition[0]), Float(boatPosition[1]), Float(angle), Float(boatPosition[2]))
        uniforms.movement = SIMD4(gravity, Float(energy))
        uniforms.color = SIMD4(0.0001, 0.16, 0.45, 0)
        uniforms.optics = SIMD4(1.46, 1.333, 0.3, 0)
        uniforms.miniatureArt = SIMD4(0, 0.75, Float(immersion), 0)
        var reports = [[String: Any]](), baseline: Data?
        let cases = [
            ("baseline", oldField, SIMD4<Float>(1, 0, 1, 0)),
            ("baseline-repeat", oldField, SIMD4<Float>(1, 0, 1, 0)),
            ("dynamic", newField, SIMD4<Float>(1, 0, 1, 0)),
            ("settled", newField, SIMD4<Float>(tangent.x, tangent.y, 3, 1))
        ]
        for (label, fieldSource, filter) in (baselineOnly ? Array(cases.prefix(1)) : cases) {
            let source = "#define LIVE_CONCATENATED_SHADER 1\n" + common + "\n" + fieldSource + "\n" + transport
            let library = try device.makeLibrary(source: source, options: nil)
            let renderer = try LiquidVolumeRenderer(device: device, library: library)
            renderer.tracesAirBubbles = true; renderer.appliesEdgeAntialiasing = true
            renderer.miniatureTexture = art; renderer.surfaceFilter = filter
            var fieldTimes = [Double](), displayTimes = [Double]()
            // Warm-up is excluded. Samples are serial GPU times on this Mac, not phone FPS.
            for sample in 0..<5 {
                let command = queue.makeCommandBuffer()!
                try renderer.field.encode(commandBuffer: command, particles: buffer, particleCount: particles.count,
                    bubbles: bubbles, bubbleCount: 0, surfaceFilter: filter)
                command.commit(); command.waitUntilCompleted()
                guard command.status == .completed, command.error == nil else { throw Failure.invalid("field GPU") }
                if sample > 0 { fieldTimes.append((command.gpuEndTime - command.gpuStartTime) * 1000) }
            }
            let copy = queue.makeCommandBuffer()!, blit = copy.makeBlitCommandEncoder()!
            blit.copy(from: renderer.field.field, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOriginMake(0, 0, 0),
                sourceSize: MTLSizeMake(w, h, d), to: readback, destinationOffset: 0,
                destinationBytesPerRow: w * 2, destinationBytesPerImage: w * h * 2)
            blit.copy(from: renderer.field.bounds, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOriginMake(0, 0, 0),
                sourceSize: MTLSizeMake(64, 136, 12), to: boundsReadback, destinationOffset: 0,
                destinationBytesPerRow: 64 * 4, destinationBytesPerImage: 64 * 136 * 4)
            blit.endEncoding(); copy.commit(); copy.waitUntilCompleted()
            guard copy.status == .completed else { throw Failure.invalid("readback") }
            let bytes = Data(bytes: readback.contents(), count: w * h * d * 2)
            let values = readback.contents().bindMemory(to: UInt16.self, capacity: w * h * d)
            func density(_ x: Int, _ y: Int, _ z: Int) -> Float { Float(Float16(bitPattern: values[x + w * (y + h * z)])) }
            if baselineOnly {
                var mask = [UInt8](repeating: 255, count: w * h * 4)
                for y in 0..<h { for x in 0..<w {
                    let occupied = (0..<d).contains { density(x, y, $0) >= 0.6 }
                    if occupied { let i = 4 * (x + w * y); mask[i] = 180; mask[i + 1] = 85; mask[i + 2] = 20 }
                } }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
                descriptor.storageMode = .shared
                let texture = device.makeTexture(descriptor: descriptor)!
                mask.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
                try png(texture, output.appendingPathComponent("full-depth-density-mask.png"))
            }
            var crossings = [[Double]](), nonfinite = 0, occupied = 0, integral = 0.0
            for index in 0..<(w * h * d) {
                let f = Float(Float16(bitPattern: values[index]))
                if !f.isFinite { nonfinite += 1 } else { integral += Double(f); if f >= 0.6 { occupied += 1 } }
            }
            // Native field coordinates run y/down; locate the top crossing at z=0.
            for x in 26...229 {
                for y in 0..<(h - 1) {
                    let a = density(x, y, d / 2), b = density(x, y + 1, d / 2)
                    if a < 0.6 && b >= 0.6 {
                        let fraction = Double((0.6 - a) / (b - a))
                        let worldY = 2.12 - (Double(y) + 0.5 + fraction) * 4.24 / Double(h)
                        crossings.append([(Double(x) + 0.5) * 2 / Double(w) - 1, worldY]); break
                    }
                }
            }
            guard crossings.count == 204 else { throw Failure.invalid("surface crossings") }
            let heights = crossings.map { $0[1] }, mean = heights.reduce(0, +) / Double(heights.count)
            let rms = sqrt(heights.reduce(0) { $0 + pow($1 - mean, 2) } / Double(heights.count))
            let averageX = crossings.reduce(0) { $0 + $1[0] } / Double(crossings.count)
            let slope = crossings.reduce(0) { $0 + ($1[0] - averageX) * ($1[1] - mean) }
                / crossings.reduce(0) { $0 + pow($1[0] - averageX, 2) }
            let residualRMS = sqrt(crossings.reduce(0) { $0 + pow($1[1] - mean - slope * ($1[0] - averageX), 2) } / Double(crossings.count))
            var sections = [[String: Any]]()
            for z in [6, 12, 24, 35, 41] {
                var sectionHeights = [Double]()
                for x in 0..<w { for y in 0..<(h - 1) {
                    let a = density(x, y, z), b = density(x, y + 1, z)
                    if a < 0.6 && b >= 0.6 {
                        sectionHeights.append(2.12 - (Double(y) + 0.5 + Double((0.6 - a) / (b - a))) * 4.24 / Double(h)); break
                    }
                } }
                sections.append(["z": z, "crossings": sectionHeights.count,
                    "mean": sectionHeights.isEmpty ? 0 : sectionHeights.reduce(0, +) / Double(sectionHeights.count)])
            }
            var boundsFailures = 0
            let boundValues = boundsReadback.contents().bindMemory(to: UInt16.self, capacity: 64 * 136 * 12 * 2)
            for z in 0..<12 { for y in 0..<136 { for x in 0..<64 {
                let i = 2 * (x + 64 * (y + 136 * z))
                let lo = Float(Float16(bitPattern: boundValues[i])), hi = Float(Float16(bitPattern: boundValues[i + 1]))
                if !lo.isFinite || !hi.isFinite { boundsFailures += 1; continue }
                for dz in 0..<5 { for dy in 0..<5 { for dx in 0..<5 {
                    let f = density(min(w - 1, x * 4 + dx), min(h - 1, y * 4 + dy), min(d - 1, z * 4 + dz))
                    if f < lo || f > hi { boundsFailures += 1 }
                } } }
            } } }
            for sample in 0..<4 {
                let command = queue.makeCommandBuffer()!
                try renderer.encodeDisplay(command: command, target: screen, particles: buffer, particleCount: particles.count,
                    bubbles: bubbles, bubbleCount: 0, uniforms: uniforms)
                command.commit(); command.waitUntilCompleted()
                guard command.status == .completed, command.error == nil else { throw Failure.invalid("display GPU") }
                if sample > 0 { displayTimes.append((command.gpuEndTime - command.gpuStartTime) * 1000) }
            }
            try png(screen, output.appendingPathComponent(label + ".png"))
            try JSONSerialization.data(withJSONObject: crossings).write(to: output.appendingPathComponent(label + "-profile.json"))
            if label == "baseline" { baseline = bytes }
            var maxDifference: Float = 0, isoDifferences = 0
            if let baseline {
                baseline.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let old = raw.bindMemory(to: UInt16.self)
                    for index in 0..<(w * h * d) {
                        let a = Float(Float16(bitPattern: old[index])), b = Float(Float16(bitPattern: values[index]))
                        maxDifference = max(maxDifference, abs(a - b))
                        if (a >= 0.6) != (b >= 0.6) { isoDifferences += 1 }
                    }
                }
            }
            guard nonfinite == 0, boundsFailures == 0 else { throw Failure.invalid("field or bounds") }
            reports.append(["label": label, "fieldSHA256": hash(bytes), "shaderSHA256": hash(Data(source.utf8)),
                "surfaceMean": mean, "surfaceRMS": rms, "surfacePeakToPeak": heights.max()! - heights.min()!,
                "surfaceLineResidualRMS": residualRMS, "surfaceSlope": slope, "fullWidthDepthSections": sections,
                "occupiedVoxels": occupied, "densityIntegral": integral, "nonfinite": nonfinite, "boundsFailures": boundsFailures,
                "baselineExactlyEqual": bytes == baseline, "baselineMaxDifference": maxDifference, "baselineIsoDifferences": isoDifferences,
                "fieldGPUMs": fieldTimes, "displayGPUMs": displayTimes])
            print("\(label): RMS=\(rms), range=\(heights.max()! - heights.min()!), fieldGPU=\(fieldTimes), displayGPU=\(displayTimes)")
            fflush(stdout)
        }
        if baselineOnly {
            let report: [String: Any] = ["snapshotSHA256": hash(snapshotData), "device": device.name, "runs": reports,
                "scope": "Baseline frozen-state diagnosis only, no rest filter or acceptance claim. Mask is orthographic full-depth density; beauty is native optical projection."]
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("report.json"))
            return
        }
        let old = reports[0], dynamic = reports[2], calm = reports[3]
        let oldOccupied = Double(old["occupiedVoxels"] as! Int), calmOccupied = Double(calm["occupiedVoxels"] as! Int)
        let occupancyChange = abs(calmOccupied / oldOccupied - 1)
        let levelChange = abs((calm["surfaceMean"] as! Double) - (old["surfaceMean"] as! Double))
        let residualRatio = (calm["surfaceLineResidualRMS"] as! Double) / (old["surfaceLineResidualRMS"] as! Double)
        let oldSections = old["fullWidthDepthSections"] as! [[String: Any]], calmSections = calm["fullWidthDepthSections"] as! [[String: Any]]
        var maxSectionLevelChange = 0.0, maxSectionCrossingChange = 0
        for (a, b) in zip(oldSections, calmSections) {
            maxSectionLevelChange = max(maxSectionLevelChange, abs((a["mean"] as! Double) - (b["mean"] as! Double)))
            maxSectionCrossingChange = max(maxSectionCrossingChange, abs((a["crossings"] as! Int) - (b["crossings"] as! Int)))
        }
        // Half precision accumulation can differ by a few ULPs without moving a visible boundary.
        let dynamicPass = (dynamic["baselineMaxDifference"] as! Float) <= 0.002
            && (dynamic["baselineIsoDifferences"] as! Int) <= 334
            && abs((dynamic["surfaceMean"] as! Double) - (old["surfaceMean"] as! Double)) < 0.0002
        let calmPass = occupancyChange < 0.005 && levelChange < 0.004 && residualRatio < 0.8
            && maxSectionLevelChange < 0.008 && maxSectionCrossingChange <= 4
        let acceptance: [String: Any] = ["dynamicPass": dynamicPass, "calmPass": calmPass,
            "occupancyRelativeChange": occupancyChange, "centralMeanLevelChange": levelChange,
            "lineResidualRatio": residualRatio, "maxFullWidthSectionLevelChange": maxSectionLevelChange,
            "maxFullWidthSectionCrossingChange": maxSectionCrossingChange]
        let report: [String: Any] = ["snapshotSHA256": hash(snapshotData), "device": device.name, "runs": reports,
            "acceptance": acceptance,
            "displayResolution": [1206, 2557], "nativeOpticsShortSide": 480, "phonePerformanceVerified": false,
            "scope": "One frozen upright rest state. Native Metal reconstruction and optics; no UIKit overlay or motion acceptance."]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("report.json"))
        guard dynamicPass, calmPass else { throw Failure.invalid("rest-surface acceptance; inspect report.json") }
    }
    static func loadArt(device: MTLDevice, queue: MTLCommandQueue) throws -> MTLTexture {
        let url = URL(fileURLWithPath: "SmallWave/Miniatures/toy-boat-blue.png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.invalid("art") }
        let scale = min(1, 512.0 / Double(max(image.width, image.height)))
        let width = Int((Double(image.width) * scale).rounded()), height = Int((Double(image.height) * scale).rounded())
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .high; context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        let texture = device.makeTexture(descriptor: descriptor)!
        bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        let command = queue.makeCommandBuffer()!, blit = command.makeBlitCommandEncoder()!
        blit.generateMipmaps(for: texture); blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw Failure.invalid("art mipmaps") }
        return texture
    }
    static func main() { do { try run() } catch { fputs("FAIL \(error)\n", stderr); exit(1) } }
}
