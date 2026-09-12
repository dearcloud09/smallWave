import Foundation
import MetalKit
import ImageIO
import simd

@main
struct SurfaceCheck {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw OceanRendererError.unavailable(message) }
    }
    static func main() throws {
        let spacing: Float = 0.098, radius = spacing*1.5
        var particles: [LiquidParticle] = []
        for z in -1...1 { for y in -6...0 { for x in -7...7 {
            let p = SIMD3<Float>(Float(x)*spacing,Float(y)*spacing,Float(z)*spacing)
            particles.append(LiquidParticle(position:p,previous:p))
        } } }
        let lone = SIMD3<Float>(0.8,1.6,0)
        particles.append(LiquidParticle(position:lone,previous:lone))
        let original = particles.map(\.position)
        let kernels = SurfaceReconstruction.kernels(for:particles,spacing:spacing,halfSize:SIMD2(1,2.12))
        try require(kernels.count == particles.count && original == particles.map(\.position), "surface reconstruction changed particle state")
        var elongated = 0
        for (i,k) in kernels.enumerated() {
            let a=SIMD2(k.axes.x,k.axes.y), b=SIMD2(k.axes.z,k.axes.w)
            try require(abs(a.x*b.y-a.y*b.x-radius*radius)<0.000001,"ellipse did not preserve footprint area")
            try require(abs(simd_dot(a,b))<0.000001,"ellipse axes are not orthogonal")
            try require(simd_length(a)/simd_length(b)<=2.00001,"ellipse exceeded aspect ratio bound")
            try require(SIMD3(k.center.x,k.center.y,k.center.z)==original[i],"kernel center moved")
            if simd_length(a)>radius*1.05 { elongated += 1 }
        }
        try require(elongated>0,"fixture did not exercise anisotropy")
        try require(kernels.last!.axes == SIMD4(radius,0,0,radius),"isolated drop did not retain a circular footprint")
        let turned = particles.map { particle -> LiquidParticle in
            let p=SIMD3(-particle.position.y,particle.position.x,particle.position.z)
            return LiquidParticle(position:p,previous:p)
        }
        let rotated=SurfaceReconstruction.kernels(for:turned,spacing:spacing,halfSize:SIMD2(2.12,1))
        func covariance(_ k:SurfaceKernel)->SIMD3<Float> {
            SIMD3(k.axes.x*k.axes.x+k.axes.z*k.axes.z,
                  k.axes.x*k.axes.y+k.axes.z*k.axes.w,
                  k.axes.y*k.axes.y+k.axes.w*k.axes.w)
        }
        for i in kernels.indices {
            let c=covariance(kernels[i]), r=covariance(rotated[i])
            try require(simd_length(r-SIMD3(c.z,-c.y,c.x))<0.000001,"kernel geometry changed under a quarter turn")
        }
        print("PASS: kernel area, center/state preservation, axis ratio, sparse-drop fallback and physical quarter-turn covariance")
        print("Mask statistics below are diagnostics, not visual acceptance or real-toy calibration.")
        for name in ["rest","tilt","shake","inverted","flat"] {
            let before=try stats(".build-cache/previews/mask/\(name).png")
            let after=try stats(".build-cache/previews/continuous-surface/mask/\(name).png")
            let change=Double(after.0-before.0)/Double(max(1,before.0))
            try require(abs(change)<0.03,"projected area changed more than 3% in \(name)")
            print("MASK \(name): area change=\(change), components >=40px \(before.1) -> \(after.1), largest \(before.2) -> \(after.2)")
        }
    }
    static func stats(_ path:String) throws -> (Int,Int,Int) {
        guard let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil),
              let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {
            throw OceanRendererError.unavailable("Missing mask: \(path)")
        }
        let width=image.width, height=image.height
        var bytes=[UInt8](repeating:0,count:width*height*4)
        bytes.withUnsafeMutableBytes { data in
            let context=CGContext(data:data.baseAddress,width:width,height:height,bitsPerComponent:8,
                bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
        }
        var occupied=(0..<width*height).map { bytes[$0*4] >= 128 }
        let area=occupied.filter{$0}.count
        var sizes:[Int]=[]
        for start in occupied.indices where occupied[start] {
            var queue=[start], head=0
            occupied[start]=false
            while head<queue.count {
                let index=queue[head]; head+=1
                let x=index%width,y=index/width
                for (nx,ny) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] where nx>=0 && nx<width && ny>=0 && ny<height {
                    let j=ny*width+nx
                    if occupied[j] { occupied[j]=false; queue.append(j) }
                }
            }
            sizes.append(queue.count)
        }
        return (area,sizes.filter{$0>=40}.count,sizes.max() ?? 0)
    }
}
