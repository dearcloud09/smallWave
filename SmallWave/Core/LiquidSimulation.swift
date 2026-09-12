import Foundation
import simd

struct LiquidStepPlan {
    let count: Int
    let stepDuration: Float
    let remainder: Float

    var duration: Float { Float(count) * stepDuration }
}

struct MotionSample {
    var gravity = SIMD3<Float>(0, -1, 0)
    var acceleration = SIMD3<Float>.zero

    var safeGravity: SIMD3<Float> {
        guard gravity.x.isFinite, gravity.y.isFinite, gravity.z.isFinite else {
            return SIMD3(0, -1, 0)
        }
        let length = simd_length(gravity)
        return length > 0.001 ? gravity / max(1, length) : .zero
    }

    var safeAcceleration: SIMD3<Float> {
        guard acceleration.x.isFinite, acceleration.y.isFinite, acceleration.z.isFinite else {
            return .zero
        }
        return acceleration / max(1, simd_length(acceleration) / 3)
    }
}

struct LiquidParticle {
    var position: SIMD3<Float>
    var previous: SIMD3<Float>
    var velocity: SIMD3<Float> = .zero
}

struct AirBubble {
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var radius: Float
    var life: Float
}

struct FloatingBoat {
    var position = SIMD3<Float>(0.05, 0.03, 0)
    var velocity = SIMD3<Float>.zero
    var angle: Float = 0
    var angularVelocity: Float = 0
    var immersion: Float = 0
}

/// A shallow, three-dimensional particle volume in device coordinates.
/// PBF density constraints (Macklin/Müller), a local neighbour grid and XSPH viscosity.
/// This is a bounded physical prototype, not a calibrated two-fluid CFD model.
final class LiquidSimulation {
    static let defaultCohesionStrength: Float = 18
    static let defaultInterfaceBubbles = true
    let halfWidth: Float = 1
    let halfHeight: Float = 2.12
    let halfDepth: Float = 0.18
    let spacing: Float = 0.098
    let smoothingRadius: Float = 0.177
    let fixedStep: Float = 1 / 120
    let cohesionStrength: Float
    let interfaceBubbles: Bool
    private(set) var particles: [LiquidParticle] = []
    private(set) var bubbles: [AirBubble] = []
    private(set) var boat = FloatingBoat()
    private(set) var time: Float = 0
    private(set) var energy: Float = 0
    private(set) var steps = 0
    private(set) var maximumCohesionDisplacement: Float = 0
    private(set) var cohesionClampCount = 0

    private var accumulator: Float = 0
    private var lambda: [Float] = []
    private var corrections: [SIMD3<Float>] = []
    private var smoothedVelocity: [SIMD3<Float>] = []
    private var neighbours: [[Int]] = []
    private var heads: [Int] = []
    private var next: [Int] = []
    private var nx = 0
    private var ny = 0
    private var nz = 0
    private var randomState: UInt64 = 0x57415645
    private var bubbleCooldown: Float = 0

    private var mass: Float { spacing * spacing * spacing }
    private var h2: Float { smoothingRadius * smoothingRadius }
    private var poly6Scale: Float {
        315 / (64 * .pi * pow(smoothingRadius, 9))
    }
    private var spikyScale: Float { -45 / (.pi * pow(smoothingRadius, 6)) }

    init(cohesionStrength: Float = LiquidSimulation.defaultCohesionStrength,
         interfaceBubbles: Bool = LiquidSimulation.defaultInterfaceBubbles) {
        self.cohesionStrength = cohesionStrength.isFinite ? min(24, max(0, cohesionStrength)) : 0
        self.interfaceBubbles = interfaceBubbles
        reset()
    }

