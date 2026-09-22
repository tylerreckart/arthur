import Metal
import MetalKit
import SwiftUI

struct SpeakingRipple: View {
  var active: Bool
  var energy: Double = 0
  var restrained = false

  var body: some View {
    RippleMetal(active: active, energy: Float(energy), restrained: restrained)
      // Restrained is still dimmer than full, but stronger than the old full-mode wash.
      .opacity(active ? (restrained ? 0.82 : 1.0) : 0)
      .mask {
        LinearGradient(
          stops: restrained
            ? [
              .init(color: .black, location: 0),
              .init(color: .black.opacity(0.94), location: 0.18),
              .init(color: .black.opacity(0.58), location: 0.46),
              .init(color: .black.opacity(0.18), location: 0.68),
              .init(color: .clear, location: 0.86),
            ]
            : [
              .init(color: .black, location: 0),
              .init(color: .black.opacity(0.98), location: 0.20),
              .init(color: .black.opacity(0.78), location: 0.48),
              .init(color: .black.opacity(0.38), location: 0.70),
              .init(color: .clear, location: 0.92),
            ],
          startPoint: .top,
          endPoint: .bottom
        )
      }
      .animation(active ? .easeOut(duration: 0.16) : .easeInOut(duration: 1.12), value: active)
      .animation(.easeInOut(duration: 0.35), value: restrained)
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

/// CPU-side speak envelope. Audio RMS is the lead; onset / shimmer / flashes
/// keep the wash from looking like one looping sine when TTS is flat.
private struct SpeakMotion {
  var energy: Float = 0
  var onset: Float = 0
  var flash: Float = 0
  var drive: Float = 0

  private var smooth: Float = 0
  private var flashEnv: Float = 0
  private var wasActive = false
  private var prevRaw: Float = 0
  private var nextFlash: Float = 0.22

  mutating func tick(dt: Float, time: Float, active: Bool, raw: Float, restrained: Bool) {
    if active && !wasActive {
      onset = 1
      flashEnv = restrained ? 0.72 : 1
      smooth = max(smooth, restrained ? 0.74 : 0.88)
      nextFlash = 0.14
    }
    wasActive = active

    let shimmer: Float
    if active {
      let s1 = sin(time * 2.17)
      let s2 = sin(time * 3.71 + 1.3)
      let s3 = sin(time * 0.91 + 2.4)
      let syllable = max(0, s1 * s2)
      shimmer = 0.24 + 0.18 * (0.5 + 0.5 * s3) + 0.28 * syllable * syllable
    } else {
      shimmer = 0
    }

    let target: Float = active ? min(1, max(raw, shimmer) + raw * 0.42) : 0
    let tau: Float = active ? 0.070 : 0.30
    smooth += (target - smooth) * (1 - exp(-dt / tau))

    onset *= exp(-dt / (active ? 0.28 : 0.12))

    let attack = raw - prevRaw
    prevRaw = raw
    if active, attack > 0.08 {
      flashEnv = min(1, flashEnv + attack * (restrained ? 1.35 : 2.25))
    }

    nextFlash -= dt
    if active, nextFlash <= 0 {
      nextFlash = 0.22 + Float.random(in: 0.14...0.78)
      if smooth > 0.12 {
        flashEnv = min(1, flashEnv + Float.random(in: 0.22...0.58) * (restrained ? 0.68 : 1))
      }
    }
    flashEnv *= exp(-dt / 0.16)

    let breath = 0.5 + 0.5 * sin(time * 0.74)
    let gain: Float = restrained ? 0.92 : 1.18
    energy = min(1, smooth * gain)
    drive = gain * (0.90 + 0.42 * smooth + 0.38 * onset + 0.10 * breath)
    flash = min(1, flashEnv * (restrained ? 0.82 : 1))
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
    view.preferredFramesPerSecond = 45
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
    let tau: Float = active ? 0.38 : 0.85
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

  float3 ripple_hue(float h) {
    h = fract(h);
    float3 ember  = float3(1.00, 0.32, 0.06);
    float3 ruby   = float3(0.96, 0.10, 0.16);
    float3 violet = float3(0.56, 0.22, 0.92);
    float3 aurora = float3(0.10, 0.78, 0.46);
    float3 gold   = float3(1.00, 0.70, 0.26);
    float3 c = mix(ember, ruby,   smoothstep(0.00, 0.18, h));
    c = mix(c, violet, smoothstep(0.18, 0.40, h));
    c = mix(c, aurora, smoothstep(0.40, 0.62, h));
    c = mix(c, gold,   smoothstep(0.62, 0.82, h));
    c = mix(c, ember,  smoothstep(0.82, 1.00, h));
    return c;
  }

  fragment float4 ripple_fragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float2 uv = in.uv;
    float t = u.time * (0.22 + 0.26 * u.drive);
    float asp = max(u.aspect, 0.7);

    // Large aurora lobes (~1.4×1.2 cycles) with inner veins — reads across
    // the window instead of a dense 152px top strip of tiny ripples.
    float2 p = uv * float2(2.20 * asp, 1.35);
    p.x += 0.09 * u.time * 0.038;
    p.x += 0.30 * sin(p.y * 1.35 + t * 0.72);
    p.y += 0.24 * sin(p.x * 1.12 + t * 0.54);
    p.y += 0.08 * u.energy * sin(t * 1.10);

    float sx = sin(p.x * 5.00 + t * 0.95);
    float sy = sin(p.y * 5.60 - t * 0.78);
    float sd = sin((p.x + p.y) * 3.80 + t * 0.42);
    float sm = sin((p.x - p.y) * 4.20 - t * 0.50);
    float detail = 0.52 + 0.48 * sin(p.x * 8.4 + p.y * 6.6 + t * 1.45);

    float ridges = saturate(sx * sy);
    float diag = saturate(sd * sm);
    float caustic = (pow(ridges, 2.05) * 0.62 + pow(diag, 2.25) * 0.40) * detail;
    caustic += pow(saturate(sx), 2.20) * 0.22;
    caustic += pow(saturate(sy), 2.20) * 0.18;
    caustic += (0.10 + 0.22 * u.energy + 0.28 * u.flash) * pow(saturate(detail * ridges), 2.4);

    float wash = (0.26 + 0.16 * u.energy + 0.18 * u.onset) * pow(saturate(0.52 + 0.28 * sx + 0.28 * sy), 1.45);
    float veil = 0.16 + 0.10 * u.energy + 0.16 * u.onset;
    float2 bloomP = float2((uv.x - 0.5) * 1.05, (1.0 - uv.y) * 0.68);
    float bloom = (0.16 + 0.64 * u.onset) * exp(-dot(bloomP, bloomP) * 1.00);
    float light = veil + wash + caustic * (1.08 + 0.48 * u.energy + 0.58 * u.flash) + bloom * 0.52;

    float y = saturate(1.0 - uv.y);
    float cover = u.restrained > 0.5 ? 0.17 : 0.32;
    float falloff = smoothstep(0.0, 0.028, y) * smoothstep(1.0, cover, y);
    falloff = max(falloff, smoothstep(1.0, 0.11, y) * 0.24);
    float sides = smoothstep(0.0, 0.016, uv.x) * smoothstep(1.0, 0.984, uv.x);

    float gain = 0.46 + 0.20 * u.energy + 0.16 * u.onset + 0.10 * u.flash;
    if (u.restrained > 0.5) gain *= 0.88;
    float a = saturate(u.opacity * falloff * sides * light * gain);
    float cap = u.restrained > 0.5 ? 0.48 : 0.60;
    a = min(a, cap + 0.10 * u.onset + 0.08 * u.flash);

    // Oil-slick / aurora: orange brand veil, jewel sheen on the lobes.
    float h = 0.06 + 0.07 * u.time * 0.12 + 0.34 * saturate(sx) + 0.24 * saturate(sy)
            + 0.16 * uv.x + 0.10 * caustic + 0.08 * u.flash;
    float3 sheen = ripple_hue(h);
    float3 ember = float3(1.00, 0.32, 0.06);
    float3 gold  = float3(1.00, 0.70, 0.26);
    float3 veilCol = ripple_hue(0.12 + 0.22 * uv.x + 0.18 * (1.0 - uv.y) + 0.10 * saturate(sx));
    float3 base = ember * 0.68 + veilCol * 0.32;
    float mixAmt = 0.40 + 0.46 * caustic + 0.08 * u.flash;
    float3 col = mix(base, sheen, mixAmt);
    col = mix(col, gold, saturate(u.flash * caustic * 0.48));
    return float4(col * a, a);
  }
  """
}
