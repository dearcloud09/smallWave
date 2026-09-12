import Foundation
import MetalKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

private struct SurfaceUniforms {
    var viewport=SIMD4<Float>(1,2.12,0,0)
    var boat=SIMD4<Float>.zero
    var movement=SIMD4<Float>(0,-1,0,0)
    var color=SIMD4<Float>(OceanStyle.waterColor,0)
    var optics=SIMD4<Float>(0,0.18,0.6,48)
}
private enum Failure: Error { case check(String) }
@main struct ParticleSurfaceRender {
    static var root: URL {
        let args=CommandLine.arguments
        if let index=args.firstIndex(of:"--folder"), index+1<args.count {
            return URL(fileURLWithPath:args[index+1])
        }
        return URL(fileURLWithPath:".build-cache/particle-surface")
    }
    static func hash(_ d: Data) -> String { SHA256.hash(data:d).map { String(format:"%02x",$0) }.joined() }
    static var geometry:URL {
        let a=CommandLine.arguments
        if let i=a.firstIndex(of:"--geometry"),i+1<a.count { return URL(fileURLWithPath:a[i+1]) }
        return URL(fileURLWithPath:".build-cache/particle-surface-exact-bubbles")
    }
    static func png(_ t: MTLTexture, _ name: String) throws -> Int {
        var data=[UInt8](repeating:0,count:t.width*t.height*4)
        data.withUnsafeMutableBytes { t.getBytes($0.baseAddress!,bytesPerRow:t.width*4,from:MTLRegionMake2D(0,0,t.width,t.height),mipmapLevel:0) }
        let image=CGImage(width:t.width,height:t.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:t.width*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider:CGDataProvider(data:Data(data) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let d=CGImageDestinationCreateWithURL(root.appendingPathComponent(name+".png") as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(d,image,nil); guard CGImageDestinationFinalize(d) else { throw Failure.check("PNG") }
        var errors=0
        for i in stride(from:0,to:data.count,by:4) where data[i]==255 && data[i+1]==0 && data[i+2]==255 { errors+=1 }
        return errors
    }
    static func main() {
        setbuf(stdout,nil)
        do { try run() } catch { fputs("FAIL \(error)\n",stderr); exit(1) }
    }
    static func run() throws {
        // A rejected candidate may be inspected internally to diagnose appearance.
        // This does not waive topology or make the result eligible for adoption.
        let diagnosticOnly=CommandLine.arguments.contains("--diagnostic")
        let exactOnly=CommandLine.arguments.contains("--exact-only")
        let wallOnly=CommandLine.arguments.contains("--wall-only")
        let studioStudy=CommandLine.arguments.contains("--studio-study")
        let dyeStudy=CommandLine.arguments.contains("--dye-study") || studioStudy
        let topology=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("topology.json"))) as! [String:Any]
        let topologyPass=topology["pass"] as? Bool == true
        guard topologyPass || diagnosticOnly else { throw Failure.check("Surface topology veto; no product render") }
        let statePath=URL(fileURLWithPath:".build-cache/optical-thickness/shake-state.json")
        let stateData=try Data(contentsOf:statePath), state=try JSONSerialization.jsonObject(with:stateData) as! [String:Any]
        let points=state["particles"] as! [[Double]], bubbles=state["bubbles"] as! [[Double]]
        let boat=state["boat"] as! [Double], gravity=state["gravity"] as! [Double]
        let sourcePath=URL(fileURLWithPath:".build-cache/optical-thickness/ray-shader.metal")
        let source=try String(contentsOf:sourcePath,encoding:.utf8)
        let volumeData=try Data(contentsOf:root.appendingPathComponent("volume.f16"))
        guard let device=MTLCreateSystemDefaultDevice(), let queue=device.makeCommandQueue() else { throw Failure.check("No Metal") }
        let library=try device.makeLibrary(source:source,options:nil)
        func pipeline(_ vertex: String,_ fragment: String,_ format: MTLPixelFormat,_ blend: Int=0) throws -> MTLRenderPipelineState {
            let d=MTLRenderPipelineDescriptor(); d.inputPrimitiveTopology = .triangle
            d.vertexFunction=library.makeFunction(name:vertex); d.fragmentFunction=library.makeFunction(name:fragment)
            let a=d.colorAttachments[0]!; a.pixelFormat=format
            if blend>0 { a.isBlendingEnabled=true; a.sourceRGBBlendFactor = .one; a.destinationRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .one }
            if blend==2 { a.rgbBlendOperation = .min; a.alphaBlendOperation = .min }
            return try device.makeRenderPipelineState(descriptor:d)
        }
        let fieldPipeline=try pipeline("volumeVertex","volumeFragment",.r16Float,1)
        let bubblePipeline=try pipeline("bubbleVolumeVertex","bubbleVolumeFragment",.r16Float,2)
        var displayPipeline=try pipeline("screenVertex","volumeRayOceanFragment",.bgra8Unorm)
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r16Float,width:256,height:544,mipmapped:false)
        descriptor.textureType = .type2DArray; descriptor.arrayLength=48; descriptor.storageMode = .shared; descriptor.usage = [.shaderRead,.renderTarget]
        guard let volume=device.makeTexture(descriptor:descriptor) else { throw Failure.check("No volume") }
        let imageDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:1200,height:2544,mipmapped:false)
        imageDescriptor.storageMode = .shared; imageDescriptor.usage = [.renderTarget,.shaderRead]
        guard let target=device.makeTexture(descriptor:imageDescriptor) else { throw Failure.check("No target") }
        let radius=Float(state["spacing"] as! Double)*1.5
        let positions=points.map { SIMD4<Float>(Float($0[0]),Float($0[1]),Float($0[2]),radius) }
        var bubblePositions=bubbles.map { SIMD4<Float>(Float($0[0]),Float($0[1]),Float($0[2]),Float($0[3])) }
        if bubblePositions.isEmpty { bubblePositions.append(.zero) }
        let particleBuffer=positions.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count)! }
        let bubbleBuffer=bubblePositions.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count)! }
        var u=SurfaceUniforms(); u.viewport.z=Float(state["time"] as! Double)
        u.boat=SIMD4(Float(boat[0]),Float(boat[1]),Float(boat[2]),Float(boat[3]))
        u.movement=SIMD4(Float(gravity[0]),Float(gravity[1]),Float(gravity[2]),Float(state["energy"] as! Double))
        var study=SIMD4<Float>(0,0,0,4)
        func finish(_ command: MTLCommandBuffer) throws { command.commit(); command.waitUntilCompleted(); if let e=command.error { throw e } }
        func display(_ name: String) throws -> Int {
            for y in stride(from:0,to:target.height,by:64) {
                let command=queue.makeCommandBuffer()!, pass=MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture=target; pass.colorAttachments[0].loadAction = y==0 ? .clear:.load; pass.colorAttachments[0].storeAction = .store
                let e=command.makeRenderCommandEncoder(descriptor:pass)!
                e.setRenderPipelineState(displayPipeline); e.setFragmentTexture(volume,index:0)
                if exactOnly {
                    var data=withUnsafeBytes(of:&u) { Data($0) }
                    var counts=SIMD4<UInt32>(UInt32(bubbles.count),0,0,0)
                    data.append(withUnsafeBytes(of:&counts) { Data($0) })
                    var spheres=bubblePositions
                    spheres+=Array(repeating:SIMD4<Float>.zero,count:36-spheres.count)
                    spheres.withUnsafeBytes { data.append(contentsOf:$0) }
                    data.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!,length:$0.count,index:0) }
                } else { e.setFragmentBytes(&u,length:MemoryLayout<SurfaceUniforms>.stride,index:0) }
                e.setFragmentBytes(&study,length:MemoryLayout<SIMD4<Float>>.stride,index:1)
                e.setScissorRect(MTLScissorRect(x:0,y:y,width:target.width,height:min(64,target.height-y)))
                e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6); e.endEncoding(); try finish(command)
            }
            let errors=try png(target,name); print("\(name): error pixels=\(errors)"); return errors
        }
        if exactOnly {
            guard diagnosticOnly else { throw Failure.check("Exact sphere comparison is an internal study") }
            let folder=geometry
            let exactSource=try String(contentsOf:URL(fileURLWithPath:".build-cache/particle-surface-exact-bubbles/exact-bubble-shader.metal"),encoding:.utf8)
            let exactLibrary=try device.makeLibrary(source:exactSource,options:nil)
            let d=MTLRenderPipelineDescriptor(); d.inputPrimitiveTopology = .triangle
            d.vertexFunction=exactLibrary.makeFunction(name:"screenVertex"); d.fragmentFunction=exactLibrary.makeFunction(name:wallOnly ? "volumeWallDiagnostic" : "volumeRayOceanFragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            displayPipeline=try device.makeRenderPipelineState(descriptor:d)
            let raw=try Data(contentsOf:folder.appendingPathComponent("volume-uncarved.f16"))
            guard raw.count==256*544*48*2 else { throw Failure.check("Uncarved dimensions") }
            raw.withUnsafeBytes { data in for layer in 0..<48 {
                volume.replace(region:MTLRegionMake2D(0,0,256,544),mipmapLevel:0,slice:layer,withBytes:data.baseAddress!.advanced(by:layer*256*544*2),bytesPerRow:512,bytesPerImage:256*544*2)
            }}
            u.color=SIMD4(0.0001,0.075,0.96,0)
            let errors=try display(wallOnly ? "diagnostic-exact-depth-occupancy" : "diagnostic-shake-exact-bubbles")
            if wallOnly { print("RGB records front/centre/back blue occupancy; colors are not optical failure flags"); return }
            try JSONSerialization.data(withJSONObject:["shaderSHA256":hash(Data(exactSource.utf8)),"volumeSHA256":hash(raw),"stateSHA256":hash(stateData),"errorPixels":errors,"adopted":false],options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("exact-render.json"))
            guard errors==0 else { throw Failure.check("Exact bubble optical errors") }
            print("PASS exact bubble frame optical error pixels=0; visual/adoption pending")
            return
        }
        let command=queue.makeCommandBuffer()!, pass=MTLRenderPassDescriptor()
        pass.renderTargetArrayLength=48; pass.colorAttachments[0].texture=volume; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        let e=command.makeRenderCommandEncoder(descriptor:pass)!
        e.setRenderPipelineState(fieldPipeline); e.setVertexBuffer(particleBuffer,offset:0,index:0)
        e.setVertexBytes(&u,length:MemoryLayout<SurfaceUniforms>.stride,index:1)
        e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:positions.count*48)
        if !bubbles.isEmpty {
            e.setRenderPipelineState(bubblePipeline); e.setVertexBuffer(bubbleBuffer,offset:0,index:0)
            e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:bubbles.count*48)
        }
        e.endEncoding(); try finish(command)
        let baselineErrors=try display("shake-particle-kernel")
        guard volumeData.count==256*544*48*2 else { throw Failure.check("Volume dimensions") }
        volumeData.withUnsafeBytes { data in
            for layer in 0..<48 {
                volume.replace(region:MTLRegionMake2D(0,0,256,544),mipmapLevel:0,slice:layer,
                    withBytes:data.baseAddress!.advanced(by:layer*256*544*2),bytesPerRow:256*2,bytesPerImage:256*544*2)
            }
        }
        let candidateName=diagnosticOnly ? "diagnostic-shake-weighted-surface":"shake-weighted-surface"
        let candidateErrors=try display(candidateName)
        var dyeEvidence=[String:Any](), studioEvidence=[String:Any]()
        var allErrors=baselineErrors+candidateErrors
        if dyeStudy {
            let old="float3 reference=clamp(u.color.rgb,float3(0.02),float3(0.98));"
            guard source.components(separatedBy:old).count==2 else { throw Failure.check("Dye source mismatch") }
            let dyeSource=source.replacingOccurrences(of:old,with:"float3 reference=clamp(u.color.rgb,float3(0.00001),float3(0.99999));")
            let dyeLibrary=try device.makeLibrary(source:dyeSource,options:nil)
            let d=MTLRenderPipelineDescriptor(); d.inputPrimitiveTopology = .triangle
            d.vertexFunction=dyeLibrary.makeFunction(name:"screenVertex")
            d.fragmentFunction=dyeLibrary.makeFunction(name:"volumeRayOceanFragment")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            displayPipeline=try device.makeRenderPipelineState(descriptor:d)
            // One art-directed transmission sample, not measured oil/water dye.
            // Prior vivid-blue experiments clipped red to 0.02 in the shader.
            u.color=SIMD4(0.0001,0.075,0.96,0)
            let dyeErrors=try display(candidateName+"-dye")
            allErrors+=dyeErrors
            try dyeSource.write(to:root.appendingPathComponent("dye-shader.metal"),atomically:true,encoding:.utf8)
            dyeEvidence=["shaderSHA256":hash(Data(dyeSource.utf8)),"referenceTransmission":[0.0001,0.075,0.96],"errorPixels":dyeErrors]
            if studioStudy {
                let scene=try String(contentsOfFile:"Studies/SharedStudio.metal",encoding:.utf8)
                var studioSource=dyeSource
                for (old,new) in [
                    ("float3 vrStudioBackdrop(float2 p) {",scene+"\nfloat3 vrStudioBackdrop(float2 p) {"),
                    ("radiance+=reflectedWeight*vrEnvironment(lightingDirection,study);","radiance+=reflectedWeight*sharedStudioRadiance(p,lightingDirection);"),
                    ("float3 scene=direction.z<0?displayToLight((uint(study.w)&64)!=0?vrStudioBackdrop(q):backdrop(q,u)):vrEnvironment(direction,study);","float3 scene=sharedStudioRadiance(p,direction);")
                ] {
                    guard studioSource.components(separatedBy:old).count==2 else { throw Failure.check("Studio source mismatch") }
                    studioSource=studioSource.replacingOccurrences(of:old,with:new)
                }
                let studioLibrary=try device.makeLibrary(source:studioSource,options:nil)
                d.vertexFunction=studioLibrary.makeFunction(name:"screenVertex")
                d.fragmentFunction=studioLibrary.makeFunction(name:"volumeRayOceanFragment")
                displayPipeline=try device.makeRenderPipelineState(descriptor:d)
                let studioErrors=try display(candidateName+"-studio")
                allErrors+=studioErrors
                try studioSource.write(to:root.appendingPathComponent("studio-shader.metal"),atomically:true,encoding:.utf8)
                studioEvidence=["shaderSHA256":hash(Data(studioSource.utf8)),"sceneSHA256":hash(Data(scene.utf8)),"errorPixels":studioErrors,"sharedReflectionAndTransmission":true]
            }
        }
        let previous=try Data(contentsOf:URL(fileURLWithPath:".build-cache/optical-thickness/shake-ray-current-physics.png"))
        let baseline=try Data(contentsOf:root.appendingPathComponent("shake-particle-kernel.png"))
        let identical=previous==baseline
        print("Prior VolumeRay baseline PNG identical: \(identical)")
        guard identical else { throw Failure.check("Frozen snapshot does not match previous baseline; comparison invalid") }
        let manifest:[String:Any] = ["stateSHA256":hash(stateData),"shaderSHA256":hash(Data(source.utf8)),"volumeSHA256":hash(volumeData),
            "baselineIdentical":identical,"baselineErrors":baselineErrors,"candidateErrors":candidateErrors,
            "diagnosticOnly":diagnosticOnly,"topologyPass":topologyPass,
            "dyeStudy":dyeEvidence,
            "studioStudy":studioEvidence,
            "target":[1200,2544],"device":device.name,"adopted":false,"completedAt":ISO8601DateFormatter().string(from:Date())]
        try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent(diagnosticOnly ? "diagnostic-render.json":"render.json"))
        guard allErrors==0 else { throw Failure.check("Optical error pixels") }
        print("PASS frozen physics and unchanged ray optics; diagnosticOnly=\(diagnosticOnly), topologyPass=\(topologyPass). No adoption decision.")
    }
}