    func reset() {
        particles.removeAll(keepingCapacity: true)
        bubbles.removeAll(keepingCapacity: true)
        boat = FloatingBoat()
        time = 0
        energy = 0
        steps = 0
        maximumCohesionDisplacement = 0
        cohesionClampCount = 0
        accumulator = 0
        randomState = 0x57415645
        bubbleCooldown = 0

        var z = -halfDepth + spacing * 0.6
        while z <= halfDepth - spacing * 0.5 {
            var y = -halfHeight + spacing * 0.6
            while y < -0.12 {
                var x = -halfWidth + spacing * 0.6
                while x < halfWidth - spacing * 0.5 {
                    let p = SIMD3(x + (random() - 0.5) * 0.004,
                                  y + (random() - 0.5) * 0.004, z)
                    particles.append(LiquidParticle(position: p, previous: p))
                    x += spacing
                }
                y += spacing
            }
            z += spacing
        }
        lambda = Array(repeating: 0, count: particles.count)
        corrections = Array(repeating: .zero, count: particles.count)
        smoothedVelocity = corrections
        neighbours = Array(repeating: [], count: particles.count)
        next = Array(repeating: -1, count: particles.count)
        nx = Int(ceil(halfWidth * 2 / smoothingRadius)) + 1
        ny = Int(ceil(halfHeight * 2 / smoothingRadius)) + 1
        nz = Int(ceil(halfDepth * 2 / smoothingRadius)) + 1
        heads = Array(repeating: -1, count: nx * ny * nz)
        buildNeighbours()
    }

    /// Discard suspended time rather than simulating minutes on app resume.
    func suspend() { accumulator = 0 }

    /// Duration over which the next accepted frame will apply its motion sample.
    func simulatedDuration(forElapsed elapsed: Float) -> Float {
        stepPlan(forElapsed: elapsed).duration
    }

    func advance(elapsed: Float, motion: MotionSample, stepMotions: [MotionSample] = []) {
        guard elapsed.isFinite, elapsed > 0 else { return }
        let plan = stepPlan(forElapsed: elapsed)
        accumulator = plan.remainder
        // A complete batch supplies the measured direction for each fixed step.
        // Existing synthetic callers keep their constant-frame input behavior.
        for index in 0..<plan.count {
            substep(motion: stepMotions.count == plan.count ? stepMotions[index] : motion)
        }
    }

    func stepPlan(forElapsed elapsed: Float) -> LiquidStepPlan {
        guard elapsed.isFinite, elapsed > 0 else {
            return LiquidStepPlan(count: 0, stepDuration: fixedStep, remainder: accumulator)
        }
        var remaining = accumulator + min(elapsed, 1 / 20)
        var budget = 0
        while remaining >= fixedStep && budget < 6 {
            remaining -= fixedStep
            budget += 1
        }
        return LiquidStepPlan(count: budget, stepDuration: fixedStep,
                              remainder: budget == 6 ? 0 : remaining)
    }

