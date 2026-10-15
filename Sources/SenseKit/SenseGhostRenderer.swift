import Metal
import simd

/// The per-view matrix the ghost shaders index by `[[amplification_id]]`:
/// projection × view, in the space `recenter` maps the controller poses into.
public struct SenseGhostView: Sendable {
    public var viewProj: simd_float4x4
    public init(viewProj: simd_float4x4) { self.viewProj = viewProj }
}

public enum SenseGhostRendererError: Error {
    case meshBuffer
    case depthState
}

/// Draws `SenseGhosts` with Metal into an encoder the app already has open —
/// a layered, vertex-amplified stereo pass like CompositorServices'. Viewports
/// and amplification mappings are the caller's; this sets pipeline, depth
/// state, cull mode and front facing (counter-clockwise), and leaves the cull
/// mode `.none`.
///
/// Both meshes are drawn body first (light grey, lit), then the soft outline:
/// the same mesh pushed out `rimWidth` along its normals with its FRONT faces
/// culled, so only the rim around the silhouette survives. Premultiplied
/// blend. Depth is WRITTEN, because visionOS reprojects the submitted frame
/// with its depth buffer and a near object stamped with a backdrop's depth
/// would swim when the head moves; the test (`.greater` with reverse Z) only
/// has the ghost's own surfaces to compete with when the scene under it is a
/// far plane. With `depthOverScene` the pass under it wrote a REAL scene's
/// depth, so the body is drawn always-pass (still writing) and only the rim
/// keeps the test, against the body it outlines — or a nearer piece of the
/// virtual world would hide a real controller.
public final class SenseGhostRenderer {
    private struct Obj {
        var model: simd_float4x4
        var color: SIMD4<Float>
        var params: SIMD4<Float>       // x inflate (m), y alpha, z lit
    }

    static let msl = """
    #include <metal_stdlib>
    using namespace metal;
    struct SGVert { packed_float3 p; packed_float3 n; float2 uv; };
    struct SGView { float4x4 vp; };
    struct SGObj  { float4x4 model; float4 color; float4 params; };
    struct SGOut  { float4 pos [[position]]; float3 n; float2 uv; };
    vertex SGOut sg_v(uint vid [[vertex_id]], ushort amp [[amplification_id]],
                      const device SGVert *vb [[buffer(0)]],
                      constant SGView *views [[buffer(1)]],
                      constant SGObj &o [[buffer(2)]]) {
        SGVert v = vb[vid];
        float3 p = float3(v.p) + float3(v.n) * o.params.x;
        SGOut out;
        out.pos = views[amp].vp * (o.model * float4(p, 1));
        out.n = (o.model * float4(float3(v.n), 0)).xyz;
        out.uv = v.uv;
        return out;
    }
    fragment float4 sg_solid_f(SGOut in [[stage_in]], constant SGObj &o [[buffer(0)]]) {
        float3 L = normalize(float3(0.3, 1.0, 0.45));
        float3 n = normalize(in.n);
        float lit = o.params.z > 0.5 ? (0.58 + 0.42 * max(dot(n, L), 0.0)) : 1.0;
        float a = o.color.a * o.params.y;
        return float4(o.color.rgb * lit * a, a);
    }
    """

    private let pipeline: MTLRenderPipelineState
    /// Nearer-passes, write: `.greater` with reverse Z, `.less` otherwise.
    private let depthTest: MTLDepthStencilState
    /// Always, write.
    private let depthAlways: MTLDepthStencilState
    private let mesh: [(vb: MTLBuffer, ib: MTLBuffer, count: Int)]

