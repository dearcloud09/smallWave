import Foundation
import MetalKit

enum PoissonCapSource {
    static func replace(_ text:String, _ anchor:String, _ replacement:String) throws -> String {
        guard text.components(separatedBy:anchor).count==2 else {
            throw OceanRendererError.unavailable("Poisson cap anchor changed: \(anchor.prefix(60))")
        }
        return text.replacingOccurrences(of:anchor,with:replacement)
    }
    static func make(original:String,kernels:String) throws -> String {
        guard let start=original.range(of:"fragment float4 oceanFragment("),
              let end=original.range(of:"vertex QuadOut bubbleVertex(") else {
            throw OceanRendererError.unavailable("Missing original ocean fragment")
        }
        let ocean=String(original[start.lowerBound..<end.lowerBound])
        var candidate=try replace(ocean,"oceanFragment(","capOceanFragment(")
        candidate=try replace(candidate,
            "float opticalPath=1.5*(1.0-exp(-max(density-0.35,0.0)*0.18));", """
            // One connected inferred height controls both absorption and normals.
            float capQ=max(0.0,surface.sample(smp,uv).r);
            float capHeight=sqrt(capQ);
            float qLeft=surface.sample(smp,uv-float2(pixel.x,0)).r;
            float qRight=surface.sample(smp,uv+float2(pixel.x,0)).r;
            float qAbove=surface.sample(smp,uv-float2(0,pixel.y)).r;
            float qBelow=surface.sample(smp,uv+float2(0,pixel.y)).r;
            float2 capGradient=float2(qRight-qLeft,qAbove-qBelow)
                /(4*u.viewport.xy*pixel)/(2*max(capHeight,0.0005));
            float3 capNormal=normalize(float3(-rotate2(capGradient,u.viewport.w),1));
            float opticalPath=2*capHeight/0.24;
            """)
        candidate=try replace(candidate,
            "float2 refracted=world+rotate2(float2(normal.x,-normal.y),u.viewport.w)*0.028;", """
            float3 capRay=refract(float3(0,0,-1),capNormal,1.0/1.33);
            float2 refracted=world+capRay.xy/max(abs(capRay.z),0.2)*(2*capHeight+0.02);
            """)
        guard let lightingStart=candidate.range(of:"    // Restrict the curved meniscus"),
              let lightingEnd=candidate.range(of:"    float3 color=mix(dry,lightToDisplay(water),coverage);") else {
            throw OceanRendererError.unavailable("Missing original surface lighting block")
        }
        candidate.replaceSubrange(lightingStart.lowerBound..<lightingEnd.lowerBound,with:"""
            // Energy-weighted studio reflection replaces additive white rims.
            // Reference pigment, scatter, gravity depth and backdrop remain original.
            float fresnel=0.02+0.98*pow(1.0-capNormal.z,5.0);
            float3 reflection=displayToLight(reflectedStudio(reflect(float3(0,0,-1),capNormal)));
            water=mix(water,reflection,fresnel);

        """)
        func mask(_ fragment:String,_ name:String,_ current:String) throws -> String {
            var result=try replace(fragment,current+"(",name+"(")
            result=try replace(result,"float4 dryToy=miniature(world,u);",
                "return float4(float3(coverage),1);\n    float4 dryToy=miniature(world,u);")
            return result
        }
        return original+"\n"+kernels+"\n"+candidate+"\n"
            + (try mask(ocean,"capBaselineMaskFragment","oceanFragment"))+"\n"
            + (try mask(candidate,"capCandidateMaskFragment","capOceanFragment"))
    }
}