    private func substep(motion: MotionSample) {
        let gravity = motion.safeGravity
        let force = (gravity - motion.safeAcceleration) * 5.8
        let dt = fixedStep
        for i in particles.indices {
            particles[i].previous = particles[i].position
            particles[i].velocity += force * dt
            particles[i].velocity *= 0.998
            particles[i].velocity = limited(particles[i].velocity, to: 5)
            particles[i].position += particles[i].velocity * dt
            constrain(&particles[i].position)
        }
        buildNeighbours()

        // Short-range cohesion. Equal/opposite pair forces keep
        // detached mass from becoming spray too readily; this is not a calibrated
        // surface-tension or second-fluid model. Density constraints below still
        // prevent compression. Strength zero preserves the original comparison path.
        if cohesionStrength > 0 {
            for i in corrections.indices { corrections[i] = .zero }
            for i in particles.indices {
                for j in neighbours[i] where j > i {
                    let delta = particles[j].position - particles[i].position
                    let radiusSquared = simd_length_squared(delta)
                    guard radiusSquared > spacing * spacing * 0.64, radiusSquared < h2 else { continue }
                    let radius = sqrt(radiusSquared)
                    let edge = 1 - radius / smoothingRadius
                    let ramp = min(1, (radius / spacing - 0.8) / 0.3)
                    let pair = delta / radius * (cohesionStrength * ramp * edge * edge)
                    corrections[i] += pair
                    corrections[j] -= pair
                }
            }
            let rawPeak = sqrt(corrections.reduce(Float(0)) { max($0, simd_length_squared($1)) }) * dt * dt
            let displacementLimit = spacing * 0.04
            let scale = min(1, displacementLimit / max(rawPeak, 0.0000001))
            // One common scale preserves pair symmetry, unlike per-particle caps.
            // Keep this extra correction small relative to the neighbour support.
            if scale < 1 { cohesionClampCount += 1 }
            maximumCohesionDisplacement = max(maximumCohesionDisplacement, rawPeak * scale)
            for i in particles.indices {
                particles[i].position += corrections[i] * (dt * dt * scale)
                constrain(&particles[i].position)
            }
        }

        // Keep constraints bounded; the neighbour list is valid over these small corrections.
        let kernelScale = poly6Scale
        let gradientScale = spikyScale
        let ownDensity = mass * kernelScale * h2 * h2 * h2
        let reference = kernel(radiusSquared: h2 * 0.09, scale: kernelScale)
        for _ in 0..<3 {
            for i in particles.indices {
                var density = ownDensity
                var gradientI = SIMD3<Float>.zero
                var gradientSum: Float = 0
                let p = particles[i].position
                let wall = depthWallSupport(at: p.z)
                density += wall.density
                gradientI.z += wall.gradient
                for j in neighbours[i] {
                    let delta = p - particles[j].position
                    let r2 = simd_length_squared(delta)
                    guard r2 < h2, r2 > 0.000001 else { continue }
                    density += mass * kernel(radiusSquared: r2, scale: kernelScale)
                    let r = sqrt(r2)
                    let gradient = delta * (mass * gradientScale * pow(smoothingRadius - r, 2) / r)
                    gradientI += gradient
                    gradientSum += simd_length_squared(gradient)
                }
                gradientSum += simd_length_squared(gradientI)
                // Free surfaces are allowed: don't contract under-dense particles into a jelly.
                lambda[i] = -max(density - 1, 0) / (gradientSum + 0.6)
            }
            for i in particles.indices {
                let p = particles[i].position
                var correction = SIMD3<Float>(0, 0, lambda[i] * depthWallSupport(at: p.z).gradient)
                for j in neighbours[i] {
                    let delta = p - particles[j].position
                    let r2 = simd_length_squared(delta)
                    guard r2 < h2, r2 > 0.000001 else { continue }
                    let r = sqrt(r2)
                    let ratio = kernel(radiusSquared: r2, scale: kernelScale) / reference
                    let antiClump = -0.000012 * ratio * ratio * ratio * ratio
                    correction += (lambda[i] + lambda[j] + antiClump)
                        * delta * (mass * gradientScale * pow(smoothingRadius - r, 2) / r)
                }
                corrections[i] = limited(correction, to: spacing * 0.16)
            }
            for i in particles.indices {
                particles[i].position += corrections[i]
                displaceAroundHull(&particles[i].position)
                constrain(&particles[i].position)
            }
        }
        var totalSpeed: Float = 0
        for i in particles.indices {
            particles[i].velocity = limited((particles[i].position - particles[i].previous) / dt, to: 5)
        }
        for i in particles.indices {
            var diffusion = SIMD3<Float>.zero
            let p = particles[i].position
            let velocity = particles[i].velocity
            for j in neighbours[i] {
                let r2 = simd_length_squared(p - particles[j].position)
                if r2 < h2 {
                    diffusion += (particles[j].velocity - velocity)
                        * (mass * kernel(radiusSquared: r2, scale: kernelScale))
                }
            }
            smoothedVelocity[i] = velocity + diffusion * 0.055
            totalSpeed += simd_length_squared(smoothedVelocity[i])
        }
        for i in particles.indices { particles[i].velocity = smoothedVelocity[i] }
        energy += (sqrt(totalSpeed / Float(particles.count)) - energy) * 0.08
        // Queries use corrected positions. Updating cell links does not change
        // the already-computed neighbour arrays used by the solver above.
        rebuildGrid()
        updateBoat(force: force, gravity: gravity, dt: dt)
        updateBubbles(gravity: gravity, acceleration: motion.safeAcceleration, dt: dt)
        time += dt
        steps += 1
    }

