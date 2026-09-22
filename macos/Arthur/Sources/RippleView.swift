import Metal
import MetalKit
import SwiftUI

struct SpeakingRipple: View {
  var active: Bool
  var energy: Double = 0
  var restrained = false

  var body: some View {
    RippleMetal(active: active, energy: Float(energy), restrained: restrained)
      .opacity(active ? (restrained ? 0.80 : 0.96) : 0)
      .mask {
        LinearGradient(
          stops: restrained
            ? [
              .init(color: .black, location: 0),
              .init(color: .black.opacity(0.94), location: 0.16),
              .init(color: .black.opacity(0.64), location: 0.48),
              .init(color: .black.opacity(0.28), location: 0.74),
              .init(color: .clear, location: 0.94),
            ]
            : [
              .init(color: .black, location: 0),
              .init(color: .black.opacity(0.98), location: 0.18),
              .init(color: .black.opacity(0.84), location: 0.46),
              .init(color: .black.opacity(0.50), location: 0.74),
              .init(color: .clear, location: 0.97),
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

    let breath: Float = active ? 0.14 + 0.08 * (0.5 + 0.5 * sin(time * 0.30)) : 0
    let target: Float = active ? min(1, 0.28 + raw * 0.50 + breath) : 0
    let tau: Float = active ? 0.52 : 0.78
    smooth += (target - smooth) * (1 - exp(-dt / tau))

    onset *= exp(-dt / (active ? 1.10 : 0.48))

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
    let tau: Float = active ? 0.90 : 1.35
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
  // hang across the pane; `speed` is sheet-spacings per second (~20–30s).
  // Wider `width` + fewer sheets = broad night-sky bands, not thin ribbons.
  float aurora_sheet(float x, float y, float t, float sheets, float phase,
                     float speed, float width, float tilt) {
    float xt = x + tilt * (1.0 - y);
    xt += 0.090 * sin(y * 1.05 + t * 0.14 + phase * 0.65);
    xt += 0.048 * sin(y * 1.90 + t * 0.22 + phase);
    xt += 0.016 * sin(y * 3.20 + t * 0.17 + phase * 1.35);
    float p = xt * sheets - t * speed - phase;
    float d = abs(p - round(p));
    return exp(-(d * d) / max(width * width, 0.0004));
  }

  fragment float4 ripple_fragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float2 uv = in.uv;
    float t = u.time;
    float x = uv.x + 0.040 * sin(t * 0.085);
    float y = uv.y;
    float ytop = saturate(1.0 - uv.y);

    float width = 0.38 + 0.16 * u.energy + 0.04 * u.onset;
    float bright = 0.60 + 0.26 * u.energy + 0.08 * u.onset;
    if (u.restrained > 0.5) {
      bright *= 0.72;
      width *= 0.96;
    }

    float cWash    = aurora_sheet(x, y, t, 0.78, 0.04, 0.022, width * 1.85, 0.08);
    float cGreen   = aurora_sheet(x, y, t, 1.08, 0.12, 0.038, width * 1.42, 0.12);
    float cViolet  = aurora_sheet(x, y, t, 1.28, 0.58, 0.028, width * 1.22, 0.18);
    float cTeal    = aurora_sheet(x, y, t, 0.90, 1.14, 0.024, width * 1.58, 0.09);
    float cMagenta = aurora_sheet(x, y, t, 1.48, 1.72, 0.032, width * 1.02, 0.14);

    float shimmer = 0.90 + 0.10 * sin(y * 1.15 + t * 0.28);
    float height = saturate(0.36 + 0.64 * exp(-ytop * (0.46 - 0.14 * u.energy)));
    cWash    *= shimmer * height;
    cGreen   *= shimmer * height;
    cViolet  *= shimmer * (0.88 + 0.12 * height);
    cTeal    *= shimmer * height;
    cMagenta *= shimmer * (0.76 + 0.24 * height);

    float3 green   = float3(0.22, 0.95, 0.48);
    float3 teal    = float3(0.12, 0.82, 0.76);
    float3 violet  = float3(0.52, 0.30, 0.98);
    float3 magenta = float3(0.88, 0.28, 0.64);
    float3 indigo  = float3(0.07, 0.08, 0.18);

    float3 aur = green * (cGreen * bright)
               + violet * (cViolet * bright * 0.86)
               + teal * (cTeal * bright * 0.80)
               + magenta * (cMagenta * bright * 0.58)
               + indigo * (cWash * bright * 0.40);
    float cover = cWash * 0.75 + cGreen * 0.78 + cViolet * 0.60
                + cTeal * 0.52 + cMagenta * 0.36;

    float sky = smoothstep(0.0, 0.022, ytop) * (1.0 - 0.42 * smoothstep(0.34, 0.98, ytop));
    if (u.restrained > 0.5) {
      sky *= (1.0 - 0.20 * smoothstep(0.24, 0.82, ytop));
    }
    float sides = smoothstep(0.0, 0.010, uv.x) * smoothstep(1.0, 0.990, uv.x);

    float night = 0.15 * (0.74 + 0.26 * u.energy);
    float a = saturate(u.opacity * sky * sides * (night + cover * bright * 0.56));
    float cap = u.restrained > 0.5 ? 0.36 : 0.52;
    a = min(a, cap + 0.02 * u.onset);

    float3 col = saturate(indigo * 0.36 + aur);
    return float4(col * a, a);
  }
  """
}
