import Foundation
import MetalKit
import ImageIO
import simd

struct OceanUniforms {
    var viewport = SIMD4<Float>(1, 2.12, 0, 0)
    var boat = SIMD4<Float>.zero
    var movement = SIMD4<Float>(0, -1, 0, 0)
    var color = SIMD4<Float>(OceanStyle.waterColor, 1)
    var optics = SIMD4<Float>.zero
    var miniatureArt = SIMD4<Float>(-1, 0.75, 0, 0) // variant, scale, immersion, hull speed
}

struct SurfaceKernel {
    var center: SIMD4<Float>
    var axes: SIMD4<Float>
}

/// Render-only local covariance. Equal-area ellipses replace circular
/// footprints; kernel centers and the liquid state remain unchanged.
enum SurfaceReconstruction {
    static func kernels(for particles: [LiquidParticle], spacing: Float,
                        halfSize: SIMD2<Float>) -> [SurfaceKernel] {
        let support = spacing * 3
        let support2 = support * support
        let radius = spacing * 1.5
        let nx = Int(ceil(halfSize.x * 2 / support)) + 1
        let ny = Int(ceil(halfSize.y * 2 / support)) + 1
        var heads = [Int](repeating: -1, count: nx * ny)
        var next = [Int](repeating: -1, count: particles.count)
        func cell(_ p: SIMD3<Float>) -> SIMD2<Int> {
            SIMD2(max(0,min(nx-1,Int((p.x+halfSize.x)/support))),
                  max(0,min(ny-1,Int((p.y+halfSize.y)/support))))
        }
        for i in particles.indices {
            let c = cell(particles[i].position), k = c.x + nx * c.y
            next[i] = heads[k]; heads[k] = i
        }
        return particles.map { particle in
            let c = cell(particle.position)
            var weight: Float = 0
            var mean = SIMD2<Float>.zero
            var moment = SIMD3<Float>.zero // xx, xy, yy around this particle
            var count = 0
            for y in max(0,c.y-1)...min(ny-1,c.y+1) {
                for x in max(0,c.x-1)...min(nx-1,c.x+1) {
                    var j = heads[x+nx*y]
                    while j >= 0 {
                        let delta = particles[j].position-particle.position
                        j = next[j]
                        let r2 = simd_length_squared(delta)
                        guard r2 < support2 else { continue }
                        let d = SIMD2(delta.x,delta.y)
                        let t = 1-r2/support2, w = t*t*t
                        weight += w; mean += d*w
                        moment += SIMD3(d.x*d.x,d.x*d.y,d.y*d.y)*w
                        count += 1
                    }
                }
            }
            // Sparse droplets stay circular instead of becoming needles.
            guard count >= 12, weight > 4 else {
                return SurfaceKernel(center: SIMD4(particle.position,1), axes: SIMD4(radius,0,0,radius))
            }
            mean /= weight
            moment = moment/weight - SIMD3(mean.x*mean.x,mean.x*mean.y,mean.y*mean.y)
            let discriminant = sqrt(max(0,pow(moment.x-moment.z,2)+4*moment.y*moment.y))
            let major = max(0,(moment.x+moment.z+discriminant)*0.5)
            let minor = max(major/4,(moment.x+moment.z-discriminant)*0.5)
            let stretch = pow(max(1,major/max(minor,0.000001)),0.25)
            let angle = 0.5*atan2(2*moment.y,moment.x-moment.z)
            let axis = SIMD2(cos(angle),sin(angle))
            let a = axis * (radius*stretch)
            let b = SIMD2(-axis.y,axis.x) * (radius/stretch)
            return SurfaceKernel(center: SIMD4(particle.position,1), axes: SIMD4(a.x,a.y,b.x,b.y))
        }
    }
}

enum OceanRendererError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let reason): return reason }
    }
}

