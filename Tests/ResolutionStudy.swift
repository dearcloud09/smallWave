import Foundation
import MetalKit
import ImageIO
import UniformTypeIdentifiers

/// A controlled resolution study, not an iPhone performance benchmark.
@main
struct ResolutionStudy {
    static func main() {
        setbuf(stdout,nil)
        do { try run() } catch { fputs("FAIL resolution study: \(error)\n",stderr); exit(1) }
    }
    static func input(_ t:Float) -> MotionSample {
        if t<2 {
            let angle=sin(t/2 * .pi)*0.85
            return MotionSample(gravity:SIMD3(sin(angle),-cos(angle),0))
        }
        if t<3.6 {
            let q=t-2
            return MotionSample(acceleration:SIMD3(sin(q*24)*2.5,cos(q*17)*1.5,sin(q*13)*0.8))
        }
        if t>=6 && t<7 { return MotionSample(gravity:SIMD3(1,0,0)) }
        if t>=7 && t<8 { return MotionSample(gravity:SIMD3(0,1,0)) }
        return MotionSample()
    }
    static func run() throws {
        let variant=ProcessInfo.processInfo.environment["SMALLWAVE_RESOLUTION"] ?? "coarse"
        guard ["coarse","fine"].contains(variant), let device=MTLCreateSystemDefaultDevice() else {
            throw OceanRendererError.unavailable("Invalid resolution variant or no Metal device")
        }
        let source=try String(contentsOfFile:".build-cache/resolution/\(variant)/LiquidShaders.metal",encoding:.utf8)
        let library=try device.makeLibrary(source:source,options:nil)
        let renderer=try LiquidRenderer(device:device,library:library)
        let simulation=renderer.simulation
        let count=simulation.particles.count
        let expected=variant=="fine" ? 9600 : 1200
        guard count==expected else { throw OceanRendererError.unavailable("Particle count mismatch \(count)") }
        let mass=Double(count)*pow(Double(simulation.spacing),3)
        let center=simulation.particles.reduce(SIMD3<Float>.zero){$0+$1.position}/Float(count)
        let initial="\(variant): particles=\(count), normalized mass=\(mass), center=\(center), step=\(simulation.fixedStep)"
        print(initial)
        let folder=URL(fileURLWithPath:".build-cache/previews/resolution/\(variant)")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try initial.write(to:folder.appendingPathComponent("initial.txt"),atomically:true,encoding:.utf8)
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:300,height:636,mipmapped:false)
        descriptor.storageMode = .shared; descriptor.usage = .renderTarget
        let target=device.makeTexture(descriptor:descriptor)!
        let start=Date()
        for _ in 0..<Int((3.5/simulation.fixedStep).rounded()) {
            simulation.advance(elapsed:simulation.fixedStep,motion:MotionSample())
        }
        let frames=150, stepsPerFrame=Int((1/(15*simulation.fixedStep)).rounded())
        var metrics="frame,seconds,particles,mass,center_x,center_y,center_z,energy,boat_y,immersion,bubbles,elapsed_wall_seconds\n"
        let movie=folder.appendingPathComponent("motion.gif")
        let destination=CGImageDestinationCreateWithURL(movie as CFURL,UTType.gif.identifier as CFString,frames,nil)!
        CGImageDestinationSetProperties(destination,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for frame in 0..<frames {
            for substep in 0..<stepsPerFrame {
                renderer.motion=input(Float(frame)/15+Float(substep)*simulation.fixedStep)
                simulation.advance(elapsed:simulation.fixedStep,motion:renderer.motion)
            }
            try renderer.render(into:target,elapsed:0,waitForCompletion:true)
            let image=readImage(target)
            CGImageDestinationAddImage(destination,image,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:[0.07,0.06,0.07][frame%3]]] as CFDictionary)
            if [0,15,30,36,42,48,54,60,74,89,104,119,134,149].contains(frame) {
                let png=CGImageDestinationCreateWithURL(folder.appendingPathComponent(String(format:"frame-%03d.png",frame)) as CFURL,UTType.png.identifier as CFString,1,nil)!
                CGImageDestinationAddImage(png,image,nil)
                guard CGImageDestinationFinalize(png) else { throw OceanRendererError.unavailable("PNG failed") }
                let c=simulation.particles.reduce(SIMD3<Float>.zero){$0+$1.position}/Float(count)
                metrics+="\(frame),\(Float(frame+1)/15),\(count),\(mass),\(c.x),\(c.y),\(c.z),\(simulation.energy),\(simulation.boat.position.y),\(simulation.boat.immersion),\(simulation.bubbles.count),\(Date().timeIntervalSince(start))\n"
                print("FRAME \(frame) center=\(c), immersion=\(simulation.boat.immersion), wall=\(Date().timeIntervalSince(start))s")
            }
            guard simulation.particles.count==count,
                  simulation.particles.allSatisfy({ p in
                    p.position.x.isFinite && p.position.y.isFinite && p.position.z.isFinite &&
                    abs(p.position.x)<=simulation.halfWidth && abs(p.position.y)<=simulation.halfHeight && abs(p.position.z)<=simulation.halfDepth
                  }), simulation.boat.position.y.isFinite else {
                throw OceanRendererError.unavailable("Non-finite state, count change or escaped particle")
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw OceanRendererError.unavailable("GIF failed") }
        try metrics.write(to:folder.appendingPathComponent("metrics.csv"),atomically:true,encoding:.utf8)
        let decoded=CGImageSourceCreateWithURL(movie as CFURL,nil)!
        var duration=0.0
        for frame in 0..<CGImageSourceGetCount(decoded) {
            let properties=CGImageSourceCopyPropertiesAtIndex(decoded,frame,nil)! as NSDictionary
            let g=properties[kCGImagePropertyGIFDictionary] as! NSDictionary
            duration+=(g[kCGImagePropertyGIFDelayTime] as! NSNumber).doubleValue
        }
        guard CGImageSourceGetCount(decoded)==150 && abs(duration-10)<0.001 else {
            throw OceanRendererError.unavailable("GIF count/duration mismatch")
        }
        print("PASS bounded 10-second tilt/shake/turn/invert/settle study: \(variant). Mac \(device.name), not iPhone FPS.")
    }
    static func readImage(_ texture:MTLTexture)->CGImage {
        var bytes=[UInt8](repeating:0,count:texture.width*texture.height*4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:texture.width*4,
            from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0) }
        return CGImage(width:texture.width,height:texture.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:texture.width*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    }
}
