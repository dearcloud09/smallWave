import Foundation
import Metal
import CryptoKit

private enum AirCheckError: Error { case invalid(String) }

@main private struct LiveAirTransportCheck {
    struct Probe { let name: String; let p: SIMD3<Float>; let d: SIMD3<Float>; let bubbles: [SIMD4<Float>]; let inside: Bool; let t: Float; let normal: SIMD3<Float>; let phase: Bool }
    static func main() { do { try run() } catch { fputs("FAIL \(error)\n", stderr); exit(1) } }
    static func run() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let paths = ["SmallWave/Rendering/LiquidShaders.metal", "SmallWave/Rendering/LiquidVolumeField.metal", "SmallWave/Rendering/MobileVolumeOptics.metal"]
        let kernel = """
        struct AirCheckQuery { float4 point; float4 direction; };
        kernel void liveAirTransportProbe(const device float4 *bubbles [[buffer(0)]],
                                          constant uint &count [[buffer(1)]],
                                          constant AirCheckQuery &query [[buffer(2)]],
                                          device float4 *result [[buffer(3)]],
                                          uint id [[thread_position_in_grid]]) {
            if (id != 0) return;
            float3 normal; bool inside = liveAirContains(query.point.xyz, bubbles, count);
            float t = liveAirBoundary(query.point.xyz, normalize(query.direction.xyz), inside, bubbles, count, normal);
            bool after = t < 1e8 ? liveAirContains(query.point.xyz + normalize(query.direction.xyz) * (t + .00008), bubbles, count) : inside;
            result[0] = float4(t, normal);
            result[1] = float4(inside ? 1 : 0, after ? 1 : 0, inside != after ? 1 : 0, 0);
        }
        kernel void liveAirBudgetProbe(texture3d<float> field [[texture(0)]],
                                        texture3d<float> bounds [[texture(1)]],
                                        device float4 *result [[buffer(0)]],
                                        uint id [[thread_position_in_grid]]) {
            if (id > 1) return;
            uint samples = 0; bool exhausted = false;
            float limit = id == 0 ? 1.2 : .1;
            float t = liveAirFieldBoundary(field, bounds, float3(0), float3(1,0,0), limit, true, samples, exhausted);
            result[id] = float4(t, float(samples), exhausted ? 1 : 0, 0);
        }
        """
        let source = "#define LIVE_CONCATENATED_SHADER 1\n" + (try paths.map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")) + "\n" + kernel
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw AirCheckError.invalid("Metal unavailable") }
        let library = try device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "liveAirTransportProbe") else { throw AirCheckError.invalid("probe kernel") }
        let pipeline = try device.makeComputePipelineState(function: function)
        let isolated = [SIMD4<Float>(0, 0, 0, 1)]
        let overlap = [SIMD4<Float>(0, 0, 0, 1), SIMD4<Float>(0.75, 0, 0, 1)]
        let nested = [SIMD4<Float>(0, 0, 0, 1), SIMD4<Float>(0.25, 0, 0, 0.25)]
        let probes = [
            Probe(name: "empty", p: SIMD3(-2,0,0), d: SIMD3(1,0,0), bubbles: [], inside: false, t: 1e9, normal: SIMD3(0,0,1), phase: false),
            Probe(name: "isolated-entry", p: SIMD3(-2,0,0), d: SIMD3(1,0,0), bubbles: isolated, inside: false, t: 1, normal: SIMD3(-1,0,0), phase: true),
            Probe(name: "isolated-exit", p: SIMD3(0,0,0), d: SIMD3(1,0,0), bubbles: isolated, inside: true, t: 1, normal: SIMD3(1,0,0), phase: true),
            Probe(name: "overlap-exit", p: SIMD3(0,0,0), d: SIMD3(1,0,0), bubbles: overlap, inside: true, t: 1.75, normal: SIMD3(1,0,0), phase: true),
            Probe(name: "nested-ignore", p: SIMD3(0,0,0), d: SIMD3(1,0,0), bubbles: nested, inside: true, t: 1, normal: SIMD3(1,0,0), phase: true),
            Probe(name: "disjoint-miss", p: SIMD3(-2,3,0), d: SIMD3(1,0,0), bubbles: isolated, inside: false, t: 1e9, normal: SIMD3(0,0,1), phase: false),
            Probe(name: "tangent-no-phase", p: SIMD3(-2,1,0), d: SIMD3(1,0,0), bubbles: isolated, inside: false, t: 1e9, normal: SIMD3(0,0,1), phase: false)
        ]
        var records = [[String: Any]](), failures = 0
        for probe in probes {
            var bubbleData = probe.bubbles; if bubbleData.isEmpty { bubbleData = [SIMD4<Float>.zero] }
            let query = [SIMD4(probe.p, probe.inside ? 1 : 0), SIMD4(probe.d, 0)]
            guard let bubbles = bubbleData.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
                  let input = query.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
                  let output = device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride * 2, options: .storageModeShared),
                  let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw AirCheckError.invalid("GPU buffers") }
            var count = UInt32(probe.bubbles.count)
            encoder.setComputePipelineState(pipeline); encoder.setBuffer(bubbles, offset: 0, index: 0); encoder.setBytes(&count, length: 4, index: 1); encoder.setBuffer(input, offset: 0, index: 2); encoder.setBuffer(output, offset: 0, index: 3)
            encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)); encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            guard command.status == .completed, command.error == nil else { throw AirCheckError.invalid("GPU command") }
            let result = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2), t = result[0].x, normal = SIMD3(result[0].y, result[0].z, result[0].w), phase = result[1].z > 0.5
            let distanceOK = probe.t >= 1e8 ? t >= 1e8 : abs(t-probe.t) < 0.001
            let normalOK = probe.t >= 1e8 || (normal.x*probe.normal.x + normal.y*probe.normal.y + normal.z*probe.normal.z) > 0.999
            let pass = distanceOK && normalOK && phase == probe.phase && (result[1].x > 0.5) == probe.inside
            if !pass { failures += 1 }
            records.append(["name":probe.name,"pass":pass,"t":t,"normal":[normal.x,normal.y,normal.z],"startInside":result[1].x>0.5,"phaseTransition":phase])
        }
        // Constant field with straddling bounds forces the sample path. The
        // expected distances and exhaustion follow from the declared budget,
        // independent of the sphere boundary implementation.
        func constantTexture(_ format: MTLPixelFormat, _ values: [Float]) throws -> MTLTexture {
            let d = MTLTextureDescriptor()
            d.textureType = .type3D; d.width = 1; d.height = 1; d.depth = 1
            d.pixelFormat = format; d.storageMode = .shared; d.usage = .shaderRead
            guard let t = device.makeTexture(descriptor: d) else { throw AirCheckError.invalid("constant field") }
            values.withUnsafeBytes { t.replace(region: MTLRegionMake3D(0,0,0,1,1,1), mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!, bytesPerRow: $0.count, bytesPerImage: $0.count) }
            return t
        }
        let constantField = try constantTexture(.r32Float, [0.8])
        let neutralBounds = try constantTexture(.rg32Float, [0,1])
        guard let budgetFunction = library.makeFunction(name: "liveAirBudgetProbe"),
              let budgetOutput = device.makeBuffer(length: 32, options: .storageModeShared),
              let budgetCommand = queue.makeCommandBuffer(),
              let budgetEncoder = budgetCommand.makeComputeCommandEncoder() else { throw AirCheckError.invalid("budget probe") }
        budgetEncoder.setComputePipelineState(try device.makeComputePipelineState(function: budgetFunction))
        budgetEncoder.setTexture(constantField, index: 0); budgetEncoder.setTexture(neutralBounds, index: 1)
        budgetEncoder.setBuffer(budgetOutput, offset: 0, index: 0)
        budgetEncoder.dispatchThreads(MTLSize(width: 2, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 2, height: 1, depth: 1))
        budgetEncoder.endEncoding(); budgetCommand.commit(); budgetCommand.waitUntilCompleted()
        guard budgetCommand.status == .completed, budgetCommand.error == nil else { throw AirCheckError.invalid("budget GPU command") }
        let budget = budgetOutput.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2)
        let budgetPass = abs(budget[0].x - 1.2) < 0.0001 && budget[0].y == 256 && budget[0].z == 1
        let shortPass = abs(budget[1].x - 0.1) < 0.0001 && budget[1].y < 40 && budget[1].z == 0
        for (name, pass, value) in [("field-budget-exhausted",budgetPass,budget[0]), ("field-short-limit",shortPass,budget[1])] {
            if !pass { failures += 1 }
            records.append(["name":name,"pass":pass,"distance":value.x,"samples":value.y,"exhausted":value.z > 0.5])
        }
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let report: [String: Any] = ["checks":records,"failures":failures,"fieldBudget":budgetPass && shortPass ? "PASS" : "FAIL","compiledSourceSHA256":digest,"device":device.name]

        let outputURL = root.appendingPathComponent(".build-cache/live-volume/air-boundary-check.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: outputURL, options: .withoutOverwriting)
        guard failures == 0 else { throw AirCheckError.invalid("\(failures) air boundary checks") }
        print("PASS air transport checks=\(records.count) fieldBudget=PASS")
    }
}
