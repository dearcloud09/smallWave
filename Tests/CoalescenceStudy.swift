import Foundation
import MetalKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Follow particle identities through one separation/reunion event. Graph
/// connectivity is a diagnostic; it is not a claim about real-liquid topology.
#if !RESOLUTION_STUDY
@main
#endif
struct CoalescenceStudy {
    static let fps = 30
    static let frameCount = 240
    struct State {
        var groups: [[Int]]
        var main: Set<Int>
        var positions: [SIMD3<Float>]
    }
    struct Variant {
        let simulation:LiquidSimulation
        let render:(MTLTexture,MotionSample) throws -> Void
    }
    static func input(_ t: Float) -> MotionSample {
        if t < 2 {
            let angle = sin(t / 2 * .pi) * 0.85
            return MotionSample(gravity: SIMD3(sin(angle), -cos(angle), 0))
        }
        if t < 3.6 {
            let q = t - 2
            return MotionSample(acceleration: SIMD3(sin(q * 24) * 2.5, cos(q * 17) * 1.5, sin(q * 13) * 0.8))
        }
        return MotionSample()
    }
    static func groups(_ points: [SIMD3<Float>], spacing: Float) -> [[Int]] {
        var parents = Array(points.indices)
        func root(_ n: Int) -> Int { var p=n; while parents[p] != p { p=parents[p] }; return p }
        let distance2 = pow(spacing * 1.4, 2)
        for i in points.indices {
            for j in 0..<i where simd_distance_squared(points[i],points[j]) < distance2 {
                let a=root(i), b=root(j)
                if a != b { parents[a]=b }
            }
        }
        var result: [Int:[Int]] = [:]
        for i in points.indices { result[root(i),default:[]].append(i) }
        return result.values.sorted { $0.count == $1.count ? $0[0] < $1[0] : $0.count > $1.count }
    }
    static func image(_ texture: MTLTexture) -> CGImage {
        var bytes = [UInt8](repeating:0,count:texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:texture.width * 4,
            from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0) }
        return CGImage(width:texture.width,height:texture.height,bitsPerComponent:8,bitsPerPixel:32,
            bytesPerRow:texture.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
            bitmapInfo:CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    }
    static func label(_ string: String, at point: CGPoint, in context: CGContext, size: CGFloat = 11) {
        let font = CTFontCreateWithName("Helvetica" as CFString,size,nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string:string,attributes:[
            NSAttributedString.Key(kCTFontAttributeName as String):font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:1,alpha:1)]))
        context.textPosition=point; CTLineDraw(line,context)
    }
    static func save(_ image:CGImage, to url:URL) throws {
        guard let d=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else {
            throw OceanRendererError.unavailable("Cannot open PNG destination")
        }
        CGImageDestinationAddImage(d,image,nil)
        guard CGImageDestinationFinalize(d) else { throw OceanRendererError.unavailable("Cannot finalize PNG") }
    }
    static func main() {
        setbuf(stdout,nil)
        do { try run() } catch { fputs("FAIL coalescence: \(error)\n",stderr); exit(1) }
    }
    static func run() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw OceanRendererError.unavailable("No Metal GPU") }
        var original=try String(contentsOfFile:"SmallWave/Rendering/LiquidShaders.metal",encoding:.utf8)
        let env=ProcessInfo.processInfo.environment
        if env["SMALLWAVE_DIAGNOSTIC_LINES"]=="1" {
            let anchor="if(u.color.w < 0.5) return color;"
            guard original.components(separatedBy:anchor).count==2 else { throw OceanRendererError.unavailable("Backdrop anchor changed") }
            original=original.replacingOccurrences(of:anchor,with:"""
            float a=1-smoothstep(0.004,0.011,abs(p.x-0.85-0.20*p.y)/sqrt(1.04));
            float b=1-smoothstep(0.004,0.011,abs(p.x+0.45+0.20*p.y)/sqrt(1.04));
            color=mix(color,float3(0.10,0.11,0.12),max(a,b));
            if(u.color.w < 0.5) return color;
            """)
        }
        let args=CommandLine.arguments
        let folder=URL(fileURLWithPath:args.count>2 ? args[2] : ".build-cache/previews/coalescence/baseline")
        let baseline=try LiquidRenderer(device:device,library:device.makeLibrary(source:original,options:nil))
        baseline.showsBubbles=false
        var renderers=[Variant(simulation:baseline.simulation,render:{ texture,motion in
            baseline.motion=motion
            try baseline.render(into:texture,elapsed:0,waitForCompletion:true)
        })]
        if args.count>1 {
            let extra=try String(contentsOfFile:args[1],encoding:.utf8)
            let source=original+"\n"+extra
            let library=try device.makeLibrary(source:source,options:nil)
            let environment=ProcessInfo.processInfo.environment
            if extra.contains("fragment float4 volumeRayOceanFragment(") {
                let candidate=try VolumeRayRenderer(device:device,library:library)
                candidate.opticalMode=Float(environment["SMALLWAVE_OPTICAL_MODE"] ?? "0") ?? 0
                candidate.displayPigment=environment["SMALLWAVE_DISPLAY_PIGMENT"]=="1"
                candidate.diagnostic=environment["SMALLWAVE_PATH_DIAGNOSTIC"]=="1"
                candidate.traceCounters=environment["SMALLWAVE_TRACE_COUNTERS"]=="1"
                candidate.tilted=environment["SMALLWAVE_OBLIQUE"]=="1"
                candidate.halfStep=environment["SMALLWAVE_HALF_STEP"]=="1"
                candidate.clearInclusions=environment["SMALLWAVE_CLEAR_INCLUSIONS"]=="1"
                candidate.antialias=environment["SMALLWAVE_ANTIALIAS"]=="1"
                candidate.secondaryTransport=environment["SMALLWAVE_SECONDARY_TRANSPORT"]=="1"
                candidate.smoothLighting=environment["SMALLWAVE_SMOOTH_LIGHTING"]=="1"
                renderers.append(Variant(simulation:candidate.simulation,render:{texture,motion in
                    try candidate.render(into:texture,motion:motion)
                }))
            } else {
                let candidate=try ContourVolumeRenderer(device:device,library:library)
                candidate.opticalMode=Float(environment["SMALLWAVE_OPTICAL_MODE"] ?? "0") ?? 0
                candidate.displayPigment=environment["SMALLWAVE_DISPLAY_PIGMENT"]=="1"
                candidate.diagnostic=environment["SMALLWAVE_PATH_DIAGNOSTIC"]=="1"
                renderers.append(Variant(simulation:candidate.simulation,render:{texture,motion in
                    try candidate.render(into:texture,motion:motion)
                }))
            }
        }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let keys=["SMALLWAVE_OPTICAL_MODE","SMALLWAVE_DISPLAY_PIGMENT","SMALLWAVE_PATH_DIAGNOSTIC",
                  "SMALLWAVE_OBLIQUE","SMALLWAVE_HALF_STEP","SMALLWAVE_CLEAR_INCLUSIONS","SMALLWAVE_DIAGNOSTIC_LINES","SMALLWAVE_TRACE_COUNTERS","SMALLWAVE_ANTIALIAS","SMALLWAVE_SECONDARY_TRANSPORT","SMALLWAVE_SMOOTH_LIGHTING"]
        let configuration=Dictionary(uniqueKeysWithValues:keys.map{($0,env[$0] ?? "0")})
        try JSONSerialization.data(withJSONObject:configuration,options:[.prettyPrinted,.sortedKeys])
            .write(to:folder.appendingPathComponent("configuration.json"))
        let width=300,height=636
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
        descriptor.storageMode = .shared; descriptor.usage = .renderTarget
        guard let texture=device.makeTexture(descriptor:descriptor) else { throw OceanRendererError.unavailable("No texture") }
        for renderer in renderers {
            // Isolate the blue liquid; bubble simulation remains identical.
            for _ in 0..<420 { renderer.simulation.advance(elapsed:1/120,motion:MotionSample()) }
        }
        var frames=[CGImage](), states=[State]()
        var failuresCSV="frame,magenta_pixels,unresolved_pixels,phase_mismatch_pixels\n", maximumMagenta=0
        var maximumUnresolved=0, maximumMismatch=0
        var countersCSV="frame,x,y,approx_travelled,approx_crossings,approx_tir\n"
        var csv="frame,seconds,particles,largest,second_largest,components,center_x,center_y,center_z\n"
        let began=Date()
        for frame in 0..<frameCount {
            let context=CGContext(data:nil,width:width*renderers.count,height:height+24,bitsPerComponent:8,
                bytesPerRow:width*renderers.count*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray:0.08,alpha:1)); context.fill(CGRect(x:0,y:0,width:context.width,height:context.height))
            for (side,renderer) in renderers.enumerated() {
                var motion=MotionSample()
                for sub in 0..<4 {
                    motion=input(Float(frame)/Float(fps)+Float(sub)/120)
                    renderer.simulation.advance(elapsed:1/120,motion:motion)
                }
                if side>0 {
                    guard renderer.simulation.particles.map(\.position)==baseline.simulation.particles.map(\.position),
                          renderer.simulation.boat.position==baseline.simulation.boat.position,
                          renderer.simulation.boat.angle==baseline.simulation.boat.angle,
                          renderer.simulation.bubbles.map({SIMD4($0.position,$0.radius)})==baseline.simulation.bubbles.map({SIMD4($0.position,$0.radius)}) else {
                        throw OceanRendererError.unavailable("Candidate changed physical trajectory")
                    }
                }
                try renderer.render(texture,motion)
                let picture=image(texture)
                if side>0 {
                    let data=picture.dataProvider!.data!, bytes=CFDataGetBytePtr(data)!
                    var count=0, unresolved=0, mismatch=0
                    for i in 0..<(width*height) {
                        if env["SMALLWAVE_TRACE_COUNTERS"]=="1" {
                            if bytes[i*4+3]>127 {
                                unresolved+=1
                                countersCSV+="\(frame),\(i%width),\(i/width),\(Float(bytes[i*4+2])/255*1.28),\(Float(bytes[i*4+1])/255*320),\(Float(bytes[i*4])/255*320)\n"
                            }
                        } else if env["SMALLWAVE_PATH_DIAGNOSTIC"]=="1" {
                            if bytes[i*4]>127 { unresolved+=1 }
                            if bytes[i*4+3]>127 { mismatch+=1 }
                        } else if bytes[i*4]==255 && bytes[i*4+1]==0 && bytes[i*4+2]==255 { count+=1 }
                    }
                    maximumMagenta=max(maximumMagenta,count)
                    maximumUnresolved=max(maximumUnresolved,unresolved); maximumMismatch=max(maximumMismatch,mismatch)
                    failuresCSV+="\(frame),\(count),\(unresolved),\(mismatch)\n"
                }
                context.draw(picture,in:CGRect(x:side*width,y:0,width:width,height:height))
                label(String(format:"%@  %.3fs",side==0 ? "CURRENT / LIQUID ONLY" : "OPTICAL STUDY",Double(frame+1)/Double(fps)),
                      at:CGPoint(x:side*width+8,y:height+7),in:context)
            }
            let positions=baseline.simulation.particles.map(\.position)
            guard positions.count==1200, positions.allSatisfy({p in
                p.x.isFinite && p.y.isFinite && p.z.isFinite && abs(p.x)<=1 && abs(p.y)<=2.12 && abs(p.z)<=0.18
            }) else { throw OceanRendererError.unavailable("Invalid particle state") }
            let components=groups(positions,spacing:baseline.simulation.spacing)
            states.append(State(groups:components,main:Set(components[0]),positions:positions))
            let center=positions.reduce(SIMD3<Float>.zero,+)/Float(positions.count)
            csv+="\(frame),\(Float(frame+1)/Float(fps)),\(positions.count),\(components[0].count),\(components.count>1 ? components[1].count : 0),\(components.count),\(center.x),\(center.y),\(center.z)\n"
            frames.append(context.makeImage()!)
        }
        // Choose the largest detached component during the forcing interval,
        // then follow these exact identities, including after it joins the body.
        let possible=(60..<120).filter { states[$0].groups.count>1 }
        guard let peak=possible.max(by:{states[$0].groups[1].count<states[$1].groups[1].count}) else {
            throw OceanRendererError.unavailable("No split event in this input; do not claim coalescence")
        }
        let tracked=Set(states[peak].groups[1])
        // Preserve evidence even when this input only detaches individual
        // particles. Such an event cannot establish macroscopic liquid breakup.
        let shares=states.map{Float(tracked.intersection($0.main).count)/Float(tracked.count)}
        let split=(0...peak).last(where: { shares[$0]>=0.9 }).map{$0+1} ?? 0
        let reunion=(peak..<frameCount-5).first { i in shares[i..<i+6].allSatisfy{$0>=0.9} }
        var event="frame,seconds,tracked_count,share_in_main,tracked_x,tracked_y,tracked_z\n"
        for (i,state) in states.enumerated() {
            let c=tracked.reduce(SIMD3<Float>.zero){$0+state.positions[$1]}/Float(tracked.count)
            event+="\(i),\(Double(i+1)/Double(fps)),\(tracked.count),\(shares[i]),\(c.x),\(c.y),\(c.z)\n"
        }
        let report="""
        Rendered 8 seconds at 30 sampled frames/second; physics 120 Hz.
        Baseline bubble drawing disabled. Candidate clear 3D inclusions: \(env["SMALLWAVE_CLEAR_INCLUSIONS"]=="1"). Bubble physics unchanged.
        Graph uses 3D neighbour distance 1.4 x spacing; diagnostic, not visible mask.
        Same particle identities, boat position/angle, bubble positions/radii across variants: PASS.
        Tracked identities: \(tracked.sorted())
        Last departure from >=90% in main before peak: frame \(split), t=\(Double(split+1)/Double(fps))
        Peak detached component: frame \(peak), count=\(tracked.count)
        Multi-particle breakup (>=4 diagnostic particles): \(tracked.count>=4 ? "OBSERVED" : "NOT OBSERVED")
        Return to >=90% in main for six frames: \(reunion.map{String($0)} ?? "NOT OBSERVED")
        Maximum explicit magenta error pixels in a candidate frame: \(maximumMagenta)
        Diagnostic mode maxima (only meaningful in diagnostic mode): unresolved=\(maximumUnresolved), phase mismatch=\(maximumMismatch)
        Read raw PNG for material; GIF palette may posterize gradients.
        Mac offscreen output, not iPhone performance or reference-toy calibration.
        """
        try report.write(to:folder.appendingPathComponent("event.txt"),atomically:true,encoding:.utf8)
        try csv.write(to:folder.appendingPathComponent("metrics.csv"),atomically:true,encoding:.utf8)
        try event.write(to:folder.appendingPathComponent("tracked-event.csv"),atomically:true,encoding:.utf8)
        try failuresCSV.write(to:folder.appendingPathComponent("ray-failures.csv"),atomically:true,encoding:.utf8)
        try countersCSV.write(to:folder.appendingPathComponent("trace-counters.csv"),atomically:true,encoding:.utf8)
        let start=max(0,split-8), end=min(frameCount-1,(reunion ?? peak+60)+36)
        var selected=Set([0,30,59,80,peak,239,start,end])
        for i in stride(from:start,through:end,by:2) { selected.insert(i) }
        if let reunion { for i in max(0,reunion-4)...min(frameCount-1,reunion+4) { selected.insert(i) } }
        for i in selected.sorted() { try save(frames[i],to:folder.appendingPathComponent(String(format:"frame-%03d.png",i))) }
        guard let gif=CGImageDestinationCreateWithURL(folder.appendingPathComponent("motion.gif") as CFURL,
            UTType.gif.identifier as CFString,frameCount,nil) else { throw OceanRendererError.unavailable("No GIF output") }
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for (i,frame) in frames.enumerated() {
            CGImageDestinationAddImage(gif,frame,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:[0.03,0.03,0.04][i%3]]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(gif) else { throw OceanRendererError.unavailable("GIF failed") }
        let decoded=CGImageSourceCreateWithURL(folder.appendingPathComponent("motion.gif") as CFURL,nil)!
        guard CGImageSourceGetCount(decoded)==frameCount else { throw OceanRendererError.unavailable("GIF lost frames") }
        var seconds=0.0
        for i in 0..<frameCount {
            let properties=CGImageSourceCopyPropertiesAtIndex(decoded,i,nil)! as NSDictionary
            let gp=properties[kCGImagePropertyGIFDictionary] as! NSDictionary
            seconds+=(gp[kCGImagePropertyGIFDelayTime] as! NSNumber).doubleValue
        }
        guard abs(seconds-8)<0.001 else { throw OceanRendererError.unavailable("GIF timing mismatch") }
        print(report)
        print("PASS 240 frames, 8 sec, finite/bounded particles, event evidence saved; harness wall time \(Date().timeIntervalSince(began)) sec")
        print(folder.path)
    }
}
