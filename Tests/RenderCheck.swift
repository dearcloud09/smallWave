import Foundation
import MetalKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

@main
struct RenderCheck {
    static let liveVolume = ProcessInfo.processInfo.environment["SMALLWAVE_LIVE"] == "1"
    static let miniatureStudy = ProcessInfo.processInfo.environment["SMALLWAVE_BACKDROP"] == "miniature"
    static let depthStudy = ProcessInfo.processInfo.environment["SMALLWAVE_DEPTH"] == "1"
    static let cohesionStudy = ProcessInfo.processInfo.environment["SMALLWAVE_COHESION"] == "1"
    static let legacyPhysics = ProcessInfo.processInfo.environment["SMALLWAVE_COHESION"] == "0"
    static let bubbleStudy = ProcessInfo.processInfo.environment["SMALLWAVE_BUBBLES"] == "1"
    static let legacyBubbles = ProcessInfo.processInfo.environment["SMALLWAVE_BUBBLES"] == "0"
    static let surfaceStudy = ProcessInfo.processInfo.environment["SMALLWAVE_SURFACE"] == "1"
    static let maskStudy = ProcessInfo.processInfo.environment["SMALLWAVE_MASK"] == "1"
    static let materialStudy = ProcessInfo.processInfo.environment["SMALLWAVE_MATERIAL"] == "1"
    static let connectedStudy = ProcessInfo.processInfo.environment["SMALLWAVE_CONNECTED_SHADE"] == "1"
    static var outputFolder: String {
        ".build-cache/previews" + (liveVolume ? "/live-volume":"") + (connectedStudy ? "/connected-shading":"") + (surfaceStudy ? "/continuous-surface" : "") + (materialStudy ? "/clear-interface" : "") + (maskStudy ? "/mask" : "") + (legacyBubbles ? "/legacy-bubbles" : "") + (bubbleStudy ? "/interface-bubbles" : "") + (legacyPhysics ? "/legacy-physics" : "") + (cohesionStudy ? "/cohesion" : "") + (depthStudy ? "/depth" : "") + (miniatureStudy ? "/miniature" : "")
    }
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw OceanRendererError.unavailable("No Metal device is available to this process")
        }
        var source = try String(contentsOfFile: "SmallWave/Rendering/LiquidShaders.metal", encoding: .utf8)
        if liveVolume {
            source = "#define LIVE_CONCATENATED_SHADER 1\n" + source
                + (try String(contentsOfFile: "SmallWave/Rendering/LiquidVolumeField.metal", encoding: .utf8))
                + (try String(contentsOfFile: "SmallWave/Rendering/MobileVolumeOptics.metal", encoding: .utf8))
        }
        if connectedStudy { source=try ConnectedShading.source(source) }
        if maskStudy {
            source = source.replacingOccurrences(of: "float4 dryToy=miniature(world,u);",
                with: "return float4(float3(coverage),1);\n    float4 dryToy=miniature(world,u);")
        }
        let library = try device.makeLibrary(source: source, options: nil)
        let renderer = try LiquidRenderer(device: device, library: library,
            cohesionStrength: legacyPhysics ? 0 : LiquidSimulation.defaultCohesionStrength,
            interfaceBubbles: !legacyBubbles && LiquidSimulation.defaultInterfaceBubbles,
            surfaceStudy: surfaceStudy || materialStudy)
        renderer.usesVolumeOptics = liveVolume
        renderer.miniatureBackdrop = miniatureStudy
        renderer.reconstructedSurface = depthStudy
        renderer.continuousSurface = surfaceStudy
        renderer.clearInterface = materialStudy
        renderer.showsBubbles = !maskStudy
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 600, height: 1272, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let target = device.makeTexture(descriptor: descriptor) else {
            throw OceanRendererError.unavailable("Cannot allocate render target")
        }
        // Rejected study code must require an explicitly prepared renderer,
        // and cannot silently mix ellipse coverage with the circular atlas.
        let savedSurface=renderer.continuousSurface, savedDepth=renderer.reconstructedSurface
        renderer.continuousSurface=true
        renderer.reconstructedSurface=surfaceStudy || materialStudy
        let stepsBeforeRejectedMode=renderer.simulation.steps
        var rejected=false
        do { try renderer.render(into:target,elapsed:1/60,waitForCompletion:true) }
        catch { rejected=true }
        guard rejected, renderer.simulation.steps==stepsBeforeRejectedMode else {
            throw OceanRendererError.unavailable("Invalid surface study mode was accepted or advanced the simulation")
        }
        renderer.continuousSurface=savedSurface
        renderer.reconstructedSurface=savedDepth
        print("PASS incompatible or unprepared surface study is rejected before simulation/render work")
        try FileManager.default.createDirectory(atPath: outputFolder, withIntermediateDirectories: true)
        // Keep the exact compiled shader beside captures so an older preview
        // cannot silently become the baseline for a newer source revision.
        let inputFiles = ["SmallWave/Core/LiquidSimulation.swift", "SmallWave/Core/OceanStyle.swift",
                          "SmallWave/Rendering/LiquidRenderer.swift", "Tests/RenderCheck.swift",
                          "Studies/ConnectedShading.swift", "SmallWave/Rendering/LiquidVolumeField.swift",
                          "SmallWave/Rendering/LiquidVolumeRenderer.swift", "scripts/test-render.sh"]
        var hashes = [String: String]()
        for file in inputFiles {
            hashes[file] = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: file)))
                .map { String(format: "%02x", $0) }.joined()
        }
        hashes["executable"] = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))).map { String(format: "%02x", $0) }.joined()
        hashes["compiledShader"] = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let studyKeys: Set<String> = ["SMALLWAVE_BACKDROP", "SMALLWAVE_DEPTH", "SMALLWAVE_COHESION",
            "SMALLWAVE_BUBBLES", "SMALLWAVE_SURFACE", "SMALLWAVE_MASK", "SMALLWAVE_MATERIAL",
            "SMALLWAVE_CONNECTED_SHADE", "SMALLWAVE_LIVE"]
        let options = ProcessInfo.processInfo.environment.filter { studyKeys.contains($0.key) }
        var provenance: [String: Any] = ["createdAt": ISO8601DateFormatter().string(from: Date()),
                                         "inputsSHA256": hashes, "studyOptions": options,
                                         "portraitSize": [600, 1272], "device": device.name]
        let start = Date()
        for _ in 0..<600 { renderer.simulation.advance(elapsed: 1/120, motion: MotionSample()) }
        try capture(renderer, target, "rest")
        print("REST boat=\(renderer.simulation.boat.position) immersion=\(renderer.simulation.boat.immersion) energy=\(renderer.simulation.energy)")
        renderer.motion = MotionSample(gravity: SIMD3(0.65, -0.76, 0))
        for _ in 0..<220 { renderer.simulation.advance(elapsed: 1/120, motion: renderer.motion) }
        try capture(renderer, target, "tilt")
        for i in 0..<120 {
            let t = Float(i) / 120
            renderer.motion = MotionSample(gravity: SIMD3(0,-1,0),
                acceleration: SIMD3(sin(t*24)*2.5, cos(t*17)*1.5, sin(t*13)*0.8))
            renderer.simulation.advance(elapsed: 1/120, motion: renderer.motion)
        }
        let portraitPixels = try capture(renderer, target, "shake")
        descriptor.width = target.height
        descriptor.height = target.width
        guard let landscape = device.makeTexture(descriptor: descriptor) else {
            throw OceanRendererError.unavailable("Cannot allocate landscape render target")
        }
        for direction in [-1, 1] {
            renderer.screenRotation = Float(direction) * .pi / 2
            let pixels = try capture(renderer, landscape, "landscape-\(direction)")
            // A display rotation alone must preserve the device-space scene.
            // Allow small GPU interpolation/half-float differences at boundaries.
            var absoluteError = 0
            var outliers = 0
            for y in 0..<target.height {
                for x in 0..<target.width {
                    let rx = direction == 1 ? target.height - 1 - y : y
                    let ry = direction == 1 ? x : target.width - 1 - x
                    for c in 0..<3 {
                        let delta = abs(Int(portraitPixels[(y * target.width + x) * 4 + c])
                                      - Int(pixels[(ry * landscape.width + rx) * 4 + c]))
                        absoluteError += delta
                        if delta > 8 { outliers += 1 }
                    }
                }
            }
            let samples = Double(target.width * target.height * 3)
            let mean = Double(absoluteError) / samples
            let outlierFraction = Double(outliers) / samples
            guard mean < 1.0, outlierFraction < 0.005 else {
                throw OceanRendererError.unavailable("Rotation mismatch: mean=\(mean), outliers=\(outlierFraction)")
            }
            print("PASS rotation \(direction): mean channel error=\(mean), outlier fraction=\(outlierFraction)")
        }
        renderer.screenRotation = 0
        renderer.motion = MotionSample(gravity: SIMD3(0,1,0))
        for _ in 0..<240 { renderer.simulation.advance(elapsed: 1/120, motion: renderer.motion) }
        try capture(renderer, target, "inverted")
        renderer.motion = MotionSample(gravity: SIMD3(0,0,-1))
        for _ in 0..<240 { renderer.simulation.advance(elapsed: 1/120, motion: renderer.motion) }
        try capture(renderer, target, "flat")
        var outputHashes = [String: String]()
        for name in ["rest", "tilt", "shake", "landscape--1", "landscape-1", "inverted", "flat"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: "\(outputFolder)/\(name).png"))
            outputHashes["\(name).png"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        provenance["outputsSHA256"] = outputHashes
        provenance["completedAt"] = ISO8601DateFormatter().string(from: Date())
        try source.write(toFile: "\(outputFolder)/shader-source.metal", atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "\(outputFolder)/provenance.json"), options: .atomic)
        print("PASS Metal source compiled, pipelines created and 5 motion states plus 2 display rotations rendered on \(device.name).")
        print("Particles=\(renderer.simulation.particles.count), elapsed=\(Date().timeIntervalSince(start))s. This is Mac rendering, not iPhone performance.")
    }

    @discardableResult
    static func capture(_ renderer: LiquidRenderer, _ texture: MTLTexture, _ name: String) throws -> [UInt8] {
        try renderer.render(into: texture, elapsed: 0, waitForCompletion: true)
        let rowBytes = texture.width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * texture.height)
        pixels.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: rowBytes,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let color = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        let image = CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8,
                            bitsPerPixel: 32, bytesPerRow: rowBytes, space: color,
                            bitmapInfo: info, provider: provider, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        let url = URL(fileURLWithPath: "\(outputFolder)/\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw OceanRendererError.unavailable("Cannot create preview PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw OceanRendererError.unavailable("Cannot write preview PNG")
        }
        print("RENDER \(url.path)")
        return pixels
    }
}