    private func rebuildGrid() {
        for i in heads.indices { heads[i] = -1 }
        for i in particles.indices {
            let c = cell(particles[i].position)
            let k = c.x + nx * (c.y + ny * c.z)
            next[i] = heads[k]
            heads[k] = i
        }
    }

    private func buildNeighbours() {
        rebuildGrid()
        for i in particles.indices {
            neighbours[i].removeAll(keepingCapacity: true)
            let c = cell(particles[i].position)
            for z in max(0, c.z - 1)...min(nz - 1, c.z + 1) {
                for y in max(0, c.y - 1)...min(ny - 1, c.y + 1) {
                    for x in max(0, c.x - 1)...min(nx - 1, c.x + 1) {
                        var j = heads[x + nx * (y + ny * z)]
                        while j >= 0 {
                            if i != j && simd_distance_squared(particles[i].position, particles[j].position) < h2 {
                                neighbours[i].append(j)
                            }
                            j = next[j]
                        }
                    }
                }
            }
        }
    }

    private func cell(_ p: SIMD3<Float>) -> SIMD3<Int> {
        SIMD3(max(0, min(nx - 1, Int((p.x + halfWidth) / smoothingRadius))),
              max(0, min(ny - 1, Int((p.y + halfHeight) / smoothingRadius))),
              max(0, min(nz - 1, Int((p.z + halfDepth) / smoothingRadius))))
    }

    private func kernel(radiusSquared r2: Float, scale: Float) -> Float {
        let q = max(0, h2 - r2)
        return scale * q * q * q
    }

    // Integrate the normalized poly6 kernel outside the two depth walls.
    // A position clamp alone lets the shallow volume collapse onto one wall,
    // then remain spread over the screen after gravity turns upright again.
    // Fixed wall support contributes to pressure only, never to blue liquid,
    // buoyancy queries or the rendered optical thickness.
    private func depthWallSupport(at z: Float) -> (density: Float, gradient: Float) {
        func cap(_ distance: Float) -> (Float, Float) {
            let t = max(0, distance / smoothingRadius)
            guard t < 1 else { return (0, 0) }
            let t2 = t*t
            var polynomial: Float = 1.0 / 9.0
            polynomial = -4.0 / 7.0 + t2 * polynomial
            polynomial = 6.0 / 5.0 + t2 * polynomial
            polynomial = -4.0 / 3.0 + t2 * polynomial
            let integral: Float = t * (1.0 + t2 * polynomial)
            let density = max(0, 0.5 - (315.0/256) * integral)
            let q = 1-t2
            let derivative = -(315.0/256) / smoothingRadius * q*q*q*q
            return (density, derivative)
        }
        let back = cap(z + halfDepth)
        let front = cap(halfDepth - z)
        return (back.0 + front.0, back.1 - front.1)
    }

    func density(at point: SIMD3<Float>) -> Float {
        // This small number of hull/bubble probes deliberately uses exact current positions,
        // independent from the slightly older neighbour grid used by the constraint iteration.
        let scale = poly6Scale
        var result: Float = 0
        for particle in particles {
            let r2 = simd_distance_squared(point, particle.position)
            if r2 < h2 { result += mass * kernel(radiusSquared: r2, scale: scale) }
        }
        return result
    }

