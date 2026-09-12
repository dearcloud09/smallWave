import Foundation
import CryptoKit

/// Fixed numerical acceptance contract. No renderer, GPU, real-fluid calibration,
/// automatic phase clamp, or global mass correction participates in these checks.
@main
struct TwoPhaseCoreCheck {
    typealias Simulation = TwoPhaseSimulation
    static let rangeTolerance = 1e-12
    static let massTolerance = 1e-9
    static let divergenceTolerance = 1e-6
    static var notes = [String]()
    static var failures = [String]()
    static var rows = ["fixture,scheme,step,time,blue_amount,minimum,maximum,tracked_amount,centroid_x,centroid_y,interface_width,components,max_div_dt,mass_error"]
    static var directory = URL(fileURLWithPath: ".build-cache/previews/two-phase")

    static func check(_ name: String, _ passed: Bool, _ evidence: String) {
        let line = "\(passed ? "PASS":"FAIL") \(name): \(evidence)"
        notes.append(line); print(line)
        if !passed { failures.append(name) }
    }
    static func maximumDifference(_ a: [Double], _ b: [Double]) -> Double {
        zip(a,b).reduce(0) { max($0,abs($1.0-$1.1)) }
    }
    struct Component {
        let cellCount: Int
        let coreAmount: Double
        let peak: Double
        let centroid: Simulation.Vector
    }
    static func components(_ c: [Double], nx: Int, ny: Int, dx: Double, dy: Double,
                           clear: Bool = false) -> [Component] {
        let tracked = clear ? c.map { 1-$0 } : c
        var visited = [Bool](repeating:false,count:c.count), found = [Component]()
        for start in c.indices where !visited[start] && (clear ? 1-c[start]:c[start]) >= 0.5 {
            var queue = [start], cursor = 0; visited[start] = true
            var amount = 0.0, peak = 0.0, x = 0.0, y = 0.0
            while cursor < queue.count {
                let k = queue[cursor], i = k % nx, j = k / nx, value = tracked[k]; cursor += 1
                let mass = value*dx*dy
                amount += mass; peak = max(peak,value)
                x += mass*(Double(i)+0.5)*dx; y += mass*(Double(j)+0.5)*dy
                var adjacent = [Int]()
                if i > 0 { adjacent.append(k-1) }; if i+1 < nx { adjacent.append(k+1) }
                if j > 0 { adjacent.append(k-nx) }; if j+1 < ny { adjacent.append(k+nx) }
                for next in adjacent where !visited[next] && (clear ? 1-c[next]:c[next]) >= 0.5 {
                    visited[next] = true; queue.append(next)
                }
            }
            found.append(Component(cellCount:queue.count,coreAmount:amount,peak:peak,
                                   centroid:.init(x:amount > 0 ? x/amount:0,y:amount > 0 ? y/amount:0)))
        }
        return found
    }
    static func componentCount(_ c: [Double], nx: Int, ny: Int, dx: Double, dy: Double,
                               clear: Bool = false) -> Int {
        components(c,nx:nx,ny:ny,dx:dx,dy:dy,clear:clear).count
    }
    static func resolvedCoreRetained(initial: [Component], current: [Component]) -> Bool {
        guard !initial.isEmpty, current.count == initial.count else { return false }
        let initialMinimumAmount = initial.map(\.coreAmount).min() ?? .infinity
        let initialMinimumCells = initial.map(\.cellCount).min() ?? Int.max
        return initial.allSatisfy { $0.cellCount >= 16 && $0.peak >= 0.9 }
            && current.allSatisfy { $0.cellCount >= 16
                && Double($0.cellCount) >= 0.5*Double(initialMinimumCells)
                && $0.coreAmount >= 0.5*initialMinimumAmount && $0.peak >= 0.9 }
    }
    static func individualCentroidError(initial: [Component], final: [Component]) -> Double {
        guard initial.count == final.count, !initial.isEmpty else { return .infinity }
        func distance(_ a: Component, _ b: Component) -> Double {
            hypot(a.centroid.x-b.centroid.x,a.centroid.y-b.centroid.y)
        }
        if initial.count == 1 { return distance(initial[0],final[0]) }
        if initial.count == 2 {
            return min(max(distance(initial[0],final[0]),distance(initial[1],final[1])),
                       max(distance(initial[0],final[1]),distance(initial[1],final[0])))
        }
        return .infinity
    }
    static func seed(_ simulation: Simulation, _ inside: (Double,Double) -> Bool) throws {
        try simulation.setPhase { x,y in
            var amount = 0.0
            for j in 0..<4 { for i in 0..<4 {
                if inside(x+(Double(i)+0.5-2)*simulation.dx/4,
                          y+(Double(j)+0.5-2)*simulation.dy/4) { amount += 1.0/16 }
            }}
            return amount
        }
    }
    static func snapshot(_ simulation: Simulation, name: String, fixtureTime: Double? = nil) throws {
        let value: [String:Any] = ["nx":simulation.nx,"ny":simulation.ny,"width":simulation.width,
            "height":simulation.height,"fixtureTime":fixtureTime ?? simulation.time,
            "simulationTime":simulation.time,"phase":simulation.phase,
            "u":simulation.u,"v":simulation.v,"densityContrast":simulation.densityContrast]
        try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:directory.appendingPathComponent(name+".json"))
    }
    static func record(_ simulation: Simulation, fixture: String, scheme: String, step: Int,
                       time: Double, initialAmount: Double, clear: Bool = false, div: Double = 0) {
        let blue = simulation.metrics(), tracked = simulation.metrics(clear:clear)
        let error = abs(blue.amount-initialAmount)/(simulation.width*simulation.height)
        let count = componentCount(simulation.phase,nx:simulation.nx,ny:simulation.ny,
                                   dx:simulation.dx,dy:simulation.dy,clear:clear)
        rows.append("\(fixture),\(scheme),\(step),\(time),\(blue.amount),\(blue.minimum),\(blue.maximum),\(tracked.amount),\(tracked.centroid.x),\(tracked.centroid.y),\(tracked.interfaceWidth),\(count),\(div),\(error)")
    }
    static func invariants(_ simulation: Simulation, initialAmount: Double) -> Bool {
        let m = simulation.metrics()
        return m.minimum >= -rangeTolerance && m.maximum <= 1+rangeTolerance
            && abs(m.amount-initialAmount)/(simulation.width*simulation.height) <= massTolerance
            && simulation.wallFluxInfinity() == 0
    }

    static func projectionFixture() throws {
        let sim = Simulation(), dt = 1.0/120
        try sim.setStreamfunction { x,y in
            if x == 0 || y == 0 || x == sim.width || y == sim.height { return 0 }
            return 0.15*pow(sin(.pi*x/sim.width),2)*pow(sin(.pi*y/sim.height),2)
        }
        let expectedU = sim.u, expectedV = sim.v
        func potential(_ x: Double, _ y: Double) -> Double {
            cos(.pi*x/sim.width)*cos(2 * .pi*y/sim.height)
        }
        try sim.setVelocity(horizontal: { x,y in
            let i = Int((x/sim.dx).rounded()), j = Int((y/sim.dy-0.5).rounded())
            return expectedU[i+(sim.nx+1)*j]+(potential(x+0.5*sim.dx,y)-potential(x-0.5*sim.dx,y))/sim.dx
        }, vertical: { x,y in
            let i = Int((x/sim.dx-0.5).rounded()), j = Int((y/sim.dy).rounded())
            return expectedV[i+sim.nx*j]+(potential(x,y+0.5*sim.dy)-potential(x,y-0.5*sim.dy))/sim.dy
        })
        let result = try sim.project(dt:dt)
        let velocityError = max(maximumDifference(sim.u,expectedU),maximumDifference(sim.v,expectedV))
        check("MAC gradient removal preserves discrete curl",velocityError < 1e-9,"max face error=\(velocityError), iterations=\(result.iterations)")
        check("pressure residual and actual divergence",result.scaledDivergence <= divergenceTolerance
              && result.residualInfinity*dt < 1e-12 && result.residualDivergenceDifference*dt < 1e-12
              && result.wallFluxInfinity == 0,
              "dt*div=\(result.scaledDivergence), dt*residual=\(result.residualInfinity*dt), correspondence=\(result.residualDivergenceDifference*dt), wall=\(result.wallFluxInfinity)")
    }

    static func equilibriumFixture(contrast: Double) throws {
        let sim = Simulation(nx:32,ny:64,width:1,height:2,densityContrast:contrast)
        if contrast == 0 {
            try seed(sim) { x,y in hypot(x-0.42,y-0.72)<0.18 || (x>0.65 && y<0.4) }
        } else { try sim.setPhase { _,y in y<0.8125 ? 1:0 } }
        let initial = sim.phase, amount = sim.metrics().amount
        var maxSpeed = 0.0, maxDiv = 0.0, allValid = true
        for step in 0..<48 {
            let result = try sim.step(dt:1/120,gravity:.init(x:contrast == 0 ? 2:0,y:-3))
            maxDiv = max(maxDiv,result.scaledDivergence)
            maxSpeed = max(maxSpeed,sim.u.map(abs).max() ?? 0,sim.v.map(abs).max() ?? 0)
            allValid = allValid && invariants(sim,initialAmount:amount)
            if step % 12 == 11 { record(sim,fixture:contrast == 0 ? "zero-contrast":"stable-layer",scheme:"fct",step:step+1,time:sim.time,initialAmount:amount,div:result.scaledDivergence) }
        }
        let error = maximumDifference(sim.phase,initial)
        check(contrast == 0 ? "zero contrast produces no phase-driven motion":"stable horizontal stratification",
              allValid && maxSpeed < 1e-9 && error < 1e-10 && maxDiv <= divergenceTolerance,
              "max speed=\(maxSpeed), phase error=\(error), max dt*div=\(maxDiv), mass error=\(abs(sim.metrics().amount-amount)/(sim.width*sim.height))")
    }

    struct AdvectionResult {
        let error: Double
        let width: Double
        let centroidError: Double
        let valid: Bool
    }
    static func advectionFixture(name: String, clear: Bool, expectedComponents: Int,
                                 scheme: Simulation.Transport) throws -> AdvectionResult {
        let sim = Simulation(nx:64,ny:64,width:1,height:1,densityContrast:0)
        try seed(sim) { x,y in
            if clear { return hypot(x-0.38,y-0.62) >= 0.11 }
            return hypot(x-0.31,y-0.46)<0.095 || hypot(x-0.69,y-0.55)<0.095
        }
        let initial = sim.phase, start = sim.metrics(clear:clear), amount = sim.metrics().amount
        let initialComponents = components(initial,nx:sim.nx,ny:sim.ny,dx:sim.dx,dy:sim.dy,clear:clear)
        let initialResolved = resolvedCoreRetained(initial:initialComponents,current:initialComponents)
        check(name+" "+scheme.rawValue+" initial resolved components",
              initialResolved && initialComponents.count == expectedComponents,
              "components=\(initialComponents.count), cells=\(initialComponents.map { $0.cellCount }), core amounts=\(initialComponents.map { $0.coreAmount }), peaks=\(initialComponents.map { $0.peak })")
        let steps = 256, dt = 1.6/Double(steps)
        let radiusLimit = clear ? 0.11 : 0.095
        var maxMassError = 0.0, minPhase = 1.0, maxPhase = 0.0, maxDiv = 0.0, maxWallFlux = 0.0, topologyValid = true
        var resolvedThroughout = initialResolved
        var maximumInterfaceWidth = start.interfaceWidth
        record(sim,fixture:name,scheme:scheme.rawValue,step:0,time:0,initialAmount:amount,clear:clear)
        try snapshot(sim,name:name+"-"+scheme.rawValue+"-initial",fixtureTime:0)
        for step in 0..<steps {
            let factor = cos(.pi*(Double(step)+0.5)/Double(steps))
            try sim.setStreamfunction { x,y in
                if x == 0 || y == 0 || x == 1 || y == 1 { return 0 }
                return factor*0.12*pow(sin(.pi*x),2)*pow(sin(.pi*y),2)
            }
            maxWallFlux = max(maxWallFlux,sim.wallFluxInfinity())
            let div = dt*(sim.divergence().map(abs).max() ?? 0)
            maxDiv = max(maxDiv,div)
            try sim.advectPhase(dt:dt,scheme:scheme)
            let m = sim.metrics()
            maxMassError = max(maxMassError,abs(m.amount-amount))
            minPhase = min(minPhase,m.minimum); maxPhase = max(maxPhase,m.maximum)
            // Smooth prescribed flow must not create topology changes in these
            // resolved shapes. This is not a test of physical breakup or merging.
            let currentComponents = components(sim.phase,nx:sim.nx,ny:sim.ny,dx:sim.dx,dy:sim.dy,clear:clear)
            topologyValid = topologyValid && currentComponents.count == expectedComponents
            resolvedThroughout = resolvedThroughout && resolvedCoreRetained(initial:initialComponents,current:currentComponents)
            maximumInterfaceWidth = max(maximumInterfaceWidth,m.interfaceWidth)
            if (step+1) % 32 == 0 {
                record(sim,fixture:name,scheme:scheme.rawValue,step:step+1,time:Double(step+1)*dt,initialAmount:amount,clear:clear,div:div)
            }
            if step+1 == steps/2 { try snapshot(sim,name:name+"-"+scheme.rawValue+"-half",fixtureTime:0.8) }
        }
        let end = sim.metrics(clear:clear)
        let finalComponents = components(sim.phase,nx:sim.nx,ny:sim.ny,dx:sim.dx,dy:sim.dy,clear:clear)
        let resolved = resolvedThroughout && resolvedCoreRetained(initial:initialComponents,current:finalComponents)
        let individualCenterError = individualCentroidError(initial:initialComponents,final:finalComponents)
        let error = zip(sim.phase,initial).reduce(0) { $0+abs($1.0-$1.1)*sim.dx*sim.dy }
        let centerError = hypot(end.centroid.x-start.centroid.x,end.centroid.y-start.centroid.y)
        let peak = clear ? 1-(sim.phase.min() ?? 1):(sim.phase.max() ?? 0)
        let valid = maxMassError <= massTolerance && minPhase >= -rangeTolerance && maxPhase <= 1+rangeTolerance
            && maxDiv <= divergenceTolerance && maxWallFlux == 0 && topologyValid && peak > 0.5
        let shapeGuards = resolved && individualCenterError <= 1.5*sim.dx && maximumInterfaceWidth <= radiusLimit
        if scheme == .fct {
            check(name+" "+scheme.rawValue+" conservation, bounds and resolved-core guards",valid && shapeGuards,
                  "max mass/domain=\(maxMassError), range=[\(minPhase),\(maxPhase)], max dt*div=\(maxDiv), max wall flux=\(maxWallFlux), topology held=\(topologyValid), resolved all steps=\(resolved), individual centroid error=\(individualCenterError), max interface width=\(maximumInterfaceWidth), limit=\(radiusLimit), phase peak=\(peak)")
        } else {
            check(name+" donor conservation, bounds, divergence and wall flux",valid,
                  "max mass/domain=\(maxMassError), range=[\(minPhase),\(maxPhase)], max dt*div=\(maxDiv), max wall flux=\(maxWallFlux), topology held=\(topologyValid), phase peak=\(peak)")
            notes.append("MEASURE \(name) donor resolved-core guards: resolved all steps=\(resolved), individual centroid error=\(individualCenterError), max interface width=\(maximumInterfaceWidth), limit=\(radiusLimit)")
            print(notes.last!)
        }
        notes.append("MEASURE \(name) \(scheme.rawValue): L1/domain=\(error), global centroid return error=\(centerError), individual centroid error=\(individualCenterError), initial width=\(start.interfaceWidth), final width=\(end.interfaceWidth), max width=\(maximumInterfaceWidth), final width/cell=\(end.interfaceWidth/sim.dx)")
        print(notes.last!)
        try snapshot(sim,name:name+"-"+scheme.rawValue+"-final",fixtureTime:1.6)
        return AdvectionResult(error:error,width:end.interfaceWidth,centroidError:centerError,valid:valid)
    }

    static func forcedFixture(name: String, gravity: Simulation.Vector) throws {
        let sim = Simulation(nx:40,ny:80,width:1,height:2,densityContrast:0.18)
        // An isolated resolved dense region makes the sign of buoyancy observable.
        // A perfectly flat inverted layer could remain at an unstable equilibrium.
        try seed(sim) { x,y in hypot(x-0.45,y-0.75)<0.17 }
        let start = sim.metrics(), dt = 1.0/240
        var valid = true, maxDiv = 0.0, maxMassError = 0.0
        for step in 0..<240 {
            let p = try sim.step(dt:dt,gravity:gravity)
            valid = valid && invariants(sim,initialAmount:start.amount)
            maxDiv = max(maxDiv,p.scaledDivergence)
            maxMassError = max(maxMassError,abs(sim.metrics().amount-start.amount)/(sim.width*sim.height))
            if (step+1) % 24 == 0 { record(sim,fixture:name,scheme:"fct",step:step+1,time:sim.time,initialAmount:start.amount,div:p.scaledDivergence) }
        }
        let end = sim.metrics()
        let displacement = Simulation.Vector(x:end.centroid.x-start.centroid.x,y:end.centroid.y-start.centroid.y)
        let along = (displacement.x*gravity.x+displacement.y*gravity.y)/hypot(gravity.x,gravity.y)
        check(name+" bounded coupled buoyancy",valid && maxDiv <= divergenceTolerance && along > 0.001,
              "centroid delta=(\(displacement.x),\(displacement.y)), along effective gravity=\(along), max mass/domain=\(maxMassError), max dt*div=\(maxDiv)")
        try snapshot(sim,name:name+"-final",fixtureTime:sim.time)
    }

    /// This constructed input preserves two tracked components, total blue amount,
    /// and range. One component is resolved; the other is one cell plus diffuse
    /// sub-threshold phase, which must not pass as retained.
    static func diffuseResidueNegativeFixture() throws {
        let initial = Simulation(nx:64,ny:64,width:1,height:1,densityContrast:0)
        try seed(initial) { x,y in
            hypot(x-0.31,y-0.46)<0.095 || hypot(x-0.69,y-0.55)<0.095
        }
        let start = components(initial.phase,nx:initial.nx,ny:initial.ny,dx:initial.dx,dy:initial.dy)
        let amount = initial.metrics().amount, area = initial.width*initial.height, cellArea = initial.dx*initial.dy
        let retained = Simulation(nx:64,ny:64,width:1,height:1,densityContrast:0)
        try seed(retained) { x,y in hypot(x-0.69,y-0.55)<0.095 }
        let zeroCells = retained.phase.indices.filter { $0 != 0 && retained.phase[$0] == 0 }.count
        let diffuse = (amount-retained.metrics().amount-cellArea)/(Double(zeroCells)*cellArea)
        let residue = Simulation(nx:64,ny:64,width:1,height:1,densityContrast:0)
        try residue.setPhase { x,y in
            let i = Int(x/residue.dx), j = Int(y/residue.dy), k = i+residue.nx*j
            if i == 0 && j == 0 { return 1 }
            return retained.phase[k] == 0 ? diffuse:retained.phase[k]
        }
        let end = components(residue.phase,nx:residue.nx,ny:residue.ny,dx:residue.dx,dy:residue.dy)
        let massError = abs(residue.metrics().amount-amount)/area
        let rangeValid = residue.metrics().minimum >= -rangeTolerance && residue.metrics().maximum <= 1+rangeTolerance
        check("negative diffuse residue is rejected by resolved-core guard",
              rangeValid && massError <= massTolerance && !resolvedCoreRetained(initial:start,current:end),
              "constructed input; range valid=\(rangeValid), mass/domain=\(massError), initial components=\(start.count), residue components=\(end.count), residue cells=\(end.map { $0.cellCount }), residue peaks=\(end.map { $0.peak }), diffuse phase=\(diffuse)")
    }

    static func run() throws {
        try projectionFixture()
        try equilibriumFixture(contrast:0.15)
        try equilibriumFixture(contrast:0)
        for (name,clear,count) in [("clear-pocket",true,1),("two-blue-regions",false,2)] {
            let donor = try advectionFixture(name:name,clear:clear,expectedComponents:count,scheme:.donor)
            let fct = try advectionFixture(name:name,clear:clear,expectedComponents:count,scheme:.fct)
            check(name+" FCT versus donor",fct.valid && fct.error < donor.error && fct.width < donor.width
                  && fct.centroidError < 1.5/64,
                  "L1 \(donor.error) -> \(fct.error), width \(donor.width) -> \(fct.width), FCT centroid return=\(fct.centroidError)")
        }
        try diffuseResidueNegativeFixture()
        try forcedFixture(name:"tilted-input",gravity:.init(x:2,y:-2))
        try forcedFixture(name:"inverted-input",gravity:.init(x:0,y:3))
    }
    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data:try Data(contentsOf:url)).map { String(format:"%02x",$0) }.joined()
    }
    static func writeProvenance(completedAt: Date) throws {
        let inputs = ["Studies/TwoPhaseSimulation.swift","Tests/TwoPhaseCoreCheck.swift","scripts/test-two-phase.sh"]
        var inputHashes = [String:String]()
        for path in inputs { inputHashes[path] = try sha256(URL(fileURLWithPath:path)) }
        let fixtureURLs = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "contract.json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var fixtureHashes = [String:String]()
        for url in fixtureURLs { fixtureHashes[url.lastPathComponent] = try sha256(url) }
        let artifacts: [String:Any] = ["contract.json":try sha256(directory.appendingPathComponent("contract.json")),
                                       "metrics.csv":try sha256(directory.appendingPathComponent("metrics.csv")),
                                       "checks.txt":try sha256(directory.appendingPathComponent("checks.txt")),
                                       "fixtureJSON":fixtureHashes]
        let completed = ISO8601DateFormatter().string(from:completedAt)
        let provenance: [String:Any] = ["algorithm":"SHA-256 (CryptoKit)","completedAt":completed,
                                         "inputSHA256":inputHashes,"artifactSHA256":artifacts]
        try JSONSerialization.data(withJSONObject:provenance,options:[.prettyPrinted,.sortedKeys])
            .write(to:directory.appendingPathComponent("provenance.json"))
    }
    static func main() {
        setbuf(stdout,nil)
        let root = directory
        let stamp = ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-")
        directory = root.appendingPathComponent("run-"+stamp+"-"+String(UUID().uuidString.prefix(6)))
        let began = Date()
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let contract: [String:Any] = ["arithmetic":"Double CPU","phaseRangeTolerance":rangeTolerance,
                "massOverDomainTolerance":massTolerance,"dtMaxDivergenceVeto":divergenceTolerance,
                "standaloneProjectionTarget":1e-14,"phaseStepProjectionTarget":1e-16,
                "phaseClamp":false,"globalMassRepair":false,
                "transport":"donor / MC face reconstruction with conservative FCT + SSPRK2",
                "resolvedCoreGuard":["trackedThreshold":0.5,"minimumCells":16,"minimumInitialComponentRetention":0.5,
                                     "minimumPeak":0.9,"appliesTo":"FCT veto; donor measurement only",
                                     "reason":"Reject one-cell residue or diffuse sub-threshold loss while preserving amount and topology count."],
                "componentCentroidGuard":["maximumError":"1.5 * dx","matching":"one-to-one nearest permutation for one or two components",
                                          "appliesTo":"FCT veto; donor measurement only"],
                "interfaceWidthGuard":["clearPocketMaximum":0.11,"twoBlueRegionsMaximum":0.095,
                                       "measurement":"maximum over every advection step","appliesTo":"FCT veto; donor measurement only",
                                       "reason":"Reject a region connected only after spreading by its initial radius; this is not exact shape validation."],
                "l1":"MEASURE only, including donor comparison; it is not a shape-pass criterion.",
                "scope":"Numerical unit; no physical split/merge, surface tension, renderer, material calibration or iPhone validation"]
            try JSONSerialization.data(withJSONObject:contract,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("contract.json"))
            try run()
        } catch {
            check("execution completed",false,String(describing:error))
        }
        notes.append("NOT_RUN: real-toy comparison, physical breakup/coalescence, pressure/free-surface paired study, iPhone/GPU, surface tension, viscosity calibration.")
        notes.append("LIMIT: momentum uses dissipative semi-Lagrangian transport; phase FCT is bounded/conservative but not exact geometric interface transport.")
        notes.append("CPU wall seconds=\(Date().timeIntervalSince(began)); failed checks=\(failures.count); output=\(directory.path)")
        do {
            try notes.joined(separator:"\n").write(to:directory.appendingPathComponent("checks.txt"),atomically:true,encoding:.utf8)
            try (rows.joined(separator:"\n")+"\n").write(to:directory.appendingPathComponent("metrics.csv"),atomically:true,encoding:.utf8)
            try notes.joined(separator:"\n").write(to:root.appendingPathComponent("checks.txt"),atomically:true,encoding:.utf8)
            try writeProvenance(completedAt:Date())
        } catch { fputs("FAIL evidence write: \(error)\n",stderr); exit(1) }
        print(notes.suffix(3).joined(separator:"\n"))
        if !failures.isEmpty { exit(1) }
    }
}