    /// `colorFormat` / `depthFormat` are the encoder's attachments,
    /// `amplification` its `maxVertexAmplificationCount`, `reverseZ` whether
    /// the depth buffer is reverse-Z (nearer is greater; visionOS's is).
    public init(device: MTLDevice, colorFormat: MTLPixelFormat,
                depthFormat: MTLPixelFormat = .depth32Float,
                amplification: Int, reverseZ: Bool = true) throws {
        let lib = try device.makeLibrary(source: Self.msl, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "sg_v")
        d.fragmentFunction = lib.makeFunction(name: "sg_solid_f")
        d.colorAttachments[0].pixelFormat = colorFormat
        d.depthAttachmentPixelFormat = depthFormat
        d.maxVertexAmplificationCount = amplification
        let c = d.colorAttachments[0]!
        c.isBlendingEnabled = true          // premultiplied
        c.rgbBlendOperation = .add; c.alphaBlendOperation = .add
        c.sourceRGBBlendFactor = .one; c.sourceAlphaBlendFactor = .one
        c.destinationRGBBlendFactor = .oneMinusSourceAlpha
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: d)

        let g = MTLDepthStencilDescriptor()
        g.depthCompareFunction = reverseZ ? .greater : .less
        g.isDepthWriteEnabled = true
        let t = MTLDepthStencilDescriptor()
        t.depthCompareFunction = .always
        t.isDepthWriteEnabled = true
        guard let test = device.makeDepthStencilState(descriptor: g),
              let always = device.makeDepthStencilState(descriptor: t)
        else { throw SenseGhostRendererError.depthState }
        depthTest = test
        depthAlways = always

        var meshes: [(vb: MTLBuffer, ib: MTLBuffer, count: Int)] = []
        for hand in SenseHand.allCases {
            let m = SenseGhostMesh.sense(right: hand == .right)
            guard m.vertexCount < 65535,
                  let vb = device.makeBuffer(bytes: m.vertices, length: m.vertices.count * 4,
                                             options: .storageModeShared),
                  let ib = device.makeBuffer(bytes: m.indices, length: m.indices.count * 2,
                                             options: .storageModeShared)
            else { throw SenseGhostRendererError.meshBuffer }
            meshes.append((vb, ib, m.indices.count))
        }
        mesh = meshes
    }

    /// Draw every ghost with alpha > 0. `views` is one entry per amplified
    /// view, in the encoder's view order; `recenter` maps the samples' space
    /// (ARKit origin) into the views' space.
    public func encode(_ enc: MTLRenderCommandEncoder, views: [SenseGhostView],
                       recenter: simd_float4x4, ghosts: SenseGhosts, depthOverScene: Bool) {
        guard !views.isEmpty, mesh.count == 2 else { return }
        let cfg = ghosts.configuration
        enc.setFrontFacing(.counterClockwise)
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthTest)
        views.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
        for h in 0...1 where ghosts.hands[h].alpha > 0 {
            if depthOverScene { enc.setDepthStencilState(depthAlways) }
            let m = mesh[h]
            let alpha = ghosts.hands[h].alpha
            let model = recenter * ghosts.hands[h].pose * cfg.fit
            // Body (light grey, lit), then the soft outline: the same mesh
            // pushed out along its normals with its FRONT faces culled, so only
            // the rim around the silhouette survives.
            var body = Obj(model: model, color: cfg.bodyColor, params: SIMD4(0, alpha, 1, 0))
            var rim = Obj(model: model, color: cfg.rimColor, params: SIMD4(cfg.rimWidth, alpha, 0, 0))
            enc.setVertexBuffer(m.vb, offset: 0, index: 0)
            enc.setCullMode(.back)
            enc.setVertexBytes(&body, length: MemoryLayout<Obj>.stride, index: 2)
            enc.setFragmentBytes(&body, length: MemoryLayout<Obj>.stride, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: m.count, indexType: .uint16,
                                      indexBuffer: m.ib, indexBufferOffset: 0)
            enc.setCullMode(.front)
            if depthOverScene { enc.setDepthStencilState(depthTest) }
            enc.setVertexBytes(&rim, length: MemoryLayout<Obj>.stride, index: 2)
            enc.setFragmentBytes(&rim, length: MemoryLayout<Obj>.stride, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: m.count, indexType: .uint16,
                                      indexBuffer: m.ib, indexBufferOffset: 0)
        }
        enc.setCullMode(.none)
    }
}