    private func updateBoat(force: SIMD3<Float>, gravity: SIMD3<Float>, dt: Float) {
        let right = SIMD3<Float>(cos(boat.angle), sin(boat.angle), 0)
        let leftDensity = density(at: boat.position - right * 0.13)
        let rightDensity = density(at: boat.position + right * 0.13)
        let centerDensity = density(at: boat.position)
        boat.immersion = min(1, (leftDensity + rightDensity + centerDensity) / 3)
        // Buoyancy follows gravity; shaking contributes inertia rather than inverting buoyancy.
        var acceleration = force - gravity * (5.8 * 2.35 * boat.immersion)
        acceleration += -boat.velocity * (0.65 + boat.immersion * 2)
        boat.velocity = limited(boat.velocity + acceleration * dt, to: 3.5)
        boat.position += boat.velocity * dt
        let old = boat.position
        boat.position.x = max(-halfWidth + 0.22, min(halfWidth - 0.22, boat.position.x))
        boat.position.y = max(-halfHeight + 0.24, min(halfHeight - 0.24, boat.position.y))
        boat.position.z = max(-halfDepth + 0.07, min(halfDepth - 0.07, boat.position.z))
        if boat.position.x != old.x { boat.velocity.x *= -0.18 }
        if boat.position.y != old.y { boat.velocity.y *= -0.18 }
        if boat.position.z != old.z { boat.velocity.z *= -0.12 }

        let planarGravity = simd_length(SIMD2(gravity.x, gravity.y))
        if planarGravity > 0.12 {
            let upright = atan2(gravity.x, -gravity.y)
            var error = upright - boat.angle
            while error > .pi { error -= 2 * .pi }
            while error < -.pi { error += 2 * .pi }
            let waveTorque = (rightDensity - leftDensity) * 7
            boat.angularVelocity += (error * 7 * planarGravity + waveTorque - boat.angularVelocity * 3) * dt
        }
        boat.angularVelocity = max(-4, min(4, boat.angularVelocity))
        boat.angle += boat.angularVelocity * dt
        if abs(boat.angle) > .pi * 4 { boat.angle.formTruncatingRemainder(dividingBy: 2 * .pi) }
    }

    private func displaceAroundHull(_ point: inout SIMD3<Float>) {
        let d = point - boat.position
        let c = cos(boat.angle), s = sin(boat.angle)
        var q = SIMD3(c * d.x + s * d.y, -s * d.x + c * d.y, d.z)
        let radii = SIMD3<Float>(0.18, 0.047, 0.07)
        let scaled = q / radii
        let distance = simd_length(scaled)
        if distance < 1 && distance > 0.001 {
            q /= distance
            point = boat.position + SIMD3(c * q.x - s * q.y, s * q.x + c * q.y, q.z)
        }
    }

    private func updateBubbles(gravity: SIMD3<Float>, acceleration: SIMD3<Float>, dt: Float) {
        if interfaceBubbles {
            updateInterfaceBubbles(gravity: gravity, acceleration: acceleration, dt: dt)
            return
        }
        bubbleCooldown -= dt
        if simd_length(acceleration) > 0.65 && bubbleCooldown <= 0 && bubbles.count < 36 {
            let index = Int(random() * Float(particles.count - 1))
            let particle = particles[index]
            bubbles.append(AirBubble(position: particle.position,
                                     velocity: particle.velocity * 0.3,
                                     radius: 0.013 + random() * 0.022,
                                     life: 2.0 + random() * 2))
            bubbleCooldown = 0.065
        }
        for i in bubbles.indices {
            bubbles[i].velocity += (-gravity * 0.7 - bubbles[i].velocity * 1.8) * dt
            bubbles[i].position += bubbles[i].velocity * dt
            bubbles[i].life -= dt
            constrain(&bubbles[i].position)
        }
        bubbles.removeAll { $0.life <= 0 }
    }

    struct FlowSample {
        var density: Float = 0
        var velocity = SIMD3<Float>.zero
        var gradient = SIMD3<Float>.zero
    }

    func sampleFlow(at point: SIMD3<Float>) -> FlowSample {
        let scale = poly6Scale
        var sample = FlowSample()
        let c = cell(point)
        for z in max(0,c.z-1)...min(nz-1,c.z+1) {
            for y in max(0,c.y-1)...min(ny-1,c.y+1) {
                for x in max(0,c.x-1)...min(nx-1,c.x+1) {
                    var index = heads[x + nx * (y + ny * z)]
                    while index >= 0 {
                        let particle = particles[index]
                        index = next[index]
                        let delta = point - particle.position
                        let r2 = simd_length_squared(delta)
                        guard r2 < h2 else { continue }
                        let q = h2 - r2
                        let weight = mass * scale * q * q * q
                        sample.density += weight
                        sample.velocity += particle.velocity * weight
                        sample.gradient += delta * (-6 * mass * scale * q * q)
                    }
                }
            }
        }
        sample.velocity /= max(sample.density, 0.00001)
        return sample
    }

