import Foundation
import Metal

private enum ProfileError: Error { case invalid(String) }

@main private struct LiveVolumeFieldProfile {
    static let width = 256, height = 544, depth = 48
    static func half(_ data: Data, _ index: Int) -> Float {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            Float(Float16(bitPattern: UInt16(raw[index * 2]) | UInt16(raw[index * 2 + 1]) << 8))
        }
    }
    static func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }
    static func main() { do { try run() } catch { fputs("FAIL \(error)\n", stderr); exit(1) } }

    static func run() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let stateData = try Data(contentsOf: root.appendingPathComponent(".build-cache/material-motion/000/state.json"))
        let expected = try Data(contentsOf: root.appendingPathComponent(".build-cache/fast-material/000/field.f16"))
        let source = try String(contentsOf: root.appendingPathComponent("SmallWave/Rendering/LiquidVolumeField.metal"))
        guard expected.count == width * height * depth * 2,
              let state = try JSONSerialization.jsonObject(with: stateData) as? [String: Any],
              let rows = state["particles"] as? [[Double]], let bubbleRows = state["bubbles"] as? [[Double]],
              let spacing = state["spacing"] as? Double, let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { throw ProfileError.invalid("input or Metal") }
        let particles = try rows.map { row -> SIMD4<Float> in guard row.count == 3 else { throw ProfileError.invalid("particle") }; return SIMD4(Float(row[0]), Float(row[1]), Float(row[2]), Float(spacing) * 1.5) }
        let bubbles = try bubbleRows.map { row -> SIMD4<Float> in guard row.count == 4 else { throw ProfileError.invalid("bubble") }; return SIMD4(Float(row[0]), Float(row[1]), Float(row[2]), Float(row[3])) }
        let library = try device.makeLibrary(source: source, options: nil)
        func arrayDescriptor() -> MTLTextureDescriptor {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: width, height: height, mipmapped: false)
            d.textureType = .type2DArray; d.arrayLength = depth; d.storageMode = .private; d.usage = [.renderTarget, .shaderRead, .shaderWrite]; return d
        }
        func volumeDescriptor(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ d: Int) -> MTLTextureDescriptor {
            let result = MTLTextureDescriptor(); result.textureType = .type3D; result.pixelFormat = format; result.width = w; result.height = h; result.depth = d; result.storageMode = .private; result.usage = [.shaderRead, .shaderWrite]; return result
        }
        guard let raw = device.makeTexture(descriptor: arrayDescriptor()), let ping = device.makeTexture(descriptor: arrayDescriptor()),
              let pong = device.makeTexture(descriptor: arrayDescriptor()), let field = device.makeTexture(descriptor: volumeDescriptor(.r16Float, width, height, depth)),
              let bounds = device.makeTexture(descriptor: volumeDescriptor(.rg16Float, 64, 136, 12)) else { throw ProfileError.invalid("textures") }
        let render = MTLRenderPipelineDescriptor(); render.inputPrimitiveTopology = .triangle
        render.vertexFunction = library.makeFunction(name: "liveFieldVolumeVertex"); render.fragmentFunction = library.makeFunction(name: "liveFieldVolumeFragment")
        render.colorAttachments[0].pixelFormat = .r16Float; let attachment = render.colorAttachments[0]!; attachment.isBlendingEnabled = true; attachment.sourceRGBBlendFactor = .one; attachment.destinationRGBBlendFactor = .one
        let splat = try device.makeRenderPipelineState(descriptor: render)
        func compute(_ name: String) throws -> MTLComputePipelineState { guard let f = library.makeFunction(name: name) else { throw ProfileError.invalid(name) }; return try device.makeComputePipelineState(function: f) }
        let wall = try compute("liveFieldWall"), fx = try compute("liveFieldFilterX"), fy = try compute("liveFieldFilterY"), fz = try compute("liveFieldFilterZ"), carve = try compute("liveFieldCarve"), bound = try compute("liveFieldBounds")
        func makeInput(_ values: [SIMD4<Float>]) -> MTLBuffer? { values.isEmpty ? device.makeBuffer(length: 16, options: .storageModeShared) : values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) } }
        guard let particleBuffer = makeInput(particles), let bubbleBuffer = makeInput(bubbles) else { throw ProfileError.invalid("buffers") }
        let fieldGrid = MTLSize(width: width, height: height, depth: depth), group = MTLSize(width: 8, height: 8, depth: 1)
        func timed(_ encode: (MTLCommandBuffer) throws -> Void) throws -> Double {
            guard let command = queue.makeCommandBuffer() else { throw ProfileError.invalid("command") }
            try encode(command); command.commit(); command.waitUntilCompleted()
            guard command.status == .completed, command.error == nil else { throw ProfileError.invalid("GPU command") }
            return max(0, command.gpuEndTime - command.gpuStartTime) * 1000
        }
        func dispatch(_ pipeline: MTLComputePipelineState, _ source: MTLTexture, _ target: MTLTexture, _ command: MTLCommandBuffer) throws {
            guard let encoder = command.makeComputeCommandEncoder() else { throw ProfileError.invalid("compute") }
            encoder.setComputePipelineState(pipeline); encoder.setTexture(source, index: 0); encoder.setTexture(target, index: 1)
            encoder.dispatchThreads(fieldGrid, threadsPerThreadgroup: group); encoder.endEncoding()
        }
        let names = ["splat", "wall", "filterX", "filterY", "filterZ", "carve", "bounds"]
        var measurements = Dictionary(uniqueKeysWithValues: names.map { ($0, [Double]()) })
        func sequence(_ collect: Bool) throws {
            func record(_ name: String, _ body: @escaping (MTLCommandBuffer) throws -> Void) throws { let ms = try timed(body); if collect { measurements[name]!.append(ms) } }
            try record("splat") { command in
                let pass = MTLRenderPassDescriptor(); pass.renderTargetArrayLength = depth; pass.colorAttachments[0].texture = raw; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
                guard let e = command.makeRenderCommandEncoder(descriptor: pass) else { throw ProfileError.invalid("splat") }
                e.setRenderPipelineState(splat); e.setVertexBuffer(particleBuffer, offset: 0, index: 0); e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: particles.count * depth); e.endEncoding()
            }
            try record("wall") { try dispatch(wall, raw, ping, $0) }; try record("filterX") { try dispatch(fx, ping, pong, $0) }
            try record("filterY") { try dispatch(fy, pong, ping, $0) }; try record("filterZ") { try dispatch(fz, ping, pong, $0) }
            try record("carve") { command in
                guard let e = command.makeComputeCommandEncoder() else { throw ProfileError.invalid("carve") }
                var count = UInt32(bubbles.count); e.setComputePipelineState(carve); e.setTexture(pong, index: 0); e.setTexture(field, index: 1); e.setBuffer(bubbleBuffer, offset: 0, index: 0); e.setBytes(&count, length: 4, index: 1); e.dispatchThreads(fieldGrid, threadsPerThreadgroup: group); e.endEncoding()
            }
            try record("bounds") { command in
                guard let e = command.makeComputeCommandEncoder() else { throw ProfileError.invalid("bounds") }
                e.setComputePipelineState(bound); e.setTexture(field, index: 0); e.setTexture(bounds, index: 1); e.dispatchThreads(MTLSize(width: 64, height: 136, depth: 12), threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 1)); e.endEncoding()
            }
        }
        try sequence(false); for _ in 0..<3 { try sequence(true) }
        guard let readback = device.makeBuffer(length: expected.count, options: .storageModeShared), let copy = queue.makeCommandBuffer(), let blit = copy.makeBlitCommandEncoder() else { throw ProfileError.invalid("readback") }
        blit.copy(from: field, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOriginMake(0, 0, 0), sourceSize: fieldGrid, to: readback, destinationOffset: 0, destinationBytesPerRow: width * 2, destinationBytesPerImage: width * height * 2); blit.endEncoding(); copy.commit(); copy.waitUntilCompleted()
        let actual = Data(bytes: readback.contents(), count: expected.count); var maxError: Float = 0
        for i in 0..<(width * height * depth) { maxError = max(maxError, abs(half(actual, i) - half(expected, i))) }
        let profile = names.map { name in
            let value = String(format: "%.3f", median(measurements[name]!))
            return "\(name)=\(value)ms"
        }.joined(separator: " ")
        let sum = names.reduce(0.0) { $0 + median(measurements[$1]!) }
        let sumText = String(format: "%.3f", sum)
        print("PASS \(profile) sum=\(sumText)ms finalMaxAbs=\(maxError)")
    }
}
