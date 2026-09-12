import Foundation
import MetalKit

/// Offline comparison wrapper. The shipping renderer and particle simulation
/// remain unchanged; only its decorative bubble pass is replaced here.
final class BubbleLensRenderer {
    struct Bubble { var positionRadius: SIMD4<Float>; var life: SIMD4<Float> }
    let base: LiquidRenderer
    var simulation: LiquidSimulation { base.simulation }
    var enabled = true
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let fieldPipeline: MTLRenderPipelineState
    private let lensPipeline: MTLRenderPipelineState
    private var scene: MTLTexture?
    private var field: MTLTexture?
    private let particles: MTLBuffer
    private let bubbles: MTLBuffer

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device=device
        base=try LiquidRenderer(device:device,library:library)
        base.showsBubbles=false
        guard let q=device.makeCommandQueue(),
              let p=device.makeBuffer(length:1200*16,options:.storageModeShared),
              let b=device.makeBuffer(length:36*MemoryLayout<Bubble>.stride,options:.storageModeShared) else {
            throw OceanRendererError.unavailable("Cannot allocate lens study")
        }
        queue=q; particles=p; bubbles=b
        func pipeline(_ vertex:String,_ fragment:String,_ format:MTLPixelFormat,_ additive:Bool) throws -> MTLRenderPipelineState {
            let d=MTLRenderPipelineDescriptor()
            d.vertexFunction=library.makeFunction(name:vertex); d.fragmentFunction=library.makeFunction(name:fragment)
            let a=d.colorAttachments[0]!
            a.pixelFormat=format; a.isBlendingEnabled=true
            a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
            a.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor:d)
        }
        fieldPipeline=try pipeline("fieldVertex","fieldFragment",.rgba16Float,true)
        lensPipeline=try pipeline("lensBubbleVertex","lensBubbleFragment",.bgra8Unorm,false)
    }

    func render(into target:MTLTexture,motion:MotionSample,rotation:Float=0) throws {
        let portrait=target.height>=target.width
        let fw=portrait ? 256 : 544, fh=portrait ? 544 : 256
        if scene?.width != target.width || scene?.height != target.height {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:target.width,height:target.height,mipmapped:false)
            d.storageMode = .private; d.usage=[.shaderRead,.renderTarget]
            scene=device.makeTexture(descriptor:d)
        }
        if field?.width != fw || field?.height != fh {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:fw,height:fh,mipmapped:false)
            d.storageMode = .private; d.usage=[.shaderRead,.renderTarget]
            field=device.makeTexture(descriptor:d)
        }
        guard let scene,let field,let command=queue.makeCommandBuffer() else {
            throw OceanRendererError.unavailable("Cannot prepare lens frame")
        }
        base.motion=motion; base.screenRotation=rotation
        try base.render(into:scene,elapsed:0,waitForCompletion:true)
        // Copy keeps every pixel outside the pocket exactly equal to the base.
        guard let copy=command.makeBlitCommandEncoder() else { throw OceanRendererError.unavailable("Cannot copy scene") }
        copy.copy(from:scene,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),
                  sourceSize:MTLSize(width:target.width,height:target.height,depth:1),to:target,
                  destinationSlice:0,destinationLevel:0,destinationOrigin:MTLOrigin(x:0,y:0,z:0))
        copy.endEncoding()
        if enabled && !simulation.bubbles.isEmpty {
            let pp=particles.contents().bindMemory(to:SIMD4<Float>.self,capacity:1200)
            for (i,p) in simulation.particles.enumerated() { pp[i]=SIMD4(p.position,simulation.spacing*1.5) }
            let bp=bubbles.contents().bindMemory(to:Bubble.self,capacity:36)
            let sorted=simulation.bubbles.sorted { $0.position.z < $1.position.z }
            for (i,b) in sorted.enumerated() {
                bp[i]=Bubble(positionRadius:SIMD4(b.position,b.radius),life:SIMD4(min(1,b.life),0,0,0))
            }
            var u=OceanUniforms()
            u.viewport=SIMD4(portrait ? 1 : 2.12,portrait ? 2.12 : 1,simulation.time,rotation)
            u.boat=SIMD4(simulation.boat.position.x,simulation.boat.position.y,simulation.boat.angle,simulation.boat.position.z)
            u.movement=SIMD4(motion.safeGravity,simulation.energy); u.color.w=0
            let fp=MTLRenderPassDescriptor()
            fp.colorAttachments[0].texture=field; fp.colorAttachments[0].loadAction = .clear
            fp.colorAttachments[0].storeAction = .store; fp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
            guard let e=command.makeRenderCommandEncoder(descriptor:fp) else { throw OceanRendererError.unavailable("No lens field encoder") }
            e.setRenderPipelineState(fieldPipeline); e.setVertexBuffer(particles,offset:0,index:0)
            e.setVertexBytes(&u,length:MemoryLayout<OceanUniforms>.stride,index:1)
            e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:simulation.particles.count); e.endEncoding()
            let dp=MTLRenderPassDescriptor()
            dp.colorAttachments[0].texture=target; dp.colorAttachments[0].loadAction = .load; dp.colorAttachments[0].storeAction = .store
            guard let display=command.makeRenderCommandEncoder(descriptor:dp) else { throw OceanRendererError.unavailable("No lens display encoder") }
            display.setRenderPipelineState(lensPipeline)
            display.setVertexBuffer(bubbles,offset:0,index:0); display.setVertexBytes(&u,length:MemoryLayout<OceanUniforms>.stride,index:1)
            display.setFragmentBytes(&u,length:MemoryLayout<OceanUniforms>.stride,index:0)
            display.setFragmentTexture(field,index:0); display.setFragmentTexture(scene,index:1)
            display.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:sorted.count); display.endEncoding()
        }
        command.commit(); command.waitUntilCompleted()
        if let error=command.error { throw error }
    }
}
