import Foundation
import MetalKit

/// Generates source-identical baseline rendering plus opt-out variants of terms
/// that already occur in oceanFragment.  This is an offscreen diagnostic only.
enum MaterialTermsSource {
    static func replace(_ text: String, _ anchor: String, _ replacement: String) throws -> String {
        guard text.components(separatedBy: anchor).count == 2 else {
            throw OceanRendererError.unavailable("Material term anchor changed: \(anchor.prefix(72))")
        }
        return text.replacingOccurrences(of: anchor, with: replacement)
    }

    static let variants: [(String, String, String)] = [
        ("transmitted-scene", "float3 water=scene*absorption+scatteredLight*(1.0-absorption);", "float3 water=scatteredLight*(1.0-absorption);"),
        ("scatter", "float3 scatteredLight=referenceTransmission*(clearInterface?0.06:0.22);", "float3 scatteredLight=float3(0);"),
        ("submerged-toy", "water=water*(1.0-wetToy.a)+submergedToy;", "// submerged toy disabled for diagnostic"),
        ("glint", "water+=float3(0.02,0.24,0.29)*glint;", "// glint disabled for diagnostic"),
        ("reflection", "water=mix(water,reflection,fresnel);", "// reflection mix disabled for diagnostic"),
        ("highlight", "water+=float3(0.9,0.98,1.0)*highlight*(reconstructed?0.35:meniscus*(clearInterface?0.08:0.30));", "// meniscus highlight disabled for diagnostic"),
        ("fine-rim", "water+=float3(0.40,0.70,0.78)*fineRim*((reconstructed||clearInterface)?0.0:0.14);", "// fine rim disabled for diagnostic"),
        ("coverage", "float3 color=mix(dry,lightToDisplay(water),coverage);", "float3 color=dry;"),
        ("wall", "color=mix(color,color*0.70+float3(0.07,0.12,0.13),wall*0.35);", "// vessel wall disabled for diagnostic"),
        ("stripe", "color+=float3(0.12,0.14,0.13)*stripe;", "// vessel stripe disabled for diagnostic"),
        ("vignette", "color*=1.0-0.06*pow(length(screen/u.viewport.xy)*0.7,3.0);", "// vignette disabled for diagnostic")
    ]

    static func make(original: String) throws -> String {
        guard let start = original.range(of: "fragment float4 oceanFragment("),
              let end = original.range(of: "vertex QuadOut bubbleVertex(") else {
            throw OceanRendererError.unavailable("Missing original ocean fragment")
        }
        let fragment = String(original[start.lowerBound..<end.lowerBound])
        var appended = "\n"
        for (name, anchor, replacement) in variants {
            let function = name.replacingOccurrences(of: "-", with: "_")
            var copy = try replace(fragment, "oceanFragment(", "material_\(function)(")
            copy = try replace(copy, anchor, replacement)
            appended += copy + "\n"
        }
        return original + appended
    }
}

final class MaterialTermsRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let fieldPipeline: MTLRenderPipelineState
    private let bubblePipeline: MTLRenderPipelineState
    private let display: [String: MTLRenderPipelineState]
    private let particleBuffer: MTLBuffer
    private let bubbleBuffer: MTLBuffer
    private var field: MTLTexture?

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        guard let queue = device.makeCommandQueue(),
              let particles = device.makeBuffer(length: 1200 * 16, options: .storageModeShared),
              let bubbles = device.makeBuffer(length: 36 * 16, options: .storageModeShared) else {
            throw OceanRendererError.unavailable("No material-term buffers")
        }
        self.queue = queue; particleBuffer = particles; bubbleBuffer = bubbles
        func pipeline(_ vertex: String, _ fragment: String, _ additive: Bool = false, _ alpha: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex); d.fragmentFunction = library.makeFunction(name: fragment)
            let a = d.colorAttachments[0]!; a.pixelFormat = fragment == "fieldFragment" ? .rgba16Float : .bgra8Unorm
            if additive || alpha { a.isBlendingEnabled = true; a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one; a.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha; a.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        fieldPipeline = try pipeline("fieldVertex", "fieldFragment", true)
        bubblePipeline = try pipeline("bubbleVertex", "bubbleFragment", false, true)
        var built = [String: MTLRenderPipelineState]()
        built["baseline"] = try pipeline("screenVertex", "oceanFragment")
        for (name, _, _) in MaterialTermsSource.variants { built[name] = try pipeline("screenVertex", "material_\(name.replacingOccurrences(of: "-", with: "_"))") }
        display = built
    }

    func render(into target: MTLTexture, simulation: LiquidSimulation, motion: MotionSample, mode: String) throws {
        let portrait = target.height >= target.width
        let width = portrait ? 256 : 544, height = portrait ? 544 : 256
        if field?.width != width || field?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            d.storageMode = .shared; d.usage = [.renderTarget, .shaderRead]
            field = device.makeTexture(descriptor: d)
        }
        guard let field, let command = queue.makeCommandBuffer(), let pipeline = display[mode] else { throw OceanRendererError.unavailable("No material-term target") }
        var u = OceanUniforms()
        u.viewport = SIMD4(portrait ? 1 : simulation.halfHeight, portrait ? simulation.halfHeight : 1, simulation.time, 0)
        u.color.w = 0
        u.optics = SIMD4(0, simulation.halfDepth, 0.6, 16)
        u.boat = SIMD4(simulation.boat.position.x, simulation.boat.position.y, simulation.boat.angle, simulation.boat.position.z)
        u.movement = SIMD4(motion.safeGravity, simulation.energy)
        let pp = particleBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 1200)
        for (i, p) in simulation.particles.enumerated() { pp[i] = SIMD4(p.position, simulation.spacing * 1.5) }
        let bp = bubbleBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 36)
        for (i, b) in simulation.bubbles.enumerated() { bp[i] = SIMD4(b.position.x, b.position.y, b.radius, min(1, b.life)) }
        let uniformSize = MemoryLayout<OceanUniforms>.stride
        let fp = MTLRenderPassDescriptor(), fa = fp.colorAttachments[0]!
        fa.texture = field; fa.loadAction = .clear; fa.storeAction = .store; fa.clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let f = command.makeRenderCommandEncoder(descriptor: fp) else { throw OceanRendererError.unavailable("No material field encoder") }
        f.setRenderPipelineState(fieldPipeline); f.setVertexBuffer(particleBuffer, offset: 0, index: 0); f.setVertexBytes(&u, length: uniformSize, index: 1)
        f.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: simulation.particles.count); f.endEncoding()
        let dp = MTLRenderPassDescriptor(), da = dp.colorAttachments[0]!
        da.texture = target; da.loadAction = .dontCare; da.storeAction = .store
        guard let d = command.makeRenderCommandEncoder(descriptor: dp) else { throw OceanRendererError.unavailable("No material display encoder") }
        d.setRenderPipelineState(pipeline); d.setFragmentTexture(field, index: 0); d.setFragmentTexture(field, index: 1); d.setFragmentBytes(&u, length: uniformSize, index: 0)
        d.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        if !simulation.bubbles.isEmpty {
            d.setRenderPipelineState(bubblePipeline); d.setVertexBuffer(bubbleBuffer, offset: 0, index: 0); d.setVertexBytes(&u, length: uniformSize, index: 1); d.setFragmentTexture(field, index: 0)
            d.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: simulation.bubbles.count)
        }
        d.endEncoding(); command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
    }
}
