import simd

/// The ghost controller's geometry, API-neutral: a PSVR2 Sense, roughly, in
/// the grip frame (OpenXR / visionOS `.grip`: Z runs through the fist, metres).
/// A capsule grip along Z, a flattened band that loops round the BACK of the
/// hand from the grip's top to its bottom — the Sense's tracking ring — and a
/// small disc on the top end where the stick and buttons sit, so the top end
/// reads as the top. Built for the right hand (back of the hand toward +X)
/// and mirrored for the left. ~1.4k triangles, ~1.5k vertices.
///
/// `SenseGhostRenderer` draws it with Metal; a RealityKit app can build a
/// `MeshResource` from the same arrays.
public struct SenseGhostMesh: Sendable {
    /// Interleaved, 8 floats per vertex: position xyz, outward normal xyz, uv.
    public var vertices: [Float]
    /// Triangle list, counter-clockwise front faces.
    public var indices: [UInt16]

    public init(vertices: [Float], indices: [UInt16]) {
        self.vertices = vertices
        self.indices = indices
    }

    public var vertexCount: Int { vertices.count / 8 }

    /// The Sense for one hand.
    public static func sense(right: Bool) -> SenseGhostMesh {
        var v: [Float] = []
        var idx: [UInt16] = []
        let sx: Float = right ? 1 : -1

        /// A (nu+1)x(nv+1) grid surface. `f(u, v)` returns position and outward
        /// normal; each triangle's winding is checked against the normal so the
        /// mirror (and any parametrisation slip) cannot turn a mesh inside out.
        func surface(_ nu: Int, _ nv: Int,
                     _ f: (Float, Float) -> (SIMD3<Float>, SIMD3<Float>)) {
            let base = v.count / 8
            var pos: [SIMD3<Float>] = [], nrm: [SIMD3<Float>] = []
            for i in 0...nu {
                for j in 0...nv {
                    var (p, n) = f(Float(i) / Float(nu), Float(j) / Float(nv))
                    p.x *= sx; n.x *= sx
                    n = simd_normalize(n)
                    pos.append(p); nrm.append(n)
                    v += [p.x, p.y, p.z, n.x, n.y, n.z, Float(i) / Float(nu), Float(j) / Float(nv)]
                }
            }
            func at(_ i: Int, _ j: Int) -> Int { i * (nv + 1) + j }
            func tri(_ a: Int, _ b: Int, _ c: Int) {
                let fn = simd_cross(pos[b] - pos[a], pos[c] - pos[a])
                let n = nrm[a] + nrm[b] + nrm[c]
                if simd_length(fn) < 1e-12 { return }           // degenerate (a pole)
                if simd_dot(fn, n) >= 0 { idx += [UInt16(base + a), UInt16(base + b), UInt16(base + c)] }
                else { idx += [UInt16(base + a), UInt16(base + c), UInt16(base + b)] }
            }
            for i in 0..<nu {
                for j in 0..<nv {
                    tri(at(i, j), at(i + 1, j), at(i + 1, j + 1))
                    tri(at(i, j), at(i + 1, j + 1), at(i, j + 1))
                }
            }
        }

        // Grip: capsule, radius 1.9 cm, from z = +5.5 cm (bottom) to -4.5 cm (top).
        let r: Float = 0.019, zBot: Float = 0.055 - r, zTop: Float = -0.045 + r
        surface(24, 24) { u, w in
            let th = u * .pi, ph = w * 2 * .pi
            let n = SIMD3<Float>(sin(th) * cos(ph), sin(th) * sin(ph), cos(th))
            let zc = n.z >= 0 ? zBot : zTop
            return (SIMD3(n.x * r, n.y * r, zc + n.z * r), n)
        }
        // Ring: a flattened band (6 mm in its plane, 14 mm tall) on a circle of
        // radius 5.5 cm in the XZ plane, centred 3 cm toward the back of the
        // hand — the part of the circle beyond the grip, i.e. about ±123°.
        let c = SIMD3<Float>(0.030, 0, 0.005), R: Float = 0.055
        let a0 = acos(-c.x / R)
        let r1: Float = 0.006, r2: Float = 0.014
        surface(48, 16) { u, w in
            let al = -a0 + u * 2 * a0, be = w * 2 * .pi
            let e1 = SIMD3<Float>(cos(al), 0, sin(al)), e2 = SIMD3<Float>(0, 1, 0)
            let p = c + R * e1 + r1 * cos(be) * e1 + r2 * sin(be) * e2
            let n = (cos(be) / r1) * e1 + (sin(be) / r2) * e2
            return (p, n)
        }
        // Top face: a small disc where the stick and buttons sit, so the top
        // end reads as the top.
        surface(1, 24) { u, w in
            let ph = w * 2 * .pi, rr = u * r * 0.85
            return (SIMD3(rr * cos(ph), rr * sin(ph), zTop - r - 0.002), SIMD3(0, 0, -1))
        }

        return SenseGhostMesh(vertices: v, indices: idx)
    }
}
