// Build capture/monitor stream formats with the production functions and render
// them through the monitor's AVAudioEngine graph offline. No device is opened.
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { spawnSync } from 'node:child_process'
const directory = await mkdtemp(join(tmpdir(), 'masc-music-session-format-'))
try {
  const swift = `import AVFoundation
@main enum Probe {
static func main() throws {
let rate = 48000.0, frames: AVAudioFrameCount = 256
// Mono/stereo devices keep the formats of the channel-count initializers.
for channels in 1...2 {
  let count = AVAudioChannelCount(channels)
  precondition(captureStreamFormat(sampleRate: rate, inputs: channels) ==
    AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: count, interleaved: false)!,
    "\\(channels)-channel capture format changed")
  for inputs in 1...2 {
    precondition(monitorStreamFormat(sampleRate: rate, inputs: inputs, outputs: channels) ==
      AVAudioFormat(standardFormatWithSampleRate: rate, channels: count)!,
      "\\(inputs)-in/\\(channels)-out monitor format changed")
  }
}
// AVAudioFormat.h: the channel-count initializers return nil above two channels.
for channels in [3, 4, 8] {
  guard let capture = captureStreamFormat(sampleRate: rate, inputs: channels) else {
    preconditionFailure("\\(channels)-channel capture format is nil")
  }
  guard let output = monitorStreamFormat(sampleRate: rate, inputs: 2, outputs: channels) else {
    preconditionFailure("\\(channels)-channel monitor output format is nil")
  }
  for format in [capture, output] {
    precondition(Int(format.channelCount) == channels && format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved,
      "\\(channels)-channel format is not deinterleaved float32")
  }
}
// DiscreteInOrder keeps its count in 16 bits; a wrapped count is refused.
let wrapped = Int(UInt16.max) + 4
precondition(captureStreamFormat(sampleRate: rate, inputs: wrapped) == nil, "\\(wrapped)-channel capture format wrapped its count")
// Input channel N carries (N + 1) / 10. Same graph as Capture.startResources:
// input -> main mixer (capture format) -> output (monitor format).
func source(_ inputs: Int) -> AVAudioPCMBuffer {
  let buffer = AVAudioPCMBuffer(pcmFormat: captureStreamFormat(sampleRate: rate, inputs: inputs)!, frameCapacity: frames)!
  for channel in 0..<inputs { for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = Float(channel + 1) / 10 } }
  return buffer
}
func render(inputs: Int, outputs: Int, tap: ((AVAudioPCMBuffer) -> Void)? = nil) throws -> [Float] {
  let capture = captureStreamFormat(sampleRate: rate, inputs: inputs)!
  let output = monitorStreamFormat(sampleRate: rate, inputs: inputs, outputs: outputs)!
  let engine = AVAudioEngine(), input = source(inputs)
  try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: frames)
  precondition(engine.inputNode.setManualRenderingInputPCMFormat(capture) { count in
    input.frameLength = count; return input.audioBufferList })
  engine.connect(engine.inputNode, to: engine.mainMixerNode, format: capture)
  engine.connect(engine.mainMixerNode, to: engine.outputNode, format: output)
  let tapped = DispatchSemaphore(value: 0)
  if let tap { engine.inputNode.installTap(onBus: 0, bufferSize: frames, format: capture) { buffer, _ in tap(buffer); tapped.signal() } }
  try engine.start()
  defer { engine.stop() }
  let rendered = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)!
  // A tap delivers 100..400 ms buffers (AVAudioNode.h) on its own thread;
  // one second of rendered input covers its first buffer.
  for _ in 0..<(tap == nil ? 1 : Int(rate) / Int(frames)) {
    let status = try engine.renderOffline(frames, to: rendered)
    precondition(status == .success && rendered.frameLength == frames, "\\(inputs)-in/\\(outputs)-out render status \\(status.rawValue)")
  }
  if tap != nil { precondition(tapped.wait(timeout: .now() + 1) == .success, "\\(inputs)-channel recording tap was not called") }
  return (0..<outputs).map { rendered.floatChannelData![$0][Int(frames) - 1] }
}
for (inputs, outputs) in [(1, 1), (1, 2), (2, 1), (2, 2)] {
  let heard = try render(inputs: inputs, outputs: outputs)
  precondition(heard.allSatisfy { $0 != 0 }, "\\(inputs)-in/\\(outputs)-out monitor is silent: \\(heard)")
}
// A discrete source mixed into an unlabelled mono/stereo output renders silence.
// Wider devices therefore route input channel N to output channel N.
for (inputs, outputs) in [(3, 2), (4, 2), (4, 1), (3, 3), (4, 4), (8, 4), (4, 8), (2, 4), (1, 4)] {
  let heard = try render(inputs: inputs, outputs: outputs)
  let expected = (0..<outputs).map { $0 < inputs ? Float($0 + 1) / 10 : 0 }
  precondition(zip(heard, expected).allSatisfy { abs($0 - $1) < 1e-6 },
    "\\(inputs)-in/\\(outputs)-out monitor heard \\(heard), expected \\(expected)")
}
// The recording tap receives every input channel of a wide device.
_ = try render(inputs: 4, outputs: 2) { buffer in
  let heard = (0..<Int(buffer.format.channelCount)).map { buffer.floatChannelData![$0][Int(buffer.frameLength) - 1] }
  precondition(heard == [0.1, 0.2, 0.3, 0.4], "4-channel recording tap received \\(heard)")
}
print("MUSIC_SESSION_FORMAT_PASS: mono/stereo formats unchanged, 3/4/8-channel capture and monitor formats, wrapped layout count refused, 13 input/output renders, 4-channel recording tap")
}
}
`
  await writeFile(join(directory, 'Probe.swift'), swift)
  const session = new URL('MusicSession.swift', import.meta.url).pathname
  let result = spawnSync('xcrun', ['swiftc', '-parse-as-library', '-D', 'MUSIC_INPUT_LIBRARY', session, join(directory, 'Probe.swift'),
    '-o', join(directory, 'probe'), '-framework', 'AVFoundation', '-framework', 'CoreAudio', '-framework', 'CoreMIDI', '-framework', 'AudioToolbox'], { encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  result = spawnSync(join(directory, 'probe'), [], { encoding: 'utf8' })
  assert.equal(result.status, 0, result.stdout + result.stderr)
  console.log(result.stdout.trim())
} finally { await rm(directory, { recursive: true, force: true }) }
