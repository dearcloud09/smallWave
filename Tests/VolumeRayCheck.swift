import Foundation
import MetalKit

@main
struct VolumeRayCheck {
    static func main() throws {
        guard let device=MTLCreateSystemDefaultDevice(), let queue=device.makeCommandQueue() else {
            throw OceanRendererError.unavailable("No Metal GPU")
        }
        let base=try String(contentsOfFile:"SmallWave/Rendering/LiquidShaders.metal",encoding:.utf8)
        let study=try String(contentsOfFile:"Studies/VolumeRay.metal",encoding:.utf8)
        let expected="""
        fragment float4 beerReference(QuadOut in [[stage_in]], constant OceanUniforms &u [[buffer(0)]],
                                      constant float4 &s [[buffer(1)]]) {
            float2 p=(in.uv*float2(2,-2)+float2(-1,1))*u.viewport.xy;
            float3 dye=-log(u.color.rgb)*0.72/0.24;
            return float4(lightToDisplay(displayToLight(backdrop(p,u))*exp(-dye*s.w)),1);
        }
        fragment float4 toyReference(QuadOut in [[stage_in]], constant OceanUniforms &u [[buffer(0)]],
                                     constant float4 &s [[buffer(1)]]) {
            float2 p=(in.uv*float2(2,-2)+float2(-1,1))*u.viewport.xy;
            float4 toy=miniature(p,u);
            float f=pow((1.46-1.333)/(1.46+1.333),2.0);
            float3 dye=-log(u.color.rgb)*0.72/0.24;
            float3 light=f*displayToLight(reflectedStudio(float3(0,0,1)))
                +(1-f)*exp(-dye*(0.07425-u.boat.w))*displayToLight(toy.rgb);
            return float4(lightToDisplay(light),toy.a);
        }
        kernel void fresnelFixture(device float *out [[buffer(0)]]) {
            out[0]=vrFresnel(0.0,1.46,1.46);
            out[1]=vrFresnel(0.36,1.46,1.333);
            out[2]=vrFresnel(0.60,1.46,1.333);
        }
        kernel void normalDirectionFixture(texture2d_array<float> volume [[texture(0)]],
                    constant OceanUniforms &u [[buffer(0)]],device float4 *out [[buffer(1)]],
                    uint id [[thread_position_in_grid]]) {
            float z=2*fract(float(id)*0.6180339887)-1;
            float angle=float(id)*2.39996323;
            float3 axis=float3(sqrt(1-z*z)*cos(angle),sqrt(1-z*z)*sin(angle),z);
            bool initial=vrDensity(volume,float3(0),u)>=0.6;
            float lo=0,hi=0.175;
            for(uint i=0;i<24;i++) {
                float mid=(lo+hi)*0.5;
                if((vrDensity(volume,axis*mid,u)>=0.6)==initial) lo=mid; else hi=mid;
            }
            float3 p=axis*((lo+hi)*0.5), ng=vrNormal(volume,p,u,false), ns=vrNormal(volume,p,u,true);
            float3 tangent=normalize(cross(ng,abs(ng.y)<0.9?float3(0,1,0):float3(1,0,0)));
            float cosine=0.01+0.98*float(id%101)/100;
            float3 incident=-ng*cosine+tangent*sqrt(1-cosine*cosine);
            if(dot(ns,incident)>0) ns=-ns;
            float3 rg=reflect(incident,ng), rs=reflect(incident,ns);
            float3 tg=refract(incident,ng,1.46/1.333),ts=refract(incident,ns,1.46/1.333);
            bool tirg=length_squared(tg)<0.000001,tirs=length_squared(ts)<0.000001;
            out[id*2]=float4(dot(rs,ng)<=0,(!tirs && dot(ts,ng)>=0),tirg!=tirs,acos(clamp(dot(ng,ns),-1.0,1.0)));
            out[id*2+1]=float4(dot(rg,ng)<=0,(!tirg && dot(tg,ng)>=0),abs(length(ns)-1),abs(vrDensity(volume,p,u)-0.6));
        }
        kernel void fieldFixture(texture2d_array<float> volume [[texture(0)]],constant OceanUniforms &u [[buffer(0)]],
                   const device float4 *points [[buffer(1)]],device float4 *out [[buffer(2)]],uint id [[thread_position_in_grid]]) {
            VRField field=vrField(volume,points[id].xyz,u);
            out[id]=float4(field.value,field.gradient);
        }
        """
        let library=try device.makeLibrary(source:base+"\n"+study+"\n"+expected,options:nil)
        func pipeline(_ fragment:String) throws -> MTLRenderPipelineState {
            let d=MTLRenderPipelineDescriptor(); d.vertexFunction=library.makeFunction(name:"screenVertex")
            d.fragmentFunction=library.makeFunction(name:fragment); d.colorAttachments[0].pixelFormat = .rgba32Float
            return try device.makeRenderPipelineState(descriptor:d)
        }
        let ray=try pipeline("volumeRayOceanFragment"), beer=try pipeline("beerReference"), toy=try pipeline("toyReference")
        let w=64,h=128,layers=48
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r32Float,width:w,height:h,mipmapped:false)
        d.textureType = .type2DArray; d.arrayLength=layers; d.storageMode = .shared; d.usage = .shaderRead
        let volume=device.makeTexture(descriptor:d)!
        let outD=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:w,height:h,mipmapped:false)
        outD.storageMode = .shared; outD.usage = .renderTarget
        let output=device.makeTexture(descriptor:outD)!
        var u=OceanUniforms(); u.color.w=0; u.viewport=SIMD4(1,2.12,0,0)
        u.optics=SIMD4(2,0.18,0.6,Float(layers)); u.boat=SIMD4(20,20,0,0)
        func fill(_ value:(Int,Float,Float,Float)->Float) {
            for z in 0..<layers {
                var pixels=[Float](repeating:0,count:w*h)
                for y in 0..<h { for x in 0..<w {
                    pixels[y*w+x]=value(z,(Float(x)+0.5)/Float(w)*2-1,
                        (1-(Float(y)+0.5)/Float(h)*2)*2.12,0.18-(Float(z)+0.5)*0.36/Float(layers))
                }}
                pixels.withUnsafeBytes { volume.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,slice:z,
                    withBytes:$0.baseAddress!,bytesPerRow:w*4,bytesPerImage:w*h*4) }
            }
        }
        func render(_ pipeline:MTLRenderPipelineState,_ params:SIMD4<Float>) -> [SIMD4<Float>] {
            var params=params
            let command=queue.makeCommandBuffer()!, pass=MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture=output; pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            let e=command.makeRenderCommandEncoder(descriptor:pass)!
            e.setRenderPipelineState(pipeline); e.setFragmentTexture(volume,index:0)
            e.setFragmentBytes(&u,length:MemoryLayout<OceanUniforms>.stride,index:0)
            e.setFragmentBytes(&params,length:16,index:1)
            e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6); e.endEncoding()
            command.commit(); command.waitUntilCompleted()
            if let error=command.error { fatalError("GPU: \(error)") }
            var result=[SIMD4<Float>](repeating:.zero,count:w*h)
            result.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow:w*16,
                from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0) }
            return result
        }
        var failures=[String](), notes=[String]()
        func check(_ name:String,_ condition:Bool,_ evidence:String) {
            let line="\(condition ? "PASS":"FAIL") \(name): \(evidence)"; print(line); notes.append(line)
            if !condition { failures.append(name) }
        }
        let center=(h/2)*w+w/2
        for (name,intervals,expectedLength,expectedCrossings) in [
            ("empty",[ClosedRange<Int>](),Float(0),0),
            ("filled",[0...47],Float(0.36),2),
            ("slab",[14...33],Float(0.1485),2),
            ("two-slabs",[10...19,28...37],Float(0.147),4)
        ] {
            fill { z,_,_,_ in intervals.contains(where:{$0.contains(z)}) ? 1:0 }
            u.optics.x=2
            let diagnostic=render(ray,SIMD4(0,1,0,0))[center]
            check(name+" path",abs(diagnostic.x*0.5-expectedLength)<0.00015 && Int(round(diagnostic.y*16))==expectedCrossings
                  && diagnostic.z==0 && diagnostic.w==0,"L=\(diagnostic.x*0.5), boundaries=\(diagnostic.y*16), unresolved=\(diagnostic.z), mismatch=\(diagnostic.w)")
            let actual=render(ray,SIMD4(0,0,0,0))[center]
            let reference=render(beer,SIMD4(0,0,0,expectedLength))[center]
            let delta=simd_abs(actual-reference)
            check(name+" Beer-Lambert",max(delta.x,max(delta.y,delta.z))<0.0003,"display error=\(delta)")
            u.optics.x=3
            let straight=render(ray,SIMD4(0,0,0,0))[center]
            check(name+" matched IOR",simd_length(actual-straight)<0.00001,"matched vs straight=\(simd_length(actual-straight))")
        }
        let coefficient=device.makeBuffer(length:12,options:.storageModeShared)!
        let command=queue.makeCommandBuffer()!, compute=command.makeComputeCommandEncoder()!
        compute.setComputePipelineState(try device.makeComputePipelineState(function:library.makeFunction(name:"fresnelFixture")!))
        compute.setBuffer(coefficient,offset:0,index:0)
        compute.dispatchThreads(MTLSize(width:1,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:1,height:1,depth:1))
        compute.endEncoding(); command.commit(); command.waitUntilCompleted()
        let f=coefficient.contents().bindMemory(to:Float.self,capacity:3)
        check("Fresnel limits",f[0]==0 && f[1]==1 && f[2]>0 && f[2]<1,"equal-tangent=\(f[0]), TIR=\(f[1]), below-critical=\(f[2])")
        u.optics.x=0
        fill { _,x,_,z in max(0,min(2,0.6-(x*sqrt(1-0.36*0.36)+z*0.36)*10)) }
        let tir=render(ray,SIMD4(0,1,0,0))[center]
        check("TIR phase",tir.x<0.0001 && tir.y>0 && tir.z==0 && tir.w==0,"diagnostic=\(tir)")
        fill { z,_,_,_ in (14...33).contains(z) ? 1:0 }
        u.boat=SIMD4(0,0,0,0.02)
        let actualToy=render(ray,SIMD4(0,0,0,0))[center], referenceToy=render(toy,SIMD4(0,0,0,0))[center]
        let td=simd_abs(actualToy-referenceToy)
        check("sprite preserves front reflection",referenceToy.w>0.999 && max(td.x,max(td.y,td.z))<0.0003,"actual=\(actualToy), closed form=\(referenceToy)")
        // No extended ray marching: isolate normal directions from transport
        // cost before retrying any full-frame smoothed-normal render.
        let normalCount=2048
        let normalOutput=device.makeBuffer(length:normalCount*2*16,options:.storageModeShared)!
        let normalPipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"normalDirectionFixture")!)
        for (name,sign) in [("sphere",Float(1)),("clear inclusion",Float(-1))] {
            fill { _,x,y,z in 0.6+sign*(0.12*0.12-x*x-y*y-z*z)*40 }
            let nc=queue.makeCommandBuffer()!, ne=nc.makeComputeCommandEncoder()!
            ne.setComputePipelineState(normalPipeline); ne.setTexture(volume,index:0)
            ne.setBytes(&u,length:MemoryLayout<OceanUniforms>.stride,index:0); ne.setBuffer(normalOutput,offset:0,index:1)
            ne.dispatchThreads(MTLSize(width:normalCount,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:32,height:1,depth:1))
            ne.endEncoding(); nc.commit(); nc.waitUntilCompleted()
            if let error=nc.error { throw error }
            let values=normalOutput.contents().bindMemory(to:SIMD4<Float>.self,capacity:normalCount*2)
            var smoothReflections=0,smoothTransmissions=0,tirDifferences=0,geometricErrors=0
            var unitError:Float=0,residual:Float=0
            for i in 0..<normalCount {
                let s=values[i*2],g=values[i*2+1]
                smoothReflections+=Int(s.x); smoothTransmissions+=Int(s.y); tirDifferences+=Int(s.z)
                geometricErrors+=Int(g.x+g.y); unitError=max(unitError,g.z); residual=max(residual,g.w)
            }
            check(name+" geometric directions",geometricErrors==0 && unitError<0.00001 && residual<0.0001,
                  "wrong geometric hemisphere=\(geometricErrors), normal length error=\(unitError), iso residual=\(residual)")
            let observation="OBSERVED \(name) smooth normal: wrong reflected hemisphere=\(smoothReflections), wrong transmitted hemisphere=\(smoothTransmissions), changed TIR=\(tirDifferences) / \(normalCount). Not a full-frame GPU-hang diagnosis."
            print(observation); notes.append(observation)
        }
        // Independent closed-form fields: B-spline convolution preserves a
        // linear field and adds a known constant variance to a quadratic.
        let cubicLibrary=try device.makeLibrary(source:base+"\n#define VR_CUBIC_FIELD 1\n"+study+"\n"+expected,options:nil)
        let cubicPipeline=try device.makeComputePipelineState(function:cubicLibrary.makeFunction(name:"fieldFixture")!)
        let probes=(0..<128).map { i -> SIMD4<Float> in
            let x=Float(i%8)/35-0.1,y=Float((i/8)%8)/35-0.1,z=Float(i%11)/55-0.09
            return SIMD4(x,y,z,0)
        }
        let probeBuffer=probes.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)! }
        let fieldOutput=device.makeBuffer(length:probes.count*16,options:.storageModeShared)!
        let voxel=SIMD3<Float>(2/Float(w),4.24/Float(h),0.36/Float(layers))
        let variance=simd_dot(voxel,voxel)/3
        for kind in 0..<3 {
            fill { _,x,y,z in
                if kind==0 { return 0.9 }
                if kind==1 { return 0.6+0.9*x-0.3*y+0.2*z }
                return 0.6+40*(0.12*0.12-x*x-y*y-z*z)
            }
            let fc=queue.makeCommandBuffer()!,fe=fc.makeComputeCommandEncoder()!
            fe.setComputePipelineState(cubicPipeline); fe.setTexture(volume,index:0)
            fe.setBytes(&u,length:MemoryLayout<OceanUniforms>.stride,index:0)
            fe.setBuffer(probeBuffer,offset:0,index:1); fe.setBuffer(fieldOutput,offset:0,index:2)
            fe.dispatchThreads(MTLSize(width:probes.count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:32,height:1,depth:1))
            fe.endEncoding(); fc.commit(); fc.waitUntilCompleted(); if let error=fc.error { throw error }
            let results=fieldOutput.contents().bindMemory(to:SIMD4<Float>.self,capacity:probes.count)
            var valueError:Float=0,gradientError:Float=0
            for(i,p) in probes.enumerated() {
                let q=SIMD3(p.x,p.y,p.z),value:Float,gradient:SIMD3<Float>
                if kind==0 { value=0.9; gradient = .zero }
                else if kind==1 { value=0.6+0.9*p.x-0.3*p.y+0.2*p.z; gradient=SIMD3(0.9,-0.3,0.2) }
                else { value=0.6+40*(0.12*0.12-simd_dot(q,q)-variance); gradient = -80*q }
                valueError=max(valueError,abs(results[i].x-value))
                gradientError=max(gradientError,simd_length(SIMD3(results[i].y,results[i].z,results[i].w)-gradient))
            }
            check("cubic \(["constant","linear","quadratic"][kind]) field",valueError<0.0001 && gradientError<0.0015,
                  "maximum scalar error=\(valueError), gradient error=\(gradientError), 128 probes")
        }
        try FileManager.default.createDirectory(atPath:".build-cache/previews/volume-ray-check",withIntermediateDirectories:true)
        try notes.joined(separator:"\n").write(toFile:".build-cache/previews/volume-ray-check/checks.txt",atomically:true,encoding:.utf8)
        if !failures.isEmpty { throw OceanRendererError.unavailable("\(failures.count) analytic checks failed") }
    }
}
