import Foundation
import MetalKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

private struct OceanUniforms { var viewport=SIMD4<Float>(1,2.12,0,0); var boat=SIMD4<Float>.zero; var movement=SIMD4<Float>(0,-1,0,0); var color=SIMD4<Float>(0.025,0.18,0.72,0); var optics=SIMD4<Float>(0,0.18,0.6,48) }
private struct Record { var summary=SIMD4<Float>.zero; var terminal=SIMD4<Float>.zero; var normal=SIMD4<Float>.zero; var phase=SIMD4<Float>.zero; var original=SIMD4<Float>.zero }
private enum Failure: Error { case check(String) }

@main struct OpticalFailureProbe {
    static let root=URL(fileURLWithPath:".build-cache/optical-failure-probe")
    static let candidate=URL(fileURLWithPath:".build-cache/particle-surface-real-centers")
    static let optics=URL(fileURLWithPath:".build-cache/optical-thickness")
    static func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func main() { do { try run() } catch { fputs("FAIL \(error)\n",stderr); exit(1) } }
    static func run() throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let pngURL=candidate.appendingPathComponent("diagnostic-shake-weighted-surface.png")
        guard let image=CGImageSourceCreateWithURL(pngURL as CFURL,nil), let cg=CGImageSourceCreateImageAtIndex(image,0,nil) else { throw Failure.check("PNG read") }
        let width=cg.width,height=cg.height
        var pixels=[UInt8](repeating:0,count:width*height*4)
        guard let context=CGContext(data:&pixels,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.check("PNG context") }
        context.draw(cg,in:CGRect(x:0,y:0,width:width,height:height))
        var points=[SIMD2<Float>](), locations=[[Int]]()
        for y in 0..<height { for x in 0..<width {
            let i=(y*width+x)*4
            if pixels[i] == 255 && pixels[i+1] == 0 && pixels[i+2] == 255 { locations.append([x,y]) }
        }}
        guard locations.count == 5 else { throw Failure.check("expected 5 magenta pixels, found \(locations.count)") }
        for xy in locations { for dy: Float in [-0.25,0.25] { for dx: Float in [-0.25,0.25] {
            points.append(SIMD2((Float(xy[0])+0.5+dx)/Float(width),(Float(xy[1])+0.5+dy)/Float(height)))
        }}}
        let stateData=try Data(contentsOf:optics.appendingPathComponent("shake-state.json"))
        let state=try JSONSerialization.jsonObject(with:stateData) as! [String:Any]
        let source=try String(contentsOf:optics.appendingPathComponent("ray-shader.metal"),encoding:.utf8)
        let suffix=try String(contentsOf:URL(fileURLWithPath:"Studies/OpticalFailureProbe.metal"),encoding:.utf8)
        let volumeData=try Data(contentsOf:candidate.appendingPathComponent("volume.f16"))
        guard volumeData.count == 256*544*48*2, let device=MTLCreateSystemDefaultDevice(), let queue=device.makeCommandQueue() else { throw Failure.check("Metal/volume") }
        let library=try device.makeLibrary(source:source+"\n"+suffix,options:nil)
        guard let function=library.makeFunction(name:"opticalFailureProbe") else { throw Failure.check("kernel") }
        let pipeline=try device.makeComputePipelineState(function:function)
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r16Float,width:256,height:544,mipmapped:false)
        descriptor.textureType = .type2DArray; descriptor.arrayLength = 48; descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        guard let volume=device.makeTexture(descriptor:descriptor) else { throw Failure.check("texture") }
        volumeData.withUnsafeBytes { raw in for z in 0..<48 { volume.replace(region:MTLRegionMake2D(0,0,256,544),mipmapLevel:0,slice:z,withBytes:raw.baseAddress!.advanced(by:z*256*544*2),bytesPerRow:512,bytesPerImage:256*544*2) } }
        let boat=state["boat"] as! [Double], gravity=state["gravity"] as! [Double]
        var uniforms=OceanUniforms(); uniforms.viewport.z=Float(state["time"] as! Double); uniforms.boat=SIMD4(Float(boat[0]),Float(boat[1]),Float(boat[2]),Float(boat[3])); uniforms.movement=SIMD4(Float(gravity[0]),Float(gravity[1]),Float(gravity[2]),Float(state["energy"] as! Double))
        var study=SIMD4<Float>(0,0,0,4)
        let uvBuffer=points.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count)! }
        guard let output=device.makeBuffer(length:MemoryLayout<Record>.stride*points.count,options:.storageModeShared), let command=queue.makeCommandBuffer(), let encoder=command.makeComputeCommandEncoder() else { throw Failure.check("buffers") }
        encoder.setComputePipelineState(pipeline); encoder.setBuffer(uvBuffer,offset:0,index:0); encoder.setBuffer(output,offset:0,index:1); encoder.setTexture(volume,index:0); encoder.setBytes(&uniforms,length:MemoryLayout<OceanUniforms>.stride,index:2); encoder.setBytes(&study,length:MemoryLayout<SIMD4<Float>>.stride,index:3)
        let probeCount=CommandLine.arguments.contains("--trace") ? 1 : points.count
        encoder.dispatchThreads(MTLSize(width:probeCount,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:min(probeCount,pipeline.maxTotalThreadsPerThreadgroup),height:1,depth:1)); encoder.endEncoding(); command.commit(); command.waitUntilCompleted(); if let error=command.error { throw error }
        let records=output.contents().bindMemory(to:Record.self,capacity:points.count)
        if CommandLine.arguments.contains("--trace") {
            let tracePipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"opticalFailureTrace")!)
            let traceBuffer=device.makeBuffer(length:2048*5*MemoryLayout<SIMD4<Float>>.stride,options:.storageModeShared)!
            memset(traceBuffer.contents(),0,traceBuffer.length)
            let c=queue.makeCommandBuffer()!, e=c.makeComputeCommandEncoder()!
            e.setComputePipelineState(tracePipeline); e.setBuffer(uvBuffer,offset:0,index:0); e.setBuffer(traceBuffer,offset:0,index:1)
            e.setTexture(volume,index:0); e.setBytes(&uniforms,length:MemoryLayout<OceanUniforms>.stride,index:2); e.setBytes(&study,length:MemoryLayout<SIMD4<Float>>.stride,index:3)
            e.dispatchThreads(MTLSize(width:1,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:1,height:1,depth:1))
            e.endEncoding(); c.commit(); c.waitUntilCompleted(); if let error=c.error { throw error }
            let values=traceBuffer.contents().bindMemory(to:SIMD4<Float>.self,capacity:2048*5)
            var trace=[[[Float]]]()
            for i in 0..<2048 where values[i*5+4].w>0 {
                trace.append((0..<5).map { let v=values[i*5+$0]; return [v.x,v.y,v.z,v.w] })
            }
            try JSONSerialization.data(withJSONObject:["pixel":locations[3],"subpixel":2,"record": "point+travelled, direction+segment, weight+inside, normal+TIR, moved+crossings","crossings":trace,"sourceSHA256":hash(Data((source+suffix).utf8))],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("trace.json"))
            print("Trace crossings=\(trace.count)")
            return
        }
        let renderDescriptor=MTLRenderPipelineDescriptor(); renderDescriptor.vertexFunction=library.makeFunction(name:"screenVertex"); renderDescriptor.fragmentFunction=library.makeFunction(name:"opticalFailurePixelProbe"); renderDescriptor.colorAttachments[0].pixelFormat = .rgba32Float
        let renderPipeline=try device.makeRenderPipelineState(descriptor:renderDescriptor)
        let targetDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:width,height:height,mipmapped:false); targetDescriptor.storageMode = .shared; targetDescriptor.usage = [.renderTarget,.shaderRead]
        guard let target=device.makeTexture(descriptor:targetDescriptor) else { throw Failure.check("pixel target") }
        for xy in locations { guard let buffer=queue.makeCommandBuffer() else { throw Failure.check("pixel command") }; let pass=MTLRenderPassDescriptor(); pass.colorAttachments[0].texture=target; pass.colorAttachments[0].loadAction = .load; pass.colorAttachments[0].storeAction = .store; guard let render=buffer.makeRenderCommandEncoder(descriptor:pass) else { throw Failure.check("pixel encoder") }; render.setRenderPipelineState(renderPipeline); render.setFragmentTexture(volume,index:0); render.setFragmentBytes(&uniforms,length:MemoryLayout<OceanUniforms>.stride,index:0); render.setFragmentBytes(&study,length:MemoryLayout<SIMD4<Float>>.stride,index:1); render.setScissorRect(MTLScissorRect(x:xy[0],y:xy[1],width:1,height:1)); render.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6); render.endEncoding(); buffer.commit(); buffer.waitUntilCompleted(); if let error=buffer.error { throw error } }
        var masks=[[String:Int]](); for xy in locations { var value=SIMD4<Float>.zero; target.getBytes(&value,bytesPerRow:MemoryLayout<SIMD4<Float>>.stride,from:MTLRegionMake2D(xy[0],xy[1],1,1),mipmapLevel:0); masks.append(["mask":Int(value.x),"packedReasons":Int(value.y)]) }
        var samples=[[String:Any]](); for i in 0..<points.count { let r=records[i]; samples.append(["pixel":locations[i/4],"subpixel":i%4,"uv":[points[i].x,points[i].y],"reasonBits":Int(r.summary.x),"travelledOver1_28":r.summary.y,"crossingsOver320":r.summary.z,"tirOver320":r.summary.w,"terminal":[r.terminal.x,r.terminal.y,r.terminal.z,r.terminal.w],"normal":[r.normal.x,r.normal.y,r.normal.z,r.normal.w],"phase":[r.phase.x,r.phase.y,r.phase.z,r.phase.w],"originalSample":[r.original.x,r.original.y,r.original.z,r.original.w]]) }
        let manifest:[String:Any]=["inputSHA256":["png":hash(try Data(contentsOf:pngURL)),"volume":hash(volumeData),"state":hash(stateData),"rayShader":hash(Data(source.utf8)),"probeShader":hash(Data(suffix.utf8))],"target":[width,height],"magentaPixels":locations,"renderedFailureMasks":masks,"sampleCount":points.count,"study":[0,0,0,4],"device":device.name,"samples":samples]
        let evidence=try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]); try evidence.write(to:root.appendingPathComponent("evidence.json")); print("PASS magenta=\(locations.count) samples=\(points.count) evidence=\(root.path)/evidence.json")
    }
}
