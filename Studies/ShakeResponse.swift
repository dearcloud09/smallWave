import Foundation
import simd

/// Offline diagnostic only. Compile with the instrumented frozen simulation,
/// never with the app target. Device sensor amplitudes are not measured here.
@main struct ShakeResponse {
    static func main() throws {
        let args = CommandLine.arguments
        guard (4...7).contains(args.count), let scale = Float(args[1]),
              ["translation", "roll", "pitch"].contains(args[2]),
              scale.isFinite && scale > 0 && scale <= 70 else {
            fatalError("usage: shake-response force-scale translation|roll|pitch output-directory [frequency-Hz] [raw-amplitude-g] [input-cap-g]")
        }
        let mode = args[2], output = URL(fileURLWithPath: args[3])
        let frequency = args.count > 4 ? (Float(args[4]) ?? .nan) : 2
        let amplitude = args.count > 5 ? (Float(args[5]) ?? .nan) : 1
        let inputCap = args.count > 6 ? (Float(args[6]) ?? .nan) : 3
        guard frequency > 0 && frequency <= 6 && amplitude >= 0 && amplitude <= 24,
              inputCap > 0 && inputCap <= 24 else { fatalError("Invalid fixture") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let simulation = LiquidSimulation(diagnosticForceScale: scale, diagnosticAccelerationCap: inputCap)
        let count = simulation.particles.count
        var rows = "t,gx,gy,gz,ax,comX,comY,comZ,topY,leftTop,rightTop,energy,wallFraction,cpuMs,predictionCaps,constraintCaps\n"
        var timings: [Double] = []
        var finite = true
        var metrics: [[String: Any]] = []
        var comCos: Float = 0, comSin: Float = 0, inputCos: Float = 0, inputSin: Float = 0
        var responseSamples = 0, rawOverCapSamples = 0
        let began = ProcessInfo.processInfo.systemUptime
        // 2 s settling, 3 s / six cycles at 2 Hz, 3 s upright rest.
        for step in 0..<960 {
            let t = Float(step) / 120
            var motion = MotionSample()
            if t >= 2 && t < 5 {
                let phase = (t - 2) * 2 * Float.pi * frequency
                if mode == "translation" {
                    motion.acceleration.x = sin(phase) * amplitude
                } else {
                    let angle = sin(phase) * Float.pi / 4
                    if mode == "roll" { motion.gravity = SIMD3(sin(angle), -cos(angle), 0) }
                    else { motion.gravity = SIMD3(0, -cos(angle), sin(angle)) }
                }
            }
            let start = ProcessInfo.processInfo.systemUptime
            simulation.advance(elapsed: simulation.fixedStep, motion: motion)
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            timings.append(ms)
            var sum = SIMD3<Float>.zero
            var top: Float = -10, left: Float = -10, right: Float = -10
            var wall = 0
            for p in simulation.particles {
                sum += p.position
                top = max(top, p.position.y)
                if p.position.x < -0.7 { left = max(left, p.position.y) }
                if p.position.x > 0.7 { right = max(right, p.position.y) }
                if abs(p.position.x) > 0.93 { wall += 1 }
                finite = finite && p.position.x.isFinite && p.position.y.isFinite && p.position.z.isFinite
                    && simd_length(p.velocity).isFinite
            }
            let center = sum / Float(count), wallFraction = Float(wall) / Float(count)
            if mode == "translation", t >= 3 && t < 5 {
                let angle = (t - 2) * 2 * Float.pi * frequency
                // The solver clips each instantaneous reading; it does not
                // shrink the entire sine wave to the cap's amplitude.
                let appliedInput = max(-inputCap, min(inputCap, motion.acceleration.x))
                comCos += center.x * cos(angle); comSin += center.x * sin(angle)
                inputCos += appliedInput * cos(angle); inputSin += appliedInput * sin(angle)
                responseSamples += 1
                if abs(motion.acceleration.x) > inputCap { rawOverCapSamples += 1 }
            }
            let floats: [Float] = [t, motion.gravity.x, motion.gravity.y, motion.gravity.z,
                motion.acceleration.x, center.x, center.y, center.z, top, left, right,
                simulation.energy, wallFraction, Float(ms)]
            rows += floats.map { String($0) }.joined(separator:",")
            rows += ",\(simulation.predictionCaps),\(simulation.constraintCaps)\n"
            if step == 239 || step == 599 || step == 959 {
                metrics.append(["t":t,"center":[center.x,center.y,center.z],"topY":top,"energy":simulation.energy])
                print("\(mode) scale=\(scale) t=\(t) center=\(center) energy=\(simulation.energy)")
            }
        }
        timings.sort()
        let componentScale = responseSamples > 0 ? 2 / Float(responseSamples) : 0
        let comFundamentalAmplitude = componentScale * sqrt(comCos * comCos + comSin * comSin)
        let inputFundamentalAmplitude = componentScale * sqrt(inputCos * inputCos + inputSin * inputSin)
        let summary: [String: Any] = ["mode":mode,"forceScale":scale,"frequencyHz":frequency,"rawAccelerationAmplitudeG":amplitude,"particles":count,
            "inputAccelerationCapG":inputCap,"inputFundamentalAmplitudeG":inputFundamentalAmplitude,
            "comFundamentalAmplitude":comFundamentalAmplitude,"responseWindowSeconds":"3-5",
            "rawOverInputCapFraction":responseSamples > 0 ? Float(rawOverCapSamples) / Float(responseSamples) : 0,
            "restEnergy":simulation.energy,
            "steps":simulation.steps,"finite":finite,"cpuMedianStepMs":timings[timings.count/2],
            "cpuP95StepMs":timings[Int(Double(timings.count)*0.95)],
            "wallSeconds":ProcessInfo.processInfo.systemUptime-began,
            "predictionCapFraction":Double(simulation.predictionCaps)/Double(count*simulation.steps),
            "constraintCapFraction":Double(simulation.constraintCaps)/Double(count*simulation.steps),
            "checkpoints":metrics,"note":"Synthetic input; desktop CPU time is not iPhone FPS. Rotation modes change gravity only, matching the current motion model's missing angular inertia."]
        try rows.write(to:output.appendingPathComponent("trace.csv"),atomically:true,encoding:.utf8)
        try JSONSerialization.data(withJSONObject:summary, options:[.prettyPrinted,.sortedKeys])
            .write(to:output.appendingPathComponent("summary.json"))
        print(String(data:try JSONSerialization.data(withJSONObject:summary,options:[.sortedKeys]),encoding:.utf8)!)
    }
}
