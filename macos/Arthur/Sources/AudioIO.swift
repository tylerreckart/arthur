import AVFoundation
import CoreMedia
import Foundation

struct MicInput: Identifiable, Hashable {
  var id: String
  var name: String
}

final class AudioIO: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
  static let sampleRate: Double = 24_000
  static let frameSamples = 1024

  var onCapture: ((Data) -> Void)?
  var soundEnabled = true {
    didSet { applyVolume() }
  }
  /// Loudest sample seen since capture started, 0…1.
  private(set) var capturePeak: Double = 0
  /// Empty follows the system default input.
  var preferredDeviceID = ""

  private let session = AVCaptureSession()
  private let micOutput = AVCaptureAudioDataOutput()
  private let micQueue = DispatchQueue(label: "arthur.mic")
  private let playEngine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var capturing = false
  private var leftover = Data()
  private var nativeConverter: AVAudioConverter?
  private var nativeFormat: AVAudioFormat?
  private let playFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: sampleRate,
    channels: 1,
    interleaved: false
  )!

  static func availableInputs() -> [MicInput] {
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone],
      mediaType: .audio,
      position: .unspecified
    )
    var seen = Set<String>()
    var inputs: [MicInput] = []
    for device in discovery.devices where seen.insert(device.uniqueID).inserted {
      let name = device.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
      inputs.append(MicInput(id: device.uniqueID, name: name.isEmpty ? "Microphone" : name))
    }
    return inputs
  }

  static func captureDevice(preferredID: String) -> AVCaptureDevice? {
    if !preferredID.isEmpty {
      let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone],
        mediaType: .audio,
        position: .unspecified
      )
      if let match = discovery.devices.first(where: { $0.uniqueID == preferredID }) {
        return match
      }
    }
    return AVCaptureDevice.default(for: .audio)
  }

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

  /// RMS of 16-bit little-endian mono PCM, scaled into 0…1.
  /// Mic capture uses a higher gain; TTS playback is already hotter.
  static func pcmLevel(_ data: Data, gain: Double = 3.4) -> Double {
    let count = data.count / 2
    guard count > 0 else { return 0 }
    return data.withUnsafeBytes { raw in
      let samples = raw.bindMemory(to: Int16.self)
      var sum = 0.0
      for i in 0..<count {
        let x = Double(samples[i]) / 32768.0
        sum += x * x
      }
      return min(1, sqrt(sum / Double(count)) * gain)
    }
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
    capturePeak = 0
    session.beginConfiguration()
    for input in session.inputs { session.removeInput(input) }
    for output in session.outputs { session.removeOutput(output) }
    guard let device = Self.captureDevice(preferredID: preferredDeviceID) else {
      session.commitConfiguration()
      throw NSError(domain: "Arthur", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone"])
    }
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input), session.canAddOutput(micOutput) else {
      session.commitConfiguration()
      throw NSError(domain: "Arthur", code: 2, userInfo: [NSLocalizedDescriptionKey: "microphone is busy"])
    }
    session.addInput(input)
    micOutput.setSampleBufferDelegate(self, queue: micQueue)
    micOutput.audioSettings = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: Self.sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    session.addOutput(micOutput)
    session.commitConfiguration()
    capturing = true
    note("capture start device=\(device.localizedName)")
    micQueue.async { [weak self] in
      self?.session.startRunning()
    }
  }

  func stopCapture() {
    guard capturing else { return }
    capturing = false
    let peak = capturePeak
    note(String(format: "capture stop peak=%.5f", peak))
    micQueue.async { [weak self] in
      guard let self else { return }
      if self.session.isRunning { self.session.stopRunning() }
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard capturing else { return }
    guard let pcm = pcm16(from: sampleBuffer) else {
      noteNativeFormat(sampleBuffer)
      return
    }
    if let peak = Self.pcmPeak(pcm), peak > capturePeak { capturePeak = peak }
    onCapture?(pcm)
  }

  private func applyVolume() {
    playEngine.mainMixerNode.outputVolume = soundEnabled ? 1 : 0
    if !soundEnabled {
      leftover.removeAll(keepingCapacity: true)
    }
  }

  private func note(_ line: String) {
    let text = line + "\n"
    guard let data = text.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/arthur-mic.log")
    if FileManager.default.fileExists(atPath: url.path),
       let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      handle.seekToEndOfFile()
      handle.write(data)
    } else {
      try? data.write(to: url)
    }
  }

  private var loggedNativeFormat = false

  private func noteNativeFormat(_ sampleBuffer: CMSampleBuffer) {
    guard !loggedNativeFormat else { return }
    loggedNativeFormat = true
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
      note("capture buffer has no audio format")
      return
    }
    let desc = asbd.pointee
    note("native format id=\(desc.mFormatID) bits=\(desc.mBitsPerChannel) ch=\(desc.mChannelsPerFrame) rate=\(desc.mSampleRate) flags=\(desc.mFormatFlags)")
  }

  /// 16-bit little-endian mono PCM at 24 kHz, or nil when the buffer is not that.
  private func pcm16(from sampleBuffer: CMSampleBuffer) -> Data? {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return nil }
    let desc = asbd.pointee
    let isPCM16 =
      desc.mFormatID == kAudioFormatLinearPCM &&
      desc.mBitsPerChannel == 16 &&
      desc.mChannelsPerFrame == 1 &&
      abs(desc.mSampleRate - Self.sampleRate) < 1 &&
      (desc.mFormatFlags & kAudioFormatFlagIsFloat) == 0 &&
      (desc.mFormatFlags & kAudioFormatFlagIsBigEndian) == 0
    if !isPCM16 { return convertNative(sampleBuffer) }
    guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
    var length = 0
    var pointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(
      block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer
    )
    guard status == noErr, let pointer, length > 1 else { return nil }
    return Data(bytes: pointer, count: length & ~1)
  }

  private func convertNative(_ sampleBuffer: CMSampleBuffer) -> Data? {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format),
          let source = AVAudioFormat(streamDescription: asbd) else { return nil }
    let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
    guard frames > 0,
          let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else { return nil }
    input.frameLength = frames
    let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sampleBuffer, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList
    )
    guard copied == noErr else { return nil }
    let target = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: Self.sampleRate,
      channels: 1,
      interleaved: false
    )!
    if nativeFormat?.sampleRate != source.sampleRate || nativeFormat?.channelCount != source.channelCount {
      nativeFormat = source
      nativeConverter = AVAudioConverter(from: source, to: target)
    }
    guard let nativeConverter else { return nil }
    let ratio = target.sampleRate / source.sampleRate
    let outFrames = AVAudioFrameCount(Double(frames) * ratio + 16)
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outFrames) else { return nil }
    var consumed = false
    var error: NSError?
    let inputBlock: AVAudioConverterInputBlock = { _, status in
      if consumed {
        status.pointee = .noDataNow
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return input
    }
    _ = nativeConverter.convert(to: out, error: &error, withInputFrom: inputBlock)
    guard error == nil, out.frameLength > 0, let floats = out.floatChannelData?[0] else { return nil }
    var pcm = Data(count: Int(out.frameLength) * 2)
    pcm.withUnsafeMutableBytes { raw in
      let dst = raw.bindMemory(to: Int16.self)
      for i in 0..<Int(out.frameLength) {
        let x = max(-1.0, min(1.0, Double(floats[i])))
        dst[i] = Int16((x * 32767.0).rounded())
      }
    }
    return pcm
  }

  private static func pcmPeak(_ data: Data) -> Double? {
    let count = data.count / 2
    guard count > 0 else { return nil }
    return data.withUnsafeBytes { raw in
      let samples = raw.bindMemory(to: Int16.self)
      var peak = 0
      for i in 0..<count { peak = max(peak, abs(Int(samples[i]))) }
      return Double(peak) / 32768.0
    }
  }

}

