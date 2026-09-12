import Foundation
import MetalKit
import CryptoKit

private struct OceanUniforms {
    var viewport: SIMD4<Float>
    var boat: SIMD4<Float>
    var movement: SIMD4<Float>
    var color: SIMD4<Float>
    var optics: SIMD4<Float>
}
private enum ExportError: Error { case invalid(String) }

@main struct MaterialFieldExport {
    static let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    static let output = root.appendingPathComponent(".build-cache/material-field-sequence")
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func arg(_ name: String) -> String? { let a=CommandLine.arguments; guard let i=a.firstIndex(of:name),i+1<a.count else { return nil }; return a[i+1] }
    static func finite(_ value: Double) -> Float? { guard value.isFinite, value >= -Double(Float.greatestFiniteMagnitude), value <= Double(Float.greatestFiniteMagnitude) else { return nil }; return Float(value) }
    static func vector(_ value: Any?, _ count: Int, _ name: String) throws -> [Float] { guard let a=value as? [Double],a.count==count else { throw ExportError.invalid(name) }; return try a.map { guard let f=finite($0) else { throw ExportError.invalid("nonfinite \(name)") }; return f } }
    static func writeNew(_ data: Data, _ url: URL) throws { guard !FileManager.default.fileExists(atPath:url.path) else { throw ExportError.invalid("refuse overwrite \(url.path)") }; try data.write(to:url,options:.withoutOverwriting) }
    static func readArray(_ texture: MTLTexture) -> Data {
        var data=Data(count:256*544*48*2)
        data.withUnsafeMutableBytes { raw in for z in 0..<48 { texture.getBytes(raw.baseAddress!.advanced(by:z*256*544*2),bytesPerRow:512,bytesPerImage:256*544*2,from:MTLRegionMake2D(0,0,256,544),mipmapLevel:0,slice:z) } }
        return data
    }
    static func checkHalf(_ data: Data) throws {
        guard data.count==256*544*48*2 else { throw ExportError.invalid("filtered byte count") }
        for i in stride(from:0,to:data.count,by:2) { let bits=UInt16(data[i])|UInt16(data[i+1])<<8; guard Float(Float16(bitPattern:bits)).isFinite else { throw ExportError.invalid("nonfinite filtered Float16") } }
    }
    private static func uniform(_ state:[String:Any]) throws -> (OceanUniforms,[SIMD4<Float>],Any,Any) {
        let time=try vector([state["time"] as? Double].compactMap{$0},1,"time")[0]
        let boat=try vector(state["boat"],4,"boat"),gravity=try vector(state["gravity"],3,"gravity")
        guard let energyDouble=state["energy"] as? Double,let energy=finite(energyDouble),let spacingDouble=state["spacing"] as? Double,let spacing=finite(spacingDouble),spacing>0,let particles=state["particles"] as? [[Double]],!particles.isEmpty else { throw ExportError.invalid("energy/spacing/particles") }
        let points=try particles.map { p -> SIMD4<Float> in guard p.count==3,let x=finite(p[0]),let y=finite(p[1]),let z=finite(p[2]) else { throw ExportError.invalid("particle") }; return SIMD4(x,y,z,spacing*1.5) }
        let u=OceanUniforms(viewport:SIMD4(1,2.12,time,0),boat:SIMD4(boat[0],boat[1],boat[2],boat[3]),movement:SIMD4(gravity[0],gravity[1],gravity[2],energy),color:SIMD4(0,0,0,0),optics:SIMD4(0,0.18,0.6,48))
        return (u,points,state["steps"] ?? NSNull(),state["time"] ?? NSNull())
    }
    static func main() { do { try run() } catch { fputs("FAIL \(error)\n",stderr); exit(1) } }
    static func run() throws {
        var frames=Array(0..<48)
        if let raw=arg("--frame") { guard let frame=Int(raw),(0..<48).contains(frame) else { throw ExportError.invalid("--frame 0...47") }; frames=[frame] }
        guard MemoryLayout<OceanUniforms>.stride==80,!FileManager.default.fileExists(atPath:output.path) else { throw ExportError.invalid("output exists or uniform ABI") }
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let appURL=root.appendingPathComponent("SmallWave/Rendering/LiquidShaders.metal"),wallURL=root.appendingPathComponent("Studies/StableWallFilm.metal"),harnessURL=URL(fileURLWithPath:#filePath),executableURL=URL(fileURLWithPath:CommandLine.arguments[0])
        let app=try Data(contentsOf:appURL),wall=try Data(contentsOf:wallURL),harness=try Data(contentsOf:harnessURL),executable=try Data(contentsOf:executableURL),source=app+Data("\n".utf8)+wall
        try writeNew(source,output.appendingPathComponent("compiled-source.metal")); try writeNew(harness,output.appendingPathComponent("harness-source.swift")); try writeNew(executable,output.appendingPathComponent("executable.bin"))
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue(),let library=try? device.makeLibrary(source:String(data:source,encoding:.utf8)!,options:nil) else { throw ExportError.invalid("Metal library") }
        let fieldDesc=MTLRenderPipelineDescriptor(); fieldDesc.inputPrimitiveTopology = .triangle; fieldDesc.vertexFunction=library.makeFunction(name:"volumeVertex"); fieldDesc.fragmentFunction=library.makeFunction(name:"volumeFragment"); fieldDesc.colorAttachments[0].pixelFormat = .r16Float; fieldDesc.colorAttachments[0].isBlendingEnabled=true; fieldDesc.colorAttachments[0].sourceRGBBlendFactor = .one; fieldDesc.colorAttachments[0].destinationRGBBlendFactor = .one
        let fieldPipeline=try device.makeRenderPipelineState(descriptor:fieldDesc); guard let wallFunction=library.makeFunction(name:"stableWallFilm") else { throw ExportError.invalid("stableWallFilm") }; let wallPipeline=try device.makeComputePipelineState(function:wallFunction)
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r16Float,width:256,height:544,mipmapped:false); descriptor.textureType = .type2DArray; descriptor.arrayLength=48; descriptor.storageMode = .shared; descriptor.usage = [.shaderRead,.shaderWrite,.renderTarget]
        guard let raw=device.makeTexture(descriptor:descriptor),let filtered=device.makeTexture(descriptor:descriptor) else { throw ExportError.invalid("volume textures") }
        func finish(_ command:MTLCommandBuffer) throws -> Double? { command.commit(); command.waitUntilCompleted(); if let error=command.error { throw error }; guard command.status == .completed else { throw ExportError.invalid("command status \(command.status.rawValue)") }; return command.gpuEndTime>command.gpuStartTime ? command.gpuEndTime-command.gpuStartTime:nil }
        var manifestFrames=[[String:Any]]()
        for frame in frames {
            let frameName=String(format:"%03d",frame),inputURL=root.appendingPathComponent(".build-cache/material-motion/\(frameName)/state.json"),stateData=try Data(contentsOf:inputURL)
            guard let state=try JSONSerialization.jsonObject(with:stateData) as? [String:Any] else { throw ExportError.invalid("state \(frame)") }
            let (uniform,points,steps,time)=try uniform(state),frameOutput=output.appendingPathComponent(frameName)
            try FileManager.default.createDirectory(at:frameOutput,withIntermediateDirectories:true); try writeNew(stateData,frameOutput.appendingPathComponent("state.json"))
            let pointBuffer=points.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count)! }
            var u=uniform; guard let render=queue.makeCommandBuffer() else { throw ExportError.invalid("field command") }; let pass=MTLRenderPassDescriptor(); pass.renderTargetArrayLength=48; pass.colorAttachments[0].texture=raw; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store; guard let encoder=render.makeRenderCommandEncoder(descriptor:pass) else { throw ExportError.invalid("field encoder") }; encoder.setRenderPipelineState(fieldPipeline); encoder.setVertexBuffer(pointBuffer,offset:0,index:0); encoder.setVertexBytes(&u,length:80,index:1); encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:points.count*48); encoder.endEncoding(); let first=try finish(render)
            guard let compute=queue.makeCommandBuffer(),let computeEncoder=compute.makeComputeCommandEncoder() else { throw ExportError.invalid("wall command") }; computeEncoder.setComputePipelineState(wallPipeline); computeEncoder.setTexture(raw,index:0); computeEncoder.setTexture(filtered,index:1); computeEncoder.setBytes(&u,length:80,index:0); computeEncoder.dispatchThreads(MTLSize(width:256,height:544,depth:48),threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1)); computeEncoder.endEncoding(); let second=try finish(compute)
            let filteredData=readArray(filtered); try checkHalf(filteredData); let filteredURL=frameOutput.appendingPathComponent("filtered.f16"); try writeNew(filteredData,filteredURL)
            let gpu:Any=(first != nil && second != nil) ? first!+second! : NSNull(); manifestFrames.append(["frame":frame,"time":time,"steps":steps,"stateSHA256":sha(stateData),"filteredSHA256":sha(filteredData),"fieldGPUSeconds":gpu])
        }
        let manifest:[String:Any]=["completedAt":ISO8601DateFormatter().string(from:Date()),"device":device.name,"uniformStride":MemoryLayout<OceanUniforms>.stride,"sourceSHA256":sha(source),"harnessSHA256":sha(harness),"executableSHA256":sha(executable),"inputsFrozen":true,"frames":manifestFrames]
        try writeNew(JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]),output.appendingPathComponent("export.json")); print("PASS exported \(frames.count) field(s)")
    }
}
