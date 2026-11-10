import Foundation

/// The assembled stiffness system, applied matrix-free: y = K·x without ever storing K.
final class FEMSystem: @unchecked Sendable {
    let nodeCount: Int
    /// 8 compact node numbers per element.
    let nodes: [Int32]
    /// Stiffness factor per element (1 = solid material, < 1 = infill).
    let scale: [Double]
    let ke: [Double]
    /// Elements grouped so that no two elements of a group share a node (processed in parallel).
    let groups: [[Int32]]
    /// 3 flags per node.
    var fixed: [Bool]

    init(nodeCount: Int, nodes: [Int32], scale: [Double], ke: [Double], groups: [[Int32]]) {
        self.nodeCount = nodeCount
        self.nodes = nodes
        self.scale = scale
        self.ke = ke
        self.groups = groups
        self.fixed = [Bool](repeating: false, count: nodeCount * 3)
    }

    var dofCount: Int { nodeCount * 3 }

    /// y = K·x (all degrees of freedom).
    func multiply(_ x: [Double], into y: inout [Double]) {
        for i in 0..<y.count { y[i] = 0 }
        x.withUnsafeBufferPointer { xp in
            y.withUnsafeMutableBufferPointer { yp in
                let xb = xp.baseAddress!, yb = yp.baseAddress!
                // Raw addresses cross the thread boundary as plain integers (the groups never touch the same node).
                let yAddress = UInt(bitPattern: yb), xAddress = UInt(bitPattern: xb)
                for group in groups {
                    let chunks = max(1, min(64, group.count / 512))
                    DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                        let from = chunk * group.count / chunks, to = (chunk + 1) * group.count / chunks
                        FEMSystem.process(group: group, from: from, to: to, nodes: nodes, scale: scale, ke: ke, x: xAddress, y: yAddress)
                    }
                }
            }
        }
    }

    /// Applies the element matrices of `group[from..<to]`. Optimised even in debug builds (the hot loop of every analysis).
    @_optimize(speed)
    private static func process(group: [Int32], from: Int, to: Int, nodes: [Int32], scale: [Double], ke: [Double], x: UInt, y: UInt) {
        let yPtr = UnsafeMutablePointer<Double>(bitPattern: y)!, xPtr = UnsafePointer<Double>(bitPattern: x)!
        // Plain pointers and while loops: generic Range/Array iteration is unspecialised (very slow) in debug builds.
        let xe = UnsafeMutablePointer<Double>.allocate(capacity: 48), ye = xe + 24
        defer { xe.deallocate() }
        nodes.withUnsafeBufferPointer { nodeBuffer in
            ke.withUnsafeBufferPointer { kb in
                group.withUnsafeBufferPointer { gb in
                    scale.withUnsafeBufferPointer { sb in
                        let k = kb.baseAddress!, nb = nodeBuffer.baseAddress!
                        var g = from
                        while g < to {
                            let e = Int(gb[g])
                            let s = sb[e]
                            var a = 0
                            while a < 8 {
                                let n = Int(nb[e * 8 + a]) * 3
                                xe[a * 3] = xPtr[n]; xe[a * 3 + 1] = xPtr[n + 1]; xe[a * 3 + 2] = xPtr[n + 2]
                                a += 1
                            }
                            var r = 0
                            while r < 24 {
                                var sum = 0.0
                                let row = k + r * 24
                                var c = 0
                                while c < 24 { sum += row[c] * xe[c]; c += 1 }
                                ye[r] = sum * s
                                r += 1
                            }
                            a = 0
                            while a < 8 {
                                let n = Int(nb[e * 8 + a]) * 3
                                yPtr[n] += ye[a * 3]; yPtr[n + 1] += ye[a * 3 + 1]; yPtr[n + 2] += ye[a * 3 + 2]
                                a += 1
                            }
                            g += 1
                        }
                    }
                }
            }
        }
    }

    @_optimize(speed)
    func diagonal() -> [Double] {
        var d = [Double](repeating: 0, count: dofCount)
        for e in 0..<scale.count {
            for a in 0..<8 {
                let n = Int(nodes[e * 8 + a]) * 3
                for c in 0..<3 { d[n + c] += ke[(a * 3 + c) * 24 + a * 3 + c] * scale[e] }
            }
        }
        return d
    }

    struct Solution {
        var displacement: [Double]
        var iterations: Int
        var residual: Double
        var converged: Bool
    }

    /// Conjugate gradients with a diagonal preconditioner; fixed degrees of freedom stay at zero.
    @_optimize(speed)
    func solve(force: [Double], tolerance: Double = 1e-5, maxIterations: Int = 6000,
               progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws -> Solution {
        let n = dofCount
        var diag = diagonal()
        for i in 0..<n where fixed[i] || diag[i] <= 0 { diag[i] = 1 }
        var u = [Double](repeating: 0, count: n)
        var r = force
        for i in 0..<n where fixed[i] { r[i] = 0 }
        let norm0 = (r.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard norm0 > 0 else { return Solution(displacement: u, iterations: 0, residual: 0, converged: true) }
        var z = [Double](repeating: 0, count: n)
        for i in 0..<n { z[i] = r[i] / diag[i] }
        var p = z
        var rz = zip(r, z).reduce(0) { $0 + $1.0 * $1.1 }
        var ap = [Double](repeating: 0, count: n)
        var iterations = 0, residual = 1.0
        while iterations < maxIterations {
            if isCancelled() { throw FEMError.cancelled }
            for i in 0..<n where fixed[i] { p[i] = 0 }
            multiply(p, into: &ap)
            for i in 0..<n where fixed[i] { ap[i] = 0 }
            let pap = zip(p, ap).reduce(0) { $0 + $1.0 * $1.1 }
            guard pap > 0 else { break }
            let alpha = rz / pap
            for i in 0..<n { u[i] += alpha * p[i]; r[i] -= alpha * ap[i] }
            iterations += 1
            residual = (r.reduce(0) { $0 + $1 * $1 }).squareRoot() / norm0
            if iterations % 25 == 0 { progress(min(1, max(0, log10(residual) / log10(tolerance)))) }
            if residual < tolerance { break }
            for i in 0..<n { z[i] = r[i] / diag[i] }
            let rzNew = zip(r, z).reduce(0) { $0 + $1.0 * $1.1 }
            let beta = rzNew / rz
            rz = rzNew
            for i in 0..<n { p[i] = z[i] + beta * p[i] }
        }
        return Solution(displacement: u, iterations: iterations, residual: residual, converged: residual < tolerance)
    }
}
