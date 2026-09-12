import Foundation
import MetalKit
import AVFoundation
import CoreVideo

@main
struct RenderMovie {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw OceanRendererError.unavailable("Metal device unavailable")
        }
        let source = try String(contentsOfFile: "SmallWave/Rendering/LiquidShaders.metal", encoding: .utf8)
        let renderer = try LiquidRenderer(device: device, library: device.makeLibrary(source: source, options: nil))
        let width = 480, height = 1018
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget]
        guard let target = device.makeTexture(descriptor: descriptor) else {
            throw OceanRendererError.unavailable("Video render target unavailable")
        }
        let folder = URL(fileURLWithPath: ".build-cache/previews")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("smallwave-physics.mp4")
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000]
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
        for frame in 0..<360 {
            let t = Float(frame) / 30
            if t < 2 {
                renderer.motion = MotionSample()
            } else if t < 4 {
                let angle = sin((t-2) / 2 * .pi) * 0.85
                renderer.motion = MotionSample(gravity: SIMD3(sin(angle), -cos(angle), 0))
            } else if t < 6 {
                let q = t-4
                renderer.motion = MotionSample(gravity: SIMD3(0,-1,0),
                    acceleration: SIMD3(sin(q*18)*1.8, cos(q*14)*1.1, sin(q*10)*0.4))
            } else if t < 9 {
                let angle = min(1,(t-6)/1.25) * .pi
                renderer.motion = MotionSample(gravity: SIMD3(sin(angle),-cos(angle),0))
            } else {
                let angle = max(0,1-(t-9)/1.0) * .pi
                renderer.motion = MotionSample(gravity: SIMD3(sin(angle),-cos(angle),0))
            }
            try renderer.render(into: target, elapsed: 1/30, waitForCompletion: true)
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
        print("PASS: 12-second, 30fps Metal physics preview: \(output.path)")
    }
}