/// Renderer also runs in a Mac offscreen harness; no UIKit dependency here.
final class LiquidRenderer: NSObject, MTKViewDelegate {
    let simulation: LiquidSimulation
    var motion = MotionSample()
    var screenRotation: Float = 0
    // Opt-in art study for comparing refraction; the app's default stays plain.
    var miniatureBackdrop = false
    var miniatureStyle: MiniatureStyle = .sunday
    var usesCraftedMiniature = true
    private var miniatureTextures: [MTLTexture] = []
    var usesVolumeOptics = false
    var reconstructedSurface = false
    var continuousSurface = false
    var clearInterface = false
    var showsBubbles = true
    var isActive = true {
        didSet {
            if oldValue != isActive { lastFrameTime = nil; simulation.suspend() }
        }
    }
    var onEnergy: ((Float) -> Void)?
    var onError: ((String) -> Void)?
    var motionProvider: ((LiquidStepPlan, TimeInterval) -> [MotionSample])?

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let fieldPipeline: MTLRenderPipelineState
    private let continuousFieldPipeline: MTLRenderPipelineState?
    private let allowsSurfaceStudy: Bool
    private let oceanPipeline: MTLRenderPipelineState
    private let bubblePipeline: MTLRenderPipelineState
    private let volumePipeline: MTLRenderPipelineState
    private let depthExtraction: MTLComputePipelineState
    private let depthSmoothing: MTLComputePipelineState
    private let shaderLibrary: MTLLibrary
    private var volumeOptics: LiquidVolumeRenderer?
    private var densityTexture: MTLTexture?
    private var rawDepthTexture: MTLTexture?
    private var smoothDepthTexture: MTLTexture?
    private var volumeTexture: MTLTexture?
    private var lastFrameTime: CFTimeInterval?
    private weak var pendingPausedRedrawView: MTKView?
    private let inFlight = DispatchSemaphore(value: 3)
    private var frameIndex = 0
    private var particleBuffers: [MTLBuffer] = []
    private var bubbleBuffers: [MTLBuffer] = []
    private var surfaceBuffers: [MTLBuffer] = []
    private var energyFrame = 0
    #if os(iOS)
    // Enabled only for a developer-launched, bounded local measurement.
    // Normal icon launches do not create or write a timing capture.
    private let timingCaptureID: String? = {
        let prefix = "--smallwave-frame-timing="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let value = String(argument.dropFirst(prefix.count))
        return value.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil ? value : nil
    }()
    private lazy var frameTimingProbe: FrameTimingProbe? = {
        guard let captureID = timingCaptureID,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return FrameTimingProbe(outputURL: caches.appendingPathComponent("smallwave-frame-timing.json"),
                                captureID: captureID)
    }()
    #endif

    init(device: MTLDevice, library: MTLLibrary? = nil,
         cohesionStrength: Float = LiquidSimulation.defaultCohesionStrength,
         interfaceBubbles: Bool = LiquidSimulation.defaultInterfaceBubbles,
         surfaceStudy: Bool = false) throws {
        simulation = LiquidSimulation(cohesionStrength: cohesionStrength, interfaceBubbles: interfaceBubbles)
        allowsSurfaceStudy = surfaceStudy
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw OceanRendererError.unavailable("그래픽 명령을 준비하지 못했어.")
        }
        self.queue = queue
        guard let library = library ?? device.makeDefaultLibrary() else {
            throw OceanRendererError.unavailable("액체 그래픽 파일을 읽지 못했어.")
        }
        shaderLibrary = library
        func pipeline(_ vertex: String, _ fragment: String,
                      _ format: MTLPixelFormat, additive: Bool = false,
                      alpha: Bool = false) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            if vertex == "volumeVertex" { descriptor.inputPrimitiveTopology = .triangle }
            descriptor.colorAttachments[0].pixelFormat = format
            if additive || alpha {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        fieldPipeline = try pipeline("fieldVertex", "fieldFragment", .rgba16Float, additive: true)
        continuousFieldPipeline = surfaceStudy
            ? try pipeline("continuousFieldVertex", "fieldFragment", .rgba16Float, additive: true) : nil
        oceanPipeline = try pipeline("screenVertex", "oceanFragment", .bgra8Unorm)
        bubblePipeline = try pipeline("bubbleVertex", "bubbleFragment", .bgra8Unorm, alpha: true)
        volumePipeline = try pipeline("volumeVertex", "volumeFragment", .r16Float, additive: true)
        guard let extractor = library.makeFunction(name: "extractDepth") else {
            throw OceanRendererError.unavailable("액체 내부 깊이를 준비하지 못했어.")
        }
        depthExtraction = try device.makeComputePipelineState(function: extractor)
        guard let smoother = library.makeFunction(name: "smoothDepth") else {
            throw OceanRendererError.unavailable("액체 깊이 필터를 준비하지 못했어.")
        }
        depthSmoothing = try device.makeComputePipelineState(function: smoother)
        super.init()
        for _ in 0..<3 {
            guard let particles = device.makeBuffer(length: simulation.particles.count * 16, options: .storageModeShared),
                  let bubbles = device.makeBuffer(length: 36 * 16, options: .storageModeShared) else {
                throw OceanRendererError.unavailable("그래픽 메모리를 준비하지 못했어.")
            }
            particleBuffers.append(particles)
            bubbleBuffers.append(bubbles)
            if surfaceStudy {
                guard let surface = device.makeBuffer(length: simulation.particles.count * MemoryLayout<SurfaceKernel>.stride,
                                                       options: .storageModeShared) else {
                    throw OceanRendererError.unavailable("수면 실험용 메모리를 준비하지 못했어.")
                }
                surfaceBuffers.append(surface)
            }
        }
    }

