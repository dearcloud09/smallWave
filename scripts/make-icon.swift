import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputPath = CommandLine.arguments.dropFirst().first ?? "SmallWave/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
let size = 1024

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                              space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Unable to create an sRGB bitmap context")
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func gradient(_ colors: [CGColor], from start: CGPoint, to end: CGPoint, in path: CGPath? = nil) {
    guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil) else { return }
    context.saveGState()
    if let path { context.addPath(path); context.clip() }
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

// Draw in the screen's top-left coordinate system. iOS applies the icon mask, so no rounded corners are drawn here.
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)

// Full-bleed opaque scene.
gradient([color(0.99, 0.965, 0.89), color(0.91, 0.88, 0.78)], from: CGPoint(x: 160, y: 0), to: CGPoint(x: 930, y: 610))

let wave = CGMutablePath()
wave.move(to: CGPoint(x: 0, y: 488))
wave.addCurve(to: CGPoint(x: 430, y: 452), control1: CGPoint(x: 156, y: 430), control2: CGPoint(x: 296, y: 548))
wave.addCurve(to: CGPoint(x: 1024, y: 500), control1: CGPoint(x: 640, y: 324), control2: CGPoint(x: 810, y: 602))
wave.addLine(to: CGPoint(x: 1024, y: 1024))
wave.addLine(to: CGPoint(x: 0, y: 1024))
wave.closeSubpath()
gradient([color(0.055, 0.44, 0.73), color(0.012, 0.15, 0.38)], from: CGPoint(x: 430, y: 400), to: CGPoint(x: 620, y: 1024), in: wave)

let crest = CGMutablePath()
crest.move(to: CGPoint(x: 0, y: 486))
crest.addCurve(to: CGPoint(x: 430, y: 450), control1: CGPoint(x: 156, y: 428), control2: CGPoint(x: 296, y: 546))
crest.addCurve(to: CGPoint(x: 1024, y: 498), control1: CGPoint(x: 640, y: 322), control2: CGPoint(x: 810, y: 600))
context.setStrokeColor(color(0.52, 0.83, 0.90, 0.60))
context.setLineWidth(18)
context.addPath(crest)
context.strokePath()

// A single, toy-like boat stays large enough to read at Home Screen size.
context.saveGState()
context.translateBy(x: 528, y: 496)

let hull = CGMutablePath()
hull.move(to: CGPoint(x: -202, y: 90))
hull.addCurve(to: CGPoint(x: -116, y: 160), control1: CGPoint(x: -164, y: 152), control2: CGPoint(x: -145, y: 165))
hull.addCurve(to: CGPoint(x: 147, y: 132), control1: CGPoint(x: -20, y: 178), control2: CGPoint(x: 110, y: 165))
hull.addCurve(to: CGPoint(x: 205, y: 84), control1: CGPoint(x: 176, y: 122), control2: CGPoint(x: 192, y: 104))
hull.closeSubpath()
gradient([color(1.0, 0.96, 0.83), color(0.73, 0.60, 0.38)], from: CGPoint(x: 0, y: 80), to: CGPoint(x: 0, y: 175), in: hull)
context.setStrokeColor(color(0.22, 0.19, 0.15, 0.55))
context.setLineWidth(10)
context.addPath(hull)
context.strokePath()

context.setStrokeColor(color(0.31, 0.25, 0.15))
context.setLineWidth(18)
context.move(to: CGPoint(x: -38, y: 92))
context.addLine(to: CGPoint(x: -38, y: -260))
context.strokePath()

let mainSail = CGMutablePath()
mainSail.move(to: CGPoint(x: -23, y: -240))
mainSail.addLine(to: CGPoint(x: -18, y: 68))
mainSail.addCurve(to: CGPoint(x: 177, y: 53), control1: CGPoint(x: 58, y: 63), control2: CGPoint(x: 128, y: 56))
mainSail.closeSubpath()
gradient([color(1.0, 0.985, 0.91), color(0.86, 0.82, 0.68)], from: CGPoint(x: -30, y: -220), to: CGPoint(x: 160, y: 72), in: mainSail)

let jib = CGMutablePath()
jib.move(to: CGPoint(x: -55, y: -154))
jib.addLine(to: CGPoint(x: -190, y: 71))
jib.addLine(to: CGPoint(x: -55, y: 65))
jib.closeSubpath()
gradient([color(0.97, 0.36, 0.22), color(0.65, 0.12, 0.10)], from: CGPoint(x: -130, y: -140), to: CGPoint(x: -130, y: 72), in: jib)

context.setStrokeColor(color(0.70, 0.64, 0.46, 0.75))
context.setLineWidth(7)
context.move(to: CGPoint(x: -15, y: -198))
context.addLine(to: CGPoint(x: 135, y: 54))
context.strokePath()

let pennant = CGMutablePath()
pennant.move(to: CGPoint(x: -38, y: -268))
pennant.addLine(to: CGPoint(x: 50, y: -238))
pennant.addLine(to: CGPoint(x: -38, y: -212))
pennant.closeSubpath()
context.setFillColor(color(0.89, 0.25, 0.14))
context.addPath(pennant)
context.fillPath()
context.restoreGState()

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Unable to create PNG destination")
}
CGImageDestinationAddImage(destination, image, [kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { fatalError("Unable to write PNG") }
print("Wrote opaque sRGB \(size)x\(size) PNG to \(outputPath)")