    private func surfaceStep(_ point: SIMD3<Float>, up: SIMD3<Float>, sample: FlowSample,
                             limit: Float) -> SIMD3<Float> {
        // Track the blue/clear boundary along buoyancy, rather than snapping to
        // the front/back vessel walls in this shallow volume. This is a visual
        // interface follower, not a simulated second phase or gas pressure solver.
        let derivative = simd_dot(sample.gradient, up)
        guard derivative < -0.2 else { return point }
        let distance = (sample.density - 0.45) / derivative
        return point - up * min(limit, max(-limit, distance))
    }

    private func updateInterfaceBubbles(gravity: SIMD3<Float>, acceleration: SIMD3<Float>, dt: Float) {
        let up = simd_length(gravity) > 0.05 ? -simd_normalize(gravity) : SIMD3<Float>(0,1,0)
        bubbleCooldown -= dt
        if simd_length(acceleration) > 0.65 && bubbleCooldown <= 0 && bubbles.count < 36 {
            // Reject interior births: look just above a fluid particle for a
            // low-density neighbour, then refine a point on the boundary.
            for _ in 0..<24 {
                let index = min(particles.count - 1, Int(random() * Float(particles.count)))
                let particle = particles[index]
                let outside = particle.position + up * (spacing * 1.2)
                // Empty space beyond the vessel is not a liquid/clear interface.
                guard abs(outside.x) < halfWidth, abs(outside.y) < halfHeight,
                      abs(outside.z) < halfDepth else { continue }
                guard density(at: outside) < 0.22 else { continue }
                var position = particle.position + up * (spacing * 0.35)
                for _ in 0..<3 {
                    position = surfaceStep(position, up: up, sample: sampleFlow(at: position), limit: spacing * 0.3)
                    constrain(&position)
                }
                let flow = sampleFlow(at: position)
                guard flow.density > 0.12 && flow.density < 0.8 else { continue }
                let size = random()
                bubbles.append(AirBubble(position: position, velocity: flow.velocity,
                    radius: 0.015 + size * size * 0.055, life: 2 + random() * 2))
                break
            }
            bubbleCooldown = 0.065
        }
        let response = 1 - exp(-8 * dt)
        for i in bubbles.indices {
            let flow = sampleFlow(at: bubbles[i].position)
            let targetVelocity = flow.velocity + up * 0.12
            bubbles[i].velocity += (targetVelocity - bubbles[i].velocity) * response
            bubbles[i].velocity = limited(bubbles[i].velocity, to: 3.5)
            bubbles[i].position += bubbles[i].velocity * dt
            let moved = sampleFlow(at: bubbles[i].position)
            if moved.density > 0.05 {
                bubbles[i].position = surfaceStep(bubbles[i].position, up: up, sample: moved, limit: spacing * 0.15)
            }
            bubbles[i].life -= dt
            constrain(&bubbles[i].position)
        }
        // Tangential separation allows a close layer without collapsing every
        // bubble onto one point. Different depths can still overlap in projection.
        for i in bubbles.indices {
            for j in 0..<i {
                let delta = bubbles[i].position - bubbles[j].position
                let distance = simd_length(delta)
                let separation = (bubbles[i].radius + bubbles[j].radius) * 0.85
                guard distance < separation else { continue }
                let tangent = delta - up * simd_dot(delta, up)
                let length = simd_length(tangent)
                guard length > 0.0001 else { continue }
                let push = tangent / length * ((separation - distance) * response * 0.5)
                bubbles[i].position += push
                bubbles[j].position -= push
            }
        }
        for i in bubbles.indices { constrain(&bubbles[i].position) }
        bubbles.removeAll { $0.life <= 0 }
    }

    private func constrain(_ p: inout SIMD3<Float>) {
        let margin = spacing * 0.35
        p = simd_clamp(p, SIMD3(-halfWidth + margin, -halfHeight + margin, -halfDepth + margin),
                      SIMD3(halfWidth - margin, halfHeight - margin, halfDepth - margin))
    }

    private func limited(_ v: SIMD3<Float>, to limit: Float) -> SIMD3<Float> {
        v / max(1, simd_length(v) / limit)
    }

    private func random() -> Float {
        randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
        return Float((randomState >> 40) & 0xffffff) / Float(0xffffff)
    }
}
