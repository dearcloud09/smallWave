import Foundation

/// CPU-only numerical study. A 2D, constant-reference-density Boussinesq model;
/// not calibrated water/oil, a free-surface model, or a replacement for the app.
final class TwoPhaseSimulation {
    struct Vector {
        var x: Double
        var y: Double
        static let zero = Vector(x: 0, y: 0)
    }
    enum Transport: String { case donor, fct }
    enum Failure: Error, CustomStringConvertible {
        case invalid(String)
        var description: String { switch self { case .invalid(let text): return text } }
    }
    struct Projection {
        let iterations: Int
        let residualInfinity: Double
        let divergenceInfinity: Double
        let scaledDivergence: Double
        let residualDivergenceDifference: Double
        let wallFluxInfinity: Double
        let rhsMean: Double
    }
    struct PhaseMetrics {
        let amount: Double
        let minimum: Double
        let maximum: Double
        let centroid: Vector
        let mixedArea: Double
        let interfaceWidth: Double
    }

    let nx: Int, ny: Int
    let width: Double, height: Double, dx: Double, dy: Double
    let densityContrast: Double
    private(set) var phase: [Double]
    /// u(i,j) at (i*dx,(j+1/2)*dy); v(i,j) at ((i+1/2)*dx,j*dy).
    private(set) var u: [Double]
    private(set) var v: [Double]
    private(set) var pressureImpulse: [Double]
    private(set) var time: Double = 0
    private(set) var lastProjection: Projection?

    init(nx: Int = 80, ny: Int = 170, width: Double = 2, height: Double = 4.24,
         densityContrast: Double = 0.15) {
        precondition(nx >= 4 && ny >= 4 && width.isFinite && height.isFinite && width > 0 && height > 0)
        precondition(densityContrast.isFinite && densityContrast >= 0 && densityContrast <= 1)
        self.nx = nx; self.ny = ny; self.width = width; self.height = height
        self.dx = width / Double(nx); self.dy = height / Double(ny)
        self.densityContrast = densityContrast
        phase = [Double](repeating: 0, count: nx * ny)
        u = [Double](repeating: 0, count: (nx + 1) * ny)
        v = [Double](repeating: 0, count: nx * (ny + 1))
        pressureImpulse = [Double](repeating: 0, count: nx * ny)
    }

    func setPhase(_ value: (Double, Double) -> Double) throws {
        var next = phase
        for j in 0..<ny { for i in 0..<nx {
            next[i + nx*j] = value((Double(i)+0.5)*dx, (Double(j)+0.5)*dy)
        }}
        try validatePhase(next, name: "initial phase")
        phase = next
    }

    func setVelocity(horizontal: (Double, Double) -> Double,
                     vertical: (Double, Double) -> Double) throws {
        for j in 0..<ny { for i in 0...nx { u[i+(nx+1)*j] = horizontal(Double(i)*dx,(Double(j)+0.5)*dy) }}
        for j in 0...ny { for i in 0..<nx { v[i+nx*j] = vertical((Double(i)+0.5)*dx,Double(j)*dy) }}
        enforceWalls()
        guard u.allSatisfy(\.isFinite), v.allSatisfy(\.isFinite) else { throw Failure.invalid("Nonfinite velocity") }
    }

    /// Discrete curl of a corner streamfunction. Prescribed tests must provide
    /// a constant value on the box boundary; this is checked, not silently fixed.
    func setStreamfunction(_ value: (Double, Double) -> Double) throws {
        var psi = [Double](repeating: 0, count: (nx+1)*(ny+1))
        for j in 0...ny { for i in 0...nx { psi[i+(nx+1)*j] = value(Double(i)*dx,Double(j)*dy) }}
        let boundary = psi[0]
        for j in 0...ny { for i in 0...nx where i == 0 || i == nx || j == 0 || j == ny {
            guard abs(psi[i+(nx+1)*j]-boundary) < 1e-13 else { throw Failure.invalid("Streamfunction is not closed at walls") }
        }}
        for j in 0..<ny { for i in 0...nx { u[i+(nx+1)*j] = (psi[i+(nx+1)*(j+1)]-psi[i+(nx+1)*j])/dy }}
        for j in 0...ny { for i in 0..<nx { v[i+nx*j] = -(psi[i+1+(nx+1)*j]-psi[i+(nx+1)*j])/dx }}
        enforceWalls()
    }

