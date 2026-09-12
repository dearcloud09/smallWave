import Foundation

/// Offline material sequence from the shipping physics. It starts at the same
/// frozen shake state used in the still comparisons, then lets the liquid settle.
@main struct MaterialMotionSnapshot {
    static func main() throws {
        setbuf(stdout,nil)
        let folder=URL(fileURLWithPath:".build-cache/material-motion")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let sim=LiquidSimulation()
        for _ in 0..<600 { sim.advance(elapsed:1/120,motion:MotionSample()) }
        for _ in 0..<220 { sim.advance(elapsed:1/120,motion:MotionSample(gravity:SIMD3(0.65,-0.76,0))) }
        var motion=MotionSample()
        for i in 0..<120 {
            let t=Float(i)/120
            motion=MotionSample(acceleration:SIMD3(sin(t*24)*2.5,cos(t*17)*1.5,sin(t*13)*0.8))
            sim.advance(elapsed:1/120,motion:motion)
        }
        for frame in 0..<48 {
            if frame>0 {
                motion=MotionSample()
                for _ in 0..<5 { sim.advance(elapsed:1/120,motion:motion) }
            }
            let s:[String:Any] = [
                "particles":sim.particles.map { [Double($0.position.x),Double($0.position.y),Double($0.position.z)] },
                "bubbles":sim.bubbles.map { [Double($0.position.x),Double($0.position.y),Double($0.position.z),Double($0.radius)] },
                "boat":[Double(sim.boat.position.x),Double(sim.boat.position.y),Double(sim.boat.angle),Double(sim.boat.position.z)],
                "gravity":[Double(motion.safeGravity.x),Double(motion.safeGravity.y),Double(motion.safeGravity.z)],
                "spacing":Double(sim.spacing),"time":Double(sim.time),"energy":Double(sim.energy),"steps":sim.steps]
            let data=try JSONSerialization.data(withJSONObject:s,options:[.sortedKeys])
            if frame==0 {
                let frozen=try Data(contentsOf:URL(fileURLWithPath:".build-cache/optical-thickness/shake-state.json"))
                guard data==frozen else { throw NSError(domain:"Frozen motion mismatch",code:1) }
            }
            let name=String(format:"%03d",frame)
            let destination=folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
            try data.write(to:destination.appendingPathComponent("state.json"))
        }
        print("PASS 48 physics snapshots at24fps; first snapshot byte-identical to frozen shake")
    }
}
