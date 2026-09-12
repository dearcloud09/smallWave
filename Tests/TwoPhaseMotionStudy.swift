import AVFoundation
import CoreGraphics
import CoreText
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Internal CPU phase-motion study. It is not an iPhone render or a material model.
@main
struct TwoPhaseMotionStudy {
    typealias Simulation = TwoPhaseSimulation
    static let dt = 1.0 / 240.0
    static let totalSteps = 8 * 240
    static let width = 600
    static let height = 1200
    static let snapshotSteps: [Int] = [0, 360, 720, 1080, 1440, 1920]
    static var output = URL(fileURLWithPath: ".build-cache/previews/two-phase-motion")
    static var rows = ["time,centroid_x,centroid_y,interface_width,minimum,maximum,mass_over_domain,dt_max_divergence,wall_flux,courant"]
    static var checks = [String]()
    static var appendedFrames = 0

    static func seed(_ simulation: Simulation) throws {
        try simulation.setPhase { _, y in
            var amount = 0.0
            for j in 0..<4 { for _ in 0..<4 {
                if y + (Double(j) + 0.5 - 2) * simulation.dy / 4 < 0.85 { amount += 1.0 / 16 }
            }}
            return amount
        }
    }
    static func gravity(at time: Double) -> Simulation.Vector {
        if time < 1 { return .init(x:0,y:-3) }
        if time < 2 {
            let s = time - 1, smooth = s*s*(3 - 2*s), angle = 0.75*smooth
            return .init(x:3*sin(angle),y:-3*cos(angle))
        }
        if time < 3 { return .init(x:3*sin(0.75),y:-3*cos(0.75)) }
        if time < 5 { return .init(x:2*cos(4 * .pi * (time - 3)),y:-2) }
        return .init(x:0,y:-3)
    }
    static func violation(_ simulation: Simulation, initialAmount: Double, projection: Simulation.Projection) -> String? {
        let metrics = simulation.metrics()
        let mass = abs(metrics.amount-initialAmount)/(simulation.width*simulation.height)
        let courant = simulation.outgoingCourant(dt:dt)
        if mass > 1e-9 { return "mass/domain veto: \(mass)" }
        if metrics.minimum < -1e-12 || metrics.maximum > 1+1e-12 { return "range veto: [\(metrics.minimum), \(metrics.maximum)]" }
        if projection.scaledDivergence > 1e-6 { return "dt divergence veto: \(projection.scaledDivergence)" }
        if simulation.wallFluxInfinity() != 0 { return "wall flux veto: \(simulation.wallFluxInfinity())" }
        if courant > 0.45 { return "CFL veto: \(courant)" }
        return nil
    }
    static func record(_ simulation: Simulation, initialAmount: Double, projection: Simulation.Projection) {
        let metrics = simulation.metrics(), mass = abs(metrics.amount-initialAmount)/(simulation.width*simulation.height)
        rows.append("\(simulation.time),\(metrics.centroid.x),\(metrics.centroid.y),\(metrics.interfaceWidth),\(metrics.minimum),\(metrics.maximum),\(mass),\(projection.scaledDivergence),\(simulation.wallFluxInfinity()),\(simulation.outgoingCourant(dt:dt))")
    }
    static func drawLabel(_ text: String, context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string:text, attributes:[kCTFontAttributeName as NSAttributedString.Key:font,
                                                                                                  kCTForegroundColorFromContextAttributeName as NSAttributedString.Key:true]))
        context.saveGState()
        context.setFillColor(CGColor(gray:0,alpha:0.82))
        context.fill(CGRect(x:0,y:0,width:width,height:34))
        context.setFillColor(CGColor(gray:1,alpha:1))
        context.textPosition = CGPoint(x:12,y:8)
        CTLineDraw(line,context)
        context.restoreGState()
    }
    static func image(_ simulation: Simulation) throws -> CGImage {
        guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                                      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Simulation.Failure.invalid("Cannot create phase image")
        }
        let cellW = CGFloat(width) / CGFloat(simulation.nx), cellH = CGFloat(height) / CGFloat(simulation.ny)
        let clear = (r:CGFloat(0.92),g:CGFloat(0.96),b:CGFloat(0.98))
        let blue = (r:CGFloat(0.04),g:CGFloat(0.29),b:CGFloat(0.72))
        for j in 0..<simulation.ny { for i in 0..<simulation.nx {
            let c = CGFloat(simulation.phase[i+simulation.nx*j])
            context.setFillColor(CGColor(srgbRed:clear.r+(blue.r-clear.r)*c,green:clear.g+(blue.g-clear.g)*c,
                                         blue:clear.b+(blue.b-clear.b)*c,alpha:1))
            context.fill(CGRect(x:CGFloat(i)*cellW,y:CGFloat(j)*cellH,width:cellW+0.5,height:cellH+0.5))
        }}
        context.setStrokeColor(CGColor(srgbRed:0.05,green:0.05,blue:0.08,alpha:0.8)); context.setLineWidth(1)
        for j in 0..<simulation.ny { for i in 0..<simulation.nx {
            let c = simulation.phase[i+simulation.nx*j], right = i+1 < simulation.nx ? simulation.phase[i+1+simulation.nx*j] : c
            let top = j+1 < simulation.ny ? simulation.phase[i+simulation.nx*(j+1)] : c
            let y = CGFloat(j)*cellH
            if (c-0.5)*(right-0.5) < 0 { let x = CGFloat(i+1)*cellW; context.move(to:CGPoint(x:x,y:y)); context.addLine(to:CGPoint(x:x,y:y+cellH)); context.strokePath() }
            if (c-0.5)*(top-0.5) < 0 { context.move(to:CGPoint(x:CGFloat(i)*cellW,y:y+cellH)); context.addLine(to:CGPoint(x:CGFloat(i+1)*cellW,y:y+cellH)); context.strokePath() }
        }}
        drawLabel("INTERNAL PHASE STUDY / NOT APP",context:context)
        guard let result = context.makeImage() else { throw Simulation.Failure.invalid("Cannot finalize phase image") }
        return result
    }
    static func savePNG(_ image: CGImage, name: String) throws {
        guard let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL,UTType.png.identifier as CFString,1,nil) else {
            throw Simulation.Failure.invalid("Cannot open PNG")
        }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw Simulation.Failure.invalid("Cannot write PNG") }
    }
    static func snapshot(_ simulation: Simulation, step: Int) throws {
        let name = String(format:"phase-t%.1f",Double(step)*dt)
        let values: [String:Any] = ["fixtureTime":Double(step)*dt,"simulationTime":simulation.time,
                                    "nx":simulation.nx,"ny":simulation.ny,"width":simulation.width,"height":simulation.height,
                                    "phase":simulation.phase]
        try JSONSerialization.data(withJSONObject:values,options:[.sortedKeys]).write(to:output.appendingPathComponent(name+".json"))
        try savePNG(image(simulation),name:name+".png")
    }
    static func append(_ image: CGImage, frame: Int, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor) throws {
        let deadline = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData {
            if Date() > deadline { throw Simulation.Failure.invalid("Video encoder timed out") }
            Thread.sleep(forTimeInterval:0.002)
        }
        guard let pool = adaptor.pixelBufferPool else { throw Simulation.Failure.invalid("Video buffer unavailable") }
        var optional: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&optional) == kCVReturnSuccess, let buffer = optional else { throw Simulation.Failure.invalid("Cannot allocate video frame") }
        CVPixelBufferLockBaseAddress(buffer,[])
        guard let context = CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:width,height:height,bitsPerComponent:8,
                                      bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpace(name:CGColorSpace.sRGB)!,
                                      bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw Simulation.Failure.invalid("Video bitmap context unavailable") }
        context.draw(image,in:CGRect(x:0,y:0,width:width,height:height)); CVPixelBufferUnlockBaseAddress(buffer,[])
        guard adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(frame),timescale:30)) else { throw Simulation.Failure.invalid("Cannot append video frame") }
        appendedFrames += 1
    }
    static func sha256(_ url: URL) throws -> String { SHA256.hash(data:try Data(contentsOf:url)).map { String(format:"%02x",$0) }.joined() }
    static func writeProvenance(began: Date, completed: Date, clock: Double) throws {
        let inputs = ["Studies/TwoPhaseSimulation.swift","Tests/TwoPhaseMotionStudy.swift","scripts/study-two-phase-motion.sh"]
        var inputHashes = [String:String](); for path in inputs { inputHashes[path] = try sha256(URL(fileURLWithPath:path)) }
        let artifacts = try FileManager.default.contentsOfDirectory(at:output,includingPropertiesForKeys:nil)
            .filter { $0.lastPathComponent != "provenance.json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var artifactHashes = [String:String](); for url in artifacts { artifactHashes[url.lastPathComponent] = try sha256(url) }
        let data: [String:Any] = ["algorithm":"SHA-256 (CryptoKit)","completedAt":ISO8601DateFormatter().string(from:completed),
                                  "actualClock":clock,"cpuWallSeconds":completed.timeIntervalSince(began),"videoFrames":appendedFrames,
                                  "simulationSource":"Studies/TwoPhaseSimulation.swift","inputSHA256":inputHashes,"artifactSHA256":artifactHashes]
        try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("provenance.json"))
    }
    static func main() {
        let began = Date(), stamp = ISO8601DateFormatter().string(from:began).replacingOccurrences(of:":",with:"-")
        output = output.appendingPathComponent("run-"+stamp+"-"+String(UUID().uuidString.prefix(6)))
        var clock = 0.0
        var activeWriter: AVAssetWriter?
        do {
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            let contract: [String:Any] = ["simulation":"Studies/TwoPhaseSimulation.swift","grid":["nx":40,"ny":80,"width":1,"height":2,"densityContrast":0.18],
                "dt":dt,"duration":8,"transport":"fct","phaseStepProjectionTarget":1e-16,
                "seed":"c=1 below y=0.85, 4x4 cell supersampling",
                "gravitySchedule":["0<=t<1: (0,-3)","1<=t<2: a=0.75*s*s*(3-2*s), s=t-1; 3*(sin(a),-cos(a))","2<=t<3: 3*(sin(0.75),-cos(0.75))","3<=t<5: (2*cos(4*pi*(t-3)),-2)","5<=t<=8: (0,-3)"],
                "prohibited":["adaptive retry","phase clamp","phase renormalization","physics tuning"],
                "vetoes":["mass/domain <= 1e-9","phase range +/- 1e-12","dt divergence <= 1e-6","wall flux = 0","outgoing CFL <= 0.45"],
                "snapshots":[0,1.5,3,4.5,6,8],"video":["fps":30,"frames":240,"times":"0 through 7.966666..."],
                "visual":"raw phase linear blue/clear interpolation plus c=0.5 contour; INTERNAL PHASE STUDY / NOT APP"]
            try JSONSerialization.data(withJSONObject:contract,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("contract.json"))
            let sim = Simulation(nx:40,ny:80,width:1,height:2,densityContrast:0.18); try seed(sim)
            let initialAmount = sim.metrics().amount
            let movie = output.appendingPathComponent("phase-motion.mp4")
            let writer = try AVAssetWriter(outputURL:movie,fileType:.mp4)
            activeWriter = writer
            let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
            guard writer.canAdd(input) else { throw Simulation.Failure.invalid("Video encoder unavailable") }; writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? Simulation.Failure.invalid("Cannot start video") }; writer.startSession(atSourceTime:.zero)
            try snapshot(sim,step:0)
            for step in 0..<totalSteps {
                if step % 8 == 0 { try append(image(sim),frame:step/8,input:input,adaptor:adaptor) }
                let projection = try sim.step(dt:dt,gravity:gravity(at:Double(step)*dt))
                clock = sim.time; record(sim,initialAmount:initialAmount,projection:projection)
                if let reason = violation(sim,initialAmount:initialAmount,projection:projection) { throw Simulation.Failure.invalid("step \(step+1), time \(sim.time): \(reason)") }
                if snapshotSteps.contains(step+1) { try snapshot(sim,step:step+1) }
            }
            guard appendedFrames == 240 else { throw Simulation.Failure.invalid("Video frame count: \(appendedFrames)") }
            input.markAsFinished(); let finished = DispatchSemaphore(value:0); writer.finishWriting { finished.signal() }
            guard finished.wait(timeout:.now()+30) == .success, writer.status == .completed else { throw writer.error ?? Simulation.Failure.invalid("Cannot finish video") }
            checks.append("PASS 8-second fixed-input study; frames=\(appendedFrames); clock=\(clock)")
        } catch {
            activeWriter?.cancelWriting()
            checks.append("FAIL after accepted time \(clock): \(error)")
        }
        let completed = Date()
        do {
            try rows.joined(separator:"\n").appending("\n").write(to:output.appendingPathComponent("metrics.csv"),atomically:true,encoding:.utf8)
            try checks.joined(separator:"\n").appending("\n").write(to:output.appendingPathComponent("checks.txt"),atomically:true,encoding:.utf8)
            try writeProvenance(began:began,completed:completed,clock:clock)
        } catch { fputs("FAIL evidence write: \(error)\n",stderr); exit(1) }
        print(checks.joined(separator:"\n")); print("output=\(output.path)")
        if checks.contains(where: { $0.hasPrefix("FAIL") }) { exit(1) }
    }
}
