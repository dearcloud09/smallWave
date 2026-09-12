import Foundation
import MetalKit

/// Local study renderer; no app target, sensors, downloads or new dependencies.
final class ContourVolumeRenderer {
    let simulation=LiquidSimulation()
    private let queue:MTLCommandQueue
    private let fieldPipeline:MTLRenderPipelineState
    private let displayPipeline:MTLRenderPipelineState
    private let seeds:MTLComputePipelineState
    private let jump:MTLComputePipelineState
    private let distance:MTLComputePipelineState
    private let particles:MTLBuffer
    private let field:MTLTexture
    private let ping:MTLTexture
    private let pong:MTLTexture
    private let sdf:MTLTexture
    var opticalMode:Float=0
    var displayPigment=false
    var diagnostic=false
    init(device:MTLDevice,library:MTLLibrary) throws {
        guard let q=device.makeCommandQueue() else { throw OceanRendererError.unavailable("No command queue") }
        queue=q
        func pipeline(_ vertex:String,_ fragment:String,_ format:MTLPixelFormat,add:Bool=false) throws -> MTLRenderPipelineState {
            let d=MTLRenderPipelineDescriptor()
            d.vertexFunction=library.makeFunction(name:vertex); d.fragmentFunction=library.makeFunction(name:fragment)
            d.colorAttachments[0].pixelFormat=format
            if add { let a=d.colorAttachments[0]!; a.isBlendingEnabled=true; a.sourceRGBBlendFactor = .one
                a.destinationRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .one }
            return try device.makeRenderPipelineState(descriptor:d)
        }
        fieldPipeline=try pipeline("fieldVertex","fieldFragment",.rgba16Float,add:true)
        displayPipeline=try pipeline("screenVertex","contourOceanFragment",.bgra8Unorm)
        func compute(_ name:String) throws -> MTLComputePipelineState {
            guard let fn=library.makeFunction(name:name) else { throw OceanRendererError.unavailable("Missing \(name)") }
            return try device.makeComputePipelineState(function:fn)
        }
        seeds=try compute("contourSeeds"); jump=try compute("contourJump"); distance=try compute("contourDistance")
        func texture(_ format:MTLPixelFormat) throws -> MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:256,height:544,mipmapped:false)
            d.usage=[.renderTarget,.shaderRead,.shaderWrite]; d.storageMode = .private
            guard let t=device.makeTexture(descriptor:d) else { throw OceanRendererError.unavailable("Study allocation failed") }
            return t
        }
        field=try texture(.rgba16Float); ping=try texture(.rgba32Float); pong=try texture(.rgba32Float); sdf=try texture(.r32Float)
        guard let b=device.makeBuffer(length:simulation.particles.count*16,options:.storageModeShared) else {
            throw OceanRendererError.unavailable("Particle allocation failed")
        }
        particles=b
    }
    func render(into target:MTLTexture,motion:MotionSample) throws {
        // Synchronous offscreen harness: buffer reuse waits for GPU completion.
        let pointer=particles.contents().bindMemory(to:SIMD4<Float>.self,capacity:simulation.particles.count)
        for (i,p) in simulation.particles.enumerated() { pointer[i]=SIMD4(p.position,simulation.spacing*1.5) }
        var u=OceanUniforms()
        u.color.w=0
        u.viewport=SIMD4(1,simulation.halfHeight,simulation.time,0)
        u.boat=SIMD4(simulation.boat.position.x,simulation.boat.position.y,simulation.boat.angle,simulation.boat.position.z)
        u.movement=SIMD4(motion.safeGravity,simulation.energy)
        u.optics=SIMD4(opticalMode,simulation.halfDepth,displayPigment ? 1:0,diagnostic ? 1:0)
        guard let command=queue.makeCommandBuffer() else { throw OceanRendererError.unavailable("No command") }
        let pass=MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture=field; pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store; pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
        guard let e=command.makeRenderCommandEncoder(descriptor:pass) else { throw OceanRendererError.unavailable("No field encoder") }
        e.setRenderPipelineState(fieldPipeline); e.setVertexBuffer(particles,offset:0,index:0)
        e.setVertexBytes(&u,length:MemoryLayout<OceanUniforms>.stride,index:1)
        e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:simulation.particles.count); e.endEncoding()
        let size=MTLSize(width:256,height:544,depth:1), group=MTLSize(width:8,height:8,depth:1)
        func encode(_ pipeline:MTLComputePipelineState,_ textures:[MTLTexture],_ jumpSize:UInt32?=nil) throws {
            guard let c=command.makeComputeCommandEncoder() else { throw OceanRendererError.unavailable("No compute encoder") }
            c.setComputePipelineState(pipeline)
            for (i,t) in textures.enumerated() { c.setTexture(t,index:i) }
            if var n=jumpSize { c.setBytes(&n,length:4,index:0) }
            else { c.setBytes(&u,length:MemoryLayout<OceanUniforms>.stride,index:0) }
            c.dispatchThreads(size,threadsPerThreadgroup:group); c.endEncoding()
        }
        try encode(seeds,[field,ping])
        var source=ping, destination=pong
        for n:UInt32 in [512,256,128,64,32,16,8,4,2,1,1] {
            try encode(jump,[source,destination],n); swap(&source,&destination)
        }
        try encode(distance,[source,field,sdf])
        let display=MTLRenderPassDescriptor()
        display.colorAttachments[0].texture=target; display.colorAttachments[0].loadAction = .dontCare
        display.colorAttachments[0].storeAction = .store
        guard let out=command.makeRenderCommandEncoder(descriptor:display) else { throw OceanRendererError.unavailable("No display encoder") }
        out.setRenderPipelineState(displayPipeline); out.setFragmentTexture(field,index:0); out.setFragmentTexture(sdf,index:1)
        out.setFragmentBytes(&u,length:MemoryLayout<OceanUniforms>.stride,index:0)
        out.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6); out.endEncoding()
        command.commit(); command.waitUntilCompleted()
        if let error=command.error { throw error }
    }
}
