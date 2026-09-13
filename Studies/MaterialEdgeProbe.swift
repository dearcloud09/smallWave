import Foundation
import MetalKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import simd

// Mirrors the active renderer ABI; this standalone study does not run simulation.
struct OceanUniforms {
    var viewport = SIMD4<Float>(1, 2.12, 0, 0)
    var boat = SIMD4<Float>.zero
    var movement = SIMD4<Float>(0, -1, 0, 0)
    var color = SIMD4<Float>(0.0001, 0.16, 0.45, 0)
    var optics = SIMD4<Float>(1.46, 1.333, 0.3, 0)
    var miniatureArt = SIMD4<Float>(-1, 0.75, 0, 0)
}

enum OceanRendererError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case let .unavailable(reason): return reason }
    }
}

/// Renders one frozen native state with the current post-ray edge pass on and off.
@main
struct MaterialEdgeProbe {
    enum Failure: Error { case invalid(String) }

    static func main() {
        do { try run() }
        catch { fputs("FAIL \(error)\n", stderr); exit(1) }
    }

    static func run() throws {
        let extras = Array(CommandLine.arguments.dropFirst(3))
        let diagnostics = extras.contains("--diagnostics")
        let overrides = extras.filter { $0 != "--diagnostics" }
        guard CommandLine.arguments.count >= 3, overrides.count <= 1 else {
            throw Failure.invalid("usage: snapshot output-directory [transport.metal] [--diagnostics]")
        }
        let snapshotURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.invalid("output exists") }
        let snapshotData = try Data(contentsOf: snapshotURL)
        guard let snapshot = try JSONSerialization.jsonObject(with: snapshotData) as? [String: Any],
              let particleRows = snapshot["particles"] as? [[String: Any]],
              let bubbleRows = snapshot["bubbles"] as? [[String: Any]],
              let radius = finiteFloat(snapshot["renderRadius"]),
              let summary = snapshot["summary"] as? [String: Any],
              let time = finiteFloat(summary["time"]),
              let energy = finiteFloat(summary["energy"]),
              let boat = summary["boat"] as? [String: Any],
              let boatPosition = vector3(boat["position"]),
              let boatVelocity = vector3(boat["velocity"]),
              let boatAngle = finiteFloat(boat["angle"]),
              let immersion = finiteFloat(boat["immersion"]) else {
            throw Failure.invalid("snapshot schema")
        }
        guard (1...4096).contains(particleRows.count), bubbleRows.count <= 36, radius > 0 else {
            throw Failure.invalid("particle/bubble count or radius")
        }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure.invalid("Metal unavailable")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let particles = try particleRows.map { row -> SIMD4<Float> in
            guard let position = vector3(row["position"]) else { throw Failure.invalid("particle position") }
            return SIMD4(position, radius)
        }
        let bubbles = try bubbleRows.map { row -> SIMD4<Float> in
            guard let position = vector3(row["position"]), let bubbleRadius = finiteFloat(row["radius"]) else {
                throw Failure.invalid("bubble")
            }
            return SIMD4(position, bubbleRadius)
        }
        guard bubbles.count <= 36 else { throw Failure.invalid("bubble count") }
        let particleBuffer = particles.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)!
        }
        let bubbleStorage = bubbles.isEmpty ? [SIMD4<Float>.zero] : bubbles
        let bubbleBuffer = bubbleStorage.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)!
        }
        let common = try String(contentsOfFile: "SmallWave/Rendering/LiquidShaders.metal", encoding: .utf8)
        let field = try String(contentsOfFile: "SmallWave/Rendering/LiquidVolumeField.metal", encoding: .utf8)
        let transport = try String(contentsOfFile: overrides.first ?? "SmallWave/Rendering/MobileVolumeOptics.metal", encoding: .utf8)
        let source = "#define LIVE_CONCATENATED_SHADER 1\n" + common + "\n" + field + "\n" + transport
        let library = try device.makeLibrary(source: source, options: nil)
        let art = try loadArt(device: device, queue: queue)
        let renderState = snapshot["renderState"] as? [String: Any]
        if let renderState {
            guard renderState["targetPixelWidth"] is NSNumber, renderState["targetPixelHeight"] is NSNumber else {
                throw Failure.invalid("captured render dimensions")
            }
        }
        let renderWidth = (renderState?["targetPixelWidth"] as? NSNumber)?.intValue ?? 1206
        let renderHeight = (renderState?["targetPixelHeight"] as? NSNumber)?.intValue ?? 2557
        guard (1...5000).contains(renderWidth), (1...5000).contains(renderHeight) else { throw Failure.invalid("render dimensions") }
        let screen = try screenTexture(device: device, width: renderWidth, height: renderHeight)

        var uniforms = OceanUniforms()
        uniforms.viewport = SIMD4(1, 2.12, time, 0) // snapshot has no screen rotation; renderer default is 0.
        uniforms.boat = SIMD4(boatPosition.x, boatPosition.y, boatAngle, boatPosition.z)
        let gravity = vector3(snapshot["gravity"]) ?? SIMD3<Float>(0, -1, 0)
        uniforms.movement = SIMD4(gravity, energy)
        uniforms.miniatureArt = SIMD4(0, 0.75, immersion,
                                      simd_dot(SIMD2(boatVelocity.x, boatVelocity.y), SIMD2(cos(boatAngle), sin(boatAngle))))
        if let renderState {
            guard let viewport = vector4(renderState["viewport"]), let boat = vector4(renderState["boat"]),
                  let movement = vector4(renderState["movement"]), let color = vector4(renderState["color"]),
                  let optics = vector4(renderState["optics"]), let miniatureArt = vector4(renderState["miniatureArt"]) else {
                throw Failure.invalid("captured render uniforms")
            }
            uniforms.viewport = viewport; uniforms.boat = boat; uniforms.movement = movement
            uniforms.color = color; uniforms.optics = optics; uniforms.miniatureArt = miniatureArt
        }
        let surfaceFilter = vector4(snapshot["surfaceFilter"]) ?? SIMD4<Float>(1, 0, 1, 0)

        var reportRows = [[String: Any]]()
        for (label, edgeAA) in [("edge-aa-on", true), ("edge-aa-off", false)] {
            let renderer = try LiquidVolumeRenderer(device: device, library: library)
            renderer.tracesAirBubbles = true
            renderer.appliesEdgeAntialiasing = edgeAA
            renderer.miniatureTexture = art
            renderer.surfaceFilter = surfaceFilter
            let command = queue.makeCommandBuffer()!
            try renderer.encodeDisplay(command: command, target: screen, particles: particleBuffer,
                                       particleCount: particles.count, bubbles: bubbleBuffer, bubbleCount: bubbles.count,
                                       uniforms: uniforms)
            command.commit(); command.waitUntilCompleted()
            guard command.status == .completed, command.error == nil else { throw Failure.invalid("native render \(label)") }
            let data = try png(screen, output.appendingPathComponent(label + ".png"))
            reportRows.append(["label": label, "edgeAntialiasing": edgeAA,
                               "gpuMs": (command.gpuEndTime - command.gpuStartTime) * 1_000,
                               "pngSHA256": hash(data)])
        }
        if diagnostics {
            // Direct native transport at the same 480px internal resolution.
            // Save both existing shader diagnostic modes without altering transport.
            for (name, prefix) in [("budget", ""), ("path", "#define LIVE_PATH_DIAGNOSTICS 1\n")] {
                let diagnosticLibrary = try device.makeLibrary(source: prefix + source, options: nil)
                let renderer = try LiquidVolumeRenderer(device: device, library: diagnosticLibrary)
                renderer.tracesAirBubbles = true
                renderer.miniatureTexture = art
                renderer.surfaceFilter = surfaceFilter
                let scale = min(1, 480.0 / Double(min(renderWidth, renderHeight)))
                let width = max(1, Int((Double(renderWidth) * scale).rounded()))
                let height = max(1, Int((Double(renderHeight) * scale).rounded()))
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
                let color = device.makeTexture(descriptor: descriptor)!
                descriptor.pixelFormat = .rgba16Float
                let values = device.makeTexture(descriptor: descriptor)!
                let command = queue.makeCommandBuffer()!
                try renderer.encode(command: command, target: color, diagnostics: values,
                                    particles: particleBuffer, particleCount: particles.count,
                                    bubbles: bubbleBuffer, bubbleCount: bubbles.count, uniforms: uniforms)
                command.commit(); command.waitUntilCompleted()
                guard command.status == .completed, command.error == nil else { throw Failure.invalid("diagnostic render") }
                let data = try png(color, output.appendingPathComponent(name + "-internal.png"))
                var bytes = [UInt16](repeating: 0, count: width * height * 4)
                bytes.withUnsafeMutableBytes { values.getBytes($0.baseAddress!, bytesPerRow: width * 8,
                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
                try bytes.withUnsafeBytes { try Data($0).write(to: output.appendingPathComponent(name + "-rgba16f.bin")) }
                let invalid = stride(from: 3, to: bytes.count, by: 4).filter { Float(Float16(bitPattern: bytes[$0])) > 0 }.count
                guard bytes.allSatisfy({ Float16(bitPattern: $0).isFinite }), invalid == 0 else {
                    throw Failure.invalid("nonfinite or invalid transport")
                }
                reportRows.append(["label": name, "width": width, "height": height,
                                   "channels": name == "budget" ? ["samples/256", "tail", "boundaries/8", "invalid"] : ["blueLength", "blueTailDistance", "blueTIR", "invalid"],
                                   "pngSHA256": hash(data), "shaderSHA256": hash(Data((prefix + source).utf8)), "invalid": invalid])
            }
        }
        let manifest: [String: Any] = [
            "snapshot": ["path": snapshotURL.path, "sha256": hash(snapshotData),
                         "time": time, "renderRadius": radius, "particleCount": particles.count, "bubbleCount": bubbles.count],
            "boat": ["position": [boatPosition.x, boatPosition.y, boatPosition.z], "velocity": [boatVelocity.x, boatVelocity.y, boatVelocity.z],
                     "angle": boatAngle, "immersion": immersion],
            "usesCapturedRenderState": renderState != nil,
            "gravityFallback": snapshot["gravity"] == nil && renderState == nil,
            "sources": ["LiquidShaders.metal": hash(Data(common.utf8)), "LiquidVolumeField.metal": hash(Data(field.utf8)),
                        "MobileVolumeOptics.metal": hash(Data(transport.utf8))],
            "device": device.name, "displayResolution": [screen.width, screen.height], "runs": reportRows,
            "scope": "Frozen-state native optics control only. Particle state is not advanced; no claim about video flicker, phone performance, or physics."
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("manifest.json"))
        print("PASS rendered edge AA on/off at \(screen.width)x\(screen.height)")
    }

    static func finiteFloat(_ value: Any?) -> Float? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, abs(double) <= Double(Float.greatestFiniteMagnitude) else { return nil }
        return Float(double)
    }
    static func vector3(_ value: Any?) -> SIMD3<Float>? {
        guard let values = value as? [Any], values.count == 3,
              let x = finiteFloat(values[0]), let y = finiteFloat(values[1]), let z = finiteFloat(values[2]) else { return nil }
        return SIMD3(x, y, z)
    }
    static func vector4(_ value: Any?) -> SIMD4<Float>? {
        guard let values = value as? [Any], values.count == 4,
              let x = finiteFloat(values[0]), let y = finiteFloat(values[1]),
              let z = finiteFloat(values[2]), let w = finiteFloat(values[3]) else { return nil }
        return SIMD4(x, y, z, w)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func screenTexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.invalid("screen") }
        return texture
    }
    static func png(_ texture: MTLTexture, _ url: URL) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let image = CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: texture.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info,
                                  provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.invalid("PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalid("PNG finalize") }
        return try Data(contentsOf: url)
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
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.invalid("art texture") }
        bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        let command = queue.makeCommandBuffer()!, blit = command.makeBlitCommandEncoder()!
        blit.generateMipmaps(for: texture); blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw Failure.invalid("art mipmaps") }
        return texture
    }
}
