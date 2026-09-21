import AVFoundation
import Foundation

final class AudioIO {
  static let sampleRate: Double = 24_000
  static let frameSamples = 1024

  var onCapture: ((Data) -> Void)?
  var soundEnabled = true {
    didSet { applyVolume() }
  }

  private let captureEngine = AVAudioEngine()
  private let playEngine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var converter: AVAudioConverter?
  private var capturing = false
  private var leftover = Data()
  private let playFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: sampleRate,
    channels: 1,
    interleaved: false
  )!

  func requestMic(_ done: @escaping (Bool) -> Void) {
    AVCaptureDevice.requestAccess(for: .audio) { ok in
      DispatchQueue.main.async { done(ok) }
    }
  }

  func startPlayback() throws {
    if playEngine.isRunning { return }
    playEngine.attach(player)
    playEngine.connect(player, to: playEngine.mainMixerNode, format: playFormat)
    playEngine.prepare()
    try playEngine.start()
    player.play()
    applyVolume()
  }

  func stopPlayback() {
    player.stop()
    if playEngine.isRunning { playEngine.stop() }
  }

  func interruptPlayback() {
    leftover.removeAll(keepingCapacity: true)
    player.stop()
    if playEngine.isRunning { player.play() }
  }

  func playPCM(_ data: Data) {
    guard soundEnabled, !data.isEmpty else {
      leftover.removeAll(keepingCapacity: true)
      return
    }
    leftover.append(data)
    let even = leftover.count & ~1
    guard even >= 2 else { return }
    let chunk = leftover.prefix(even)
    leftover.removeSubrange(..<even)

    let frames = even / 2
    guard let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)) else {
      return
    }
    buffer.frameLength = AVAudioFrameCount(frames)
    guard let dest = buffer.floatChannelData?[0] else { return }
    chunk.withUnsafeBytes { raw in
      let src = raw.bindMemory(to: Int16.self)
      for i in 0..<frames {
        dest[i] = Float(src[i]) / 32768.0
      }
    }
    player.scheduleBuffer(buffer)
    if !player.isPlaying { player.play() }
  }

  func startCapture() throws {
    if capturing { return }
    leftover.removeAll(keepingCapacity: true)
    let input = captureEngine.inputNode
    let hw = input.inputFormat(forBus: 0)
    guard hw.sampleRate > 0, hw.channelCount > 0 else {
      throw NSError(domain: "Arthur", code: 1, userInfo: [NSLocalizedDescriptionKey: "no input format"])
    }
    let target = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: Self.sampleRate,
      channels: 1,
      interleaved: true
    )!
    converter = AVAudioConverter(from: hw, to: target)
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 2048, format: hw) { [weak self] buffer, _ in
      self?.convert(buffer, target: target)
    }
    captureEngine.prepare()
    try captureEngine.start()
    capturing = true
  }

  func stopCapture() {
    guard capturing else { return }
    captureEngine.inputNode.removeTap(onBus: 0)
    captureEngine.stop()
    capturing = false
    converter = nil
  }

  private func applyVolume() {
    playEngine.mainMixerNode.outputVolume = soundEnabled ? 1 : 0
    if !soundEnabled {
      leftover.removeAll(keepingCapacity: true)
    }
  }

  private func convert(_ buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
    guard let converter else { return }
    let ratio = target.sampleRate / buffer.format.sampleRate
    let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames) else { return }
    var consumed = false
    var error: NSError?
    let inputBlock: AVAudioConverterInputBlock = { _, status in
      if consumed {
        status.pointee = .noDataNow
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return buffer
    }
    _ = converter.convert(to: out, error: &error, withInputFrom: inputBlock)
    guard error == nil, out.frameLength > 0, let floats = out.floatChannelData?[0] else { return }

    var pcm = Data(count: Int(out.frameLength) * 2)
    pcm.withUnsafeMutableBytes { raw in
      let dst = raw.bindMemory(to: Int16.self)
      for i in 0..<Int(out.frameLength) {
        let x = max(-1.0, min(1.0, Double(floats[i])))
        dst[i] = Int16((x * 32767.0).rounded())
      }
    }
    onCapture?(pcm)
  }
}
