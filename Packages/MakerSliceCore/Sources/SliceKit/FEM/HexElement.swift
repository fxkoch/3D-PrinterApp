import Foundation

/// Small dense matrix helpers (row-major arrays).
enum Dense {
    @_optimize(speed)
    static func multiply(_ a: [Double], _ ar: Int, _ ac: Int, _ b: [Double], _ bc: Int) -> [Double] {
        var c = [Double](repeating: 0, count: ar * bc)
        for i in 0..<ar { for k in 0..<ac { let v = a[i * ac + k]; if v != 0 { for j in 0..<bc { c[i * bc + j] += v * b[k * bc + j] } } } }
        return c
    }

    static func transpose(_ a: [Double], _ r: Int, _ c: Int) -> [Double] {
        var t = [Double](repeating: 0, count: r * c)
        for i in 0..<r { for j in 0..<c { t[j * r + i] = a[i * c + j] } }
        return t
    }

    /// Inverse by Gauss-Jordan with partial pivoting; nil for a singular matrix.
    static func inverse(_ m: [Double], _ n: Int) -> [Double]? {
        var a = m
        var inv = [Double](repeating: 0, count: n * n)
        for i in 0..<n { inv[i * n + i] = 1 }
        for col in 0..<n {
            var pivot = col
            for r in col..<n where abs(a[r * n + col]) > abs(a[pivot * n + col]) { pivot = r }
            guard abs(a[pivot * n + col]) > 1e-300 else { return nil }
            if pivot != col {
                for j in 0..<n { a.swapAt(col * n + j, pivot * n + j); inv.swapAt(col * n + j, pivot * n + j) }
            }
            let d = a[col * n + col]
            for j in 0..<n { a[col * n + j] /= d; inv[col * n + j] /= d }
            for r in 0..<n where r != col {
                let f = a[r * n + col]
                if f != 0 { for j in 0..<n { a[r * n + j] -= f * a[col * n + j]; inv[r * n + j] -= f * inv[col * n + j] } }
            }
        }
        return inv
    }
}

/// Stiffness of one cubic 8-node element with incompatible modes (Wilson Q6): bending is captured with few elements
/// across a wall. All elements of the grid are identical cubes, so the condensed matrix is computed once.
struct HexElement {
    /// 24×24 stiffness for the reference material (row-major, order: node 0 x,y,z, node 1 x,y,z …).
    let ke: [Double]
    /// For each of the 8 Gauss points a 6×24 matrix: strain (εx, εy, εz, γxy, γyz, γzx) from the 24 displacements.
    let strainAtGauss: [[Double]]
    /// Reference constitutive matrix (6×6) the matrices were built with.
    let d: [Double]

