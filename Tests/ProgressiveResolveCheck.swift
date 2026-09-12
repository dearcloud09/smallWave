import Foundation
import MetalKit
import CryptoKit

@main struct ProgressiveResolveCheck {
    static func main() throws {
        let paths=["SmallWave/Rendering/LiquidShaders.metal","Studies/FastMaterial.metal","Studies/StochasticMaterial.metal"]
        let source=try paths.map { try String(contentsOfFile:$0,encoding:.utf8) }.joined(separator:"\n")
        let device=MTLCreateSystemDefaultDevice()!,queue=device.makeCommandQueue()!
        let library=try device.makeLibrary(source:source,options:nil)
        let descriptor=MTLRenderPipelineDescriptor()
        descriptor.vertexFunction=library.makeFunction(name:"screenVertex")
        descriptor.fragmentFunction=library.makeFunction(name:"stochasticResolveFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline=try device.makeRenderPipelineState(descriptor:descriptor)
        let inputDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:4,height:1,mipmapped:false)
        inputDescriptor.storageMode = .shared; inputDescriptor.usage = .shaderRead
        let input=device.makeTexture(descriptor:inputDescriptor)!
        // Finite radiance, one failed path among valid samples, overflow, empty.
        let values:[Float16]=[0.2,0.4,0.6,0, 0.2,0.4,0.6,1, .infinity,0,0,0, 0,0,0,0]
        values.withUnsafeBytes { input.replace(region:MTLRegionMake2D(0,0,4,1),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:32) }
        let outputDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:4,height:1,mipmapped:false)
        outputDescriptor.storageMode = .shared; outputDescriptor.usage = .renderTarget
        let output=device.makeTexture(descriptor:outputDescriptor)!
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=output
        pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        let command=queue.makeCommandBuffer()!,encoder=command.makeRenderCommandEncoder(descriptor:pass)!
        encoder.setRenderPipelineState(pipeline);encoder.setFragmentTexture(input,index:0)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6);encoder.endEncoding()
        command.commit();command.waitUntilCompleted()
        if let error=command.error { throw error }
        precondition(command.status == .completed)
        var result=[UInt8](repeating:0,count:16)
        result.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow:16,from:MTLRegionMake2D(0,0,4,1),mipmapLevel:0) }
        func display(_ value:Float16)->Int {
            let x=Double(value),mapped=(x*(2.51*x+0.03))/(x*(2.43*x+0.59)+0.14)
            return Int((pow(min(1,max(0,mapped)),1/2.2)*255).rounded())
        }
        let expected=[display(values[2]),display(values[1]),display(values[0]),255]
        precondition(zip(result.prefix(4),expected).allSatisfy { abs(Int($0)-$1)<=1 })
        precondition(Array(result[4..<8]) == [255,0,255,255])
        precondition(Array(result[8..<12]) == [255,0,255,255])
        precondition(Array(result[12..<16]) == [0,0,0,255])
        let hash=SHA256.hash(data:Data(source.utf8)).map { String(format:"%02x",$0) }.joined()
        let report:[String:Any]=["checks":"PASS","fixtures":4,"device":device.name,"outputBGRA":result,"compiledSourceSHA256":hash,"appAdopted":false]
        let folder=URL(fileURLWithPath:".build-cache/fast-material/progressive-resolve-check")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try Data(source.utf8).write(to:folder.appendingPathComponent("compiled-source.metal"))
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("check.json"))
        print("PASS finite radiance / one failed path / overflow / empty")
    }
}
