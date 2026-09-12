import Foundation
import MetalKit
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

@main struct LiveVolumePreview {
    static func arg(_ key: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: key), i+1<a.count else { return nil }
        return a[i+1]
    }
    static func savePNG(_ texture: MTLTexture, _ url: URL) throws {
        let w=texture.width,h=texture.height
        var bytes=[UInt8](repeating:0,count:w*h*4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:w*4,
            from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0) }
        let image=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
        let sink=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(sink,image,nil)
        guard CGImageDestinationFinalize(sink) else { throw OceanRendererError.unavailable("PNG failed") }
    }
    static func motion(_ t: Float) -> MotionSample {
        if t<1 { return MotionSample() }
        if t<3 {
            let angle=sin((t-1)/2 * .pi)*0.85
            return MotionSample(gravity:SIMD3(sin(angle),-cos(angle),0))
        }
        if t<5 {
            let q=t-3
            return MotionSample(gravity:SIMD3(0,-1,0),acceleration:SIMD3(sin(q*18)*1.8,cos(q*14)*1.1,sin(q*10)*0.4))
        }
        if t<8 {
            let angle=min(1,(t-5)/1.25) * .pi
            return MotionSample(gravity:SIMD3(sin(angle),-cos(angle),0))
        }
        let angle=max(0,1-(t-8)) * .pi
        return MotionSample(gravity:SIMD3(sin(angle),-cos(angle),0))
    }
    static func main() throws {
        let width=Int(arg("--width") ?? "320")!,height=Int((Float(width)*2.12).rounded())
        let frames=Int(arg("--frames") ?? "1")!, label=arg("--label") ?? "first"
        guard width>0,width<=1280,frames>0,frames<=360,
              label.range(of:"^[a-zA-Z0-9_-]+$",options:.regularExpression) != nil else {
            throw OceanRendererError.unavailable("Invalid preview arguments")
        }
        let output=URL(fileURLWithPath:".build-cache/live-volume/\(label)")
        guard !FileManager.default.fileExists(atPath:output.path) else { throw OceanRendererError.unavailable("Output exists") }
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let paths=["SmallWave/Rendering/LiquidShaders.metal","SmallWave/Rendering/LiquidVolumeField.metal",arg("--shader") ?? "SmallWave/Rendering/MobileVolumeOptics.metal"]
        let pathDiagnostics=CommandLine.arguments.contains("--path-diagnostics")
        let boundaryDiagnostics=CommandLine.arguments.contains("--boundary-diagnostics")
        guard !(pathDiagnostics&&boundaryDiagnostics) else {throw OceanRendererError.unavailable("Choose one diagnostic mode") }
        let source="#define LIVE_CONCATENATED_SHADER 1\n" + (pathDiagnostics ? "#define LIVE_PATH_DIAGNOSTICS 1\n":"") + (boundaryDiagnostics ? "#define LIVE_BOUNDARY_DIAGNOSTICS 1\n":"") + (try paths.map { try String(contentsOfFile:$0,encoding:.utf8) }.joined(separator:"\n"))
        try source.write(to:output.appendingPathComponent("compiled-source.metal"),atomically:true,encoding:.utf8)
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {
            throw OceanRendererError.unavailable("Metal unavailable")
        }
        let library=try device.makeLibrary(source:source,options:nil)
        let renderer=try LiquidVolumeRenderer(device:device,library:library)
        renderer.tracesAirBubbles=CommandLine.arguments.contains("--air-bubbles") || arg("--shader") == nil
        renderer.appliesEdgeAntialiasing = !CommandLine.arguments.contains("--no-edge-aa") &&
            (CommandLine.arguments.contains("--edge-aa") || arg("--shader") == nil)
        if let path=arg("--texture-image") {
            renderer.environment=try MTKTextureLoader(device:device).newTexture(URL:URL(fileURLWithPath:path),options:[.SRGB:true,.origin:MTKTextureLoader.Origin.topLeft])
        }
        if let path=arg("--environment") {
            let data=try Data(contentsOf:URL(fileURLWithPath:path))
            guard data.count==1024*512*8 else {throw OceanRendererError.unavailable("HDR texture byte count")}
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:1024,height:512,mipmapped:false)
            d.storageMode = .shared;d.usage = .shaderRead
            let texture=device.makeTexture(descriptor:d)!
            data.withUnsafeBytes {texture.replace(region:MTLRegionMake2D(0,0,1024,512),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:1024*8)}
            renderer.environment=texture
        }
        func texture(_ format:MTLPixelFormat) -> MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:width,height:height,mipmapped:false)
            d.storageMode = .shared; d.usage = [.renderTarget,.shaderRead]
            return device.makeTexture(descriptor:d)!
        }
        let target=texture(.bgra8Unorm),diagnostics=texture(.rgba16Float)
        let simulation=LiquidSimulation()
        for _ in 0..<600 { simulation.advance(elapsed:1/120,motion:MotionSample()) }
        let startFrame=Int(arg("--start-frame") ?? "0")!
        guard startFrame>=0,startFrame+frames<=360 else {throw OceanRendererError.unavailable("Invalid frame interval")}
        for f in 0..<startFrame {simulation.advance(elapsed:1/30,motion:motion(Float(f)/30))}
        if arg("--pose") == "regression-shake" {
            for _ in 0..<220 {simulation.advance(elapsed:1/120,motion:MotionSample(gravity:SIMD3(0.65,-0.76,0)))}
            for i in 0..<120 {
                let t=Float(i)/120
                simulation.advance(elapsed:1/120,motion:MotionSample(gravity:SIMD3(0,-1,0),acceleration:SIMD3(sin(t*24)*2.5,cos(t*17)*1.5,sin(t*13)*0.8)))
            }
        }
        if arg("--pose") == "shake" {
            for f in 0..<120 {
                let t=Float(f)/120
                simulation.advance(elapsed:1/120,motion:MotionSample(gravity:SIMD3(0,-1,0),acceleration:SIMD3(sin(t*18)*1.8,cos(t*14)*1.1,sin(t*10)*0.4)))
            }
        }
        let particleBuffer=device.makeBuffer(length:simulation.particles.count*16,options:.storageModeShared)!
        let bubbleBuffer=device.makeBuffer(length:36*16,options:.storageModeShared)!
        var writer:AVAssetWriter?,input:AVAssetWriterInput?,adaptor:AVAssetWriterInputPixelBufferAdaptor?
        if frames>1 {
            writer=try AVAssetWriter(outputURL:output.appendingPathComponent("motion.mp4"),fileType:.mp4)
            input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,
                AVVideoWidthKey:width,AVVideoHeightKey:height,
                AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:4_000_000]])
            adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input!,sourcePixelBufferAttributes:[
                kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,
                kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
            writer!.add(input!)
            guard writer!.startWriting() else {throw writer!.error!}
            writer!.startSession(atSourceTime:.zero)
        }
        var records=[[String:Any]]()
        for frame in 0..<frames {
            let t=Float(frame+startFrame)/30,m=motion(t),start=Date()
            if frames>1 {simulation.advance(elapsed:1/30,motion:m)}
            let cpuSeconds=Date().timeIntervalSince(start)
            let particles=particleBuffer.contents().bindMemory(to:SIMD4<Float>.self,capacity:simulation.particles.count)
            for (i,p) in simulation.particles.enumerated() {particles[i]=SIMD4(p.position,simulation.spacing*1.5)}
            let bubbles=bubbleBuffer.contents().bindMemory(to:SIMD4<Float>.self,capacity:36)
            for (i,b) in simulation.bubbles.prefix(36).enumerated() {bubbles[i]=SIMD4(b.position,b.radius)}
            var u=OceanUniforms()
            u.viewport=SIMD4(1,2.12,simulation.time,0)
            let b=simulation.boat
            u.boat=SIMD4(b.position.x,b.position.y,b.angle,b.position.z)
            u.movement=SIMD4(m.gravity,simulation.energy)
            u.color=SIMD4(Float(arg("--red") ?? "0.0001")!,Float(arg("--green") ?? "0.16")!,Float(arg("--blue") ?? "0.45")!,0)
            u.optics=SIMD4(Float(arg("--clear-index") ?? "1.46")!,Float(arg("--blue-index") ?? "1.333")!,Float(arg("--view-tilt") ?? "0.3")!,0)
            let command=queue.makeCommandBuffer()!
            var fieldSeconds:Double?=nil
            if CommandLine.arguments.contains("--profile") {
                let fieldCommand=queue.makeCommandBuffer()!
                try renderer.field.encode(commandBuffer:fieldCommand,particles:particleBuffer,
                    particleCount:simulation.particles.count,bubbles:bubbleBuffer,
                    bubbleCount:renderer.tracesAirBubbles ? 0 : min(36,simulation.bubbles.count))
                fieldCommand.commit();fieldCommand.waitUntilCompleted()
                if let error=fieldCommand.error {throw error}
                fieldSeconds=fieldCommand.gpuEndTime-fieldCommand.gpuStartTime
                try renderer.encodeTransport(command:command,target:target,diagnostics:diagnostics,uniforms:u,
                    bubbles:bubbleBuffer,bubbleCount:renderer.tracesAirBubbles ? min(36,simulation.bubbles.count) : 0)
            } else {
                try renderer.encode(command:command,target:target,diagnostics:diagnostics,
                    particles:particleBuffer,particleCount:simulation.particles.count,
                    bubbles:bubbleBuffer,bubbleCount:min(36,simulation.bubbles.count),uniforms:u)
            }
            command.commit();command.waitUntilCompleted()
            if let error=command.error {throw error}
            guard command.status == .completed else {throw OceanRendererError.unavailable("GPU incomplete")}
            var values=[UInt16](repeating:0,count:width*height*4)
            values.withUnsafeMutableBytes {diagnostics.getBytes($0.baseAddress!,bytesPerRow:width*8,
                from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)}
            if pathDiagnostics || boundaryDiagnostics {
                try values.withUnsafeBytes {Data($0)}.write(to:output.appendingPathComponent(String(format:(boundaryDiagnostics ? "boundaries-%03d.rgba16f":"paths-%03d.rgba16f"),frame)))
            }
            var errors=0,tailPixels=0,stepSum=0.0,tailSum=0.0,fluidSum=0.0
            for i in stride(from:0,to:values.count,by:4) {
                let steps=Double(Float16(bitPattern:values[i])),tail=Double(Float16(bitPattern:values[i+(boundaryDiagnostics ? 2:1)]))
                if boundaryDiagnostics {fluidSum+=Double(Float16(bitPattern:values[i+1]))}
                if Float16(bitPattern:values[i+3])>0 {errors+=1}
                if tail>0.05 {tailPixels+=1};stepSum+=steps*256;tailSum+=tail
            }
            let state:[String:Any]=["frame":frame,"time":simulation.time,
                "particles":simulation.particles.map {[$0.position.x,$0.position.y,$0.position.z]},
                "bubbles":simulation.bubbles.map {[$0.position.x,$0.position.y,$0.position.z,$0.radius]},
                "boat":[b.position.x,b.position.y,b.angle,b.position.z]]
            let stateData=try JSONSerialization.data(withJSONObject:state,options:.sortedKeys)
            var record:[String:Any]=["frame":frame,"seconds":t,"gpuSeconds":command.gpuEndTime-command.gpuStartTime,
                "simulationCPUSeconds":cpuSeconds,"numericErrors":errors,(pathDiagnostics ? "diagnosticTailLengthAbove005Pixels":"largeTailPixels"):tailPixels,
                "fieldGPUSeconds":fieldSeconds as Any? ?? NSNull(),
                (pathDiagnostics ? "meanBlueLength":(boundaryDiagnostics ? "meanShellBoundaryInteractions":"averageSteps")):stepSum/Double(width*height)/((pathDiagnostics||boundaryDiagnostics) ? 256:1),
                (pathDiagnostics ? "meanAssumedTailLength":"averageTail"):tailSum/Double(width*height),
                "stateSHA256":SHA256.hash(data:stateData).map {String(format:"%02x",$0)}.joined()]
            if boundaryDiagnostics {record["meanFluidBoundaryInteractions"]=fluidSum/Double(width*height)}
            records.append(record)
            if frame%30==0 || frame==frames-1 {
                try savePNG(target,output.appendingPathComponent(String(format:"frame-%03d.png",frame)))
                try stateData.write(to:output.appendingPathComponent(String(format:"state-%03d.json",frame)))
                print("frame \(frame) gpu \(String(format:"%0.1f",(command.gpuEndTime-command.gpuStartTime)*1000)) ms errors \(errors) tail>5% \(tailPixels)")
                fflush(stdout)
            }
            if let writer,let input,let adaptor {
                let deadline=Date().addingTimeInterval(10)
                while !input.isReadyForMoreMediaData {
                    guard writer.status != .failed,Date()<deadline else {throw writer.error ?? OceanRendererError.unavailable("Video timeout")}
                    Thread.sleep(forTimeInterval:0.002)
                }
                var optional:CVPixelBuffer?
                guard let pool=adaptor.pixelBufferPool,
                    CVPixelBufferPoolCreatePixelBuffer(nil,pool,&optional)==kCVReturnSuccess,let buffer=optional else {throw OceanRendererError.unavailable("Video buffer")}
                CVPixelBufferLockBaseAddress(buffer,[])
                target.getBytes(CVPixelBufferGetBaseAddress(buffer)!,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)
                CVPixelBufferUnlockBaseAddress(buffer,[])
                guard adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(frame),timescale:30)) else {throw writer.error!}
            }
        }
        if let writer,let input {
            input.markAsFinished();let done=DispatchSemaphore(value:0)
            writer.finishWriting {done.signal()}
            guard done.wait(timeout:.now()+30) == .success,writer.status == .completed else {throw writer.error ?? OceanRendererError.unavailable("Finish video")}
        }
        let evidencePaths=paths+["SmallWave/Core/LiquidSimulation.swift","SmallWave/Core/OceanStyle.swift",
            "SmallWave/Rendering/LiquidRenderer.swift","SmallWave/Rendering/LiquidVolumeField.swift",
            "SmallWave/Rendering/LiquidVolumeRenderer.swift","Tests/LiveVolumePreview.swift",CommandLine.arguments[0]]
            + (arg("--environment").map {[$0]} ?? []) + (arg("--texture-image").map {[$0]} ?? [])
        var inputHashes=[String:String]()
        for path in evidencePaths {inputHashes[path]=SHA256.hash(data:try Data(contentsOf:URL(fileURLWithPath:path))).map {String(format:"%02x",$0)}.joined()}
        let report:[String:Any]=["device":device.name,"resolution":[width,height],"frames":records,
            "arguments":Array(CommandLine.arguments.dropFirst()),"sourcePaths":paths,"inputHashes":inputHashes,
            "diagnosticChannels":pathDiagnostics ? ["actualBlueLength","assumedBlueTailLength","blueTIRCount","numericError"]:(boundaryDiagnostics ? ["shellBoundaryInteractions","fluidBoundaryInteractions","residualWeight","numericError"]:["samplesDiv256","residualWeight","boundariesDiv8","numericError"]),
            "compiledSourceSHA256":SHA256.hash(data:Data(source.utf8)).map {String(format:"%02x",$0)}.joined(),
            "liveField":true,"phonePerformanceVerified":false,"boundedTransportApproximation":true]
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("report.json"))
        print("Written \(output.path)")
    }
}
