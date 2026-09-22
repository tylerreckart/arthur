import Metal
import MetalKit
import SwiftUI

struct SpeakingRipple: View {
  var active: Bool
  var energy: Double = 0
  var restrained = false

  var body: some View {
    RippleMetal(active: active, energy: Float(energy), restrained: restrained)
      .opacity(active ? (restrained ? 0.46 : 0.88) : 0)
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
      flashEnv = restrained ? 0.42 : 0.86
      smooth = max(smooth, 0.58)
      nextFlash = 0.18
    }
    wasActive = active

    let shimmer: Float
    if active {
      let s1 = sin(time * 2.17)
      let s2 = sin(time * 3.71 + 1.3)
      let s3 = sin(time * 0.91 + 2.4)
      let syllable = max(0, s1 * s2)
      shimmer = 0.15 + 0.14 * (0.5 + 0.5 * s3) + 0.22 * syllable * syllable
    } else {
      shimmer = 0
    }

    let target: Float = active ? min(1, max(raw, shimmer) + raw * 0.32) : 0
    let tau: Float = active ? 0.075 : 0.30
    smooth += (target - smooth) * (1 - exp(-dt / tau))

    onset *= exp(-dt / (active ? 0.22 : 0.12))

    let attack = raw - prevRaw
    prevRaw = raw
    if active, attack > 0.09 {
      flashEnv = min(1, flashEnv + attack * (restrained ? 1.15 : 2.05))
    }

    nextFlash -= dt
    if active, nextFlash <= 0 {
      nextFlash = 0.26 + Float.random(in: 0.16...0.92)
      if smooth > 0.14 {
        flashEnv = min(1, flashEnv + Float.random(in: 0.16...0.50) * (restrained ? 0.52 : 1))
      }
    }
    flashEnv *= exp(-dt / 0.13)

    let breath = 0.5 + 0.5 * sin(time * 0.74)
    let gain: Float = restrained ? 0.68 : 1
    energy = min(1, smooth * gain)
    drive = gain * (0.72 + 0.34 * smooth + 0.28 * onset + 0.08 * breath)
    flash = min(1, flashEnv * (restrained ? 0.62 : 1))
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
  var pad: Float = 0
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
    float pad;
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
    float t = u.time * (0.26 + 0.22 * u.drive);
    float scale = 1.0 + 0.07 * u.energy + 0.11 * u.onset;
    float2 p = uv * float2(3.1 * max(u.aspect, 0.7), 1.85) * scale;
    p.x += 0.18 * u.time * 0.045;
    p.x += 0.22 * sin(p.y * 1.45 + t * 0.9);
    p.y += 0.16 * sin(p.x * 1.18 + t * 0.68);
    p.y += 0.05 * u.energy * sin(t * 1.35);

    float w = 0.0;
    w += 0.50 * sin(p.x * 1.7 + t * 1.1);
    w += 0.38 * sin(p.y * 2.15 - t * 0.82);
    w += 0.26 * sin((p.x + p.y) * 1.4 + t * 0.5);
    w += 0.18 * sin((p.x - p.y) * 1.9 - t * 0.64);
    w += 0.12 * sin(p.x * 3.1 + p.y * 1.05 + t * 1.4);
    w += (0.08 + 0.18 * u.energy + 0.24 * u.flash) * sin(p.x * 4.35 + p.y * 2.05 + t * 2.15);
    w += (0.05 + 0.10 * u.onset) * sin(p.y * 3.4 - t * 1.65);

    float field = saturate(0.5 + 0.5 * w);
    float sharp = 3.6 - 0.85 * u.flash - 0.28 * u.energy;
    float caustic = pow(field, max(sharp, 2.2));
    float wash = pow(field, 2.4) * (0.18 + 0.16 * u.energy + 0.20 * u.onset);
    float light = wash + caustic * (0.72 + 0.42 * u.energy + 0.55 * u.flash);

    float2 bloomP = float2((uv.x - 0.5) * 1.55, (1.0 - uv.y) * 1.15);
    float bloom = u.onset * exp(-dot(bloomP, bloomP) * 2.35);
    light += bloom * 0.50;

    float y = saturate(1.0 - uv.y);
    float falloff = smoothstep(0.0, 0.06, y) * smoothstep(1.0, 0.08, y);
    float sides = smoothstep(0.0, 0.05, uv.x) * smoothstep(1.0, 0.95, uv.x);
    float a = saturate(u.opacity * falloff * sides * light * (0.28 + 0.10 * u.energy + 0.08 * u.onset));
    a = min(a, 0.40 + 0.10 * u.onset + 0.06 * u.flash);

    float3 deep = float3(1.0, 0.30, 0.04);
    float3 hot = float3(1.0, 0.55, 0.14);
    float3 flare = float3(1.0, 0.68, 0.22);
    float3 col = mix(deep, hot, saturate(caustic));
    col = mix(col, flare, saturate(u.flash * caustic));
    return float4(col * a, a);
  }
  """
}
