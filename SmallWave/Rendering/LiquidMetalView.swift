import SwiftUI
import MetalKit
import UIKit

struct LiquidMetalView: UIViewControllerRepresentable {
    let motion: MotionInput
    let controls: OceanControls
    let active: Bool
    let sound: Bool
    let haptics: Bool
    let reducedMotion: Bool
    let miniatureStyle: MiniatureStyle

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> OceanViewController {
        let controller = OceanViewController()
        let view = OceanMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        controller.view = view
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.framebufferOnly = true
        view.isOpaque = true
        view.clearColor = MTLClearColorMake(0.95, 0.94, 0.89, 1)
        guard let device = view.device else {
            DispatchQueue.main.async { controls.rendererError = "이 기기의 그래픽 기능에 연결하지 못했어." }
            return controller
        }
        do {
            let renderer = try LiquidRenderer(device: device)
            guard let resources = Bundle.main.resourceURL else {
                throw OceanRendererError.unavailable("작은 배의 재료를 찾지 못했어.")
            }
            try renderer.loadMiniatureArt(from: resources.appendingPathComponent("Miniatures"))
            renderer.miniatureStyle = miniatureStyle
            renderer.usesVolumeOptics = true
            context.coordinator.renderer = renderer
            controls.renderer = renderer
            view.oceanRenderer = renderer
            view.delegate = renderer
            renderer.onEnergy = { [weak controls] energy in
                DispatchQueue.main.async { controls?.sensory.update(energy: energy) }
            }
            renderer.onError = { [weak controls] message in
                DispatchQueue.main.async { controls?.rendererError = message }
            }
        } catch {
            DispatchQueue.main.async { controls.rendererError = error.localizedDescription }
        }
        return controller
    }

    func updateUIViewController(_ controller: OceanViewController, context: Context) {
        guard let view = controller.view as? OceanMTKView else { return }
        let renderer = context.coordinator.renderer
        let artChanged = renderer?.miniatureStyle != miniatureStyle
        renderer?.miniatureStyle = miniatureStyle
        if renderer?.isActive != active { motion.discardPending() }
        renderer?.isActive = active
        view.isPaused = !active
        controls.sensory.configure(soundEnabled: sound, hapticsEnabled: haptics && !reducedMotion, rendererActive: active)
        renderer?.motionProvider = { [weak motion] plan, timestamp in
            var samples = motion?.samples(for: plan, at: timestamp) ?? Array(repeating: MotionSample(), count: plan.count)
            if reducedMotion {
                for index in samples.indices { samples[index].acceleration *= 0.2 }
            }
            return samples
        }
        renderer?.motionDiagnosticsProvider = { [weak motion] in
            var snapshot = motion?.timingDiagnostics ?? [:]
            snapshot["reducedMotion"] = reducedMotion ? 1 : 0
            return snapshot
        }
        view.updateOrientation()
        if artChanged && view.isPaused { view.draw() }
    }

    static func dismantleUIViewController(_ controller: OceanViewController, coordinator: Coordinator) {
        guard let view = controller.view as? OceanMTKView else { return }
        view.isPaused = true
        coordinator.renderer?.isActive = false
        view.delegate = nil
        coordinator.renderer = nil
    }

    final class Coordinator { var renderer: LiquidRenderer? }
}

final class OceanViewController: UIViewController {
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // During layout the scene can still report its previous orientation.
        // Resolve the final orientation after UIKit finishes the transition.
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let view = self?.view as? OceanMTKView else { return }
            view.updateOrientation()
            if view.isPaused { view.draw() }
        }
    }
}

final class OceanMTKView: MTKView {
    weak var oceanRenderer: LiquidRenderer?
    override func layoutSubviews() {
        super.layoutSubviews()
        // Bound fill-rate while keeping the particle solver independent from screen pixels.
        let scale = min(window?.screen.scale ?? 2, 2)
        let requestedSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let oldRotation = oceanRenderer?.screenRotation
        let sizeChanged = drawableSize != requestedSize
        updateOrientation()
        if sizeChanged { drawableSize = requestedSize }
        if isPaused && (sizeChanged || oldRotation != oceanRenderer?.screenRotation) {
            draw()
        }
    }

    func updateOrientation() {
        guard let orientation = window?.windowScene?.interfaceOrientation else { return }
        switch orientation {
        case .portraitUpsideDown: oceanRenderer?.screenRotation = .pi
        case .landscapeLeft: oceanRenderer?.screenRotation = -.pi / 2
        case .landscapeRight: oceanRenderer?.screenRotation = .pi / 2
        default: oceanRenderer?.screenRotation = 0
        }
    }
}
