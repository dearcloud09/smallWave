import Foundation
import Metal

/// GPU-only sampled density field used by the live volume ray evaluator.
/// Particle and bubble buffers contain `SIMD4<Float>(x, y, z, radius)` values.
public final class LiquidVolumeField {
    public static let fieldDimensions = SIMD3<Int>(256, 544, 48)
    public static let boundsDimensions = SIMD3<Int>(64, 136, 12)

    enum Error: LocalizedError {
        case unavailable(String)
        case invalidInput(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason), .invalidInput(let reason): return reason
            }
        }
    }

    /// Final density samples, in world order x/right, y/down, z/front-to-rear.
    public let field: MTLTexture
    /// Per-four-cell conservative min/max density bounds in `.rg`.
    public let bounds: MTLTexture

    private let splatPipeline: MTLRenderPipelineState
    private let wallPipeline: MTLComputePipelineState
    private let filterXPipeline: MTLComputePipelineState
    private let filterYPipeline: MTLComputePipelineState
    private let filterZPipeline: MTLComputePipelineState
    private let carvePipeline: MTLComputePipelineState
    private let boundsPipeline: MTLComputePipelineState
    private let raw: MTLTexture
    private let ping: MTLTexture
    private let pong: MTLTexture

    public init(device: MTLDevice, library: MTLLibrary) throws {
        func textureArray() -> MTLTextureDescriptor {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float,
                                                              width: Self.fieldDimensions.x,
                                                              height: Self.fieldDimensions.y,
                                                              mipmapped: false)
            d.textureType = .type2DArray
            d.arrayLength = Self.fieldDimensions.z
            d.storageMode = .private
            d.usage = [.shaderRead, .shaderWrite, .renderTarget]
            return d
        }
        let fieldDescriptor = MTLTextureDescriptor()
        fieldDescriptor.textureType = .type3D
        fieldDescriptor.pixelFormat = .r16Float
        fieldDescriptor.width = Self.fieldDimensions.x
        fieldDescriptor.height = Self.fieldDimensions.y
        fieldDescriptor.depth = Self.fieldDimensions.z
        fieldDescriptor.storageMode = .private
        fieldDescriptor.usage = [.shaderRead, .shaderWrite]
        let boundsDescriptor = MTLTextureDescriptor()
        boundsDescriptor.textureType = .type3D
        boundsDescriptor.pixelFormat = .rg16Float
        boundsDescriptor.width = Self.boundsDimensions.x
        boundsDescriptor.height = Self.boundsDimensions.y
        boundsDescriptor.depth = Self.boundsDimensions.z
        boundsDescriptor.storageMode = .private
        boundsDescriptor.usage = [.shaderRead, .shaderWrite]
        guard let raw = device.makeTexture(descriptor: textureArray()),
              let ping = device.makeTexture(descriptor: textureArray()),
              let pong = device.makeTexture(descriptor: textureArray()),
              let field = device.makeTexture(descriptor: fieldDescriptor),
              let bounds = device.makeTexture(descriptor: boundsDescriptor) else {
            throw Error.unavailable("3D 액체 필드 텍스처를 만들지 못했어.")
        }
        self.raw = raw; self.ping = ping; self.pong = pong
        self.field = field; self.bounds = bounds

        guard let vertex = library.makeFunction(name: "liveFieldVolumeVertex"),
              let fragment = library.makeFunction(name: "liveFieldVolumeFragment") else {
            throw Error.unavailable("액체 필드 splat 셰이더를 찾지 못했어.")
        }
        let render = MTLRenderPipelineDescriptor()
        render.inputPrimitiveTopology = .triangle
        render.vertexFunction = vertex
        render.fragmentFunction = fragment
        render.colorAttachments[0].pixelFormat = .r16Float
        let attachment = render.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one
        splatPipeline = try device.makeRenderPipelineState(descriptor: render)
        func compute(_ name: String) throws -> MTLComputePipelineState {
            guard let f = library.makeFunction(name: name) else {
                throw Error.unavailable("액체 필드 커널을 찾지 못했어: \(name)")
            }
            return try device.makeComputePipelineState(function: f)
        }
        wallPipeline = try compute("liveFieldWall")
        filterXPipeline = try compute("liveFieldFilterX")
        filterYPipeline = try compute("liveFieldFilterY")
        filterZPipeline = try compute("liveFieldFilterZ")
        carvePipeline = try compute("liveFieldCarve")
        boundsPipeline = try compute("liveFieldBounds")
    }

    /// Encodes one field update into `commandBuffer`; it neither commits nor waits.
    public func encode(commandBuffer: MTLCommandBuffer, particles: MTLBuffer, particleCount: Int,
                       bubbles: MTLBuffer, bubbleCount: Int) throws {
        guard particleCount >= 0, particleCount <= particles.length / MemoryLayout<SIMD4<Float>>.stride,
              bubbleCount >= 0, bubbleCount <= bubbles.length / MemoryLayout<SIMD4<Float>>.stride else {
            throw Error.invalidInput("액체 필드 버퍼 길이 또는 개수가 맞지 않아.")
        }
        let dims = Self.fieldDimensions
        let renderPass = MTLRenderPassDescriptor()
        renderPass.renderTargetArrayLength = dims.z
        renderPass.colorAttachments[0].texture = raw
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let splat = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            throw Error.unavailable("액체 필드 splat 인코더를 만들지 못했어.")
        }
        splat.setRenderPipelineState(splatPipeline)
        splat.setVertexBuffer(particles, offset: 0, index: 0)
        splat.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                             instanceCount: particleCount * dims.z)
        splat.endEncoding()

        func dispatch(_ pipeline: MTLComputePipelineState, _ source: MTLTexture, _ target: MTLTexture) throws {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw Error.unavailable("액체 필드 compute 인코더를 만들지 못했어.")
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(target, index: 1)
            encoder.dispatchThreads(MTLSize(width: dims.x, height: dims.y, depth: dims.z),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
        }
        try dispatch(wallPipeline, raw, ping)
        try dispatch(filterXPipeline, ping, pong)
        try dispatch(filterYPipeline, pong, ping)
        try dispatch(filterZPipeline, ping, pong)
        guard let carve = commandBuffer.makeComputeCommandEncoder() else {
            throw Error.unavailable("액체 필드 carve 인코더를 만들지 못했어.")
        }
        carve.setComputePipelineState(carvePipeline)
        carve.setTexture(pong, index: 0); carve.setTexture(field, index: 1)
        carve.setBuffer(bubbles, offset: 0, index: 0)
        var count = UInt32(bubbleCount); carve.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 1)
        carve.dispatchThreads(MTLSize(width: dims.x, height: dims.y, depth: dims.z),
                              threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        carve.endEncoding()
        guard let bound = commandBuffer.makeComputeCommandEncoder() else {
            throw Error.unavailable("액체 필드 bounds 인코더를 만들지 못했어.")
        }
        bound.setComputePipelineState(boundsPipeline)
        bound.setTexture(field, index: 0); bound.setTexture(bounds, index: 1)
        let bd = Self.boundsDimensions
        bound.dispatchThreads(MTLSize(width: bd.x, height: bd.y, depth: bd.z),
                              threadsPerThreadgroup: MTLSize(width: 4, height: 4, depth: 1))
        bound.endEncoding()
    }
}