    func reset() { simulation.reset(); lastFrameTime = nil }

    /// Explicit directory keeps command-line studies independent of app resources.
    /// Premultiply before filtering and mip generation so transparent texel colors
    /// cannot become bright rigging halos when the tiny object is minified.
    func loadMiniatureArt(from directory: URL) throws {
        var sharedTextures: [String: MTLTexture] = [:]
        miniatureTextures = try MiniatureStyle.allCases.map { style in
            if let texture = sharedTextures[style.textureAssetName] { return texture }
            let url = directory.appendingPathComponent(style.textureAssetName + ".png")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw OceanRendererError.unavailable("작은 배의 재료를 읽지 못했어.")
            }
            // The hull is about 71pt wide. Retain full originals for inspection,
            // but share one 512px mip chain (~1.3 MiB) across all paint colors.
            let scale = min(1, 512.0 / Double(max(image.width, image.height)))
            let width = max(1, Int((Double(image.width) * scale).rounded()))
            let height = max(1, Int((Double(image.height) * scale).rounded()))
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            try bytes.withUnsafeMutableBytes { data in
                guard let context = CGContext(data: data.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else {
                    throw OceanRendererError.unavailable("작은 배의 색을 준비하지 못했어.")
                }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                width: width, height: height, mipmapped: true)
            descriptor.storageMode = .shared; descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor),
                  let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
                throw OceanRendererError.unavailable("작은 배의 질감을 준비하지 못했어.")
            }
            bytes.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: $0.baseAddress!, bytesPerRow: width * 4)
            }
            blit.generateMipmaps(for: texture); blit.endEncoding()
            command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            sharedTextures[style.textureAssetName] = texture
            return texture
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lastFrameTime = nil
    }

    func draw(in view: MTKView) {
        // Inactive automatic frames mean an error stop, not a paused resize.
        guard isActive || view.isPaused else { return }
        #if os(iOS)
        let drawEntered = timingCaptureID != nil ? CACurrentMediaTime() : 0
        #else
        let drawEntered: TimeInterval = 0
        #endif
        guard let drawable = view.currentDrawable else { return }
        let now = CACurrentMediaTime()
        // A manual redraw of a paused view updates its projection only. Keep
        // both the simulated state and the captured motion sample frozen.
        let dt: Float = isActive ? Float(lastFrameTime.map { now - $0 } ?? 1 / 60) : 0
        do {
            // Time belongs to accepted simulation frames. A busy GPU must not
            // silently consume time before the next accepted motion update.
            if try render(into: drawable.texture, elapsed: dt, drawable: drawable, motionTimestamp: now,
                          drawableWait: drawEntered > 0 ? now - drawEntered : 0,
                          measuredInterval: lastFrameTime.map { now - $0 }) {
                pendingPausedRedrawView = nil
                lastFrameTime = isActive ? now : nil
            } else if !isActive && view.isPaused {
                pendingPausedRedrawView = view
            }
        } catch {
            isActive = false
            onError?(error.localizedDescription)
        }
    }

    private func retryPausedRedrawAfterCompletion() {
        // A rotation may arrive while all three frame slots are busy. Retry
        // only after a slot is released; coalesce repeated resize requests.
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.pendingPausedRedrawView else { return }
            self.pendingPausedRedrawView = nil
            guard !self.isActive, view.isPaused else { return }
            view.draw()
        }
    }

    /// Returns after encoding unless waitForCompletion is requested by the offscreen harness.
    @discardableResult
    func render(into target: MTLTexture, elapsed: Float,
                drawable: CAMetalDrawable? = nil, waitForCompletion: Bool = false,
                motionTimestamp: TimeInterval? = nil, drawableWait: TimeInterval = 0,
                measuredInterval: TimeInterval? = nil) throws -> Bool {
        if continuousSurface || clearInterface {
            guard allowsSurfaceStudy else {
                throw OceanRendererError.unavailable("수면 실험은 별도로 준비한 렌더러에서만 실행할 수 있어.")
            }
            guard !reconstructedSurface else {
                throw OceanRendererError.unavailable("서로 다른 수면 재구성 실험을 동시에 켤 수 없어.")
            }
        }
        guard inFlight.wait(timeout: .now()) == .success else { return false }
        var committed = false
        defer { if !committed { inFlight.signal() } }
        // A busy GPU cannot consume sensor history. Accepted frames resample the
        // real timeline once per physics step, preserving quick direction changes.
        let plan = simulation.stepPlan(forElapsed: elapsed)
        #if os(iOS)
        let providerStarted = timingCaptureID != nil ? CACurrentMediaTime() : 0
        #endif
        var stepMotions: [MotionSample] = []
        if isActive, plan.count > 0, let provider = motionProvider {
            stepMotions = provider(plan, motionTimestamp ?? CACurrentMediaTime())
            if let latest = stepMotions.last { motion = latest }
        }
        #if os(iOS)
        let simulationStarted = timingCaptureID != nil ? CACurrentMediaTime() : 0
        #endif
        simulation.advance(elapsed: elapsed, motion: motion, stepMotions: stepMotions)
        #if os(iOS)
        let encodingStarted = timingCaptureID != nil ? CACurrentMediaTime() : 0
        #endif
        let portrait = target.height >= target.width
        let screenHalf = portrait ? SIMD2<Float>(1, simulation.halfHeight)
                                  : SIMD2<Float>(simulation.halfHeight, 1)
        let fieldWidth = portrait ? 256 : 544
        let fieldHeight = portrait ? 544 : 256
        if densityTexture?.width != fieldWidth || densityTexture?.height != fieldHeight {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                width: fieldWidth, height: fieldHeight, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            densityTexture = device.makeTexture(descriptor: descriptor)
        }
        guard let field = densityTexture, let command = queue.makeCommandBuffer() else {
            throw OceanRendererError.unavailable("프레임을 준비하지 못했어.")
        }
        if reconstructedSurface && (rawDepthTexture?.width != fieldWidth || rawDepthTexture?.height != fieldHeight) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                width: fieldWidth, height: fieldHeight, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
            rawDepthTexture = device.makeTexture(descriptor: descriptor)
            smoothDepthTexture = device.makeTexture(descriptor: descriptor)
            descriptor.pixelFormat = .r16Float
            descriptor.textureType = .type2DArray
            descriptor.arrayLength = 16
            descriptor.usage = [.renderTarget, .shaderRead]
            volumeTexture = device.makeTexture(descriptor: descriptor)
            guard rawDepthTexture != nil, smoothDepthTexture != nil, volumeTexture != nil else {
                throw OceanRendererError.unavailable("액체 깊이 화면을 준비하지 못했어.")
            }
        }
        let slot = frameIndex % 3
        frameIndex += 1
        let particleBuffer = particleBuffers[slot]
        let pointers = particleBuffer.contents().bindMemory(to: SIMD4<Float>.self,
                                                            capacity: simulation.particles.count)
        for (i, particle) in simulation.particles.enumerated() {
            pointers[i] = SIMD4(particle.position, simulation.spacing * 1.5)
        }
        if continuousSurface {
            let kernels = SurfaceReconstruction.kernels(for: simulation.particles, spacing: simulation.spacing,
                halfSize: SIMD2(simulation.halfWidth,simulation.halfHeight))
            let pointer = surfaceBuffers[slot].contents().bindMemory(to: SurfaceKernel.self, capacity: kernels.count)
            for i in kernels.indices { pointer[i] = kernels[i] }
        }
        let bubbleBuffer = bubbleBuffers[slot]
        let bubblePointers = bubbleBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 36)
        let live = usesVolumeOptics && !reconstructedSurface && !continuousSurface && !clearInterface
        for (i, bubble) in simulation.bubbles.enumerated() {
            bubblePointers[i] = live ? SIMD4(bubble.position,bubble.radius)
                : SIMD4(bubble.position.x,bubble.position.y,bubble.radius,min(1,bubble.life))
        }
        var uniforms = OceanUniforms()
        uniforms.color.w = miniatureBackdrop ? 1 : 0
        uniforms.optics = SIMD4(reconstructedSurface ? 1 : (clearInterface ? 2 : 0), simulation.halfDepth, 0.6, 16)
        uniforms.viewport = SIMD4(screenHalf.x, screenHalf.y, simulation.time, screenRotation)
        uniforms.boat = SIMD4(simulation.boat.position.x, simulation.boat.position.y,
                             simulation.boat.angle, simulation.boat.position.z)
        uniforms.movement = SIMD4(motion.safeGravity, simulation.energy)
        let miniatureTexture = !usesCraftedMiniature || miniatureTextures.isEmpty
            ? nil : miniatureTextures[miniatureStyle.rawValue]
        if miniatureTexture != nil {
            let forward = SIMD2<Float>(cos(simulation.boat.angle), sin(simulation.boat.angle))
            let velocity = SIMD2(simulation.boat.velocity.x, simulation.boat.velocity.y)
            uniforms.miniatureArt = SIMD4(Float(miniatureStyle.rawValue), 0.75,
                simulation.boat.immersion, simd_dot(velocity, forward))
        }
        if live {
            if volumeOptics == nil {
                volumeOptics = try LiquidVolumeRenderer(device:device,library:shaderLibrary)
                volumeOptics?.tracesAirBubbles = true
                volumeOptics?.appliesEdgeAntialiasing = true
            }
            guard let volumeOptics else {throw OceanRendererError.unavailable("새 액체 재질을 읽지 못했어.")}
            volumeOptics.miniatureTexture = miniatureTexture
            uniforms.color=SIMD4(0.0001,0.16,0.45,0)
            uniforms.optics=SIMD4(1.46,1.333,0.3,0)
            try volumeOptics.encodeDisplay(command:command,target:target,
                particles:particleBuffer,particleCount:simulation.particles.count,
                bubbles:bubbleBuffer,bubbleCount:showsBubbles ? simulation.bubbles.count : 0,uniforms:uniforms)
            if let drawable {command.present(drawable)}
            let semaphore=inFlight
            command.addCompletedHandler { [weak self] completed in
                semaphore.signal()
                if let error=completed.error {self?.onError?(error.localizedDescription)}
                self?.retryPausedRedrawAfterCompletion()
            }
            #if os(iOS)
            if timingCaptureID != nil, isActive, let timestamp = motionTimestamp {
                recordTiming(command: command, timestamp: timestamp, interval: measuredInterval,
                             simulatedDuration: Double(plan.duration), drawableWait: drawableWait,
                             providerCPU: simulationStarted - providerStarted,
                             simulationCPU: encodingStarted - simulationStarted,
                             encodingCPU: CACurrentMediaTime() - encodingStarted)
            }
            #endif
            committed=true;command.commit()
            if waitForCompletion {command.waitUntilCompleted();if let error=command.error {throw error}}
            energyFrame+=1
            if energyFrame%3==0 {onEnergy?(simulation.energy)}
            return true
        }
        let uniformSize = MemoryLayout<OceanUniforms>.stride
        let fieldPass = MTLRenderPassDescriptor()
        fieldPass.colorAttachments[0].texture = field
        fieldPass.colorAttachments[0].loadAction = .clear
        fieldPass.colorAttachments[0].storeAction = .store
        fieldPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: fieldPass) else {
            throw OceanRendererError.unavailable("액체 표면을 계산하지 못했어.")
        }
        encoder.setRenderPipelineState(continuousSurface ? continuousFieldPipeline! : fieldPipeline)
        encoder.setVertexBuffer(continuousSurface ? surfaceBuffers[slot] : particleBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: uniformSize, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: simulation.particles.count)
        encoder.endEncoding()

        if reconstructedSurface, let raw = rawDepthTexture, let smooth = smoothDepthTexture, let volume = volumeTexture {
            let depthPass = MTLRenderPassDescriptor()
            depthPass.colorAttachments[0].texture = volume
            depthPass.renderTargetArrayLength = 16
            depthPass.colorAttachments[0].loadAction = .clear
            depthPass.colorAttachments[0].storeAction = .store
            depthPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            guard let depth = command.makeRenderCommandEncoder(descriptor: depthPass) else {
                throw OceanRendererError.unavailable("액체 앞뒤 깊이를 계산하지 못했어.")
            }
            depth.setRenderPipelineState(volumePipeline)
            depth.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            depth.setVertexBytes(&uniforms, length: uniformSize, index: 1)
            depth.setFragmentBytes(&uniforms, length: uniformSize, index: 0)
            depth.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                 instanceCount: simulation.particles.count * 16)
            depth.endEncoding()
            guard let filter = command.makeComputeCommandEncoder() else {
                throw OceanRendererError.unavailable("액체 깊이 필터를 실행하지 못했어.")
            }
            filter.setComputePipelineState(depthExtraction)
            filter.setTexture(volume, index: 0)
            filter.setTexture(raw, index: 1)
            filter.setBytes(&uniforms, length: uniformSize, index: 0)
            filter.dispatchThreads(MTLSize(width: fieldWidth, height: fieldHeight, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            filter.setComputePipelineState(depthSmoothing)
            filter.setTexture(raw, index: 0)
            filter.setTexture(smooth, index: 1)
            filter.dispatchThreads(MTLSize(width: fieldWidth, height: fieldHeight, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            filter.endEncoding()
        }

        let displayPass = MTLRenderPassDescriptor()
        displayPass.colorAttachments[0].texture = target
        displayPass.colorAttachments[0].loadAction = .dontCare
        displayPass.colorAttachments[0].storeAction = .store
        guard let display = command.makeRenderCommandEncoder(descriptor: displayPass) else {
            throw OceanRendererError.unavailable("바다를 그리지 못했어.")
        }
        display.setRenderPipelineState(oceanPipeline)
        display.setFragmentTexture(field, index: 0)
        display.setFragmentTexture(reconstructedSurface ? smoothDepthTexture : field, index: 1)
        display.setFragmentTexture(miniatureTexture, index: 3)
        display.setFragmentBytes(&uniforms, length: uniformSize, index: 0)
        display.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        if showsBubbles && !simulation.bubbles.isEmpty {
            display.setRenderPipelineState(bubblePipeline)
            display.setVertexBuffer(bubbleBuffer, offset: 0, index: 0)
            display.setVertexBytes(&uniforms, length: uniformSize, index: 1)
            display.setFragmentTexture(field, index: 0)
            display.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                   instanceCount: simulation.bubbles.count)
        }
        display.endEncoding()
        if let drawable { command.present(drawable) }
        let semaphore = inFlight
        command.addCompletedHandler { [weak self] _ in
            semaphore.signal()
            self?.retryPausedRedrawAfterCompletion()
        }
        #if os(iOS)
        if timingCaptureID != nil, isActive, let timestamp = motionTimestamp {
            recordTiming(command: command, timestamp: timestamp, interval: measuredInterval,
                         simulatedDuration: Double(plan.duration), drawableWait: drawableWait,
                         providerCPU: simulationStarted - providerStarted,
                         simulationCPU: encodingStarted - simulationStarted,
                         encodingCPU: CACurrentMediaTime() - encodingStarted)
        }
        #endif
        committed = true
        command.commit()
        if waitForCompletion {
            command.waitUntilCompleted()
            if let error = command.error { throw error }
        }
        energyFrame += 1
        if energyFrame % 6 == 0 { onEnergy?(simulation.energy) }
        return true
    }

    #if os(iOS)
    private func recordTiming(command: MTLCommandBuffer, timestamp: TimeInterval,
                              interval: TimeInterval?, simulatedDuration: TimeInterval,
                              drawableWait: TimeInterval, providerCPU: TimeInterval,
                              simulationCPU: TimeInterval, encodingCPU: TimeInterval) {
        guard let probe = frameTimingProbe,
              let frameID = probe.record(FrameTimingSample(acceptedAt: timestamp, interval: interval,
                  simulatedDuration: simulatedDuration, drawableWait: drawableWait,
                  providerCPU: providerCPU, simulationCPU: simulationCPU, encodingCPU: encodingCPU)) else { return }
        let submitted = CACurrentMediaTime()
        command.addCompletedHandler { completed in
            let execution = completed.gpuEndTime > completed.gpuStartTime && completed.gpuStartTime > 0
                ? completed.gpuEndTime - completed.gpuStartTime : nil
            probe.recordGPU(frameID: frameID, execution: execution,
                            submitToCompletion: CACurrentMediaTime() - submitted)
        }
    }
    #endif
}
