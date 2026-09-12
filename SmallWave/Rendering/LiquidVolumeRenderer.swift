import Foundation
import MetalKit

/// One live GPU field and one deterministic primary ray per output pixel.
/// Used by the native prototype and by the offscreen motion checks.
/// Real-device performance and visual acceptance remain separate gates.
final class LiquidVolumeRenderer {
    let field: LiquidVolumeField
    // Optional lighting input for the offscreen comparison harness; not loaded by the app.
    var environment: MTLTexture?
    var miniatureTexture: MTLTexture?
    // Native rendering enables analytic air boundaries. Archived two-medium
    // shader comparisons can still request the carved scalar field.
    var tracesAirBubbles = false
    var appliesEdgeAntialiasing = false
    private let pipeline: MTLRenderPipelineState
    private let resolvePipeline: MTLRenderPipelineState
    private let edgePipeline: MTLRenderPipelineState?
    private let device: MTLDevice
    private var renderTarget: MTLTexture?
    private var diagnosticTarget: MTLTexture?
    private var unfilteredTarget: MTLTexture?

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        field = try LiquidVolumeField(device: device, library: library)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "liveToyFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[1].pixelFormat = .rgba16Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let resolve = MTLRenderPipelineDescriptor()
        resolve.vertexFunction = library.makeFunction(name: "screenVertex")
        resolve.fragmentFunction = library.makeFunction(name: "liveResolveFragment")
        resolve.colorAttachments[0].pixelFormat = .bgra8Unorm
        resolvePipeline = try device.makeRenderPipelineState(descriptor: resolve)
        if let edgeFunction = library.makeFunction(name: "liveEdgeResolveFragment") {
            let edge = MTLRenderPipelineDescriptor()
            edge.vertexFunction = library.makeFunction(name: "screenVertex")
            edge.fragmentFunction = edgeFunction
            edge.colorAttachments[0].pixelFormat = .bgra8Unorm
            edgePipeline = try device.makeRenderPipelineState(descriptor: edge)
        } else {
            edgePipeline = nil // Archived comparison shaders have no edge pass.
        }
    }

    func encodeDisplay(command: MTLCommandBuffer, target: MTLTexture,
                       particles: MTLBuffer, particleCount: Int, bubbles: MTLBuffer, bubbleCount: Int,
                       uniforms: OceanUniforms) throws {
        let scale = min(1,480.0/Double(min(target.width,target.height)))
        let width = max(1,Int((Double(target.width)*scale).rounded()))
        let height = max(1,Int((Double(target.height)*scale).rounded()))
        if renderTarget?.width != width || renderTarget?.height != height {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
            d.storageMode = .private;d.usage = [.renderTarget,.shaderRead]
            renderTarget=device.makeTexture(descriptor:d)
            d.pixelFormat = .rgba16Float
            diagnosticTarget=device.makeTexture(descriptor:d)
        }
        guard let renderTarget,let diagnosticTarget else {throw OceanRendererError.unavailable("액체 화면을 준비하지 못했어.")}
        try encode(command:command,target:renderTarget,diagnostics:diagnosticTarget,
                   particles:particles,particleCount:particleCount,bubbles:bubbles,bubbleCount:bubbleCount,uniforms:uniforms)
        let pass=MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture=target
        pass.colorAttachments[0].loadAction = .dontCare;pass.colorAttachments[0].storeAction = .store
        guard let encoder=command.makeRenderCommandEncoder(descriptor:pass) else {throw OceanRendererError.unavailable("액체 화면을 표시하지 못했어.")}
        encoder.setRenderPipelineState(resolvePipeline)
        encoder.setFragmentTexture(renderTarget,index:0)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6)
        encoder.endEncoding()
    }

    func encode(command: MTLCommandBuffer, target: MTLTexture, diagnostics: MTLTexture,
                particles: MTLBuffer, particleCount: Int, bubbles: MTLBuffer, bubbleCount: Int,
                uniforms: OceanUniforms) throws {
        try field.encode(commandBuffer: command, particles: particles, particleCount: particleCount,
                         bubbles: bubbles, bubbleCount: tracesAirBubbles ? 0 : bubbleCount)
        try encodeTransport(command: command, target: target, diagnostics: diagnostics, uniforms: uniforms,
                            bubbles: bubbles, bubbleCount: tracesAirBubbles ? bubbleCount : 0)
    }

    func encodeTransport(command: MTLCommandBuffer, target: MTLTexture, diagnostics: MTLTexture,
                         uniforms: OceanUniforms, bubbles: MTLBuffer? = nil, bubbleCount: Int = 0) throws {
        let traceTarget: MTLTexture
        if appliesEdgeAntialiasing {
            guard edgePipeline != nil else { throw OceanRendererError.unavailable("Edge resolve shader unavailable") }
            if unfilteredTarget?.width != target.width || unfilteredTarget?.height != target.height {
                let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:target.width,height:target.height,mipmapped:false)
                d.storageMode = .private; d.usage = [.renderTarget,.shaderRead]
                unfilteredTarget=device.makeTexture(descriptor:d)
            }
            guard let unfilteredTarget else { throw OceanRendererError.unavailable("Edge resolve texture unavailable") }
            traceTarget=unfilteredTarget
        } else {
            traceTarget=target
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = traceTarget
        pass.colorAttachments[1].texture = diagnostics
        for i in 0...1 {
            pass.colorAttachments[i].loadAction = .dontCare
            pass.colorAttachments[i].storeAction = .store
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw OceanRendererError.unavailable("Volume resolve encoder unavailable")
        }
        encoder.label = "Live liquid transport"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(field.field, index: 0)
        encoder.setFragmentTexture(field.bounds, index: 1)
        encoder.setFragmentTexture(environment,index:2)
        encoder.setFragmentTexture(miniatureTexture,index:3)
        var u = uniforms
        encoder.setFragmentBytes(&u, length: MemoryLayout<OceanUniforms>.stride, index: 0)
        encoder.setFragmentBuffer(bubbles, offset: 0, index: 1)
        var count = UInt32(min(36, max(0, min(bubbleCount, (bubbles?.length ?? 0) / 16))))
        encoder.setFragmentBytes(&count, length: MemoryLayout<UInt32>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        if appliesEdgeAntialiasing, let edgePipeline {
            let edgePass=MTLRenderPassDescriptor()
            edgePass.colorAttachments[0].texture=target
            edgePass.colorAttachments[0].loadAction = .dontCare
            edgePass.colorAttachments[0].storeAction = .store
            guard let edge=command.makeRenderCommandEncoder(descriptor:edgePass) else {
                throw OceanRendererError.unavailable("Edge resolve encoder unavailable")
            }
            edge.label="Liquid edge antialias"
            edge.setRenderPipelineState(edgePipeline)
            edge.setFragmentTexture(traceTarget,index:0)
            edge.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6)
            edge.endEncoding()
        }
    }
}
