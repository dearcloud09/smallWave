import Foundation
import MetalKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

@main struct MaterialTermsStudy {
    static let inputPaths = ["SmallWave/Core/LiquidSimulation.swift", "SmallWave/Core/OceanStyle.swift", "SmallWave/Rendering/LiquidRenderer.swift", "SmallWave/Rendering/LiquidShaders.metal", "Studies/MaterialTerms.swift", "Studies/MaterialTerms.md", "Tests/MaterialTermsStudy.swift", "scripts/study-material-terms.sh"]
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hashes() throws -> [String: String] { try Dictionary(uniqueKeysWithValues: inputPaths.map { ($0, try hash(Data(contentsOf: URL(fileURLWithPath: $0)))) }) }
    static func state(_ sim: LiquidSimulation) -> String {
        var data = Data(); func f(_ x: Float) { var y = x.bitPattern.littleEndian; withUnsafeBytes(of: &y) { data.append(contentsOf: $0) } }; func v(_ x: SIMD3<Float>) { f(x.x); f(x.y); f(x.z) }
        for p in sim.particles { v(p.position); v(p.previous); v(p.velocity) }; for b in sim.bubbles { v(b.position); v(b.velocity); f(b.radius); f(b.life) }
        v(sim.boat.position); v(sim.boat.velocity); f(sim.boat.angle); f(sim.boat.angularVelocity); f(sim.boat.immersion); f(sim.time); f(sim.energy); f(Float(sim.steps)); return hash(data)
    }
    static func bytes(_ texture: MTLTexture) -> [UInt8] { var b = [UInt8](repeating: 0, count: texture.width * texture.height * 4); b.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }; return b }
    static func image(_ b: [UInt8], _ w: Int, _ h: Int) -> CGImage { CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)), provider: CGDataProvider(data: Data(b) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)! }
    static func save(_ b: [UInt8], _ texture: MTLTexture, _ url: URL) throws { guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw OceanRendererError.unavailable("Cannot create material PNG") }; CGImageDestinationAddImage(d, image(b, texture.width, texture.height), nil); guard CGImageDestinationFinalize(d) else { throw OceanRendererError.unavailable("Cannot finalize material PNG") } }
    static func pngBytes(_ url: URL) throws -> (bytes: [UInt8], width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw OceanRendererError.unavailable("Cannot read PNG \(url.lastPathComponent)") }
        let width = sourceImage.width, height = sourceImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok = bytes.withUnsafeMutableBytes { raw in
            guard let c = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)).rawValue) else { return false }
            c.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard ok else { throw OceanRendererError.unavailable("Cannot decode PNG \(url.lastPathComponent)") }
        return (bytes, width, height)
    }
    static func samples(_ sim: LiquidSimulation, _ w: Int, _ h: Int) -> [(String, Int, Int)] {
        let p = sim.particles.map(\.position); guard !p.isEmpty else { return [] }
        let limit2 = pow(sim.spacing * 2.6, 2); var links = [[Int]](repeating: [], count: p.count)
        for i in p.indices { for j in (i + 1)..<p.count where simd_length_squared(p[i] - p[j]) < limit2 { links[i].append(j); links[j].append(i) } }
        var seen = Set<Int>(), largest = [Int]()
        for root in p.indices where !seen.contains(root) { var q = [root], group = [Int](), head = 0; seen.insert(root); while head < q.count { let i = q[head]; head += 1; group.append(i); for j in links[i] where !seen.contains(j) { seen.insert(j); q.append(j) } }; if group.count > largest.count { largest = group } }
        let center = largest.reduce(SIMD3<Float>.zero) { $0 + p[$1] } / Float(max(1, largest.count)); let body = largest.min { simd_length_squared(p[$0] - center) < simd_length_squared(p[$1] - center) } ?? 0; let end = largest.max { simd_length_squared(p[$0] - p[body]) < simd_length_squared(p[$1] - p[body]) } ?? body
        var parent = [Int](repeating: -1, count: p.count), q = [body], head = 0; parent[body] = body
        while head < q.count { let i = q[head]; head += 1; if i == end { break }; for j in links[i] where parent[j] < 0 { parent[j] = i; q.append(j) } }
        var path = [Int](), c = end; while c >= 0 && c != body { path.append(c); c = parent[c] }; path.append(body)
        let neck = path.dropFirst().dropLast().min { links[$0].count < links[$1].count } ?? body
        func pixel(_ i: Int) -> (Int, Int) { (max(0, min(w - 1, Int(((p[i].x + 1) * 0.5 * Float(w)).rounded()))), max(0, min(h - 1, Int(((0.5 - p[i].y / 4.24) * Float(h)).rounded()))) ) }
        return [("body", pixel(body).0, pixel(body).1), ("neck", pixel(neck).0, pixel(neck).1), ("rounded-end", pixel(end).0, pixel(end).1)]
    }
    static func main() { do { try run() } catch { fputs("FAIL MaterialTerms: \(error)\n", stderr); exit(1) } }
    static func run() throws {
        guard CommandLine.arguments.count == 3 else { throw OceanRendererError.unavailable("Run folder and Poisson shake PNG required") }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1]), began = Date(), initial = try hashes()
        let original = try String(contentsOfFile: "SmallWave/Rendering/LiquidShaders.metal", encoding: .utf8), source = try MaterialTermsSource.make(original: original)
        try original.write(to: folder.appendingPathComponent("baseline-shader.metal"), atomically: true, encoding: .utf8); try source.write(to: folder.appendingPathComponent("compiled-shader.metal"), atomically: true, encoding: .utf8)
        guard let device = MTLCreateSystemDefaultDevice() else { throw OceanRendererError.unavailable("No Metal device") }
        let baseline = try LiquidRenderer(device: device, library: device.makeLibrary(source: original, options: nil)); let study = try MaterialTermsRenderer(device: device, library: device.makeLibrary(source: source, options: nil)); let sim = baseline.simulation
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 600, height: 1272, mipmapped: false); descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        guard let target = device.makeTexture(descriptor: descriptor) else { throw OceanRendererError.unavailable("No material target") }
        for _ in 0..<600 { sim.advance(elapsed: 1 / 120, motion: MotionSample()) }
        let tilt = MotionSample(gravity: SIMD3(0.65, -0.76, 0)); for _ in 0..<220 { sim.advance(elapsed: 1 / 120, motion: tilt) }
        var shake = MotionSample(); for i in 0..<120 { let t = Float(i) / 120; shake = MotionSample(acceleration: SIMD3(sin(t * 24) * 2.5, cos(t * 17) * 1.5, sin(t * 13) * 0.8)); sim.advance(elapsed: 1 / 120, motion: shake) }
        let frozen = state(sim); baseline.motion = shake; try baseline.render(into: target, elapsed: 0, waitForCompletion: true); let a = bytes(target); try study.render(into: target, simulation: sim, motion: shake, mode: "baseline"); guard bytes(target) == a, frozen == state(sim) else { throw OceanRendererError.unavailable("Baseline wrapper/state mismatch") }
        let baselineURL = folder.appendingPathComponent("shake-baseline.png"); try save(a, target, baselineURL)
        let pngBaseline = try pngBytes(baselineURL), poissonBaseline = try pngBytes(URL(fileURLWithPath: CommandLine.arguments[2]))
        guard pngBaseline.width == target.width, pngBaseline.height == target.height, pngBaseline.bytes == a,
              poissonBaseline.width == target.width, poissonBaseline.height == target.height, poissonBaseline.bytes == pngBaseline.bytes else { throw OceanRendererError.unavailable("Poisson shake PNG mismatch") }
        var csv = "term,changed_pixels,mean_abs_rgb,max_abs_rgb_channel\n", sampleCSV = "term,region,x,y,baseline_b,baseline_g,baseline_r,baseline_a,off_b,off_g,off_r,off_a\n"; let points = samples(sim, target.width, target.height); var checks = ["PASS PoissonCap rest600/tilt220/shake120 fixture and 600x1272 shake PNG RGB identity", "PASS original renderer / wrapper byte identity and physical state SHA unchanged"]
        for (name, _, _) in MaterialTermsSource.variants {
            try study.render(into: target, simulation: sim, motion: shake, mode: name); let b = bytes(target); guard frozen == state(sim) else { throw OceanRendererError.unavailable("Simulation changed at \(name)") }
            let offURL = folder.appendingPathComponent("shake-off-\(name).png"); try save(b, target, offURL); let pngOff = try pngBytes(offURL)
            guard pngOff.width == target.width, pngOff.height == target.height, pngOff.bytes == b else { throw OceanRendererError.unavailable("Saved PNG mismatch \(name)") }
            var changed = 0, sum = 0, maximum = 0
            for pixel in 0..<(target.width * target.height) { let i = pixel * 4; var pixelChanged = false; for channel in 0..<3 { let d = abs(Int(pngBaseline.bytes[i + channel]) - Int(pngOff.bytes[i + channel])); sum += d; maximum = max(maximum, d); pixelChanged = pixelChanged || d > 0 }; if pixelChanged { changed += 1 } }
            let mean = String(format: "%.6f", Double(sum) / Double(target.width * target.height * 3))
            csv += "\(name),\(changed),\(mean),\(maximum)\n"
            for (region, x, y) in points { let i = (y * target.width + x) * 4; sampleCSV += "\(name),\(region),\(x),\(y),\(pngBaseline.bytes[i]),\(pngBaseline.bytes[i + 1]),\(pngBaseline.bytes[i + 2]),\(pngBaseline.bytes[i + 3]),\(pngOff.bytes[i]),\(pngOff.bytes[i + 1]),\(pngOff.bytes[i + 2]),\(pngOff.bytes[i + 3])\n" }
        }
        guard try hashes() == initial else { throw OceanRendererError.unavailable("Input changed during rendering") }
        checks.append("PASS every source input SHA unchanged from compile through run")
        checks.append("PASS each image is actual term on/off from cloned current oceanFragment; no new material term")
        checks.append("PASS metrics.csv recomputed from separately decoded saved PNG RGB for every term; RGB-any changed pixel and RGB-only MAE")
        checks.append("MEASURE samples.csv has fixed particle-graph sample points only; it makes no neck-causality claim")
        checks.append("LIMIT total-image MAE is term extent/range evidence, not a white-band cause ranking")
        try csv.write(to: folder.appendingPathComponent("metrics.csv"), atomically: true, encoding: .utf8); try sampleCSV.write(to: folder.appendingPathComponent("samples.csv"), atomically: true, encoding: .utf8); try checks.joined(separator: "\n").write(to: folder.appendingPathComponent("checks.txt"), atomically: true, encoding: .utf8)
        var outputs = [String: String](); for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where url.lastPathComponent != "provenance.json" { if ["png", "csv", "metal", "txt"].contains(url.pathExtension) { outputs[url.lastPathComponent] = try hash(Data(contentsOf: url)) } }
        let manifest: [String: Any] = ["inputsSHA256": initial, "outputsSHA256": outputs, "executableSHA256": try hash(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))), "baselineShaderSHA256": hash(Data(original.utf8)), "compiledShaderSHA256": hash(Data(source.utf8)), "beganAt": ISO8601DateFormatter().string(from: began), "completedAt": ISO8601DateFormatter().string(from: Date()), "device": device.name, "normalSize": [600, 1272], "stateSHA256": frozen, "adopted": false]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("provenance.json"), options: .atomic)
        print(checks.joined(separator: "\n")); print(folder.path)
    }
}
