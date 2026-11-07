import Foundation

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
