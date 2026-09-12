import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct BenchSettings {
    var width: UInt32 = 480, height: UInt32 = 1018, samples: UInt32 = 24, state: UInt32 = 0
    var clearIOR: Float = 1.46, blueIOR: Float = 1.333, viewPitch: Float = 0.19, halfDepth: Float = 0.32
    var maximumEvents: UInt32 = 48, maximumSearchSteps: UInt32 = 4096, diagnosticFlags: UInt32 = 0, reserved: UInt32 = 0
}
enum BenchError: Error { case failed(String) }

@main
struct OpticsCheck {
    static func main() {
        setbuf(stdout,nil)
        do { try run() }
        catch { fputs("FAIL optical study: \(error)\n",stderr); exit(1) }
    }
    static func run() throws {
        guard let device=MTLCreateSystemDefaultDevice(), let queue=device.makeCommandQueue() else {
            throw BenchError.failed("No Metal device")
        }
        let source=try String(contentsOfFile:"Studies/OpticalBench.metal",encoding:.utf8)
        let library=try device.makeLibrary(source:source,options:nil)
        let fixtures=try device.makeComputePipelineState(function:library.makeFunction(name:"opticalFixtures")!)
        let buffer=device.makeBuffer(length:8*16,options:.storageModeShared)!
        let checkCommand=queue.makeCommandBuffer()!
        let checkEncoder=checkCommand.makeComputeCommandEncoder()!
        checkEncoder.setComputePipelineState(fixtures)
        checkEncoder.setBuffer(buffer,offset:0,index:0)
        checkEncoder.dispatchThreads(MTLSize(width:8,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:1,height:1,depth:1))
        checkEncoder.endEncoding(); checkCommand.commit(); checkCommand.waitUntilCompleted()
        if let error=checkCommand.error { throw error }
        let values=buffer.contents().bindMemory(to:SIMD4<Float>.self,capacity:8)
        func near(_ value:Float,_ expected:Float,_ label:String) throws {
            guard value.isFinite,abs(value-expected)<0.00001 else { throw BenchError.failed("\(label): \(value) != \(expected)") }
        }
        try near(values[0].w,0.04,"normal-incidence reflectance")
        try near(values[0].z,-1,"normal-incidence direction")
        try near(values[1].x,1/3,"Snell sine at 30 degrees")
        try near(values[2].w,1,"total internal reflection")
        try near(values[2].x,0,"TIR has no transmitted ray")
        try near(values[3].w,0,"matched media no reflection")
        try near(values[3].x,0.5,"matched media no bending")
        try near(values[4].x,0.5,"parallel slab restores direction")
        try near(values[4].z,-sqrt(0.75),"parallel slab output angle")
        for axis in 0..<3 { try near(values[5][axis],0,"split path absorption") }
        try near(values[6].x,0.10,"clear sphere entry distance")
        try near(values[6].y,0.28,"clear sphere exit distance")
        try near(values[6].z,1,"blue-clear-blue phase transitions")
        try near(values[6].w,-1,"clear sphere normal points into clear medium")
        try near(values[7].x,0.670320046,"absolute red transmission")
        try near(values[7].y,0.367879441,"absolute green transmission")
        try near(values[7].z,0.135335283,"absolute blue transmission")
        print("PASS 8 GPU optical fixtures including sphere intersections/phase transitions and absolute absorption")
        var settings=BenchSettings()
        let environment=ProcessInfo.processInfo.environment
        let variant=environment["SMALLWAVE_OPTICS_VARIANT"] ?? "two-medium"
        switch variant {
        case "two-medium": break
        case "lower-contrast": settings.clearIOR=1.39
        case "matched-index": settings.clearIOR=settings.blueIOR
        default: throw BenchError.failed("Unknown optical study variant")
        }
        if let samples=ProcessInfo.processInfo.environment["SMALLWAVE_OPTICS_SAMPLES"].flatMap(UInt32.init) {
            guard samples>0,samples<=128 else { throw BenchError.failed("samples must be 1...128") }
            settings.samples=samples
        }
        let pipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"opticalBench")!)
        func render(_ configuration:BenchSettings) throws -> [SIMD4<Float>] {
            var settings=configuration
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,
                width:Int(settings.width),height:Int(settings.height),mipmapped:false)
            descriptor.storageMode = .shared; descriptor.usage = .shaderWrite
            let texture=device.makeTexture(descriptor:descriptor)!
            let command=queue.makeCommandBuffer()!
            let encoder=command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(texture,index:0)
            encoder.setBytes(&settings,length:MemoryLayout<BenchSettings>.stride,index:0)
            encoder.dispatchThreads(MTLSize(width:texture.width,height:texture.height,depth:1),
                threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1))
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            if let error=command.error { throw error }
            if command.gpuEndTime>command.gpuStartTime {
                print("GPU \(settings.width)x\(settings.height), \(settings.samples) spp, state \(settings.state): \((command.gpuEndTime-command.gpuStartTime)*1000) ms (Mac study only)")
            }
            var pixels=[SIMD4<Float>](repeating:.zero,count:texture.width*texture.height)
            pixels.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:texture.width*16,
                from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0) }
            guard pixels.allSatisfy({ p in (0..<4).allSatisfy { p[$0].isFinite && p[$0]>=0 } }) else {
                throw BenchError.failed("Nonfinite/negative radiance")
            }
            return pixels
        }
        // A full tracer fixture: a lossless scene under uniform white light must
        // stay white. Report search/event truncation separately from material color.
        var diagnostic=settings
        diagnostic.width=96; diagnostic.height=204; diagnostic.samples=32
        diagnostic.state=2; diagnostic.diagnosticFlags=3; diagnostic.maximumEvents=24
        let white=try render(diagnostic)
        let whiteError=white.reduce(0.0){$0+Double(abs($1.x-1)+abs($1.y-1)+abs($1.z-1))}/Double(white.count*3)
        let whiteUnresolved=white.reduce(0.0){$0+Double($1.w)}/Double(white.count)
        print("WHITE lossless scene mean error=\(whiteError), unresolved=\(whiteUnresolved)")
        guard whiteError<0.001,whiteUnresolved<0.001 else { throw BenchError.failed("Lossless white scene loses energy") }
        diagnostic.maximumEvents=48
        let deeper=try render(diagnostic)
        let limitDifference=zip(white,deeper).reduce(0.0){$0+Double(abs($1.0.x-$1.1.x))}/Double(white.count)
        print("WHITE 24 vs 48 event limit mean difference=\(limitDifference)")
        guard limitDifference<0.001 else { throw BenchError.failed("Event limit has material termination bias") }
        let folder=".build-cache/previews/optics"+(variant=="two-medium" ? "" : "/\(variant)")
        try FileManager.default.createDirectory(atPath:folder,withIntermediateDirectories:true)
        for (state,name) in ["calm","wave","inclusions"].enumerated() {
            settings.state=UInt32(state)
            let pixels=try render(settings)
            let unresolved=pixels.reduce(0.0){$0+Double($1.w)}/Double(pixels.count)
            let peak=pixels.map(\.w).max() ?? 0
            let localized=pixels.filter{$0.w>0.25}.count
            print("\(name): unresolved mean=\(unresolved), peak=\(peak), pixels over 25%=\(localized), \(settings.samples) samples/pixel")
            // Save before reporting a convergence failure so failures are inspectable.
            try save(pixels,width:Int(settings.width),height:Int(settings.height),path:"\(folder)/\(name).png")
            try save(pixels.map{SIMD4($0.w,0,0,1)},width:Int(settings.width),height:Int(settings.height),
                path:"\(folder)/\(name)-unresolved.png")
            guard unresolved<0.01 else { throw BenchError.failed("More than 1% of paths failed to reach environment in \(name)") }
            guard localized==0 else { throw BenchError.failed("Localized ray failure exceeds 25% in \(name); inspect unresolved map") }
        }
        print("PASS 3 static analytic optical scenes rendered on \(device.name). No dynamic fluid, acrylic layer, toy, or iPhone performance claim.")
    }
    static func save(_ pixels:[SIMD4<Float>],width:Int,height:Int,path:String) throws {
        func encode(_ x:Float)->UInt8 {
            let linear=max(0,min(1,x))
            let srgb=linear<=0.0031308 ? 12.92*linear : 1.055*pow(linear,1/2.4)-0.055
            return UInt8(clamping:Int((srgb*255).rounded()))
        }
        var bytes=[UInt8](); bytes.reserveCapacity(width*height*4)
        for p in pixels { bytes.append(contentsOf:[encode(p.x),encode(p.y),encode(p.z),255]) }
        let provider=CGDataProvider(data:Data(bytes) as CFData)!
        let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,
            bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
            provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let url=URL(fileURLWithPath:path)
        guard let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else {
            throw BenchError.failed("Cannot save PNG")
        }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw BenchError.failed("PNG write failed") }
        print("RENDER \(url.path)")
    }
}
