import Foundation
import MetalKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import AVFoundation

/// Uses the app renderer, including its 480px volume pass and final upscale.
/// Art is switched on the same frozen state; the solver is never reset per style.
@main struct MiniatureArtReview {
    static var output: URL {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--output"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        return URL(fileURLWithPath: "References/miniature-art-direction")
    }
    static func require(_ test: Bool, _ message: String) throws {
        if !test { throw OceanRendererError.unavailable(message) }
    }
    static func stateHash(_ s: LiquidSimulation) -> String {
        var values = [Float]()
        func v(_ p: SIMD3<Float>) { values += [p.x,p.y,p.z] }
        for p in s.particles { v(p.position); v(p.previous); v(p.velocity) }
        for b in s.bubbles { v(b.position); v(b.velocity); values += [b.radius,b.life] }
        v(s.boat.position); v(s.boat.velocity)
        values += [s.boat.angle,s.boat.angularVelocity,s.boat.immersion,s.time,s.energy]
        return values.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format:"%02x",$0) }.joined() }
    }
    static func pixels(_ texture: MTLTexture) -> [UInt8] {
        var data = [UInt8](repeating:0,count:texture.width*texture.height*4)
        data.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:texture.width*4,
            from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0) }
        return data
    }
    static func png(_ bytes: [UInt8], width: Int, height: Int, name: String) throws {
        let info = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue))
        let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:info,
            provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
        let sink = CGImageDestinationCreateWithURL(output.appendingPathComponent(name).appendingPathExtension("png") as CFURL,
            UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(sink,image,nil)
        try require(CGImageDestinationFinalize(sink),"PNG write failed")
    }
    static func motion(_ t: Float) -> MotionSample {
        // Rest → tilt right → reverse left → let go, with no per-variant input.
        if t < 1 { return MotionSample() }
        let angle: Float
        if t < 2.5 { angle = sin((t-1)/1.5 * .pi/2) * 0.7 }
        else if t < 4.5 { angle = 0.7*cos((t-2.5)/2 * .pi) }
        else { angle = -0.7*max(0,1-(t-4.5)/1.5) }
        return MotionSample(gravity:SIMD3(sin(angle),-cos(angle),0))
    }
    static func main() throws {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let paths=["SmallWave/Rendering/LiquidShaders.metal","SmallWave/Rendering/LiquidVolumeField.metal","SmallWave/Rendering/MobileVolumeOptics.metal"]
        let source="#define LIVE_CONCATENATED_SHADER 1\n" + (try paths.map { try String(contentsOfFile:$0,encoding:.utf8) }.joined(separator:"\n"))
        guard let device=MTLCreateSystemDefaultDevice() else { throw OceanRendererError.unavailable("Metal unavailable") }
        let library=try device.makeLibrary(source:source,options:nil)
        let renderer=try LiquidRenderer(device:device,library:library)
        renderer.usesVolumeOptics=true
        try renderer.loadMiniatureArt(from:URL(fileURLWithPath:"SmallWave/Miniatures"))
        let width=804,height=1748
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget,.shaderRead]
        let target=device.makeTexture(descriptor:descriptor)!
        let s=renderer.simulation
        var states=[[String:Any]]()
        func capture(_ name: String, motion: MotionSample = MotionSample()) throws {
            // The volume and art shaders must see the same pose used by the solver.
            renderer.motion=motion
            let hash=stateHash(s)
            for variant in -1...2 {
                renderer.usesCraftedMiniature=variant>=0
                if let style=MiniatureStyle(rawValue:variant) {renderer.miniatureStyle=style}
                try renderer.render(into:target,elapsed:0,waitForCompletion:true)
                try require(stateHash(s)==hash,"Rendering changed the simulation")
                let label=variant<0 ? "baseline" : MiniatureStyle(rawValue:variant)!.assetName
                try png(pixels(target),width:width,height:height,name:"\(label)-\(name)")
            }
            states.append(["pose":name,"stateSHA256":hash,"boatPosition":[s.boat.position.x,s.boat.position.y,s.boat.position.z],
                           "boatAngle":s.boat.angle,"immersion":s.boat.immersion,
                           "renderGravity":[motion.safeGravity.x,motion.safeGravity.y,motion.safeGravity.z]])
            print("PASS \(name): baseline and three variants share the same simulation state")
        }
        for _ in 0..<600 {s.advance(elapsed:1/120,motion:MotionSample())}
        try capture("rest")
        for _ in 0..<220 {s.advance(elapsed:1/120,motion:MotionSample(gravity:SIMD3(0.65,-0.76,0)))}
        try capture("tilt",motion:MotionSample(gravity:SIMD3(0.65,-0.76,0)))
        for i in 0..<120 {
            let t=Float(i)/120
            s.advance(elapsed:1/120,motion:MotionSample(gravity:SIMD3(0,-1,0),acceleration:SIMD3(sin(t*24)*2.5,cos(t*17)*1.5,sin(t*13)*0.8)))
        }
        try capture("shake")
        for _ in 0..<240 {s.advance(elapsed:1/120,motion:MotionSample(gravity:SIMD3(0,1,0)))}
        try capture("inverted",motion:MotionSample(gravity:SIMD3(0,1,0)))
        for _ in 0..<240 {s.advance(elapsed:1/120,motion:MotionSample(gravity:SIMD3(0,0,-1)))}
        try capture("flat",motion:MotionSample(gravity:SIMD3(0,0,-1)))
        if !CommandLine.arguments.contains("--stills-only") {
            s.reset()
            for _ in 0..<600 {s.advance(elapsed:1/120,motion:MotionSample())}
            var movies=[(AVAssetWriter,AVAssetWriterInput,AVAssetWriterInputPixelBufferAdaptor)]()
            for style in MiniatureStyle.allCases {
                let url=output.appendingPathComponent(style.assetName+"-motion.mp4")
                if FileManager.default.fileExists(atPath:url.path) {try FileManager.default.removeItem(at:url)}
                let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
                let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height,
                    AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:3500000]])
                let adapter=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height])
                writer.add(input);try require(writer.startWriting(),"Movie start failed")
                writer.startSession(atSourceTime:.zero);movies.append((writer,input,adapter))
            }
            var trace=[[String:Any]]()
            for frame in 0..<180 {
                let t=Float(frame)/30, input=motion(t)
                s.advance(elapsed:1/30,motion:input);renderer.motion=input
                let hash=stateHash(s)
                trace.append(["frame":frame,"stateSHA256":hash,"gravityAngle":atan2(input.gravity.x,-input.gravity.y),
                              "boatAngle":s.boat.angle,"boatX":s.boat.position.x,"boatY":s.boat.position.y,"immersion":s.boat.immersion])
                for style in MiniatureStyle.allCases {
                    renderer.usesCraftedMiniature=true;renderer.miniatureStyle=style
                    try renderer.render(into:target,elapsed:0,waitForCompletion:true)
                    try require(stateHash(s)==hash,"Variant motion render changed the solver")
                    let (_,track,adapter)=movies[style.rawValue]
                    while !track.isReadyForMoreMediaData {Thread.sleep(forTimeInterval:0.001)}
                    var buffer:CVPixelBuffer?
                    try require(CVPixelBufferPoolCreatePixelBuffer(nil,adapter.pixelBufferPool!,&buffer)==kCVReturnSuccess,"Pixel buffer allocation failed")
                    CVPixelBufferLockBaseAddress(buffer!,[])
                    target.getBytes(CVPixelBufferGetBaseAddress(buffer!)!,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer!),from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)
                    CVPixelBufferUnlockBaseAddress(buffer!,[])
                    try require(adapter.append(buffer!,withPresentationTime:CMTime(value:Int64(frame),timescale:30)),"Movie append failed")
                }
            }
            for (writer,track,_) in movies {
                track.markAsFinished();let done=DispatchSemaphore(value:0)
                writer.finishWriting {done.signal()};done.wait()
                try require(writer.status == .completed,"Movie completion failed")
            }
            try JSONSerialization.data(withJSONObject:trace,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("motion-trace.json"))
            print("PASS 180 motion states × 3 variants; six-second movies written")
        }
        let report:[String:Any]=["renderer":"Native LiquidRenderer; live volume optics; unchanged 480px trace cap and edge resolve",
            "device":device.name,"pixelSize":[width,height],"displaySizePoints":[402,874],"hullScale":0.75,
            "states":states,"physicalIPhoneValidation":"NOT_RUN; offscreen Mac rendering with synthetic tilt input"]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("verification.json"))
        print("PASS native phone-size art review")
    }
}
