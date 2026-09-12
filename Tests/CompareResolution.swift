import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

@main
struct CompareResolution {
    static func main() throws {
        let folder=URL(fileURLWithPath:".build-cache/previews/resolution")
        let sources=try ["coarse","fine"].map { name -> CGImageSource in
            guard let s=CGImageSourceCreateWithURL(folder.appendingPathComponent("\(name)/motion.gif") as CFURL,nil),
                  CGImageSourceGetCount(s)==150 else { throw NSError(domain:"ResolutionComparison",code:1) }
            return s
        }
        let url=folder.appendingPathComponent("comparison.gif")
        let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.gif.identifier as CFString,150,nil)!
        CGImageDestinationSetProperties(destination,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        for frame in 0..<150 {
            let context=CGContext(data:nil,width:600,height:660,bitsPerComponent:8,bytesPerRow:600*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray:0.08,alpha:1)); context.fill(CGRect(x:0,y:0,width:600,height:660))
            for side in 0...1 {
                let picture=CGImageSourceCreateImageAtIndex(sources[side],frame,nil)!
                context.draw(picture,in:CGRect(x:side*300,y:0,width:300,height:636))
                let label=side==0 ? "BASELINE 1200" : "RESOLUTION STUDY 9600"
                let font=CTFontCreateWithName("Helvetica" as CFString,11,nil)
                let attrs=[kCTFontAttributeName:font,kCTForegroundColorAttributeName:CGColor(gray:1,alpha:1)] as CFDictionary
                let string=CFAttributedStringCreate(nil,label as CFString,attrs)!
                context.textPosition=CGPoint(x:side*300+10,y:643)
                CTLineDraw(CTLineCreateWithAttributedString(string),context)
            }
            let image=context.makeImage()!
            let delay=[0.07,0.06,0.07][frame%3]
            CGImageDestinationAddImage(destination,image,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:delay]] as CFDictionary)
            if [0,15,30,36,42,48,54,60,74,89,104,119,134,149].contains(frame) {
                // Static review uses original PNG colors, not a palette-quantized
                // GIF frame. The GIF remains only a compact motion delivery.
                for (side,name) in ["coarse","fine"].enumerated() {
                    let raw=folder.appendingPathComponent(name).appendingPathComponent(String(format:"frame-%03d.png",frame))
                    let original=CGImageSourceCreateWithURL(raw as CFURL,nil)!
                    context.draw(CGImageSourceCreateImageAtIndex(original,0,nil)!,
                                 in:CGRect(x:side*300,y:0,width:300,height:636))
                }
                let path=folder.appendingPathComponent(String(format:"pair-%03d.png",frame))
                let png=CGImageDestinationCreateWithURL(path as CFURL,UTType.png.identifier as CFString,1,nil)!
                CGImageDestinationAddImage(png,context.makeImage()!,nil)
                guard CGImageDestinationFinalize(png) else { throw NSError(domain:"ResolutionComparison",code:2) }
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain:"ResolutionComparison",code:3) }
        let result=CGImageSourceCreateWithURL(url as CFURL,nil)!
        var duration=0.0
        for i in 0..<CGImageSourceGetCount(result) {
            let p=CGImageSourceCopyPropertiesAtIndex(result,i,nil)! as NSDictionary
            let g=p[kCGImagePropertyGIFDictionary] as! NSDictionary
            duration+=(g[kCGImagePropertyGIFDelayTime] as! NSNumber).doubleValue
        }
        guard CGImageSourceGetCount(result)==150 && abs(duration-10)<0.001 else {
            throw NSError(domain:"ResolutionComparison",code:4)
        }
        print("PASS: paired 150-frame, 10-second resolution GIF. GIF palette conversion is a delivery artifact, not a material measurement.")
    }
}
