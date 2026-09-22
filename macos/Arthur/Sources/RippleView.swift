import Metal
import MetalKit
import SwiftUI

struct SpeakingRipple: View {
  var active: Bool
  var energy: Double = 0
  var restrained = false

  var body: some View {
    RippleMetal(active: active, energy: Float(energy), restrained: restrained)
      .opacity(active ? (restrained ? 0.72 : 0.92) : 0)
      .mask {
        LinearGradient(
          stops: restrained
            ? [
              .init(color: .black, location: 0),
              .init(color: .black.opacity(0.90), location: 0.14),
              .init(color: .black.opacity(0.50), location: 0.40),
              .init(color: .black.opacity(0.16), location: 0.62),
              .init(color: .clear, location: 0.80),
            ]
            : [
              .init(color: .black, location: 0),
              .init(color: .black.opacity(0.96), location: 0.14),
              .init(color: .black.opacity(0.74), location: 0.38),
              .init(color: .black.opacity(0.32), location: 0.64),
              .init(color: .clear, location: 0.90),
            ],
          startPoint: .top,
          endPoint: .bottom
        )
      }
      .animation(active ? .easeInOut(duration: 0.85) : .easeInOut(duration: 1.30), value: active)
      .animation(.easeInOut(duration: 0.40), value: restrained)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

private struct RippleMetal: NSViewRepresentable {
  var active: Bool
  var energy: Float
  var restrained: Bool

  func makeCoordinator() -> RippleRenderer { RippleRenderer() }

  func makeNSView(context: Context) -> MTKView {
    let view = MTKView()
    context.coordinator.attach(view)
    context.coordinator.active = active
    context.coordinator.energy = energy
    context.coordinator.restrained = restrained
    return view
  }

  func updateNSView(_ view: MTKView, context: Context) {
    context.coordinator.active = active
    context.coordinator.energy = energy
    context.coordinator.restrained = restrained
    if active || context.coordinator.opacity > 0.008 { view.isPaused = false }
  }
}

/// Slow speak envelope. RMS brightens and widens curtains; no attack flashes.
private struct SpeakMotion {
  var energy: Float = 0
  var onset: Float = 0
  var flash: Float = 0
  var drive: Float = 0

  private var smooth: Float = 0
  private var wasActive = false

  mutating func tick(dt: Float, time: Float, active: Bool, raw: Float, restrained: Bool) {
    if active && !wasActive {
      onset = 0.42
      smooth = max(smooth, restrained ? 0.28 : 0.36)
    }
    wasActive = active

    let breath: Float = active ? 0.16 + 0.07 * (0.5 + 0.5 * sin(time * 0.48)) : 0
    let target: Float = active ? min(1, 0.22 + raw * 0.58 + breath) : 0
    let tau: Float = active ? 0.36 : 0.58
    smooth += (target - smooth) * (1 - exp(-dt / tau))

    onset *= exp(-dt / (active ? 0.90 : 0.40))

    let gain: Float = restrained ? 0.70 : 1
    energy = min(1, smooth * gain)
    drive = 1
    flash = 0
  }
}

final class RippleRenderer: NSObject, MTKViewDelegate {
  var active = false
  var energy: Float = 0
  var restrained = false
  private(set) var opacity: Float = 0

  private var device: MTLDevice?
  private var queue: MTLCommandQueue?
  private var pipeline: MTLRenderPipelineState?
  private var uniforms: MTLBuffer?
  private var t0 = CACurrentMediaTime()
  private var last = CACurrentMediaTime()
  private var motion = SpeakMotion()
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
    let tau: Float = active ? 0.70 : 1.15
    opacity += (target - opacity) * (1 - exp(-dt / tau))

    let time = Float(now - t0)
    motion.tick(dt: dt, time: time, active: active, raw: energy, restrained: restrained)

    if opacity < 0.008, !active {
      view.isPaused = true
      return
    }

    guard let pipeline, let queue, let uniforms,
          let drawable = view.currentDrawable,
          let descriptor = view.currentRenderPassDescriptor
    else { return }

    var u = RippleUniforms()
    u.time = time
    u.aspect = Float(max(view.drawableSize.width / max(view.drawableSize.height, 1), 0.5))
    u.opacity = opacity
    u.energy = motion.energy
    u.onset = motion.onset
    u.flash = motion.flash
    u.drive = motion.drive
    u.restrained = restrained ? 1 : 0
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
  var energy: Float = 0
  var onset: Float = 0
  var flash: Float = 0
  var drive: Float = 0
  var restrained: Float = 0
}

private enum RippleShaderSource {
  static let source = """
  #include <metal_stdlib>
  using namespace metal;

  struct Uniforms {
    float time;
    float aspect;
    float opacity;
    float energy;
    float onset;
    float flash;
    float drive;
    float restrained;
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

  // Soft vertical / diagonal Gaussian curtain. `sheets` is how many
  // hang across the pane; `speed` is sheet-spacings per second (~8–12s).
  float aurora_sheet(float x, float y, float t, float sheets, float phase,
                     float speed, float width, float tilt) {
    float xt = x + tilt * (1.0 - y);
    xt += 0.050 * sin(y * 2.4 + t * 0.38 + phase);
    xt += 0.022 * sin(y * 4.0 + t * 0.22 + phase * 1.3);
    float p = xt * sheets - t * speed - phase;
    float d = abs(p - round(p));
    return exp(-(d * d) / max(width * width, 0.0004));
  }

  fragment float4 ripple_fragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float2 uv = in.uv;
    float t = u.time;
    float x = uv.x;
    float y = uv.y;
    float ytop = saturate(1.0 - uv.y);

    float width = 0.16 + 0.10 * u.energy + 0.03 * u.onset;
    float bright = 0.50 + 0.32 * u.energy + 0.10 * u.onset;
    if (u.restrained > 0.5) {
      bright *= 0.62;
      width *= 0.88;
    }

    float cGreen   = aurora_sheet(x, y, t, 2.05, 0.10, 0.085, width * 1.15, 0.18);
    float cViolet  = aurora_sheet(x, y, t, 2.55, 0.62, 0.062, width * 0.92, 0.24);
    float cTeal    = aurora_sheet(x, y, t, 1.55, 1.18, 0.048, width * 1.25, 0.12);
    float cMagenta = aurora_sheet(x, y, t, 3.05, 1.85, 0.070, width * 0.72, 0.20);

    float shimmer = 0.82 + 0.18 * sin(y * 1.8 + t * 0.52);
    float height = saturate(0.20 + 0.80 * exp(-ytop * (0.95 - 0.22 * u.energy)));
    cGreen   *= shimmer * height;
    cViolet  *= shimmer * (0.85 + 0.15 * height);
    cTeal    *= shimmer * height;
    cMagenta *= shimmer * (0.70 + 0.30 * height);

    float3 green   = float3(0.22, 0.95, 0.48);
    float3 teal    = float3(0.12, 0.82, 0.76);
    float3 violet  = float3(0.52, 0.30, 0.98);
    float3 magenta = float3(0.88, 0.28, 0.64);
    float3 indigo  = float3(0.07, 0.08, 0.18);

    float3 aur = green * (cGreen * bright)
               + violet * (cViolet * bright * 0.90)
               + teal * (cTeal * bright * 0.78)
               + magenta * (cMagenta * bright * 0.70);
    float cover = cGreen * 0.85 + cViolet * 0.70 + cTeal * 0.55 + cMagenta * 0.45;

    float sky = smoothstep(0.0, 0.045, ytop) * (1.0 - 0.72 * smoothstep(0.22, 0.92, ytop));
    if (u.restrained > 0.5) {
      sky *= (1.0 - 0.35 * smoothstep(0.18, 0.70, ytop));
    }
    float sides = smoothstep(0.0, 0.028, x) * smoothstep(1.0, 0.972, x);

    float night = 0.09 * (0.70 + 0.30 * u.energy);
    float a = saturate(u.opacity * sky * sides * (night + cover * bright * 0.62));
    float cap = u.restrained > 0.5 ? 0.30 : 0.44;
    a = min(a, cap + 0.03 * u.onset);

    float3 col = saturate(indigo * 0.40 + aur);
    return float4(col * a, a);
  }
  """
}