/// Offscreen study only. Uses a supplied immutable-at-render simulation state.
final class PoissonCapRenderer {
    enum Mode { case baseline, candidate, baselineMask, candidateMask }
    let device:MTLDevice
    private let queue:MTLCommandQueue
    private let fieldPipeline:MTLRenderPipelineState
    private let display:[Mode:MTLRenderPipelineState]
    private let bubbles:MTLRenderPipelineState
    private let initialize:MTLComputePipelineState
    private let jacobi:MTLComputePipelineState
    private let particleBuffer:MTLBuffer
    private let bubbleBuffer:MTLBuffer
    private(set) var field:MTLTexture!
    private(set) var cap:MTLTexture!
    private var scratch:MTLTexture!
    static let iterations=512

    init(device:MTLDevice,library:MTLLibrary) throws {
        self.device=device
        guard let queue=device.makeCommandQueue(),
              let particles=device.makeBuffer(length:1200*16,options:.storageModeShared),
              let bubbleBuffer=device.makeBuffer(length:36*16,options:.storageModeShared) else {
            throw OceanRendererError.unavailable("No cap study buffers")
        }
        self.queue=queue; particleBuffer=particles; self.bubbleBuffer=bubbleBuffer
        func pipeline(_ vertex:String,_ fragment:String,_ format:MTLPixelFormat,
                      additive:Bool=false,alpha:Bool=false) throws -> MTLRenderPipelineState {
            let d=MTLRenderPipelineDescriptor()
            d.vertexFunction=library.makeFunction(name:vertex); d.fragmentFunction=library.makeFunction(name:fragment)
            let a=d.colorAttachments[0]!
            a.pixelFormat=format
            if additive || alpha {
                a.isBlendingEnabled=true; a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
                a.destinationRGBBlendFactor=additive ? .one : .oneMinusSourceAlpha
                a.destinationAlphaBlendFactor=additive ? .one : .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor:d)
        }
        fieldPipeline=try pipeline("fieldVertex","fieldFragment",.rgba16Float,additive:true)
        bubbles=try pipeline("bubbleVertex","bubbleFragment",.bgra8Unorm,alpha:true)
        display=[.baseline:try pipeline("screenVertex","oceanFragment",.bgra8Unorm),
                 .candidate:try pipeline("screenVertex","capOceanFragment",.bgra8Unorm),
                 .baselineMask:try pipeline("screenVertex","capBaselineMaskFragment",.bgra8Unorm),
                 .candidateMask:try pipeline("screenVertex","capCandidateMaskFragment",.bgra8Unorm)]
        guard let a=library.makeFunction(name:"capInitialize"), let b=library.makeFunction(name:"capJacobi") else {
            throw OceanRendererError.unavailable("No cap kernels")
        }
        initialize=try device.makeComputePipelineState(function:a)
        jacobi=try device.makeComputePipelineState(function:b)
    }
    func render(into target:MTLTexture,simulation:LiquidSimulation,motion:MotionSample,
                mode:Mode,rotation:Float=0,showsBubbles:Bool=true) throws {
        let portrait=target.height>=target.width
        let width=portrait ? 256 : 544, height=portrait ? 544 : 256
        if field?.width != width || field?.height != height {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:width,height:height,mipmapped:false)
            d.storageMode = .shared; d.usage=[.renderTarget,.shaderRead]
            field=device.makeTexture(descriptor:d)
            d.pixelFormat = .r32Float; d.usage=[.shaderRead,.shaderWrite]
            cap=device.makeTexture(descriptor:d); scratch=device.makeTexture(descriptor:d)
        }
        guard field != nil, cap != nil, scratch != nil, let command=queue.makeCommandBuffer() else {
            throw OceanRendererError.unavailable("No cap textures/command")
        }
        var u=OceanUniforms()
        u.viewport=SIMD4(portrait ? 1 : simulation.halfHeight,portrait ? simulation.halfHeight : 1,simulation.time,rotation)
        u.color.w=0
        u.boat=SIMD4(simulation.boat.position.x,simulation.boat.position.y,simulation.boat.angle,simulation.boat.position.z)
        u.movement=SIMD4(motion.safeGravity,simulation.energy)
        let uniformSize=MemoryLayout<OceanUniforms>.stride
        let pp=particleBuffer.contents().bindMemory(to:SIMD4<Float>.self,capacity:1200)
        for (i,p) in simulation.particles.enumerated() { pp[i]=SIMD4(p.position,simulation.spacing*1.5) }
        let bp=bubbleBuffer.contents().bindMemory(to:SIMD4<Float>.self,capacity:36)
        for (i,b) in simulation.bubbles.enumerated() { bp[i]=SIMD4(b.position.x,b.position.y,b.radius,min(1,b.life)) }
        let fp=MTLRenderPassDescriptor(), fa=fp.colorAttachments[0]!
        fa.texture=field; fa.loadAction = .clear; fa.storeAction = .store; fa.clearColor=MTLClearColorMake(0,0,0,0)
        guard let fieldEncoder=command.makeRenderCommandEncoder(descriptor:fp) else { throw OceanRendererError.unavailable("No cap field pass") }
        fieldEncoder.setRenderPipelineState(fieldPipeline); fieldEncoder.setVertexBuffer(particleBuffer,offset:0,index:0)
        fieldEncoder.setVertexBytes(&u,length:uniformSize,index:1)
        fieldEncoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:simulation.particles.count); fieldEncoder.endEncoding()
        if mode == .candidate || mode == .candidateMask {
            guard let compute=command.makeComputeCommandEncoder() else { throw OceanRendererError.unavailable("No cap compute pass") }
            let size=MTLSize(width:width,height:height,depth:1), group=MTLSize(width:8,height:8,depth:1)
            compute.setComputePipelineState(initialize); compute.setTexture(field,index:0); compute.setTexture(cap,index:1)
            compute.dispatchThreads(size,threadsPerThreadgroup:group)
            compute.setComputePipelineState(jacobi); compute.setBytes(&u,length:uniformSize,index:0)
            for _ in 0..<Self.iterations {
                compute.setTexture(field,index:0); compute.setTexture(cap,index:1); compute.setTexture(scratch,index:2)
                compute.dispatchThreads(size,threadsPerThreadgroup:group)
                swap(&cap,&scratch)
            }
            compute.endEncoding()
        }
        let dp=MTLRenderPassDescriptor(), da=dp.colorAttachments[0]!
        da.texture=target; da.loadAction = .dontCare; da.storeAction = .store
        guard let e=command.makeRenderCommandEncoder(descriptor:dp) else { throw OceanRendererError.unavailable("No cap display pass") }
        e.setRenderPipelineState(display[mode]!); e.setFragmentTexture(field,index:0)
        e.setFragmentTexture(mode == .candidate || mode == .candidateMask ? cap : field,index:1)
        e.setFragmentBytes(&u,length:uniformSize,index:0); e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6)
        if showsBubbles && (mode == .baseline || mode == .candidate) && !simulation.bubbles.isEmpty {
            e.setRenderPipelineState(bubbles); e.setVertexBuffer(bubbleBuffer,offset:0,index:0)
            e.setVertexBytes(&u,length:uniformSize,index:1); e.setFragmentTexture(field,index:0)
            e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:simulation.bubbles.count)
        }
        e.endEncoding(); command.commit(); command.waitUntilCompleted()
        if let error=command.error { throw error }
    }
    func capMetrics() -> (minimum:Float,maximum:Float,lastHeightDelta:Float,finite:Bool) {
        func read(_ texture:MTLTexture)->[Float] {
            var a=[Float](repeating:0,count:texture.width*texture.height)
            a.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:texture.width*4,
                from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0) }
            return a
        }
        let a=read(cap),b=read(scratch)
        var delta:Float=0
        for i in a.indices { delta=max(delta,abs(sqrt(max(0,a[i]))-sqrt(max(0,b[i])))) }
        return (a.min() ?? .nan,a.max() ?? .nan,delta,a.allSatisfy { $0.isFinite } && b.allSatisfy { $0.isFinite })
    }
}
