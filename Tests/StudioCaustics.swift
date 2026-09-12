import Foundation
import MetalKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

private struct DispatchABI { var resolution=SIMD4<UInt32>(128,200,256,400); var tile=SIMD4<UInt32>.zero; var controls=SIMD4<UInt32>.zero; var scale=SIMD4<Float>(4096,0,0,0) }
private struct PhotonRecord { var incident=SIMD4<Float>.zero; var deposited=SIMD4<Float>.zero; var outside=SIMD4<Float>.zero; var absorbed=SIMD4<Float>.zero; var reflected=SIMD4<Float>.zero; var unresolved=SIMD4<Float>.zero }
private enum Failure: Error { case check(String) }

@main struct StudioCaustics {
    static let input=URL(fileURLWithPath:".build-cache/particle-surface-exact-bubbles")
    static let nearPlane=CommandLine.arguments.contains("--near-plane")
    static var output:URL { URL(fileURLWithPath:nearPlane ? ".build-cache/studio-caustics-near" : ".build-cache/studio-caustics") }
    static func sha(_ d:Data)->String { SHA256.hash(data:d).map { String(format:"%02x",$0) }.joined() }
    static func main() { setbuf(stdout,nil); do { try run() } catch { fputs("FAIL \(error)\n",stderr); exit(1) } }
    static func replace(_ source:String,_ old:String,_ new:String) throws -> String { guard source.components(separatedBy:old).count==2 else { throw Failure.check("shader anchor: \(old.prefix(40))") }; return source.replacingOccurrences(of:old,with:new) }
    static func writePNG(_ texture:MTLTexture,_ url:URL) throws {
        var bytes=[UInt8](repeating:0,count:texture.width*texture.height*4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:texture.width*4,from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0) }
        let cg=CGImage(width:texture.width,height:texture.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:texture.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)),provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let sink=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!; CGImageDestinationAddImage(sink,cg,nil); guard CGImageDestinationFinalize(sink) else { throw Failure.check("PNG") }
    }
    static func run() throws {
        precondition(MemoryLayout<DispatchABI>.stride==64 && MemoryLayout<PhotonRecord>.stride==96,"caustic ABI")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let volumeData=try Data(contentsOf:input.appendingPathComponent("volume-uncarved.f16")); guard volumeData.count==256*544*48*2 else { throw Failure.check("volume dimensions") }
        let stateData=try Data(contentsOf:URL(fileURLWithPath:".build-cache/optical-thickness/shake-state.json")); let state=try JSONSerialization.jsonObject(with:stateData) as! [String:Any]
        let exactURL=input.appendingPathComponent("exact-bubble-shader.metal"); var exact=try String(contentsOf:exactURL,encoding:.utf8)
        var caustic=try String(contentsOf:URL(fileURLWithPath:"Studies/StudioCaustics.metal"),encoding:.utf8)
        if nearPlane {
            exact=try replace(exact,"const float3 low=float3(-3.0,-2.30,-1.20);","const float3 low=float3(-3.0,-2.30,-0.24);")
            caustic=try replace(caustic,"const float z=-1.20;","const float z=-0.24;")
            caustic=try replace(caustic,"float3(target,-1.20)-card","float3(target,-0.24)-card")
        }
        // These guarded source edits bind the generated map only to the rear card.
        var source=try replace(exact,"float3 sharedStudioRadiance(float3 origin, float3 direction) {","float3 sharedStudioRadiance(float3 origin, float3 direction, texture2d<float> caustics) {")
        source=try replace(source,"return shade*float3(0.965,0.982,1.0);","constexpr sampler causticSampler(coord::normalized,address::clamp_to_edge,filter::linear); float2 cuv=float2((p.x+2.0)/4.0,(p.y+3.12)/6.24); return shade*float3(0.965,0.982,1.0)*(0.35+0.65*caustics.sample(causticSampler,cuv).rgb);")
        source=try replace(source,"float4 vrSample(float2 uv,texture2d_array<float> volume,","float4 vrSample(float2 uv,texture2d_array<float> volume,texture2d<float> caustics,")
        source=try replace(source,"sharedStudioRadiance(p,lightingDirection)","sharedStudioRadiance(p,lightingDirection,caustics)")
        source=try replace(source,"sharedStudioRadiance(p,direction)","sharedStudioRadiance(p,direction,caustics)")
        source=try replace(source,"float4 value=vrSample(in.uv,volume,u,study);","float4 value=vrSample(in.uv,volume,caustics,u,study);")
        source=try replace(source,"float4 value=vrSample(in.uv+offset,volume,u,study);","float4 value=vrSample(in.uv+offset,volume,caustics,u,study);")
        source=try replace(source,"texture2d_array<float> volume [[texture(0)]],\n                                       constant OceanUniforms &u [[buffer(0)]],","texture2d_array<float> volume [[texture(0)]],\n                                       texture2d<float> caustics [[texture(1)]],\n                                       constant OceanUniforms &u [[buffer(0)]],")
        source += "\n"+caustic
        try source.write(to:output.appendingPathComponent("compiled-shader.metal"),atomically:true,encoding:.utf8)
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw Failure.check("Metal") }
        let library=try device.makeLibrary(source:source,options:nil)
        guard let emit=library.makeFunction(name:"causticEmit"),let resolve=library.makeFunction(name:"causticResolve") else { throw Failure.check("caustic kernels") }
        let emitPSO=try device.makeComputePipelineState(function:emit), resolvePSO=try device.makeComputePipelineState(function:resolve)
        let renderDesc=MTLRenderPipelineDescriptor(); renderDesc.vertexFunction=library.makeFunction(name:"screenVertex"); renderDesc.fragmentFunction=library.makeFunction(name:"volumeRayOceanFragment"); renderDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let displayPSO=try device.makeRenderPipelineState(descriptor:renderDesc)
        let vd=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r16Float,width:256,height:544,mipmapped:false); vd.textureType = .type2DArray; vd.arrayLength=48; vd.storageMode = .shared; vd.usage = .shaderRead
        guard let volume=device.makeTexture(descriptor:vd) else { throw Failure.check("volume texture") }
        volumeData.withUnsafeBytes { raw in for z in 0..<48 { volume.replace(region:MTLRegionMake2D(0,0,256,544),mipmapLevel:0,slice:z,withBytes:raw.baseAddress!.advanced(by:z*256*544*2),bytesPerRow:512,bytesPerImage:256*544*2) } }
        let boat=state["boat"] as! [Double], gravity=state["gravity"] as! [Double], bubbles=state["bubbles"] as! [[Double]]
        var uniformData=Data(count:672); uniformData.withUnsafeMutableBytes { raw in
            let header=[SIMD4<Float>(1,2.12,Float(state["time"] as! Double),0),SIMD4(Float(boat[0]),Float(boat[1]),Float(boat[2]),Float(boat[3])),SIMD4(Float(gravity[0]),Float(gravity[1]),Float(gravity[2]),Float(state["energy"] as! Double)),SIMD4<Float>(0.0001,0.075,0.96,0),SIMD4<Float>(0,0.18,0.6,48)]
            for i in 0..<5 { raw.storeBytes(of:header[i],toByteOffset:i*16,as:SIMD4<Float>.self) }
            let count=UInt32(min(bubbles.count,36)); raw.storeBytes(of:SIMD4<UInt32>(count,0,0,0),toByteOffset:80,as:SIMD4<UInt32>.self)
            for i in 0..<Int(count) { raw.storeBytes(of:SIMD4(Float(bubbles[i][0]),Float(bubbles[i][1]),Float(bubbles[i][2]),Float(bubbles[i][3])),toByteOffset:96+i*16,as:SIMD4<Float>.self) }
        }
        let mapDesc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:128,height:200,mipmapped:false); mapDesc.storageMode = .shared; mapDesc.usage = [.shaderRead,.shaderWrite]
        let imageDesc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:1200,height:2544,mipmapped:false); imageDesc.storageMode = .shared; imageDesc.usage = [.renderTarget,.shaderRead]
        var gpuSeconds=0.0
        func finish(_ c:MTLCommandBuffer) throws { c.commit(); c.waitUntilCompleted(); if let e=c.error { throw e }; gpuSeconds+=max(0,c.gpuEndTime-c.gpuStartTime) }
        func causticMap(_ flags:UInt32,_ label:String) throws -> (MTLTexture,[String:Any]) {
            if flags==UInt32.max {
                let map=device.makeTexture(descriptor:mapDesc)!
                let data=[UInt16](repeating:Float16(1).bitPattern,count:128*200*4)
                data.withUnsafeBytes { map.replace(region:MTLRegionMake2D(0,0,128,200),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:128*8) }
                return (map,["constantUnitMap":true])
            }
            let started=Date(), gpuStart=gpuSeconds
            print("Tracing \(label)…")
            guard let accum=device.makeBuffer(length:128*200*3*MemoryLayout<UInt32>.stride,options:.storageModeShared),let map=device.makeTexture(descriptor:mapDesc) else { throw Failure.check("caustic storage") }
            memset(accum.contents(),0,accum.length); var totals=["incident", "deposited", "outside", "absorbed", "reflected", "unresolved"].reduce(into:[String:SIMD3<Double>]()) { $0[$1] = .zero }
            for row in stride(from:0,to:400,by:16) { let count=min(16,400-row); var d=DispatchABI(); d.tile = SIMD4(0,UInt32(row),256,UInt32(count)); d.controls.x = flags
                guard let records=device.makeBuffer(length:256*count*MemoryLayout<PhotonRecord>.stride,options:.storageModeShared),let c=queue.makeCommandBuffer(),let e=c.makeComputeCommandEncoder() else { throw Failure.check("emit resources") }; e.setComputePipelineState(emitPSO); e.setTexture(volume,index:0); e.setBuffer(accum,offset:0,index:0); e.setBuffer(records,offset:0,index:1); uniformData.withUnsafeBytes { e.setBytes($0.baseAddress!,length:672,index:2) }; e.setBytes(&d,length:64,index:3); e.dispatchThreads(MTLSize(width:256,height:count,depth:1),threadsPerThreadgroup:MTLSize(width:min(256,emitPSO.maxTotalThreadsPerThreadgroup),height:1,depth:1)); e.endEncoding(); try finish(c)
                let p=records.contents().bindMemory(to:PhotonRecord.self,capacity:256*count); for i in 0..<(256*count) { let r=p[i]; let values=[r.incident,r.deposited,r.outside,r.absorbed,r.reflected,r.unresolved]; guard values.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.x >= 0 && $0.y >= 0 && $0.z >= 0 }) else { throw Failure.check("nonfinite photon") }; let rest=r.deposited+r.outside+r.absorbed+r.reflected+r.unresolved; guard max(abs(r.incident.x-rest.x),max(abs(r.incident.y-rest.y),abs(r.incident.z-rest.z))) <= 0.00001 else { throw Failure.check("photon conservation") }; for (name,v) in [("incident",r.incident),("deposited",r.deposited),("outside",r.outside),("absorbed",r.absorbed),("reflected",r.reflected),("unresolved",r.unresolved)] { totals[name]! += SIMD3(Double(v.x),Double(v.y),Double(v.z)) } }
            }
            let raw=accum.contents().bindMemory(to:UInt32.self,capacity:128*200*3); var atomics=SIMD3<Double>.zero; for i in stride(from:0,to:128*200*3,by:3) { atomics += SIMD3(Double(raw[i])/4096,Double(raw[i+1])/4096,Double(raw[i+2])/4096) }; let deposited=totals["deposited"]!; let delta=atomics-deposited
            var d=DispatchABI(); d.controls.x=flags; guard let c=queue.makeCommandBuffer(),let e=c.makeComputeCommandEncoder() else { throw Failure.check("resolve resources") }; e.setComputePipelineState(resolvePSO); e.setBuffer(accum,offset:0,index:0); e.setTexture(map,index:0); e.setBytes(&d,length:64,index:1); e.dispatchThreads(MTLSize(width:128,height:200,depth:1),threadsPerThreadgroup:MTLSize(width:min(128,resolvePSO.maxTotalThreadsPerThreadgroup),height:1,depth:1)); e.endEncoding(); try finish(c)
            var mapData=[UInt16](repeating:0,count:128*200*4); mapData.withUnsafeMutableBytes { map.getBytes($0.baseAddress!,bytesPerRow:128*8,from:MTLRegionMake2D(0,0,128,200),mipmapLevel:0) }; var rgb=[UInt8](repeating:0,count:128*200*4), interior=[Float](); for y in 0..<200 { for x in 0..<128 { let i=y*128+x, r=Float(Float16(bitPattern:mapData[i*4])), g=Float(Float16(bitPattern:mapData[i*4+1])), b=Float(Float16(bitPattern:mapData[i*4+2])); rgb[i*4]=UInt8(clamping:Int(b*255)); rgb[i*4+1]=UInt8(clamping:Int(g*255)); rgb[i*4+2]=UInt8(clamping:Int(r*255)); rgb[i*4+3]=255; if flags==3 && x>0 && x<127 && y>0 && y<199 { interior.append((r+g+b)/3) } } }; let tmp=device.makeTexture(descriptor:MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:128,height:200,mipmapped:false))!; rgb.withUnsafeBytes { tmp.replace(region:MTLRegionMake2D(0,0,128,200),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:128*4) }; try writePNG(tmp,output.appendingPathComponent("\(label)-map.png"))
            try mapData.withUnsafeBytes { try Data($0).write(to:output.appendingPathComponent(label+"-map.f16")) }; print("Map \(label) ready, unresolved=\(totals["unresolved"]!)"); var report=totals.mapValues { [ $0.x,$0.y,$0.z ] as Any }; report["wallSeconds"]=Date().timeIntervalSince(started); report["gpuSeconds"]=gpuSeconds-gpuStart; report["atomicDeposited"]=[atomics.x,atomics.y,atomics.z]; report["quantizationDelta"]=[delta.x,delta.y,delta.z]; if !interior.isEmpty { report["interiorIrradiance"]=["mean":interior.reduce(0,+)/Float(interior.count),"min":interior.min()!,"max":interior.max()!] }; return (map,report)
        }
        var result=[String:Any](); var errorPixels=[String:Int]()
        for (flags,label) in [(UInt32(0),"real"),(UInt32(1),"equal-ior"),(UInt32(3),"equal-ior-no-dye"),(UInt32.max,"unit-map")] { let (map,energies)=try causticMap(flags,label); result[label]=energies
            guard let image=device.makeTexture(descriptor:imageDesc) else { throw Failure.check("image") }; var study=SIMD4<Float>(0,0,0,4); for y in stride(from:0,to:2544,by:64) { let c=queue.makeCommandBuffer()!,p=MTLRenderPassDescriptor(); p.colorAttachments[0].texture=image; p.colorAttachments[0].loadAction=y==0 ? .clear:.load; p.colorAttachments[0].storeAction = .store; let e=c.makeRenderCommandEncoder(descriptor:p)!; e.setRenderPipelineState(displayPSO); e.setFragmentTexture(volume,index:0); e.setFragmentTexture(map,index:1); uniformData.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!,length:672,index:0) }; e.setFragmentBytes(&study,length:16,index:1); e.setScissorRect(MTLScissorRect(x:0,y:y,width:1200,height:min(64,2544-y))); e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6); e.endEncoding(); try finish(c) }; try writePNG(image,output.appendingPathComponent("\(label).png")) }
        for label in ["real","equal-ior","equal-ior-no-dye","unit-map"] {
            let png=CGImageSourceCreateWithURL(output.appendingPathComponent(label+".png") as CFURL,nil)!
            let image=CGImageSourceCreateImageAtIndex(png,0,nil)!
            var bytes=[UInt8](repeating:0,count:1200*2544*4)
            let context=CGContext(data:&bytes,width:1200,height:2544,bitsPerComponent:8,bytesPerRow:1200*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image,in:CGRect(x:0,y:0,width:1200,height:2544))
            errorPixels[label]=stride(from:0,to:bytes.count,by:4).filter { bytes[$0]==255 && bytes[$0+1]==0 && bytes[$0+2]==255 }.count
        }
        let reference=try Data(contentsOf:URL(fileURLWithPath:".build-cache/particle-surface-real-centers/diagnostic-shake-exact-bubbles.png"))
        let control=try Data(contentsOf:output.appendingPathComponent("equal-ior-no-dye.png"))
        let unit=try Data(contentsOf:output.appendingPathComponent("unit-map.png"))
        let baselineIdentical=unit==control
        let manifest:[String:Any]=["device":device.name,"inputs":["volume":sha(volumeData),"state":sha(stateData),"source":sha(Data(exact.utf8)),"caustics":sha(Data(caustic.utf8)),"harness":sha(try Data(contentsOf:URL(fileURLWithPath:"Tests/StudioCaustics.swift")))],"energies":result,"abi":["uniformBytes":672,"dispatchBytes":64,"recordBytes":96],"map":[128,200],"photons":[256,400],"tileRows":16,"gpuSecondsTotal":gpuSeconds,"errorPixels":errorPixels,"baselineIdentical":baselineIdentical,"historicalShaderByteIdentical":reference==control,"backplaneZ":nearPlane ? -0.24 : -1.20,"adopted":false,"finishedAt":ISO8601DateFormatter().string(from:Date())]
        try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("manifest.json"))
        print("Finished; baselineIdentical=\(baselineIdentical), errorPixels=\(errorPixels), GPU seconds=\(gpuSeconds)")
        guard baselineIdentical && errorPixels.values.allSatisfy({ $0==0 }) else { throw Failure.check("Frame control/errors") }
    }
}