    static let nodeSigns: [(Double, Double, Double)] = [(-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1),
                                                         (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]

    /// Constitutive matrix of a material with axis z (layer direction): E in the plane, E across the layers.
    static func constitutive(exy: Double, ez: Double, nu: Double) -> [Double] {
        let nu31 = nu
        let g12 = exy / (2 * (1 + nu)), g13 = ez / (2 * (1 + nu31))
        var s = [Double](repeating: 0, count: 36)
        s[0] = 1 / exy; s[1] = -nu / exy; s[2] = -nu31 / ez
        s[6] = -nu / exy; s[7] = 1 / exy; s[8] = -nu31 / ez
        s[12] = -nu31 / ez; s[13] = -nu31 / ez; s[14] = 1 / ez
        s[21] = 1 / g12; s[28] = 1 / g13; s[35] = 1 / g13
        return Dense.inverse(s, 6) ?? [Double](repeating: 0, count: 36)
    }

    /// Strain-displacement matrix B (6×24) at local coordinates.
    static func bMatrix(_ xi: Double, _ eta: Double, _ zeta: Double, h: Double) -> [Double] {
        var b = [Double](repeating: 0, count: 6 * 24)
        let f = 2 / h
        for (n, s) in nodeSigns.enumerated() {
            let dx = 0.125 * s.0 * (1 + eta * s.1) * (1 + zeta * s.2) * f
            let dy = 0.125 * s.1 * (1 + xi * s.0) * (1 + zeta * s.2) * f
            let dz = 0.125 * s.2 * (1 + xi * s.0) * (1 + eta * s.1) * f
            let c = 3 * n
            b[0 * 24 + c] = dx; b[1 * 24 + c + 1] = dy; b[2 * 24 + c + 2] = dz
            b[3 * 24 + c] = dy; b[3 * 24 + c + 1] = dx
            b[4 * 24 + c + 1] = dz; b[4 * 24 + c + 2] = dy
            b[5 * 24 + c] = dz; b[5 * 24 + c + 2] = dx
        }
        return b
    }

    /// Strain matrix G (6×9) of the incompatible modes (1−ξ², 1−η², 1−ζ² for each displacement direction).
    static func gMatrix(_ xi: Double, _ eta: Double, _ zeta: Double, h: Double) -> [Double] {
        var g = [Double](repeating: 0, count: 6 * 9)
        let coords = [xi, eta, zeta]
        for dir in 0..<3 {
            for mode in 0..<3 {
                let c = dir * 3 + mode
                var grad = [0.0, 0.0, 0.0]
                grad[mode] = -4 * coords[mode] / h
                let (gx, gy, gz) = (grad[0], grad[1], grad[2])
                switch dir {
                case 0: g[0 * 9 + c] = gx; g[3 * 9 + c] = gy; g[5 * 9 + c] = gz
                case 1: g[1 * 9 + c] = gy; g[3 * 9 + c] = gx; g[4 * 9 + c] = gz
                default: g[2 * 9 + c] = gz; g[4 * 9 + c] = gy; g[5 * 9 + c] = gx
                }
            }
        }
        return g
    }

    @_optimize(speed)
    init?(h: Double, d: [Double]) {
        let a = 1 / 3.0.squareRoot()
        let points: [(Double, Double, Double)] = HexElement.nodeSigns.map { ($0.0 * a, $0.1 * a, $0.2 * a) }
        let dV = pow(h / 2, 3)
        var kuu = [Double](repeating: 0, count: 24 * 24), kua = [Double](repeating: 0, count: 24 * 9), kaa = [Double](repeating: 0, count: 81)
        var bs: [[Double]] = [], gs: [[Double]] = []
        for p in points {
            let b = HexElement.bMatrix(p.0, p.1, p.2, h: h), g = HexElement.gMatrix(p.0, p.1, p.2, h: h)
            bs.append(b); gs.append(g)
            let db = Dense.multiply(d, 6, 6, b, 24), dg = Dense.multiply(d, 6, 6, g, 9)
            let btdb = Dense.multiply(Dense.transpose(b, 6, 24), 24, 6, db, 24)
            let btdg = Dense.multiply(Dense.transpose(b, 6, 24), 24, 6, dg, 9)
            let gtdg = Dense.multiply(Dense.transpose(g, 6, 9), 9, 6, dg, 9)
            for i in 0..<kuu.count { kuu[i] += btdb[i] * dV }
            for i in 0..<kua.count { kua[i] += btdg[i] * dV }
            for i in 0..<81 { kaa[i] += gtdg[i] * dV }
        }
        guard let kaaInv = Dense.inverse(kaa, 9) else { return nil }
        let kau = Dense.transpose(kua, 24, 9)
        // Condensation of the incompatible modes: K = Kuu − Kua Kaa⁻¹ Kau, and α = A·u with A = −Kaa⁻¹ Kau.
        let correction = Dense.multiply(Dense.multiply(kua, 24, 9, kaaInv, 9), 24, 9, kau, 24)
        var ke = kuu
        for i in 0..<ke.count { ke[i] -= correction[i] }
        let alphaMap = Dense.multiply(kaaInv, 9, 9, kau, 24).map { -$0 }
        var strain: [[Double]] = []
        for (b, g) in zip(bs, gs) {
            let enhanced = Dense.multiply(g, 6, 9, alphaMap, 24)
            strain.append(zip(b, enhanced).map { $0 + $1 })
        }
        self.ke = ke
        self.strainAtGauss = strain
        self.d = d
    }
}
