import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import Speech

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
  /// Device opened for the current or most recent capture.
  private(set) var activeDeviceName = "microphone"
  /// Empty follows the system default input.
  var preferredDeviceID = ""
  /// Fires on the main queue when the leading name is heard.
  var onWake: (() -> Void)?

  private let session = AVCaptureSession()
  private let micOutput = AVCaptureAudioDataOutput()
  private let micQueue = DispatchQueue(label: "arthur.mic")
  private var engineConverter: AVAudioConverter?
  private var engineSourceKey = ""
  private var loggedNativeFormat = false
  private var loggedPeaks = false
  private var loggedConvertFailure = false
  private let playEngine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var capturing = false
  private var leftover = Data()
  private let clipLock = NSLock()
  private var clipSink = false
  private var clipBuffer = Data()
  private var clipHandler: ((Data?) -> Void)?
  /// Frames queued on the player since the last interrupt. Speech text uses
  /// this with `playedFrames()` so words stay with the voice.
  private(set) var scheduledFrames: AVAudioFramePosition = 0
  private var lastPlayedFrames: AVAudioFramePosition = 0
  /// Wall clock for the queued voice. The player's own timeline keeps running
  /// from app launch, so it cannot tell us which word is being spoken.
  private var playbackAnchor: Date?
  private var playbackAnchorFrames: AVAudioFramePosition = 0
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
      if device.uniqueID.hasPrefix("CADefaultDeviceAggregate") { continue }
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
    scheduledFrames = 0
    lastPlayedFrames = 0
    playbackAnchor = nil
    playbackAnchorFrames = 0
    if playEngine.isRunning { player.play() }
  }

  /// How far the voice has actually rendered, in frames at 24 kHz.
  func playedFrames() -> AVAudioFramePosition {
    guard let anchor = playbackAnchor else { return lastPlayedFrames }
    let elapsed = Date().timeIntervalSince(anchor)
    let frames = playbackAnchorFrames + AVAudioFramePosition(elapsed * Self.sampleRate)
    let played = min(scheduledFrames, max(playbackAnchorFrames, frames))
    lastPlayedFrames = played
    if played >= scheduledFrames {
      playbackAnchor = nil
      playbackAnchorFrames = played
    }
    return played
  }

  /// True while queued speech has not finished rendering.
  var playbackPending: Bool {
    scheduledFrames > playedFrames() + 1_200
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
    if playbackAnchor == nil {
      playbackAnchor = Date()
      playbackAnchorFrames = lastPlayedFrames
    }
    scheduledFrames += AVAudioFramePosition(frames)
    player.scheduleBuffer(buffer)
    if !player.isPlaying { player.play() }
  }

  func startCapture() throws {
    if capturing { return }
    leftover.removeAll(keepingCapacity: true)
    capturePeak = 0
    loggedNativeFormat = false
    loggedPeaks = false
    loggedConvertFailure = false
    engineSourceKey = ""
    engineConverter = nil
    guard let device = Self.captureDevice(preferredID: preferredDeviceID) else {
      throw NSError(domain: "Arthur", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone"])
    }
    session.beginConfiguration()
    for input in session.inputs { session.removeInput(input) }
    if !session.outputs.contains(where: { $0 === micOutput }) {
      micOutput.setSampleBufferDelegate(self, queue: micQueue)
      guard session.canAddOutput(micOutput) else {
        session.commitConfiguration()
        throw NSError(domain: "Arthur", code: 2, userInfo: [NSLocalizedDescriptionKey: "microphone is busy"])
      }
      session.addOutput(micOutput)
    }
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
      session.commitConfiguration()
      throw NSError(domain: "Arthur", code: 2, userInfo: [NSLocalizedDescriptionKey: "microphone is busy"])
    }
    session.addInput(input)
    session.commitConfiguration()
    capturing = true
    activeDeviceName = device.localizedName
    unmuteInput()
    note("capture start device=\(device.localizedName)")
    micQueue.async { [weak self] in
      self?.session.startRunning()
    }
  }

  /// A short enrollment clip. Fails if a turn already owns the microphone.
  /// Wake listening is paused for the clip and is not restarted here.
  /// The samples are not a turn.
  func recordClip(_ handler: @escaping (Data?) -> Void) {
    setWakeWanted(false)
    if capturing {
      DispatchQueue.main.async { handler(nil) }
      return
    }
    clipLock.lock()
    clipBuffer.removeAll(keepingCapacity: true)
    clipHandler = handler
    clipSink = true
    clipLock.unlock()
    do {
      try startCapture()
    } catch {
      clipLock.lock()
      clipSink = false
      clipHandler = nil
      clipLock.unlock()
      DispatchQueue.main.async { handler(nil) }
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
      self?.finishClip()
    }
  }

  private func finishClip() {
    clipLock.lock()
    let handler = clipHandler
    clipHandler = nil
    let data = clipBuffer
    clipBuffer.removeAll(keepingCapacity: true)
    clipLock.unlock()
    guard let handler else { return }
    stopCapture()
    clipLock.lock()
    clipSink = false
    clipLock.unlock()
    let clip = data.isEmpty ? nil : data
    if Thread.isMainThread {
      handler(clip)
    } else {
      DispatchQueue.main.async { handler(clip) }
    }
  }

  func stopCapture() {
    guard capturing else { return }
    capturing = false
    micQueue.sync { [weak self] in
      guard let self else { return }
      if self.session.isRunning { self.session.stopRunning() }
    }
    note(String(format: "capture stop peak=%.5f", capturePeak))
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard capturing else { return }
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format),
          let source = AVAudioFormat(streamDescription: asbd) else { return }
    if !loggedNativeFormat {
      loggedNativeFormat = true
      let desc = asbd.pointee
      note("native rate=\(desc.mSampleRate) ch=\(desc.mChannelsPerFrame) bits=\(desc.mBitsPerChannel) flags=\(desc.mFormatFlags)")
    }
    let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
    guard frames > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else { return }
    buffer.frameLength = frames
    let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
    )
    let copyPeak = copied == noErr ? Self.bufferPeak(buffer) : -1
    let listPeak = Self.listPeak(sampleBuffer, floatSamples: (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0)
    if !loggedPeaks {
      loggedPeaks = true
      note(String(format: "peaks copy=%.5f list=%.5f", copyPeak, listPeak))
    }
    let peak = max(copyPeak, listPeak)
    if peak > capturePeak { capturePeak = peak }
    guard copied == noErr else { return }
    wakeLock.lock()
    let wanted = wakeWanted
    let gate = wakeGate
    let request = speechRequest
    wakeLock.unlock()
    if wanted && !gate {
      request?.append(buffer)
      return
    }
    guard let pcm = pcm16(from: buffer) else { return }
    clipLock.lock()
    let sinking = clipSink
    if sinking { clipBuffer.append(pcm) }
    clipLock.unlock()
    if sinking { return }
    onCapture?(pcm)
  }

  /// Hardware mute on the default input. An app-level mute is separate and
  /// is cleared when a turn the user started is already underway.
  static func inputHardwareMuted() -> Bool {
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device) == noErr,
          device != 0 else { return false }
    var muted: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    address.mSelector = kAudioDevicePropertyMute
    address.mScope = kAudioDevicePropertyScopeInput
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else {
      return false
    }
    return muted != 0
  }

  func setWakeWanted(_ on: Bool) {
    wakeLock.lock()
    wakeWanted = on
    let gate = wakeGate
    let running = capturing
    let hearing = speechRequest != nil
    wakeLock.unlock()
    if !on {
      stopWakeRecognizer()
      if !gate { stopCapture() }
      return
    }
    if gate { return }
    if running && hearing { return }
    if running {
      startWakeRecognizer()
      return
    }
    beginWakeIfIdle()
  }

  /// `send` means the open capture belongs to a turn and should reach Intercom.
  func armWakeGate(_ send: Bool) {
    wakeLock.lock()
    wakeGate = send
    if !send { wakeFired = false }
    wakeLock.unlock()
    if send { stopWakeRecognizer() }
  }

  /// Peak from the sample buffer's own audio buffer list. The PCM copy can
  /// land on a zeroed destination when the microphone is non-interleaved.
  private static func listPeak(_ sampleBuffer: CMSampleBuffer, floatSamples: Bool) -> Double {
    var needed = 0
    _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: &needed,
      bufferListOut: nil,
      bufferListSize: 0,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: 0,
      blockBufferOut: nil
    )
    guard needed > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: needed,
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    var block: CMBlockBuffer?
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: raw.assumingMemoryBound(to: AudioBufferList.self),
      bufferListSize: needed,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
      blockBufferOut: &block
    )
    guard status == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    var peak = 0.0
    for audioBuffer in list {
      guard let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { continue }
      if floatSamples, audioBuffer.mDataByteSize % 4 == 0 {
        let count = Int(audioBuffer.mDataByteSize) / 4
        data.assumingMemoryBound(to: Float.self).withMemoryRebound(to: Float.self, capacity: count) { pointer in
          for i in 0..<count { peak = max(peak, abs(Double(pointer[i]))) }
        }
      } else if !floatSamples, audioBuffer.mDataByteSize % 2 == 0 {
        let count = Int(audioBuffer.mDataByteSize) / 2
        var samplePeak = 0
        data.assumingMemoryBound(to: Int16.self).withMemoryRebound(to: Int16.self, capacity: count) { pointer in
          for i in 0..<count { samplePeak = max(samplePeak, abs(Int(pointer[i]))) }
        }
        peak = max(peak, Double(samplePeak) / 32768.0)
      }
    }
    return peak
  }

  /// Control Center and AirPods mute this app by zeroing its microphone samples
  /// while the hardware mute stays off.
  private func unmuteInput() {
    let application = AVAudioApplication.shared
    note("inputMuted=\(application.isInputMuted)")
    guard application.isInputMuted else { return }
    do {
      try application.setInputMuted(false)
      note("input unmuted")
    } catch {
      note("unmute failed \(error.localizedDescription)")
    }
  }

  private func applyVolume() {
    playEngine.mainMixerNode.outputVolume = soundEnabled ? 1 : 0
    if !soundEnabled {
      leftover.removeAll(keepingCapacity: true)
    }
  }

  private let wakeLock = NSLock()
  private var wakeWanted = false
  private var wakeGate = false
  private var wakeFired = false
  private var speechRecognizer: SFSpeechRecognizer?
  private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
  private var speechTask: SFSpeechRecognitionTask?
  private var wakeRetryAt = Date.distantPast

  private func beginWakeIfIdle() {
    wakeLock.lock()
    let wanted = wakeWanted
    let gate = wakeGate
    let running = capturing
    wakeLock.unlock()
    guard wanted, !gate, !running else { return }
    if Self.inputHardwareMuted() { return }
    let start = { [weak self] in
      guard let self else { return }
      self.wakeLock.lock()
      let still = self.wakeWanted && !self.wakeGate && !self.capturing
      self.wakeLock.unlock()
      guard still, !Self.inputHardwareMuted() else { return }
      do {
        try self.startCapture()
        self.startWakeRecognizer()
      } catch {
        self.note("wake capture failed \(error.localizedDescription)")
      }
    }
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized:
      start()
    case .notDetermined:
      SFSpeechRecognizer.requestAuthorization { status in
        DispatchQueue.main.async {
          if status == .authorized { start() }
        }
      }
    default:
      note("wake speech recognition is off")
    }
  }

  private func startWakeRecognizer() {
    stopWakeRecognizer()
    guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
      note("wake recognizer unavailable")
      return
    }
    speechRecognizer = recognizer
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition {
      request.requiresOnDeviceRecognition = true
    }
    wakeLock.lock()
    speechRequest = request
    wakeLock.unlock()
    speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }
      if let text = result?.bestTranscription.formattedString {
        self.noteWakeMatch(text)
      }
      if error != nil || result?.isFinal == true {
        DispatchQueue.main.async { self.restartWakeLater() }
      }
    }
  }

  private func restartWakeLater() {
    wakeLock.lock()
    let wanted = wakeWanted
    let gate = wakeGate
    wakeLock.unlock()
    guard wanted, !gate else { return }
    guard Date() >= wakeRetryAt else { return }
    wakeRetryAt = Date().addingTimeInterval(0.4)
    startWakeRecognizer()
  }

  private func noteWakeMatch(_ text: String) {
    guard WakePhrase.matches(text) else { return }
    wakeLock.lock()
    let already = wakeFired || wakeGate
    if !already { wakeFired = true }
    wakeLock.unlock()
    guard !already else { return }
    DispatchQueue.main.async { [weak self] in self?.onWake?() }
  }

  private func stopWakeRecognizer() {
    wakeLock.lock()
    let request = speechRequest
    let task = speechTask
    speechRequest = nil
    speechTask = nil
    wakeLock.unlock()
    request?.endAudio()
    task?.cancel()
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

  /// 16-bit little-endian mono PCM at 24 kHz.
  private func pcm16(from buffer: AVAudioPCMBuffer) -> Data? {
    let source = buffer.format
    guard source.sampleRate > 0, buffer.frameLength > 0 else { return nil }
    let key = "\(source.sampleRate)-\(source.channelCount)-\(source.commonFormat.rawValue)"
    let target = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: Self.sampleRate,
      channels: 1,
      interleaved: false
    )!
    if engineSourceKey != key {
      engineSourceKey = key
      engineConverter = AVAudioConverter(from: source, to: target)
    }
    guard let engineConverter else { return nil }
    let ratio = target.sampleRate / source.sampleRate
    let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
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
      return buffer
    }
    _ = engineConverter.convert(to: out, error: &error, withInputFrom: inputBlock)
    if error != nil || out.frameLength == 0 || out.floatChannelData == nil {
      if !loggedConvertFailure {
        loggedConvertFailure = true
        note("convert failed \(error?.localizedDescription ?? "empty") rate=\(source.sampleRate) ch=\(source.channelCount)")
      }
      return nil
    }
    guard let floats = out.floatChannelData?[0] else { return nil }
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

  private static func bufferPeak(_ buffer: AVAudioPCMBuffer) -> Double {
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return 0 }
    var peak = 0.0
    if let channels = buffer.floatChannelData {
      let count = max(Int(buffer.format.channelCount), 1)
      for channel in 0..<count {
        for i in 0..<frames {
          peak = max(peak, abs(Double(channels[channel][i])))
        }
      }
      return peak
    }
    if let channels = buffer.int16ChannelData {
      let count = max(Int(buffer.format.channelCount), 1)
      var samplePeak = 0
      for channel in 0..<count {
        for i in 0..<frames {
          samplePeak = max(samplePeak, abs(Int(channels[channel][i])))
        }
      }
      return Double(samplePeak) / 32768.0
    }
    return 0
  }

}
