import Foundation
import MetalKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

@main struct PoissonCapStudy {
    static let inputPaths=["SmallWave/Core/LiquidSimulation.swift","SmallWave/Core/OceanStyle.swift",
        "SmallWave/Rendering/LiquidRenderer.swift","SmallWave/Rendering/LiquidShaders.metal",
        "Studies/PoissonCap.swift","Studies/PoissonCap.metal","Studies/PoissonCap.md",
        "Tests/PoissonCapStudy.swift","scripts/study-poisson-cap.sh"]
    static func hash(_ data:Data)->String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func hashes() throws -> [String:String] {
        try Dictionary(uniqueKeysWithValues:inputPaths.map { ($0,try hash(Data(contentsOf:URL(fileURLWithPath:$0)))) })
    }
    static func state(_ sim:LiquidSimulation)->String {
        var d=Data()
        func scalar(_ f:Float) { var value=f.bitPattern.littleEndian; withUnsafeBytes(of:&value) { d.append(contentsOf:$0) } }
        func vector(_ p:SIMD3<Float>) { scalar(p.x); scalar(p.y); scalar(p.z) }
        for p in sim.particles { vector(p.position); vector(p.previous); vector(p.velocity) }
        for b in sim.bubbles { vector(b.position); vector(b.velocity); scalar(b.radius); scalar(b.life) }
        vector(sim.boat.position); vector(sim.boat.velocity); scalar(sim.boat.angle)
        scalar(sim.boat.angularVelocity); scalar(sim.boat.immersion); scalar(sim.time); scalar(sim.energy)
        scalar(Float(sim.steps))
        return hash(d)
    }
    static func bytes(_ t:MTLTexture)->[UInt8] {
        var b=[UInt8](repeating:0,count:t.width*t.height*4)
        b.withUnsafeMutableBytes { t.getBytes($0.baseAddress!,bytesPerRow:t.width*4,
            from:MTLRegionMake2D(0,0,t.width,t.height),mipmapLevel:0) }
        return b
    }
    static func picture(_ b:[UInt8],width:Int,height:Int)->CGImage {
        CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider:CGDataProvider(data:Data(b) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    }
    static func save(_ image:CGImage,_ url:URL) throws {
        guard let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else {
            throw OceanRendererError.unavailable("Cannot create cap PNG")
        }
        CGImageDestinationAddImage(dest,image,nil)
        guard CGImageDestinationFinalize(dest) else { throw OceanRendererError.unavailable("Cannot finalize cap PNG") }
    }
    static func pair(_ a:CGImage,_ b:CGImage,label:String)->CGImage {
        let width=a.width,height=a.height
        let c=CGContext(data:nil,width:width*2,height:height+24,bitsPerComponent:8,bytesPerRow:width*8,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(gray:0.08,alpha:1)); c.fill(CGRect(x:0,y:0,width:width*2,height:height+24))
        c.draw(a,in:CGRect(x:0,y:0,width:width,height:height)); c.draw(b,in:CGRect(x:width,y:0,width:width,height:height))
        let font=CTFontCreateWithName("Helvetica" as CFString,11,nil)
        for (i,text) in ["CURRENT  "+label,"CAP STUDY — NOT ADOPTED  "+label].enumerated() {
            let line=CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[
                NSAttributedString.Key(kCTFontAttributeName as String):font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:1,alpha:1)]))
            c.textPosition=CGPoint(x:i*width+6,y:height+7); CTLineDraw(line,c)
        }
        return c.makeImage()!
    }
    static func motion(_ t:Float)->MotionSample {
        if t<2 { let a=sin(t/2 * .pi)*0.85; return MotionSample(gravity:SIMD3(sin(a),-cos(a),0)) }
        if t<3.6 { let q=t-2; return MotionSample(acceleration:SIMD3(sin(q*24)*2.5,cos(q*17)*1.5,sin(q*13)*0.8)) }
        return MotionSample()
    }
    static func main() {
        setbuf(stdout,nil)
        do { try run() } catch { fputs("FAIL PoissonCap: \(error)\n",stderr); exit(1) }
    }
    static func run() throws {
        guard CommandLine.arguments.count==2 else { throw OceanRendererError.unavailable("Run folder required") }
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]), began=Date(), initialInputs=try hashes()
        let original=try String(contentsOfFile:"SmallWave/Rendering/LiquidShaders.metal",encoding:.utf8)
        let source=try PoissonCapSource.make(original:original,
            kernels:String(contentsOfFile:"Studies/PoissonCap.metal",encoding:.utf8))
        try original.write(to:folder.appendingPathComponent("baseline-shader.metal"),atomically:true,encoding:.utf8)
        try source.write(to:folder.appendingPathComponent("compiled-shader.metal"),atomically:true,encoding:.utf8)
        guard let device=MTLCreateSystemDefaultDevice() else { throw OceanRendererError.unavailable("No Metal device") }
        let baseline=try LiquidRenderer(device:device,library:device.makeLibrary(source:original,options:nil))
        let cap=try PoissonCapRenderer(device:device,library:device.makeLibrary(source:source,options:nil))
        let sim=baseline.simulation
        func texture(_ w:Int,_ h:Int) throws -> MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:w,height:h,mipmapped:false)
            d.storageMode = .shared; d.usage=[.renderTarget,.shaderRead]
            guard let t=device.makeTexture(descriptor:d) else { throw OceanRendererError.unavailable("No target") }
            return t
        }
        let target=try texture(600,1272), small=try texture(300,636)
        var checks=[String](), csv="frame,seconds,state_sha256,mask_changed_pixels,outside_changed_pixels,cap_min,cap_max,last_height_delta\n"
        var maxMaskChange=0,maxOutsideChange=0,maxMagenta=0
        func capture(_ name:String,_ input:MotionSample,_ output:MTLTexture,savePair:Bool) throws -> CGImage {
            let before=state(sim)
            baseline.motion=input
            try baseline.render(into:output,elapsed:0,waitForCompletion:true)
            let a=bytes(output)
            try cap.render(into:output,simulation:sim,motion:input,mode:.baseline)
            guard bytes(output)==a else { throw OceanRendererError.unavailable("Baseline wrapper mismatch \(name)") }
            try cap.render(into:output,simulation:sim,motion:input,mode:.candidate)
            let b=bytes(output), metrics=cap.capMetrics()
            let pA=picture(a,width:output.width,height:output.height), pB=picture(b,width:output.width,height:output.height)
            try cap.render(into:output,simulation:sim,motion:input,mode:.baselineMask,showsBubbles:false)
            let maskA=bytes(output)
            try cap.render(into:output,simulation:sim,motion:input,mode:.candidateMask,showsBubbles:false)
            let maskB=bytes(output)
            var maskChange=0,outsideChange=0,magenta=0
            for i in 0..<(output.width*output.height) {
                if maskA[i*4] != maskB[i*4] { maskChange+=1 }
                if maskA[i*4]==0 && a[i*4..<i*4+4] != b[i*4..<i*4+4] { outsideChange+=1 }
                if b[i*4]==255 && b[i*4+1]==0 && b[i*4+2]==255 { magenta+=1 }
            }
            maxMaskChange=max(maxMaskChange,maskChange); maxOutsideChange=max(maxOutsideChange,outsideChange); maxMagenta=max(maxMagenta,magenta)
            guard before==state(sim),maskChange==0,magenta==0,
                  metrics.finite,metrics.minimum>=0,metrics.maximum<=0.01440001 else {
                throw OceanRendererError.unavailable("State/mask/cap veto \(name): masks=\(maskChange), cap=\(metrics)")
            }
            // At quantized-zero coverage, a sub-1/255 original coverage can still
            // round the final color differently. Count rather than mislabel this as exact outside equality.
            csv+="\(name),\(sim.time),\(before),\(maskChange),\(outsideChange),\(metrics.minimum),\(metrics.maximum),\(metrics.lastHeightDelta)\n"
            if savePair {
                try save(pA,folder.appendingPathComponent(name+"-baseline.png"))
                try save(pB,folder.appendingPathComponent(name+"-candidate.png"))
                try save(picture(maskA,width:output.width,height:output.height),folder.appendingPathComponent(name+"-coverage.png"))
                try save(pair(pA,pB,label:name),folder.appendingPathComponent(name+"-comparison.png"))
            }
            return pair(pA,pB,label:name)
        }
        for _ in 0..<600 { sim.advance(elapsed:1/120,motion:MotionSample()) }
        _=try capture("rest",MotionSample(),target,savePair:true)
        let tilt=MotionSample(gravity:SIMD3(0.65,-0.76,0))
        for _ in 0..<220 { sim.advance(elapsed:1/120,motion:tilt) }
        _=try capture("tilt",tilt,target,savePair:true)
        var shake=MotionSample()
        for i in 0..<120 {
            let t=Float(i)/120
            shake=MotionSample(acceleration:SIMD3(sin(t*24)*2.5,cos(t*17)*1.5,sin(t*13)*0.8))
            sim.advance(elapsed:1/120,motion:shake)
        }
        _=try capture("shake",shake,target,savePair:true)
        print("PASS three 600×1272 same-state static pairs; baseline wrapper identity and exact coverage")
        sim.reset()
        for _ in 0..<420 { sim.advance(elapsed:1/120,motion:MotionSample()) }
        let gifURL=folder.appendingPathComponent("motion.gif")
        guard let gif=CGImageDestinationCreateWithURL(gifURL as CFURL,UTType.gif.identifier as CFString,240,nil) else {
            throw OceanRendererError.unavailable("No motion destination")
        }
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for frame in 0..<240 {
            var input=MotionSample()
            for sub in 0..<4 { input=motion(Float(frame)/30+Float(sub)/120); sim.advance(elapsed:1/120,motion:input) }
            let name=String(format:"frame-%03d",frame)
            let p=try capture(name,input,small,savePair:[0,60,80,116,150,239].contains(frame))
            // GIF stores centiseconds. Alternate 3/3/4 cs so 240 frames really
            // play for 8 seconds instead of silently truncating to 7.2 seconds.
            let delay=frame%3==2 ? 0.04 : 0.03
            CGImageDestinationAddImage(gif,p,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:delay]] as CFDictionary)
            if frame%30==0 { print("Motion \(frame)/240; same-state/mask PASS") }
        }
        guard CGImageDestinationFinalize(gif),let gifRead=CGImageSourceCreateWithURL(gifURL as CFURL,nil),
              CGImageSourceGetCount(gifRead)==240 else { throw OceanRendererError.unavailable("Incomplete GIF") }
        var gifSeconds=0.0
        for frame in 0..<240 {
            guard let properties=CGImageSourceCopyPropertiesAtIndex(gifRead,frame,nil) as? [String:Any],
                  let gifProperties=properties[kCGImagePropertyGIFDictionary as String] as? [String:Any],
                  let delay=gifProperties[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
                    ?? gifProperties[kCGImagePropertyGIFDelayTime as String] as? Double else {
                throw OceanRendererError.unavailable("GIF delay metadata missing")
            }
            gifSeconds+=delay
        }
        guard abs(gifSeconds-8)<1e-6 else { throw OceanRendererError.unavailable("GIF duration \(gifSeconds)") }
        guard try hashes()==initialInputs else { throw OceanRendererError.unavailable("Input changed during rendering") }
        checks.append("PASS original renderer / wrapper byte identity at all 243 states")
        checks.append("PASS physical state SHA unchanged across every render; original simulation advanced only by harness")
        checks.append("PASS baseline/candidate coverage byte identity at all 243 states; max changed pixels=\(maxMaskChange)")
        checks.append("MEASURE quantized-zero-coverage changed pixels max=\(maxOutsideChange); exact geometric coverage formula unchanged")
        checks.append("PASS inferred q range [0,H²], magenta pixels max=\(maxMagenta); last-iteration height deltas in metrics.csv")
        checks.append("PASS three normal-size pairs and 240-frame 8-second GIF; 120 Hz physics, 30 Hz sampling")
        checks.append("NOT_RUN physical liquid volume recovery, exact optics, iPhone performance, real-toy split/merge comparison, adoption")
        checks.append("LIMIT this is screened Poisson inferred depth plus original absorption/scatter and one-interface refraction; not conserved 3D volume")
        checks.append("Source frozen from compile via script input hash comparison; completed checks in \(Date().timeIntervalSince(began)) seconds")
        try csv.write(to:folder.appendingPathComponent("metrics.csv"),atomically:true,encoding:.utf8)
        try checks.joined(separator:"\n").write(to:folder.appendingPathComponent("checks.txt"),atomically:true,encoding:.utf8)
        var outputs=[String:String]()
        for url in try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil) where url.lastPathComponent != "provenance.json" {
            if ["png","gif","csv","metal","txt"].contains(url.pathExtension) { outputs[url.lastPathComponent]=try hash(Data(contentsOf:url)) }
        }
        let manifest:[String:Any]=["inputsSHA256":initialInputs,"outputsSHA256":outputs,
            "executableSHA256":try hash(Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[0]))),
            "compiledShaderSHA256":hash(Data(source.utf8)),"baselineShaderSHA256":hash(Data(original.utf8)),
            "beganAt":ISO8601DateFormatter().string(from:began),"completedAt":ISO8601DateFormatter().string(from:Date()),
            "device":device.name,"capHalfDepth":0.12,"jacobiIterations":PoissonCapRenderer.iterations,
            "normalSize":[600,1272],"motionSizePerVariant":[300,636],"motionFrames":240,"motionSeconds":8,"encodedGIFSeconds":gifSeconds,
            "adopted":false,"silhouetteChanged":false,"inferred3DVolumeChanged":true]
        try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys])
            .write(to:folder.appendingPathComponent("provenance.json"),options:.atomic)
        print(checks.joined(separator:"\n")); print(folder.path)
    }
}
