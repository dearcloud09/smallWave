import Foundation
import MetalKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Same sensor input for both candidates; a GIF is a rendered test sequence,
/// not a recording from an iPhone or proof of real-time performance.
@main
struct MotionStudy {
    static let strongInput = ProcessInfo.processInfo.environment["SMALLWAVE_MOTION"] == "strong"
    static func main() {
        setbuf(stdout,nil)
        do { try run() } catch { fputs("FAIL motion study: \(error)\n",stderr); exit(1) }
    }
    static func input(_ t:Float) -> MotionSample {
        if t<2 {
            let angle=sin(t/2 * .pi)*0.85
            return MotionSample(gravity:SIMD3(sin(angle),-cos(angle),0))
        }
        if t<3.6 {
            let q=t-2
            if strongInput {
                return MotionSample(acceleration:SIMD3(sin(q*24)*2.5,cos(q*17)*1.5,sin(q*13)*0.8))
            }
            return MotionSample(acceleration:SIMD3(sin(q*18)*1.8,cos(q*14)*1.1,sin(q*10)*0.4))
        }
        return MotionSample()
    }
    static func run() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw OceanRendererError.unavailable("No Metal device") }
        let source=try String(contentsOfFile:"SmallWave/Rendering/LiquidShaders.metal",encoding:.utf8)
        let library=try device.makeLibrary(source:source,options:nil)
        let bubbleStudy=ProcessInfo.processInfo.environment["SMALLWAVE_BUBBLES"] == "1"
        let surfaceStudy=ProcessInfo.processInfo.environment["SMALLWAVE_SURFACE"] == "1"
        let materialStudy=surfaceStudy && ProcessInfo.processInfo.environment["SMALLWAVE_MATERIAL"] == "1"
        let baseline=try LiquidRenderer(device:device,library:library,cohesionStrength:(bubbleStudy||surfaceStudy) ? 18 : 0,interfaceBubbles:surfaceStudy,surfaceStudy:surfaceStudy)
        let candidate=try LiquidRenderer(device:device,library:library,cohesionStrength:18,interfaceBubbles:bubbleStudy||surfaceStudy,surfaceStudy:surfaceStudy)
        baseline.continuousSurface=materialStudy
        candidate.continuousSurface=surfaceStudy
        candidate.clearInterface=materialStudy
        let renderers=[baseline,candidate]
        let width=300,height=636
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
        descriptor.storageMode = .shared; descriptor.usage = .renderTarget
        let target=device.makeTexture(descriptor:descriptor)!
        let study=surfaceStudy ? ("continuous-surface" + (materialStudy ? "/clear-interface" : "")) : (bubbleStudy ? "interface-bubbles" : "cohesion")
        let folder=URL(fileURLWithPath: ".build-cache/previews/" + study + (strongInput ? "/strong-motion" : "/motion"))
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let gif=folder.appendingPathComponent("comparison.gif")
        let frames=90,fps:Float=15
        guard let destination=CGImageDestinationCreateWithURL(gif as CFURL,UTType.gif.identifier as CFString,frames,nil) else {
            throw OceanRendererError.unavailable("Cannot create GIF")
        }
        CGImageDestinationSetProperties(destination,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for renderer in renderers {
            for _ in 0..<420 { renderer.simulation.advance(elapsed:1/120,motion:MotionSample()) }
        }
        var metrics="frame,seconds,variant,cohesion,energy,center_x,center_y,single_particles,largest_component,components_2_to_8,bubbles,surface_bubbles\n"
        for frame in 0..<frames {
            let context=CGContext(data:nil,width:width*2,height:height+24,bitsPerComponent:8,bytesPerRow:width*8,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray:0.08,alpha:1)); context.fill(CGRect(x:0,y:0,width:width*2,height:height+24))
            for (side,renderer) in renderers.enumerated() {
                // 8 fixed 1/120 steps represent one 1/15 GIF frame. Passing
                // 1/15 to advance once would trigger its deliberate elapsed cap.
                for step in 0..<8 {
                    renderer.motion=input(Float(frame)/fps+Float(step)/120)
                    renderer.simulation.advance(elapsed:1/120,motion:renderer.motion)
                }
                try renderer.render(into:target,elapsed:0,waitForCompletion:true)
                let picture=readImage(target)
                context.draw(picture,in:CGRect(x:side*width,y:0,width:width,height:height))
                let label=side==0 ? (materialStudy ? "SHAPE ONLY" : "BASELINE") : (surfaceStudy ? (materialStudy ? "CLEAR EDGE" : "SURFACE STUDY") : (bubbleStudy ? "INTERFACE BUBBLES" : "COHESION STUDY"))
                context.setFillColor(CGColor(gray:1,alpha:1))
                context.setFont(CGFont("Helvetica" as CFString)!); context.setFontSize(11)
                let font=CTFontCreateWithName("Helvetica" as CFString,11,nil)
                let text=label.utf16.map{UniChar($0)}
                var glyphs=[CGGlyph](repeating:0,count:text.count)
                CTFontGetGlyphsForCharacters(font,text,&glyphs,text.count)
                var advances=[CGSize](repeating:.zero,count:text.count)
                CTFontGetAdvancesForGlyphs(font,.horizontal,glyphs,&advances,glyphs.count)
                var x=CGFloat(side*width+10)
                let positions=advances.map { size -> CGPoint in defer { x+=size.width }; return CGPoint(x:x,y:CGFloat(height+7)) }
                context.showGlyphs(glyphs,at:positions)
                if frame%6==0 || frame==frames-1 {
                    let stats=components(renderer.simulation)
                    let center=renderer.simulation.particles.reduce(SIMD3<Float>.zero){$0+$1.position}/Float(renderer.simulation.particles.count)
                    let near=renderer.simulation.bubbles.filter { (0.2...0.75).contains(renderer.simulation.density(at:$0.position)) }.count
                    metrics+="\(frame),\(Float(frame+1)/fps),\(side),\(renderer.simulation.cohesionStrength),\(renderer.simulation.energy),\(center.x),\(center.y),\(stats.0),\(stats.1),\(stats.2),\(renderer.simulation.bubbles.count),\(near)\n"
                }
            }
            let image=context.makeImage()!
            // GIF delays are centiseconds: 7/6/7 keeps 15 frames = one second.
            let delay=[0.07,0.06,0.07][frame%3]
            CGImageDestinationAddImage(destination,image,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:delay]] as CFDictionary)
            if [0,15,30,42,54,74,89].contains(frame) || (surfaceStudy && frame>=30 && frame<=60 && frame%3==0) {
                let url=folder.appendingPathComponent(String(format:"frame-%02d.png",frame))
                let png=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
                CGImageDestinationAddImage(png,image,nil)
                guard CGImageDestinationFinalize(png) else { throw OceanRendererError.unavailable("PNG write failed") }
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw OceanRendererError.unavailable("GIF write failed") }
        try metrics.write(to:folder.appendingPathComponent("metrics.csv"),atomically:true,encoding:.utf8)
        let decoded=CGImageSourceCreateWithURL(gif as CFURL,nil)!
        guard CGImageSourceGetCount(decoded)==frames else { throw OceanRendererError.unavailable("GIF frame count mismatch") }
        var duration=0.0
        for frame in 0..<frames {
            let properties=CGImageSourceCopyPropertiesAtIndex(decoded,frame,nil)! as NSDictionary
            let gifProperties=properties[kCGImagePropertyGIFDictionary] as! NSDictionary
            duration+=(gifProperties[kCGImagePropertyGIFDelayTime] as! NSNumber).doubleValue
        }
        guard abs(duration-6)<0.001 else { throw OceanRendererError.unavailable("GIF playback duration mismatch: \(duration)") }
        print("PASS 90-frame same-input comparison GIF (6 simulated seconds); \(gif.path)")
        print("Metrics use 3D connectivity radius 1.4×particle spacing; they are descriptive, not real-toy calibration.")
    }
    static func readImage(_ target:MTLTexture) -> CGImage {
        var bytes=[UInt8](repeating:0,count:target.width*target.height*4)
        bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow:target.width*4,
            from:MTLRegionMake2D(0,0,target.width,target.height),mipmapLevel:0) }
        return CGImage(width:target.width,height:target.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:target.width*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    }
    static func components(_ simulation:LiquidSimulation) -> (Int,Int,Int) {
        let points=simulation.particles.map(\.position)
        var parent=Array(points.indices)
        func root(_ i:Int)->Int { var p=i; while parent[p] != p { p=parent[p] }; return p }
        let threshold=pow(simulation.spacing*1.4,2)
        for i in points.indices {
            for j in 0..<i where simd_distance_squared(points[i],points[j])<threshold {
                let a=root(i),b=root(j); if a != b { parent[a]=b }
            }
        }
        var sizes:[Int:Int]=[:]
        for i in points.indices { sizes[root(i),default:0]+=1 }
        return (sizes.values.filter{$0==1}.count,sizes.values.max() ?? 0,sizes.values.filter{$0>=2&&$0<=8}.count)
    }
}