    private func enforceWalls() {
        for j in 0..<ny { u[(nx+1)*j] = 0; u[nx+(nx+1)*j] = 0 }
        for i in 0..<nx { v[i] = 0; v[i+nx*ny] = 0 }
    }
    func wallFluxInfinity() -> Double {
        var result = 0.0
        for j in 0..<ny { result = max(result,abs(u[(nx+1)*j]),abs(u[nx+(nx+1)*j])) }
        for i in 0..<nx { result = max(result,abs(v[i]),abs(v[i+nx*ny])) }
        return result
    }
    func divergence() -> [Double] {
        var result = phase
        for j in 0..<ny { for i in 0..<nx {
            result[i+nx*j] = (u[i+1+(nx+1)*j]-u[i+(nx+1)*j])/dx + (v[i+nx*(j+1)]-v[i+nx*j])/dy
        }}
        return result
    }
    private func applyNegativeLaplacian(_ p: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: p.count)
        let xx = 1/(dx*dx), yy = 1/(dy*dy)
        for j in 0..<ny { for i in 0..<nx {
            let k = i+nx*j
            if i > 0 { out[k] += (p[k]-p[k-1])*xx }
            if i+1 < nx { out[k] += (p[k]-p[k+1])*xx }
            if j > 0 { out[k] += (p[k]-p[k-nx])*yy }
            if j+1 < ny { out[k] += (p[k]-p[k+nx])*yy }
        }}
        return out
    }
    private func removeMean(_ p: inout [Double]) {
        let mean = p.reduce(0,+)/Double(p.count)
        for i in p.indices { p[i] -= mean }
    }
    private func dot(_ a: [Double], _ b: [Double]) -> Double {
        var result = 0.0
        for i in a.indices { result += a[i]*b[i] }
        return result
    }
    private func infinity(_ a: [Double]) -> Double { a.reduce(0) { max($0,abs($1)) } }

    /// Solve A q = -D u*, A = -D G, q = dt*p/rho0. The public divergence veto
    /// is 1e-6 per step. Standalone projection allows cancellation roundoff from
    /// large manufactured gradients; step requests a tighter transport target.
    @discardableResult
    func project(dt: Double, targetScaledResidual: Double = 1e-14,
                 maximumIterations: Int = 4000) throws -> Projection {
        guard dt.isFinite && dt > 0 else { throw Failure.invalid("Invalid projection dt") }
        enforceWalls()
        let originalDivergence = divergence()
        var rhs = originalDivergence.map { -$0 }
        let rhsMean = rhs.reduce(0,+)/Double(rhs.count)
        guard abs(rhsMean)*dt < 1e-12 else { throw Failure.invalid("Incompatible closed pressure RHS: \(rhsMean)") }
        removeMean(&rhs) // pressure nullspace only, never phase renormalization
        var q = [Double](repeating: 0, count: rhs.count), r = rhs
        var inverseDiagonal = rhs
        for j in 0..<ny { for i in 0..<nx {
            inverseDiagonal[i+nx*j] = 1/(Double((i>0 ? 1:0)+(i+1<nx ? 1:0))/(dx*dx)
                + Double((j>0 ? 1:0)+(j+1<ny ? 1:0))/(dy*dy))
        }}
        func precondition(_ residual: [Double]) -> [Double] {
            var z = residual
            for k in z.indices { z[k] *= inverseDiagonal[k] }
            removeMean(&z)
            return z
        }
        var z = precondition(r), direction = z, rz = dot(r,z), iterations = 0
        while infinity(r)*dt > targetScaledResidual && iterations < maximumIterations {
            let aDirection = applyNegativeLaplacian(direction)
            let denominator = dot(direction,aDirection)
            guard denominator.isFinite && denominator > 0 && rz.isFinite else { throw Failure.invalid("PCG breakdown at \(iterations)") }
            let alpha = rz/denominator
            for k in q.indices { q[k] += alpha*direction[k]; r[k] -= alpha*aDirection[k] }
            iterations += 1
            let recompute = infinity(r)*dt <= targetScaledResidual || iterations % 160 == 0
            if recompute {
                let aq = applyNegativeLaplacian(q)
                for k in r.indices { r[k] = rhs[k]-aq[k] }
                removeMean(&r)
                if infinity(r)*dt <= targetScaledResidual { break }
            }
            z = precondition(r)
            let nextRZ = dot(r,z)
            if recompute { direction = z }
            else {
                let beta = nextRZ/rz
                for k in direction.indices { direction[k] = z[k]+beta*direction[k] }
            }
            rz = nextRZ
        }
        removeMean(&q)
        let aq = applyNegativeLaplacian(q)
        var residual = rhs
        for k in residual.indices { residual[k] = rhs[k]-aq[k] }
        guard infinity(residual)*dt <= 4*targetScaledResidual else {
            throw Failure.invalid("Pressure residual not converged: dt*res=\(infinity(residual)*dt), iterations=\(iterations)")
        }
        for j in 0..<ny { for i in 1..<nx { u[i+(nx+1)*j] -= (q[i+nx*j]-q[i-1+nx*j])/dx }}
        for j in 1..<ny { for i in 0..<nx { v[i+nx*j] -= (q[i+nx*j]-q[i+nx*(j-1)])/dy }}
        enforceWalls()
        let div = divergence()
        var correspondence = 0.0
        for k in div.indices { correspondence = max(correspondence,abs(div[k]+residual[k]+rhsMean)) }
        let result = Projection(iterations:iterations,residualInfinity:infinity(residual),divergenceInfinity:infinity(div),
            scaledDivergence:dt*infinity(div),residualDivergenceDifference:correspondence,wallFluxInfinity:wallFluxInfinity(),rhsMean:rhsMean)
        guard result.scaledDivergence <= 1e-6 else { throw Failure.invalid("Divergence veto: \(result.scaledDivergence)") }
        pressureImpulse = q; lastProjection = result
        return result
    }

    func outgoingCourant(dt: Double) -> Double {
        var maximum = 0.0
        for j in 0..<ny { for i in 0..<nx {
            let out = (max(u[i+1+(nx+1)*j],0)+max(-u[i+(nx+1)*j],0))/dx
                + (max(v[i+nx*(j+1)],0)+max(-v[i+nx*j],0))/dy
            maximum = max(maximum,dt*out)
        }}
        return maximum
    }
    private func slope(_ left: Double, _ center: Double, _ right: Double) -> Double {
        let a = 2*(center-left), b = (right-left)*0.5, c = 2*(right-center)
        if a > 0 && b > 0 && c > 0 { return min(a,b,c) }
        if a < 0 && b < 0 && c < 0 { return max(a,b,c) }
        return 0
    }
    private func validatePhase(_ c: [Double], name: String) throws {
        guard c.allSatisfy({ $0.isFinite && $0 >= -1e-12 && $0 <= 1+1e-12 }) else {
            throw Failure.invalid("\(name) range veto: min=\(c.min() ?? .nan), max=\(c.max() ?? .nan)")
        }
    }

    /// Conservative Euler stage. Each limited face correction is transferred
    /// between its two cells once. No cell clamp and no global mass repair.
    private func transportStage(_ c: [Double], dt: Double, scheme: Transport) throws -> [Double] {
        var low = c
        var ax = [Double](repeating:0,count:u.count), ay = [Double](repeating:0,count:v.count)
        var sx = [Double](repeating:0,count:c.count), sy = sx
        if scheme == .fct {
            for j in 0..<ny { for i in 0..<nx {
                let k = i+nx*j
                sx[k] = slope(c[max(0,i-1)+nx*j],c[k],c[min(nx-1,i+1)+nx*j])
                sy[k] = slope(c[i+nx*max(0,j-1)],c[k],c[i+nx*min(ny-1,j+1)])
            }}
        }
        for j in 0..<ny { for i in 1..<nx {
            let face = i+(nx+1)*j, right = i+nx*j, left = right-1, speed = u[face]
            let donor = speed >= 0 ? c[left]:c[right]
            let amount = dt/dx*speed*donor
            low[left] -= amount; low[right] += amount
            if scheme == .fct {
                let reconstructed = speed >= 0 ? c[left]+0.5*sx[left]:c[right]-0.5*sx[right]
                ax[face] = dt/dx*speed*(reconstructed-donor)
            }
        }}
        for j in 1..<ny { for i in 0..<nx {
            let face = i+nx*j, top = i+nx*j, bottom = top-nx, speed = v[face]
            let donor = speed >= 0 ? c[bottom]:c[top]
            let amount = dt/dy*speed*donor
            low[bottom] -= amount; low[top] += amount
            if scheme == .fct {
                let reconstructed = speed >= 0 ? c[bottom]+0.5*sy[bottom]:c[top]-0.5*sy[top]
                ay[face] = dt/dy*speed*(reconstructed-donor)
            }
        }}
        try validatePhase(low,name:"donor stage")
        if scheme == .donor { return low }
        var incoming = [Double](repeating:0,count:c.count), outgoing = incoming
        func budgets(_ left: Int, _ right: Int, _ amount: Double) {
            if amount >= 0 { outgoing[left] += amount; incoming[right] += amount }
            else { incoming[left] -= amount; outgoing[right] -= amount }
        }
        for j in 0..<ny { for i in 1..<nx { budgets(i-1+nx*j,i+nx*j,ax[i+(nx+1)*j]) }}
        for j in 1..<ny { for i in 0..<nx { budgets(i+nx*(j-1),i+nx*j,ay[i+nx*j]) }}
        var plus = incoming, minus = outgoing
        for k in c.indices {
            plus[k] = incoming[k] > 0 ? min(1,max(0,1-low[k])/incoming[k]):1
            minus[k] = outgoing[k] > 0 ? min(1,max(0,low[k])/outgoing[k]):1
        }
        func correct(_ left: Int, _ right: Int, _ amount: Double) {
            let factor = amount >= 0 ? min(minus[left],plus[right]):min(plus[left],minus[right])
            low[left] -= factor*amount; low[right] += factor*amount
        }
        for j in 0..<ny { for i in 1..<nx { correct(i-1+nx*j,i+nx*j,ax[i+(nx+1)*j]) }}
        for j in 1..<ny { for i in 0..<nx { correct(i+nx*(j-1),i+nx*j,ay[i+nx*j]) }}
        try validatePhase(low,name:"FCT stage")
        return low
    }

    func advectPhase(dt: Double, scheme: Transport = .fct) throws {
        guard dt.isFinite && dt > 0 else { throw Failure.invalid("Invalid transport dt") }
        let courant = outgoingCourant(dt:dt)
        guard courant <= 0.45 else { throw Failure.invalid("Outgoing CFL veto: \(courant) > 0.45") }
        let first = try transportStage(phase,dt:dt,scheme:scheme)
        let second = try transportStage(first,dt:dt,scheme:scheme)
        var next = phase
        for k in next.indices { next[k] = 0.5*(phase[k]+second[k]) }
        try validatePhase(next,name:"SSPRK2 result")
        phase = next
    }

    private func sample(_ values: [Double], columns: Int, rows: Int, x: Double, y: Double) -> Double {
        let xx = max(0,min(Double(columns-1),x)), yy = max(0,min(Double(rows-1),y))
        let i = Int(floor(xx)), j = Int(floor(yy)), a = xx-Double(i), b = yy-Double(j)
        let r = min(columns-1,i+1), t = min(rows-1,j+1)
        return (1-b)*((1-a)*values[i+columns*j]+a*values[r+columns*j])
            + b*((1-a)*values[i+columns*t]+a*values[r+columns*t])
    }
    /// Momentum uses midpoint semi-Lagrangian backtracing. It is dissipative
    /// and not a momentum-conserving discretization; phase transport is separate.
    private func advectVelocity(dt: Double) {
        let oldU = u, oldV = v
        func velocity(_ x: Double, _ y: Double) -> Vector {
            Vector(x:sample(oldU,columns:nx+1,rows:ny,x:x/dx,y:y/dy-0.5),
                   y:sample(oldV,columns:nx,rows:ny+1,x:x/dx-0.5,y:y/dy))
        }
        for j in 0..<ny { for i in 1..<nx {
            let x = Double(i)*dx, y = (Double(j)+0.5)*dy, a = velocity(x,y)
            let b = velocity(x-0.5*dt*a.x,y-0.5*dt*a.y)
            u[i+(nx+1)*j] = sample(oldU,columns:nx+1,rows:ny,x:(x-dt*b.x)/dx,y:(y-dt*b.y)/dy-0.5)
        }}
        for j in 1..<ny { for i in 0..<nx {
            let x = (Double(i)+0.5)*dx, y = Double(j)*dy, a = velocity(x,y)
            let b = velocity(x-0.5*dt*a.x,y-0.5*dt*a.y)
            v[i+nx*j] = sample(oldV,columns:nx,rows:ny+1,x:(x-dt*b.x)/dx-0.5,y:(y-dt*b.y)/dy)
        }}
        enforceWalls()
    }

    @discardableResult
    func step(dt: Double, gravity: Vector, scheme: Transport = .fct) throws -> Projection {
        guard dt.isFinite && dt > 0 && gravity.x.isFinite && gravity.y.isFinite else { throw Failure.invalid("Invalid step input") }
        advectVelocity(dt:dt)
        for j in 0..<ny { for i in 1..<nx {
            let c = 0.5*(phase[i-1+nx*j]+phase[i+nx*j])
            u[i+(nx+1)*j] += dt*densityContrast*(c-0.5)*gravity.x
        }}
        for j in 1..<ny { for i in 0..<nx {
            let c = 0.5*(phase[i+nx*(j-1)]+phase[i+nx*j])
            v[i+nx*j] += dt*densityContrast*(c-0.5)*gravity.y
        }}
        // A persistent 1e-14 compressive residual exceeded the unchanged 1e-12
        // phase bound after 115 resting steps, so transport needs a tighter solve.
        let result = try project(dt:dt,targetScaledResidual:1e-16)
        try advectPhase(dt:dt,scheme:scheme)
        time += dt
        return result
    }

    func metrics(clear: Bool = false) -> PhaseMetrics {
        let c = clear ? phase.map { 1-$0 }:phase
        var amount = 0.0, x = 0.0, y = 0.0, mixed = 0.0, perimeter = 0.0
        for j in 0..<ny { for i in 0..<nx {
            let k = i+nx*j, mass = c[k]*dx*dy
            amount += mass; x += mass*(Double(i)+0.5)*dx; y += mass*(Double(j)+0.5)*dy
            mixed += 4*c[k]*(1-c[k])*dx*dy
            if i+1 < nx { perimeter += abs(c[k+1]-c[k])*dy }
            if j+1 < ny { perimeter += abs(c[k+nx]-c[k])*dx }
        }}
        return PhaseMetrics(amount:amount,minimum:c.min() ?? 0,maximum:c.max() ?? 0,
            centroid:Vector(x:amount>0 ? x/amount:0,y:amount>0 ? y/amount:0),
            mixedArea:mixed,interfaceWidth:perimeter>0 ? mixed/perimeter:0)
    }
}