/// Matches the daemon's energy detector: speech starts the utterance, about
/// 700 ms of trailing silence ends it, and bursts under 300 ms are ignored.
struct UtteranceEndpoint {
  let sampleRate = 24_000
  let trailingSilenceMs = 700
  let minSpeechMs = 300
  let speechRms = 0.02

  private var pending: [Int16] = []
  private var speechSamples = 0
  private var silenceSamples = 0
  private var confirmed = false
  private var odd: UInt8?

  private var windowSamples: Int { sampleRate / 50 }
  private var minSpeechSamples: Int { sampleRate * minSpeechMs / 1000 }
  private var trailingSamples: Int { sampleRate * trailingSilenceMs / 1000 }

  mutating func reset() {
    pending.removeAll(keepingCapacity: true)
    speechSamples = 0
    silenceSamples = 0
    confirmed = false
    odd = nil
  }

  mutating func push(_ data: Data) -> Bool {
    var bytes = [UInt8]()
    bytes.reserveCapacity(data.count + (odd == nil ? 0 : 1))
    if let odd { bytes.append(odd) }
    self.odd = nil
    data.withUnsafeBytes { raw in
      bytes.append(contentsOf: raw.bindMemory(to: UInt8.self))
    }
    if bytes.count % 2 == 1 {
      odd = bytes.removeLast()
    }
    var i = 0
    while i + 1 < bytes.count {
      let sample = Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
      pending.append(sample)
      i += 2
    }
    let window = windowSamples
    while pending.count >= window {
      var sum = 0.0
      for sample in pending.prefix(window) {
        let x = Double(sample) / 32768.0
        sum += x * x
      }
      pending.removeFirst(window)
      let rms = (sum / Double(window)).squareRoot()
      if rms >= speechRms {
        speechSamples += window
        silenceSamples = 0
        if speechSamples >= minSpeechSamples { confirmed = true }
      } else if speechSamples == 0 {
        continue
      } else {
        silenceSamples += window
        if !confirmed && silenceSamples >= minSpeechSamples {
          speechSamples = 0
          silenceSamples = 0
          continue
        }
      }
      if confirmed && silenceSamples >= trailingSamples { return true }
    }
    return false
  }
}
