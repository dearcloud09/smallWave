import Foundation
import MetalKit
import CoreGraphics

/// Same particle states, same optics; isolate output pixels from field voxels.
@main
struct OpticalResolutionStudy {
    static func main() {
        do { try run() } catch { fputs("FAIL resolution study: \(error)\n",stderr); exit(1) }
    }
    static func run() throws {
        setbuf(stdout,nil)
        guard let device=MTLCreateSystemDefaultDevice() else { throw OceanRendererError.unavailable("No GPU") }
        let env=ProcessInfo.processInfo.environment
        let cubic=env["SMALLWAVE_CUBIC_FIELD"]=="1"
        let source=try String(contentsOfFile:"SmallWave/Rendering/LiquidShaders.metal",encoding:.utf8)+"\n#define VR_CUBIC_FIELD \(cubic ? 1:0)\n"+String(contentsOfFile:"Studies/VolumeRay.metal",encoding:.utf8)
        let library=try device.makeLibrary(source:source,options:nil)
        let fragment=env["SMALLWAVE_WALL_DIAGNOSTIC"]=="1" ? "volumeWallDiagnostic":"volumeRayOceanFragment"
        let calibration=env["SMALLWAVE_CALIBRATION"]=="1"
        let normal=try VolumeRayRenderer(device:device,library:library,displayFragment:fragment,calibration:calibration)
        let fine=try VolumeRayRenderer(device:device,library:library,volumeScale:2,displayFragment:fragment,calibration:calibration)
        for renderer in [normal,fine] {
            renderer.clearInclusions=true; renderer.antialias=true
            renderer.tileRows=cubic ? 64:0
            renderer.tilted=env["SMALLWAVE_OBLIQUE"]=="1"
            renderer.studioLighting=env["SMALLWAVE_STUDIO_LIGHTING"]=="1"
            renderer.smoothLighting=env["SMALLWAVE_SMOOTH_LIGHTING"]=="1"
            renderer.mirrorDepthBoundary=env["SMALLWAVE_MIRROR_DEPTH"]=="1"
            renderer.contrastLighting=env["SMALLWAVE_CONTRAST_LIGHTING"]=="1"
            if env["SMALLWAVE_VIVID_BLUE"]=="1" { renderer.waterColor=SIMD3(0.001,0.20,0.98) }
            for _ in 0..<420 { renderer.simulation.advance(elapsed:1/120,motion:MotionSample()) }
        }
        func texture(_ width:Int) throws -> MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:width*212/100,mipmapped:false)
            d.storageMode = .shared; d.usage = .renderTarget
            guard let t=device.makeTexture(descriptor:d) else { throw OceanRendererError.unavailable("No target") }; return t
        }
        let previewWidth=env["SMALLWAVE_TINY_CHECK"]=="1" ? 60:300
        let low=try texture(previewWidth), high=try texture(1200)
        let folder=URL(fileURLWithPath:CommandLine.arguments.count>1 ? CommandLine.arguments[1]:".build-cache/previews/optical-resolution")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var report="Same physical particles/boat/bubbles. 4 optical samples per output pixel. PNG sRGB, no GIF.\n"
        report+="Display fragment: \(fragment). Diagnostic occupancy colors are not optical error colors.\n"
        report+="Depth mirror support: \(normal.mirrorDepthBoundary). This changes reconstructed phase volume, not particle mass.\n"
        report+="Static analytic wave and 8 clear inclusions: \(calibration). When true, physics is not rendered; this is an optical calibration fixture, not the app.\n"
        report+="Contrasting HDR reflection environment: \(normal.contrastLighting). Transmitted backdrop unchanged unless Studio lighting is explicitly true.\n"
        report+="Cubic scalar field: \(cubic). Oblique view: \(normal.tilted). Studio lighting: \(normal.studioLighting). Smooth lighting: \(normal.smoothLighting). Linear reference transmission: \(normal.waterColor).\n"
        try source.write(to:folder.appendingPathComponent("shader-source.metal"),atomically:true,encoding:.utf8)
        for frame in 0..<240 {
            var motion=MotionSample()
            for sub in 0..<4 {
                motion=CoalescenceStudy.input(Float(frame)/30+Float(sub)/120)
                for renderer in [normal,fine] { renderer.simulation.advance(elapsed:1/120,motion:motion) }
            }
            guard normal.simulation.particles.map(\.position)==fine.simulation.particles.map(\.position),
                  normal.simulation.boat.position==fine.simulation.boat.position,
                  normal.simulation.boat.angle==fine.simulation.boat.angle,
                  normal.simulation.bubbles.map({SIMD4($0.position,$0.radius)})==fine.simulation.bubbles.map({SIMD4($0.position,$0.radius)}) else {
                throw OceanRendererError.unavailable("State mismatch")
            }
            if !(calibration ? [80]:[80,128,239]).contains(frame) { continue }
            let variants=env["SMALLWAVE_PREVIEW_ONLY"]=="1" ? [("preview",normal,low)] : [("preview",normal,low),("native",normal,high),("fine-volume",fine,high)]
            for (name,renderer,target) in variants {
                try renderer.render(into:target,motion:motion)
                let picture=CoalescenceStudy.image(target)
                try CoalescenceStudy.save(picture,to:folder.appendingPathComponent(String(format:"%@-%03d.png",name,frame)))
                let data=picture.dataProvider!.data!, bytes=CFDataGetBytePtr(data)!
                let errors=fragment=="volumeWallDiagnostic" ? 0:(0..<(target.width*target.height)).filter { i in bytes[i*4]==255 && bytes[i*4+1]==0 && bytes[i*4+2]==255 }.count
                let line="frame \(frame), \(name), \(target.width)x\(target.height), magenta errors \(errors)"
                print(line); report+=line+"\n"
            }
        }
        try report.write(to:folder.appendingPathComponent("report.txt"),atomically:true,encoding:.utf8)
        print("PASS identical simulated states at all 240 frames; saved \((calibration ? 1:3)*(env["SMALLWAVE_PREVIEW_ONLY"]=="1" ? 1:3)) direct PNG renders. Calibration=\(calibration)")
    }
}
