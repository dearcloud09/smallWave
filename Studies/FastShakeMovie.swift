import Foundation
import MetalKit
import AVFoundation
import CoreVideo

@main
struct FastShakeMovie {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw OceanRendererError.unavailable("Metal device unavailable")
        }
        guard CommandLine.arguments.count == 3, let forceScale = Float(CommandLine.arguments[1]),
              [Float(5.8), Float(23.2)].contains(forceScale) else {
            throw OceanRendererError.unavailable("Use 5.8 or 23.2, and an output folder")
        }
        let shaderPaths = ["SmallWave/Rendering/LiquidShaders.metal", "SmallWave/Rendering/LiquidVolumeField.metal", "SmallWave/Rendering/MobileVolumeOptics.metal"]
        let source = "#define LIVE_CONCATENATED_SHADER 1\n" + (try shaderPaths.map { try String(contentsOfFile: $0, encoding: .utf8) }.joined(separator: "\n"))
        LiquidSimulation.diagnosticDefaultForceScale = forceScale
        let renderer = try LiquidRenderer(device: device, library: device.makeLibrary(source: source, options: nil))
        renderer.usesVolumeOptics = true
        try renderer.loadMiniatureArt(from: URL(fileURLWithPath: "SmallWave/Miniatures"))
        renderer.motionProvider = { plan, end in
            (0..<plan.count).map { index in
                let t = Float(end) - plan.duration + (Float(index) + 0.5) * plan.stepDuration
                let ax: Float = t >= 0.5 && t < 3.5 ? sin((t - 0.5) * 4 * Float.pi) : 0
                return MotionSample(acceleration: SIMD3(ax, 0, 0))
            }
        }
        let width = 804, height = 1704
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget]
        guard let target = device.makeTexture(descriptor: descriptor) else {
            throw OceanRendererError.unavailable("Video render target unavailable")
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("smallwave-physics.mp4")
        guard !FileManager.default.fileExists(atPath: output.path) else { throw OceanRendererError.unavailable("Output already exists") }
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
        guard writer.canAdd(input) else { throw OceanRendererError.unavailable("Video encoder unavailable") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? OceanRendererError.unavailable("Cannot start video") }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw OceanRendererError.unavailable("Video buffer unavailable") }
        for _ in 0..<360 { renderer.simulation.advance(elapsed: 1/120, motion: MotionSample()) }
        for frame in 0..<180 {
            let t = Float(frame) / 30
            try renderer.render(into: target, elapsed: 1/30, waitForCompletion: true, motionTimestamp: Double(t + 1/30))
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed || Date() > deadline {
                    throw writer.error ?? OceanRendererError.unavailable("Video encoder timed out")
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
                  let buffer = optionalBuffer else { throw OceanRendererError.unavailable("Cannot allocate video frame") }
            CVPixelBufferLockBaseAddress(buffer, [])
            target.getBytes(CVPixelBufferGetBaseAddress(buffer)!, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? OceanRendererError.unavailable("Cannot append video frame")
            }
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now()+30) == .success, writer.status == .completed else {
            throw writer.error ?? OceanRendererError.unavailable("Cannot finish video")
        }
        print("PASS: synthetic 2Hz, 6-second, 30fps Metal preview: \(output.path)")
    }
}
