import Foundation
import MetalKit
import CryptoKit

@main
struct BubbleLensStudy {
    static func bytes(_ texture:MTLTexture) -> [UInt8] {
        var b=[UInt8](repeating:0,count:texture.width*texture.height*4)
        b.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:texture.width*4,
            from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0) }
        return b
    }
    static func main() throws {
        guard let device=MTLCreateSystemDefaultDevice() else { throw OceanRendererError.unavailable("No Metal") }
        let original=try String(contentsOfFile:"SmallWave/Rendering/LiquidShaders.metal",encoding:.utf8)
        let source=original+"\n"+(try String(contentsOfFile:"Studies/BubbleLens.metal",encoding:.utf8))
        let library=try device.makeLibrary(source:source,options:nil)
        let baseline=try LiquidRenderer(device:device,library:library)
        let candidate=try BubbleLensRenderer(device:device,library:library)
        let folder=URL(fileURLWithPath:".build-cache/previews/bubble-lens")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:600,height:1272,mipmapped:false)
        d.storageMode = .shared; d.usage=[.renderTarget,.shaderRead]
        guard let target=device.makeTexture(descriptor:d) else { throw OceanRendererError.unavailable("No target") }
        var report=[String](), outputHashes=[String:String]()
        func save(_ name:String) throws {
            let url=folder.appendingPathComponent(name+".png")
            try CoalescenceStudy.save(CoalescenceStudy.image(target),to:url)
            outputHashes[name+".png"]=SHA256.hash(data:try Data(contentsOf:url)).map { String(format:"%02x",$0) }.joined()
        }
        func advance(_ n:Int,_ input:(Int)->MotionSample) {
            for i in 0..<n {
                let m=input(i)
                baseline.simulation.advance(elapsed:1/120,motion:m)
                candidate.simulation.advance(elapsed:1/120,motion:m)
            }
        }
        func capture(_ name:String,_ motion:MotionSample) throws {
            guard baseline.simulation.particles.map(\.position)==candidate.simulation.particles.map(\.position),
                  baseline.simulation.boat.position==candidate.simulation.boat.position,
                  baseline.simulation.boat.angle==candidate.simulation.boat.angle,
                  baseline.simulation.bubbles.map({SIMD4($0.position,$0.radius)})==candidate.simulation.bubbles.map({SIMD4($0.position,$0.radius)}) else {
                throw OceanRendererError.unavailable("Study changed physical state")
            }
            baseline.motion=motion; baseline.showsBubbles=true
            try baseline.render(into:target,elapsed:0,waitForCompletion:true)
            try save(name+"-baseline")
            baseline.showsBubbles=false
            try baseline.render(into:target,elapsed:0,waitForCompletion:true)
            let bare=bytes(target)
            candidate.enabled=false
            try candidate.render(into:target,motion:motion)
            guard bytes(target)==bare else { throw OceanRendererError.unavailable("Disabled lens changed bare liquid") }
            candidate.enabled=true
            try candidate.render(into:target,motion:motion)
            let rendered=bytes(target)
            var outsideChanges=0,insideChanges=0
            for y in 0..<target.height { for x in 0..<target.width {
                let world=SIMD2((Float(x)+0.5)/Float(target.width)*2-1,
                    (1-(Float(y)+0.5)/Float(target.height)*2)*2.12)
                let inside=candidate.simulation.bubbles.contains { b in
                    abs(world.x-b.position.x)<=b.radius+0.01 && abs(world.y-b.position.y)<=b.radius+0.01
                }
                let i=(y*target.width+x)*4
                if rendered[i..<i+4] != bare[i..<i+4] {
                    if inside { insideChanges+=1 } else { outsideChanges+=1 }
                }
            }}
            guard outsideChanges==0 else { throw OceanRendererError.unavailable("Lens changed outside bubble bounds: \(outsideChanges)") }
            try save(name+"-candidate")
            report.append("PASS \(name): same physical state, disabled exact identity, outside pocket bounds unchanged; bubbles=\(candidate.simulation.bubbles.count), changed inside=\(insideChanges)")
        }
        advance(600) { _ in MotionSample() }
        try capture("rest",MotionSample())
        let tilted=MotionSample(gravity:SIMD3(0.65,-0.76,0))
        advance(220) { _ in tilted }
        try capture("tilt",tilted)
        var last=MotionSample()
        advance(120) { i in
            let t=Float(i)/120
            last=MotionSample(acceleration:SIMD3(sin(t*24)*2.5,cos(t*17)*1.5,sin(t*13)*0.8))
            return last
        }
        try capture("shake",last)
        advance(240) { _ in MotionSample(gravity:SIMD3(0,1,0)) }
        try capture("inverted",MotionSample(gravity:SIMD3(0,1,0)))
        advance(240) { _ in MotionSample(gravity:SIMD3(0,0,-1)) }
        try capture("flat",MotionSample(gravity:SIMD3(0,0,-1)))
        var inputs=[String:String]()
        for path in ["SmallWave/Core/LiquidSimulation.swift","SmallWave/Core/OceanStyle.swift","SmallWave/Rendering/LiquidRenderer.swift",
                     "SmallWave/Rendering/LiquidShaders.metal","Studies/BubbleLensRenderer.swift","Studies/BubbleLens.metal","Tests/BubbleLensStudy.swift"] {
            inputs[path]=SHA256.hash(data:try Data(contentsOf:URL(fileURLWithPath:path))).map { String(format:"%02x",$0) }.joined()
        }
        try source.write(to:folder.appendingPathComponent("shader-source.metal"),atomically:true,encoding:.utf8)
        let manifest:[String:Any]=["inputsSHA256":inputs,"outputsSHA256":outputHashes,"completedAt":ISO8601DateFormatter().string(from:Date()),"device":device.name]
        try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("provenance.json"),options:.atomic)
        report.append("Mac offscreen study. Screen-space approximation; depth/volume conservation and real-device performance not validated. No product adoption.")
        let text=report.joined(separator:"\n")
        try text.write(to:folder.appendingPathComponent("checks.txt"),atomically:true,encoding:.utf8)
        print(text)
        print(folder.path)
    }
}
