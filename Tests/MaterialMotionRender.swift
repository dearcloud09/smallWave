import Foundation
import MetalKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

private enum Failure: Error { case check(String) }
@main struct MaterialMotionRender {
    static let root=URL(fileURLWithPath:".build-cache/material-motion")
    static let shaderURL=URL(fileURLWithPath:".build-cache/particle-surface-exact-bubbles/exact-bubble-shader.metal")
    static let firstReference=URL(fileURLWithPath:".build-cache/particle-surface-hard-film/diagnostic-shake-exact-bubbles.png")
    static func hash(_ d:Data)->String { SHA256.hash(data:d).map { String(format:"%02x",$0) }.joined() }
    static func volumeBytes(_ texture:MTLTexture)->Data {
        var data=Data(count:256*544*48*2)
        data.withUnsafeMutableBytes { raw in for z in 0..<48 {
            texture.getBytes(raw.baseAddress!.advanced(by:z*256*544*2),bytesPerRow:512,bytesPerImage:256*544*2,from:MTLRegionMake2D(0,0,256,544),mipmapLevel:0,slice:z)
        }}
        return data
    }
    static func filledVoxels(_ data:Data) throws -> Int {
        try data.withUnsafeBytes { raw in
            let values=raw.bindMemory(to:UInt16.self)
            guard values.allSatisfy({ $0<0x7c00 }) else { throw Failure.check("Nonfinite/negative density") }
            return values.reduce(0) { $0+($1>=Float16(0.6).bitPattern ? 1:0) }
        }
    }
    static func png(_ texture:MTLTexture,_ url:URL) throws -> (Data,Int) {
        var bytes=[UInt8](repeating:0,count:texture.width*texture.height*4); bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:texture.width*4,from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0) }
        var errors=0; for i in stride(from:0,to:bytes.count,by:4) where bytes[i]==255 && bytes[i+1]==0 && bytes[i+2]==255 { errors += 1 }
        let image=CGImage(width:texture.width,height:texture.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:texture.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)),provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!; CGImageDestinationAddImage(destination,image,nil); guard CGImageDestinationFinalize(destination) else { throw Failure.check("PNG") }; return (try Data(contentsOf:url),errors)
    }
    static func uniform(_ state:[String:Any]) throws -> Data {
        let boat=state["boat"] as! [Double], gravity=state["gravity"] as! [Double], bubbles=state["bubbles"] as! [[Double]]
        var data=Data(count:672); data.withUnsafeMutableBytes { raw in
            let header=[SIMD4<Float>(1,2.12,Float(state["time"] as! Double),0),SIMD4(Float(boat[0]),Float(boat[1]),Float(boat[2]),Float(boat[3])),SIMD4(Float(gravity[0]),Float(gravity[1]),Float(gravity[2]),Float(state["energy"] as! Double)),SIMD4<Float>(0.0001,0.075,0.96,0),SIMD4<Float>(0,0.18,0.6,48)]
            for i in 0..<5 { raw.storeBytes(of:header[i],toByteOffset:i*16,as:SIMD4<Float>.self) }; let count=UInt32(min(36,bubbles.count)); raw.storeBytes(of:SIMD4<UInt32>(count,0,0,0),toByteOffset:80,as:SIMD4<UInt32>.self)
            for i in 0..<Int(count) { raw.storeBytes(of:SIMD4(Float(bubbles[i][0]),Float(bubbles[i][1]),Float(bubbles[i][2]),Float(bubbles[i][3])),toByteOffset:96+i*16,as:SIMD4<Float>.self) }
        }; return data
    }
    static func main() { setbuf(stdout,nil); do { try run() } catch { fputs("FAIL \(error)\n",stderr); exit(1) } }
    static func run() throws {
        let args=CommandLine.arguments
        let kernelFilm=args.contains("--kernel-film"), oblique=args.contains("--oblique")
        let shell=args.contains("--shell"), shellControl=args.contains("--shell-control")
        let probe=args.contains("--probe")
        let preview=args.contains("--preview") || probe, imageWidth=args.contains("--probe") ? 1:(args.contains("--preview") ? 300:1200)
        let imageHeight=imageWidth*212/100, tileRows=shell ? 4:64, tileColumns=shell ? 32:imageWidth
        guard !(shell && shellControl), !(shell || shellControl) || kernelFilm else { throw Failure.check("shell modes require --kernel-film and are mutually exclusive") }
        var indices=Array(0..<48)
        if let argument=args.firstIndex(of:"--frame") {
            guard argument+1<args.count,let index=Int(args[argument+1]),(0..<48).contains(index) else { throw Failure.check("--frame expects 0...47") }
            indices=[index]
        }
        let shellFolder=URL(fileURLWithPath:".build-cache/material-vessel-shell")
        let selectedOutput=(shell || shellControl) ? shellFolder.appendingPathComponent(shell ? "enabled" : "control") : (kernelFilm ? URL(fileURLWithPath:oblique ? ".build-cache/material-kernel-oblique" : ".build-cache/material-kernel-film") : root)
        let output=preview ? selectedOutput.appendingPathComponent(probe ? "probe":"preview") : selectedOutput
        let selectedSource=(shell || shellControl) ? shellFolder.appendingPathComponent("shell-shader.metal") : shaderURL
        var source=try String(contentsOf:selectedSource,encoding:.utf8); if kernelFilm { let wall=try String(contentsOf:URL(fileURLWithPath:"Studies/StableWallFilm.metal"),encoding:.utf8); source += "\n"+wall }; let sourceData=Data(source.utf8); guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw Failure.check("Metal") }
        let library=try device.makeLibrary(source:source,options:nil); let descriptor=MTLRenderPipelineDescriptor(); descriptor.vertexFunction=library.makeFunction(name:"screenVertex"); descriptor.fragmentFunction=library.makeFunction(name:"volumeRayOceanFragment"); descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm; let pipeline=try device.makeRenderPipelineState(descriptor:descriptor)
        let volumeDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r16Float,width:256,height:544,mipmapped:false); volumeDescriptor.textureType = .type2DArray; volumeDescriptor.arrayLength=48; volumeDescriptor.storageMode = .shared; volumeDescriptor.usage = [.shaderRead,.shaderWrite,.renderTarget]; guard let volume=device.makeTexture(descriptor:volumeDescriptor), let rawVolume=kernelFilm ? device.makeTexture(descriptor:volumeDescriptor) : volume else { throw Failure.check("volume") }
        var fieldPipeline:MTLRenderPipelineState?; var wallPipeline:MTLComputePipelineState?; if kernelFilm { let field=MTLRenderPipelineDescriptor(); field.inputPrimitiveTopology = .triangle; field.vertexFunction=library.makeFunction(name:"volumeVertex"); field.fragmentFunction=library.makeFunction(name:"volumeFragment"); field.colorAttachments[0].pixelFormat = .r16Float; field.colorAttachments[0].isBlendingEnabled=true; field.colorAttachments[0].sourceRGBBlendFactor = .one; field.colorAttachments[0].destinationRGBBlendFactor = .one; fieldPipeline=try device.makeRenderPipelineState(descriptor:field); wallPipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"stableWallFilm")!) }
        let imageDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:imageWidth,height:imageHeight,mipmapped:false); imageDescriptor.storageMode = .shared; imageDescriptor.usage = [.renderTarget,.shaderRead]; guard let target=device.makeTexture(descriptor:imageDescriptor) else { throw Failure.check("target") }
        var commandNumber=0
        func finish(_ command:MTLCommandBuffer) throws -> Double { commandNumber+=1; if probe { print("command \(commandNumber) start") }; command.commit(); command.waitUntilCompleted(); if let error=command.error { throw error }; return max(0,command.gpuEndTime-command.gpuStartTime) }
        func originalRawField(_ state:[String:Any],_ u:Data) throws -> Data {
            let original=try String(contentsOfFile:".build-cache/optical-thickness/ray-shader.metal",encoding:.utf8)
            let old=try device.makeLibrary(source:original,options:nil)
            let desc=MTLRenderPipelineDescriptor(); desc.inputPrimitiveTopology = .triangle
            desc.vertexFunction=old.makeFunction(name:"volumeVertex"); desc.fragmentFunction=old.makeFunction(name:"volumeFragment")
            let a=desc.colorAttachments[0]!; a.pixelFormat = .r16Float; a.isBlendingEnabled=true
            a.sourceRGBBlendFactor = .one; a.destinationRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .one
            let oldPipeline=try device.makeRenderPipelineState(descriptor:desc)
            let oldVolume=device.makeTexture(descriptor:volumeDescriptor)!
            let positions=(state["particles"] as! [[Double]]).map { SIMD4<Float>(Float($0[0]),Float($0[1]),Float($0[2]),Float(state["spacing"] as! Double)*1.5) }
            let points=positions.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count)! }
            let c=queue.makeCommandBuffer()!, pass=MTLRenderPassDescriptor()
            pass.renderTargetArrayLength=48; pass.colorAttachments[0].texture=oldVolume
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            let e=c.makeRenderCommandEncoder(descriptor:pass)!; e.setRenderPipelineState(oldPipeline)
            e.setVertexBuffer(points,offset:0,index:0); u.withUnsafeBytes { e.setVertexBytes($0.baseAddress!,length:80,index:1) }
            e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:positions.count*48)
            e.endEncoding(); _=try finish(c)
            return volumeBytes(oldVolume)
        }
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true); var frames=[[String:Any]](), failed=false; let reference=kernelFilm ? Data() : try Data(contentsOf:firstReference), frozenState=try Data(contentsOf:URL(fileURLWithPath:".build-cache/optical-thickness/shake-state.json"))
        for index in indices { let folder=root.appendingPathComponent(String(format:"%03d",index)); let stateData=try Data(contentsOf:folder.appendingPathComponent("state.json")), state=try JSONSerialization.jsonObject(with:stateData) as! [String:Any]; let volumeData=kernelFilm ? Data() : try Data(contentsOf:folder.appendingPathComponent("volume-uncarved.f16")); if !kernelFilm { guard volumeData.count==256*544*48*2 else { throw Failure.check("volume size \(index)") } }; let reconstruction=kernelFilm ? [:] : try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("reconstruction.json"))) as! [String:Any]
            if kernelFilm { guard index != 0 || stateData == frozenState else { throw Failure.check("kernel frame0 state differs from frozen shake") } }
            guard kernelFilm || (reconstruction["prescribedWallFilm"] as? [String:Any]) != nil else { throw Failure.check("missing ZB hard-film metadata") }; guard let hard=(reconstruction["prescribedWallFilm"] as? [String:Any]) ?? (kernelFilm ? ["enabled":true,"depth":0.009,"joinWidth":0.0] : nil),
                  hard["enabled"] as? Bool == true, let thickness=hard["depth"] as? Double,
                  abs(thickness-0.009)<0.0000001, hard["joinWidth"] as? Double == 0 else { throw Failure.check("hard-film .009 \(index)") }
            var fieldGpuSeconds=0.0; let u=try uniform(state); if kernelFilm { let particles=(state["particles"] as! [[Double]]).map { SIMD4<Float>(Float($0[0]),Float($0[1]),Float($0[2]),Float(state["spacing"] as! Double)*1.5) }; let particleBuffer=particles.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count)! }; let c=queue.makeCommandBuffer()!,p=MTLRenderPassDescriptor(); p.renderTargetArrayLength=48; p.colorAttachments[0].texture=rawVolume; p.colorAttachments[0].loadAction = .clear; p.colorAttachments[0].storeAction = .store; let e=c.makeRenderCommandEncoder(descriptor:p)!; e.setRenderPipelineState(fieldPipeline!); e.setVertexBuffer(particleBuffer,offset:0,index:0); u.withUnsafeBytes { e.setVertexBytes($0.baseAddress!,length:672,index:1) }; e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:particles.count*48); e.endEncoding(); fieldGpuSeconds += try finish(c); let wc=queue.makeCommandBuffer()!,we=wc.makeComputeCommandEncoder()!; we.setComputePipelineState(wallPipeline!); we.setTexture(rawVolume,index:0); we.setTexture(volume,index:1); u.withUnsafeBytes { we.setBytes($0.baseAddress!,length:672,index:0) }; we.dispatchThreads(MTLSize(width:256,height:544,depth:48),threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1)); we.endEncoding(); fieldGpuSeconds += try finish(wc) } else { volumeData.withUnsafeBytes { raw in for z in 0..<48 { volume.replace(region:MTLRegionMake2D(0,0,256,544),mipmapLevel:0,slice:z,withBytes:raw.baseAddress!.advanced(by:z*256*544*2),bytesPerRow:512,bytesPerImage:256*544*2) } } }; var study=SIMD4<Float>(0,0,oblique ? 1:0,shell ? 1028:4); let started=DispatchTime.now().uptimeNanoseconds; var gpuSeconds=0.0
            for y in stride(from:0,to:imageHeight,by:tileRows) { for x in stride(from:0,to:imageWidth,by:tileColumns) { let command=queue.makeCommandBuffer()!, pass=MTLRenderPassDescriptor(); pass.colorAttachments[0].texture=target; pass.colorAttachments[0].loadAction=(x==0 && y==0) ? .clear:.load; pass.colorAttachments[0].storeAction = .store; let encoder=command.makeRenderCommandEncoder(descriptor:pass)!; encoder.setRenderPipelineState(pipeline); encoder.setFragmentTexture(volume,index:0); u.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!,length:672,index:0) }; encoder.setFragmentBytes(&study,length:16,index:1); encoder.setScissorRect(MTLScissorRect(x:x,y:y,width:min(tileColumns,imageWidth-x),height:min(tileRows,imageHeight-y))); encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6); encoder.endEncoding(); gpuSeconds += try finish(command) } }
            let ended=DispatchTime.now().uptimeNanoseconds; let frameFolder=kernelFilm ? output.appendingPathComponent(String(format:"%03d",index)) : folder; try FileManager.default.createDirectory(at:frameFolder,withIntermediateDirectories:true); let (pngData,errors)=try png(target,frameFolder.appendingPathComponent("frame.png")); let firstIdentical=kernelFilm ? (index==0 ? stateData==frozenState : true) : (index==0 ? pngData==reference : true); if errors>0 || !firstIdentical { failed=true };
            let renderedVolume=kernelFilm ? volumeBytes(volume) : volumeData
            let rawBytes=kernelFilm ? volumeBytes(rawVolume) : volumeData
            if kernelFilm && index==0 {
                let original=try originalRawField(state,u)
                guard original==rawBytes else { throw Failure.check("Original particle field mismatch") }
                print("PASS first raw volume byte-identical to original 80B shader")
            }
            let rawCount=try filledVoxels(rawBytes), filteredCount=try filledVoxels(renderedVolume)
            if kernelFilm && [0,12,24,36,47].contains(index) {
                try rawBytes.write(to:frameFolder.appendingPathComponent("raw.f16"))
                try renderedVolume.write(to:frameFolder.appendingPathComponent("filtered.f16"))
            }
            frames.append(["index":index,"time":state["time"]! ,"steps":state["steps"]! ,"stateSHA256":hash(stateData),"volumeSHA256":hash(renderedVolume),"rawSHA256":hash(rawBytes),"pngSHA256":hash(pngData),"wallSeconds":Double(ended-started)/1e9,"renderGPUSeconds":gpuSeconds,"surfaceGPUSeconds":fieldGpuSeconds,"magentaErrors":errors,"firstFrameIdentical":firstIdentical,"hardFilmThickness":thickness,"bulkProxy":["rawVoxels":rawCount,"filteredVoxels":filteredCount,"beforeAnalyticBubbles":true]])
            try JSONSerialization.data(withJSONObject:frames,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("render-progress.json"))
            print("frame \(index): errors=\(errors), GPU=\(gpuSeconds), firstMatch=\(firstIdentical)")
            if errors>=100 || !firstIdentical { throw Failure.check("Optical error budget or first frame mismatch") }
        }
        let manifest:[String:Any]=["sourceSHA256":hash(sourceData),"device":device.name,"target":[imageWidth,imageHeight],"preview":preview,"tileRows":tileRows,"tileColumns":tileColumns,"shellEnabled":shell,"shellControl":shellControl,"viewDirection":oblique ? [0.10,-0.38,-1.0] : [0.0,0.0,-1.0],"rendererSHA256":hash(try Data(contentsOf:URL(fileURLWithPath:"Tests/MaterialMotionRender.swift"))),"fps":24,"frames":frames,"pass":!failed,"continuationRule":"continue only while errors < 100; preserve every frame.png"]
        try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("render.json")); if failed { throw Failure.check("frame optical error or first-frame mismatch") }
    }
}
