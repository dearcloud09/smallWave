import Foundation
import MetalKit

/// Analytic rays test occupied fluid length, including gaps and object occlusion.
/// This validates extraction, not reconstruction quality or two-fluid dynamics.
@main
struct DepthCheck {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw OceanRendererError.unavailable("No Metal device")
        }
        let source = try String(contentsOfFile: "SmallWave/Rendering/LiquidShaders.metal", encoding: .utf8)
        let samplingProbe = """
        kernel void samplingProbe(texture2d<float> input [[texture(0)]],
                                   texture2d<float,access::write> output [[texture(1)]],
                                   constant float2 &uv [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
            SurfaceSample s=sampleSurface(input,uv);
            output.write(float4(s.depth.x,s.depth.w,s.coverage,1),gid);
        }
        """
        let library = try device.makeLibrary(source: source + samplingProbe, options: nil)
        let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "extractDepth")!)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float,
            width: 1, height: 1, mipmapped: false)
        descriptor.textureType = .type2DArray
        descriptor.arrayLength = 16
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let volume = device.makeTexture(descriptor: descriptor)!
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
            width: 1, height: 1, mipmapped: false)
        outputDescriptor.storageMode = .shared
        outputDescriptor.usage = .shaderWrite
        let target = device.makeTexture(descriptor: outputDescriptor)!
        var uniforms = OceanUniforms()
        uniforms.optics = SIMD4(1, 0.18, 0.6, 16)
        func evaluate(_ values: [Float], toyZ: Float = 0,
                      gravity: SIMD3<Float> = SIMD3(0,-1,0)) throws -> SIMD4<Float> {
            precondition(values.count == 16)
            for (i, value) in values.enumerated() {
                var sample = value
                volume.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0, slice: i,
                    withBytes: &sample, bytesPerRow: 4, bytesPerImage: 4)
            }
            uniforms.boat.w = toyZ
            uniforms.movement = SIMD4(gravity, 0)
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(volume, index: 0)
            encoder.setTexture(target, index: 1)
            encoder.setBytes(&uniforms, length: MemoryLayout<OceanUniforms>.stride, index: 0)
            encoder.dispatchThreads(MTLSize(width: 1,height: 1,depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1,height: 1,depth: 1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            if let error = command.error { throw error }
            var result = SIMD4<Float>.zero
            target.getBytes(&result, bytesPerRow: 16, from: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0)
            return result
        }
        func check(_ name: String, _ actual: SIMD4<Float>, _ expected: SIMD4<Float>) throws {
            for i in 0..<4 where !actual[i].isFinite || abs(actual[i]-expected[i]) > 0.00001 {
                throw OceanRendererError.unavailable("\(name): \(actual), expected \(expected)")
            }
            print("PASS \(name): \(actual)")
        }
        let empty = [Float](repeating: 0.2, count: 16)
        try check("empty", evaluate(empty), SIMD4(repeating: 1))
        try check("full ray", evaluate([Float](repeating: 1, count: 16)), SIMD4(0,-0.36,0.18,0.36))
        // Midpoint crossings: slice spacing .0225; entry .0675, exit .135.
        var single = empty
        for i in 3...5 { single[i] = 1 }
        try check("single interval", evaluate(single), SIMD4(0.0675,-0.135,0.0675,0.0675))
        var split = single
        for i in 10...12 { split[i] = 1 }
        let expected = SIMD4<Float>(0.0675,-0.2925,0.0675,0.135)
        try check("disjoint intervals exclude gap", evaluate(split), expected)
        try check("gravity does not change geometry", evaluate(split, gravity: SIMD3(1,0,0)), expected)
        try check("toy before fluid", evaluate(split, toyZ: 0.15), SIMD4(0.0675,-0.2925,0,0.135))
        try check("toy inside first interval", evaluate(split, toyZ: 0.09), SIMD4(0.0675,-0.2925,0.0225,0.135))
        try check("toy behind all fluid", evaluate(split, toyZ: -0.17), SIMD4(0.0675,-0.2925,0.135,0.135))
        let samplePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "samplingProbe")!)
        let halfDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: 2, height: 2, mipmapped: false)
        halfDescriptor.storageMode = .shared
        halfDescriptor.usage = .shaderRead
        let halfTexture = device.makeTexture(descriptor: halfDescriptor)!
        // One valid production-format texel surrounded by invalid metadata.
        var fixture: [Float16] = [0.0625,-0.1875,0.0625,0.125,
                                 1,1,1,1, 1,1,1,1, 1,1,1,1]
        fixture.withUnsafeMutableBytes { bytes in
            halfTexture.replace(region: MTLRegionMake2D(0,0,2,2), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: 16)
        }
        for (name, coordinate, expected) in [
            ("valid texel", SIMD2<Float>(0.25,0.25), SIMD4<Float>(0.0625,0.125,1,1)),
            ("mixed boundary preserves thickness", SIMD2<Float>(0.5,0.5), SIMD4<Float>(0.0625,0.125,0.25,1)),
            ("empty texel has no coverage", SIMD2<Float>(0.75,0.75), SIMD4<Float>(1,1,0,1))
        ] {
            var uv = coordinate
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(samplePipeline)
            encoder.setTexture(halfTexture, index: 0)
            encoder.setTexture(target, index: 1)
            encoder.setBytes(&uv, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.dispatchThreads(MTLSize(width: 1,height: 1,depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1,height: 1,depth: 1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            if let error = command.error { throw error }
            var actual = SIMD4<Float>.zero
            target.getBytes(&actual, bytesPerRow: 16, from: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0)
            try check(name, actual, expected)
        }
        print("PASS 8 extraction + 3 production-format boundary cases on \(device.name). Appearance, full atlas reconstruction and iPhone behavior remain unverified.")
    }
}
