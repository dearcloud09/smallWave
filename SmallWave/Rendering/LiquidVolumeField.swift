import Foundation
import Metal
import simd

/// Removes particle-scale surface grain only after both the hand and liquid
/// have settled. It changes reconstruction, never the particle state or forces.
struct LiquidSurfaceRestState {
    private struct Cell: Hashable { let x, y, z: Int }

    private(set) var strength: Float = 0
    private var quietTime: Float = 0
    private var previousGravity: SIMD3<Float>?
    private var tangent = SIMD2<Float>(1, 0)

    var parameters: SIMD4<Float> { SIMD4(tangent.x, tangent.y, 1 + 2 * strength, strength) }

    mutating func reset() { self = LiquidSurfaceRestState() }

    mutating func update(elapsed: Float, gravity: SIMD3<Float>,
                         maximumAcceleration: Float, energy: Float, coherentBulk: Bool) {
        guard elapsed.isFinite, elapsed > 0 else { return }
        guard elapsed <= 0.25, gravity.x.isFinite, gravity.y.isFinite, gravity.z.isFinite,
              maximumAcceleration.isFinite, energy.isFinite else { reset(); return }
        let length = simd_length(gravity)
        let unit = length > 0.001 ? gravity / length : SIMD3<Float>.zero
        let projected = simd_length(SIMD2(unit.x, unit.y))
        let gravityRate = previousGravity.map { simd_length(unit - $0) / elapsed } ?? 0
        previousGravity = unit
        if projected > 0.25 { tangent = SIMD2(-unit.y, unit.x) / projected }
        let quiet = length > 0.8 && projected > 0.25 && maximumAcceleration < 0.06
            && gravityRate < 0.10 && energy < 0.13 && coherentBulk
        if !coherentBulk {
            quietTime = 0
            strength = 0
            return
        }
        quietTime = quiet ? min(8, quietTime + elapsed) : 0
        let target: Float = quietTime > 0.75 ? 1 : 0
        // Re-enter calm gradually; give a new shake its detailed shape promptly.
        let response: Float = target > strength ? 1.4 : 0.02
        strength += (target - strength) * (1 - exp(-elapsed / response))
        if strength < 0.0001 { strength = 0 }
    }

    /// Allows smoothing only for a finite, stationary, connected liquid bulk.
    static func isCoherentBulk(particles: [LiquidParticle], connectionRadius: Float,
                               neighbourCandidates: [[Int]]? = nil) -> Bool {
        guard !particles.isEmpty, connectionRadius.isFinite, connectionRadius > 0 else { return false }
        let radius = Double(connectionRadius)
        var minimum = SIMD3<Double>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Double>(repeating: -.greatestFiniteMagnitude)
        for particle in particles {
            let position = SIMD3<Double>(Double(particle.position.x), Double(particle.position.y), Double(particle.position.z))
            let velocity = SIMD3<Double>(Double(particle.velocity.x), Double(particle.velocity.y), Double(particle.velocity.z))
            guard isFinite(position), isFinite(velocity), magnitude(velocity) <= 0.25 else { return false }
            minimum = SIMD3(min(minimum.x, position.x), min(minimum.y, position.y), min(minimum.z, position.z))
            maximum = SIMD3(max(maximum.x, position.x), max(maximum.y, position.y), max(maximum.z, position.z))
        }
        guard isFinite(minimum), isFinite(maximum) else { return false }

        var parents = Array(particles.indices)
        func root(_ index: Int) -> Int {
            var node = index
            while parents[node] != node {
                parents[node] = parents[parents[node]]
                node = parents[node]
            }
            return node
        }
        func join(_ lhs: Int, _ rhs: Int) {
            let left = root(lhs), right = root(rhs)
            if left != right { parents[right] = left }
        }
        let radiusSquared = radius * radius
        if let neighbourCandidates {
            guard neighbourCandidates.count == particles.count else { return false }
            let radiusSquaredFloat = connectionRadius * connectionRadius
            for (index, candidates) in neighbourCandidates.enumerated() {
                for other in candidates {
                    guard particles.indices.contains(other) else { return false }
                    let delta = particles[index].position - particles[other].position
                    let distanceSquared = simd_dot(delta, delta)
                    if distanceSquared.isFinite && distanceSquared <= radiusSquaredFloat { join(index, other) }
                }
            }
            let first = root(0)
            return particles.indices.allSatisfy { root($0) == first }
        }

        let positions = particles.map {
            SIMD3<Double>(Double($0.position.x), Double($0.position.y), Double($0.position.z))
        }

        func cell(for position: SIMD3<Double>) -> Cell? {
            func coordinate(_ value: Double) -> Int? {
                let scaled = (value / radius).rounded(.down)
                guard scaled.isFinite, scaled > Double(Int.min) + 1, scaled < Double(Int.max) - 1 else { return nil }
                return Int(scaled)
            }
            guard let x = coordinate(position.x - minimum.x), let y = coordinate(position.y - minimum.y),
                  let z = coordinate(position.z - minimum.z) else { return nil }
            return Cell(x: x, y: y, z: z)
        }
        var cells: [Cell: [Int]] = [:]
        for index in positions.indices {
            guard let current = cell(for: positions[index]) else { return false }
            for x in (current.x - 1)...(current.x + 1) {
                for y in (current.y - 1)...(current.y + 1) {
                    for z in (current.z - 1)...(current.z + 1) {
                        for other in cells[Cell(x: x, y: y, z: z)] ?? [] {
                            let delta = positions[index] - positions[other]
                            if simd_dot(delta, delta) <= radiusSquared { join(index, other) }
                        }
                    }
                }
            }
            cells[current, default: []].append(index)
        }
        let first = root(0)
        return positions.indices.allSatisfy { root($0) == first }
    }

    private static func isFinite(_ value: SIMD3<Double>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private static func magnitude(_ value: SIMD3<Double>) -> Double {
        (value.x * value.x + value.y * value.y + value.z * value.z).squareRoot()
    }
}

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
                       bubbles: MTLBuffer, bubbleCount: Int,
                       surfaceFilter: SIMD4<Float> = SIMD4(1, 0, 1, 0)) throws {
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
        var filter = surfaceFilter
        let tangentLength = simd_length(SIMD2(filter.x, filter.y))
        guard filter.x.isFinite, filter.y.isFinite, filter.z.isFinite, filter.w.isFinite,
              tangentLength > 0.99 && tangentLength < 1.01,
              (1...3).contains(filter.z), (0...1).contains(filter.w) else {
            splat.endEncoding()
            throw Error.invalidInput("정지 수면 재구성 범위가 맞지 않아.")
        }
        splat.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                             instanceCount: particleCount * dims.z)
        splat.endEncoding()

        func dispatch(_ pipeline: MTLComputePipelineState, _ source: MTLTexture, _ target: MTLTexture) throws {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw Error.unavailable("액체 필드 compute 인코더를 만들지 못했어.")
            }
            encoder.setComputePipelineState(pipeline)
            if pipeline === filterXPipeline {
                encoder.setBytes(&filter, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            }
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
