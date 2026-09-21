import Metal
import MetalKit
import SwiftUI

struct SpeakingRipple: View {
  var active: Bool
  var restrained = false

  var body: some View {
    RippleMetal(active: active)
      .opacity(active ? (restrained ? 0.48 : 0.88) : 0)
      .mask {
        LinearGradient(
          stops: [
            .init(color: .black, location: 0),
            .init(color: .black.opacity(0.78), location: 0.52),
            .init(color: .clear, location: 1),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
      }
      .animation(.easeInOut(duration: 1.15), value: active)
      .animation(.easeInOut(duration: 0.35), value: restrained)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

private struct RippleMetal: NSViewRepresentable {
  var active: Bool

  func makeCoordinator() -> RippleRenderer { RippleRenderer() }

  func makeNSView(context: Context) -> MTKView {
    let view = MTKView()
    context.coordinator.attach(view)
    context.coordinator.active = active
    return view
  }

  func updateNSView(_ view: MTKView, context: Context) {
    context.coordinator.active = active
    if active { view.isPaused = false }
  }
}

final class RippleRenderer: NSObject, MTKViewDelegate {
  var active = false
  private(set) var opacity: Float = 0

  private var device: MTLDevice?
  private var queue: MTLCommandQueue?
  private var pipeline: MTLRenderPipelineState?
  private var uniforms: MTLBuffer?
  private var t0 = CACurrentMediaTime()
  private var last = CACurrentMediaTime()
  private weak var view: MTKView?

  func attach(_ view: MTKView) {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    self.device = device
    self.view = view
    view.device = device
    view.delegate = self
    view.framebufferOnly = true
    view.isPaused = false
    view.enableSetNeedsDisplay = false
    view.preferredFramesPerSecond = 30
    view.colorPixelFormat = .bgra8Unorm
    view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    view.wantsLayer = true
    view.layer?.isOpaque = false
    view.layer?.backgroundColor = CGColor(gray: 0, alpha: 0)
    if let metal = view.layer as? CAMetalLayer {
      metal.isOpaque = false
    }
    queue = device.makeCommandQueue()
    uniforms = device.makeBuffer(length: MemoryLayout<RippleUniforms>.stride, options: .storageModeShared)
    pipeline = Self.makePipeline(device: device, pixelFormat: view.colorPixelFormat)
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    let now = CACurrentMediaTime()
    let dt = Float(min(now - last, 0.05))
    last = now
    let target: Float = active ? 1 : 0
    let tau: Float = active ? 0.55 : 0.9
    opacity += (target - opacity) * (1 - exp(-dt / tau))
    if opacity < 0.008, !active {
      view.isPaused = true
      return
    }

    guard let pipeline, let queue, let uniforms,
          let drawable = view.currentDrawable,
          let descriptor = view.currentRenderPassDescriptor
    else { return }

    var u = RippleUniforms()
    u.time = Float(now - t0)
    u.aspect = Float(max(view.drawableSize.width / max(view.drawableSize.height, 1), 0.5))
    u.opacity = opacity
    uniforms.contents().assumingMemoryBound(to: RippleUniforms.self).pointee = u

    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

    guard let cmd = queue.makeCommandBuffer(),
          let enc = cmd.makeRenderCommandEncoder(descriptor: descriptor)
    else { return }
    enc.setRenderPipelineState(pipeline)
    enc.setVertexBuffer(uniforms, offset: 0, index: 0)
    enc.setFragmentBuffer(uniforms, offset: 0, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
    cmd.present(drawable)
    cmd.commit()
  }

  private static func makePipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
    guard let library = try? device.makeLibrary(source: RippleShaderSource.source, options: nil),
          let vs = library.makeFunction(name: "ripple_vertex"),
          let fs = library.makeFunction(name: "ripple_fragment")
    else { return nil }
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = vs
    desc.fragmentFunction = fs
    desc.colorAttachments[0].pixelFormat = pixelFormat
    desc.colorAttachments[0].isBlendingEnabled = true
    desc.colorAttachments[0].sourceRGBBlendFactor = .one
    desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    desc.colorAttachments[0].sourceAlphaBlendFactor = .one
    desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    return try? device.makeRenderPipelineState(descriptor: desc)
  }
}

private struct RippleUniforms {
  var time: Float = 0
  var aspect: Float = 1
  var opacity: Float = 0
}

private enum RippleShaderSource {
  static let source = """
  #include <metal_stdlib>
  using namespace metal;

  struct Uniforms {
    float time;
    float aspect;
    float opacity;
  };

  struct VertexOut {
    float4 position [[position]];
    float2 uv;
  };

  vertex VertexOut ripple_vertex(uint vid [[vertex_id]]) {
    float2 pos[3] = { float2(-1.0, -1.0), float2(-1.0, 3.0), float2(3.0, -1.0) };
    VertexOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv = pos[vid] * 0.5 + 0.5;
    return out;
  }

  fragment float4 ripple_fragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float2 uv = in.uv;
    float t = u.time * 0.32;
    float2 p = uv * float2(3.1 * max(u.aspect, 0.7), 1.85);
    p.x += 0.22 * sin(p.y * 1.45 + t * 0.9);
    p.y += 0.16 * sin(p.x * 1.18 + t * 0.68);

    float w = 0.0;
    w += 0.50 * sin(p.x * 1.7 + t * 1.1);
    w += 0.38 * sin(p.y * 2.15 - t * 0.82);
    w += 0.26 * sin((p.x + p.y) * 1.4 + t * 0.5);
    w += 0.18 * sin((p.x - p.y) * 1.9 - t * 0.64);
    w += 0.12 * sin(p.x * 3.1 + p.y * 1.05 + t * 1.4);

    float field = saturate(0.5 + 0.5 * w);
    float caustic = pow(field, 3.6);
    float wash = pow(field, 2.4) * 0.22;
    float light = wash + caustic * 0.85;

    float y = saturate(1.0 - uv.y);
    float falloff = smoothstep(0.0, 0.06, y) * smoothstep(1.0, 0.08, y);
    float sides = smoothstep(0.0, 0.05, uv.x) * smoothstep(1.0, 0.95, uv.x);
    float a = saturate(u.opacity * falloff * sides * light * 0.34);

    float3 deep = float3(1.0, 0.30, 0.04);
    float3 hot = float3(1.0, 0.55, 0.14);
    float3 col = mix(deep, hot, saturate(caustic));
    return float4(col * a, a);
  }
  """
}
