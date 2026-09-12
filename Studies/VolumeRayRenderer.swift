import Foundation
import MetalKit

final class VolumeRayRenderer {
    let simulation=LiquidSimulation()
    private let queue:MTLCommandQueue
    private let volumePipeline:MTLRenderPipelineState
    private let bubblePipeline:MTLRenderPipelineState
    private let displayPipeline:MTLRenderPipelineState
    private let particles:MTLBuffer
    private let bubbles:MTLBuffer
    private let volume:MTLTexture
    private let layers:Int
    private let calibration:Bool
    var opticalMode:Float=0
    var displayPigment=false
    var diagnostic=false
    var traceCounters=false
    var tilted=false
    var halfStep=false
    var clearInclusions=false
    var antialias=false
    var secondaryTransport=false
    var smoothLighting=false
    var waterColor=OceanStyle.waterColor
    var studioLighting=false
    /// Offline study only: bound each high-cost GPU submission to a few rows.
    var tileRows=0
    var mirrorDepthBoundary=false
    var contrastLighting=false
    init(device:MTLDevice,library:MTLLibrary,volumeScale:Int=1,displayFragment:String="volumeRayOceanFragment",calibration:Bool=false) throws {
        guard (1...2).contains(volumeScale) else { throw OceanRendererError.unavailable("Unsupported study volume scale") }
        layers=48*volumeScale
        self.calibration=calibration
        guard let q=device.makeCommandQueue() else { throw OceanRendererError.unavailable("No command queue") }
        queue=q
        func pipeline(_ vertex:String,_ fragment:String,_ format:MTLPixelFormat,add:Bool=false,minimum:Bool=false) throws -> MTLRenderPipelineState {
            let d=MTLRenderPipelineDescriptor()
            d.inputPrimitiveTopology = .triangle
            d.vertexFunction=library.makeFunction(name:vertex); d.fragmentFunction=library.makeFunction(name:fragment)
            d.colorAttachments[0].pixelFormat=format
            if add || minimum {
                let a=d.colorAttachments[0]!; a.isBlendingEnabled=true; a.sourceRGBBlendFactor = .one
                a.destinationRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .one
                if minimum { a.rgbBlendOperation = .min; a.alphaBlendOperation = .min }
            }
            return try device.makeRenderPipelineState(descriptor:d)
        }
        volumePipeline=try pipeline(calibration ? "calibrationVolumeVertex":"volumeVertex",calibration ? "calibrationVolumeFragment":"volumeFragment",.r16Float,add: !calibration)
        bubblePipeline=try pipeline("bubbleVolumeVertex","bubbleVolumeFragment",.r16Float,minimum:true)
        displayPipeline=try pipeline("screenVertex",displayFragment,.bgra8Unorm)
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r16Float,width:256*volumeScale,height:544*volumeScale,mipmapped:false)
        d.textureType = .type2DArray; d.arrayLength=layers; d.usage=[.renderTarget,.shaderRead]; d.storageMode = .private
        guard let t=device.makeTexture(descriptor:d),
              let b=device.makeBuffer(length:simulation.particles.count*3*16,options:.storageModeShared),
              let bb=device.makeBuffer(length:36*16,options:.storageModeShared) else {
            throw OceanRendererError.unavailable("Volume study allocation failed")
        }
        volume=t; particles=b; bubbles=bb
    }
    func render(into target:MTLTexture,motion:MotionSample) throws {
        let pointer=particles.contents().bindMemory(to:SIMD4<Float>.self,capacity:simulation.particles.count*3)
        let radius=simulation.spacing*1.5
        var renderedParticleCount=0
        for p in simulation.particles {
            pointer[renderedParticleCount]=SIMD4(p.position,radius); renderedParticleCount+=1
            if mirrorDepthBoundary {
                // Rendering boundary-condition study, not additional fluid mass.
                // Mirror support across solid depth planes; this changes the
                // reconstructed phase volume and must be evaluated explicitly.
                if simulation.halfDepth-p.position.z<radius {
                    pointer[renderedParticleCount]=SIMD4(p.position.x,p.position.y,2*simulation.halfDepth-p.position.z,radius)
                    renderedParticleCount+=1
                }
                if simulation.halfDepth+p.position.z<radius {
                    pointer[renderedParticleCount]=SIMD4(p.position.x,p.position.y,-2*simulation.halfDepth-p.position.z,radius)
                    renderedParticleCount+=1
                }
            }
        }
        var u=OceanUniforms(); u.color=SIMD4(waterColor,0)
        u.viewport=SIMD4(1,simulation.halfHeight,simulation.time,0)
        u.boat=SIMD4(simulation.boat.position.x,simulation.boat.position.y,simulation.boat.angle,simulation.boat.position.z)
        if calibration { u.boat=SIMD4(20,20,0,0) }
        u.movement=SIMD4(motion.safeGravity,simulation.energy)
        u.optics=SIMD4(opticalMode,simulation.halfDepth,0.6,Float(layers))
        var study=SIMD4<Float>(displayPigment ? 1:0,traceCounters ? 2:(diagnostic ? 1:0),tilted ? 1:0,
                              (halfStep ? 1:0)+(antialias ? 4:0)+(secondaryTransport ? 16:0)+(smoothLighting ? 32:0)+(studioLighting ? 64:0)+(contrastLighting ? 256:0))
        guard let command=queue.makeCommandBuffer() else { throw OceanRendererError.unavailable("No command") }
        let pass=MTLRenderPassDescriptor(); pass.renderTargetArrayLength=layers
        pass.colorAttachments[0].texture=volume; pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store; pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0)
        guard let e=command.makeRenderCommandEncoder(descriptor:pass) else { throw OceanRendererError.unavailable("No volume encoder") }
        e.setRenderPipelineState(volumePipeline); e.setVertexBuffer(particles,offset:0,index:0)
        e.setVertexBytes(&u,length:MemoryLayout<OceanUniforms>.stride,index:1)
        e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:calibration ? layers:renderedParticleCount*layers)
        if !calibration && clearInclusions && !simulation.bubbles.isEmpty {
            let bp=bubbles.contents().bindMemory(to:SIMD4<Float>.self,capacity:36)
            for(i,b) in simulation.bubbles.enumerated() { bp[i]=SIMD4(b.position,b.radius) }
            e.setRenderPipelineState(bubblePipeline); e.setVertexBuffer(bubbles,offset:0,index:0)
            e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:simulation.bubbles.count*layers)
        }
        e.endEncoding()
        func display(_ command:MTLCommandBuffer,y:Int,height:Int) throws {
            let pass=MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture=target
            pass.colorAttachments[0].loadAction = y==0 ? .clear:.load
            pass.colorAttachments[0].storeAction = .store
            guard let out=command.makeRenderCommandEncoder(descriptor:pass) else { throw OceanRendererError.unavailable("No display encoder") }
            out.setRenderPipelineState(displayPipeline); out.setFragmentTexture(volume,index:0)
            out.setFragmentBytes(&u,length:MemoryLayout<OceanUniforms>.stride,index:0)
            out.setFragmentBytes(&study,length:MemoryLayout<SIMD4<Float>>.stride,index:1)
            out.setScissorRect(MTLScissorRect(x:0,y:y,width:target.width,height:height))
            out.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6); out.endEncoding()
        }
        func finish(_ command:MTLCommandBuffer) throws {
            command.commit(); command.waitUntilCompleted()
            if let error=command.error { throw error }
        }
        if tileRows>0 {
            try finish(command)
            for y in stride(from:0,to:target.height,by:tileRows) {
                guard let part=queue.makeCommandBuffer() else { throw OceanRendererError.unavailable("No tile command") }
                try display(part,y:y,height:min(tileRows,target.height-y)); try finish(part)
            }
        } else {
            try display(command,y:0,height:target.height); try finish(command)
        }
    }
}
