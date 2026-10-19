// Two reusable source-rate buffers per voice bound decoded storage independently
// of duration/repetition. Disk streaming uses 64 KiB per channel, rounded up to
// an output render quantum, so refill IO need not finish within one render call.
import Foundation
import AVFoundation
import CoreAudio
import CryptoKit

struct AudioFailure: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
}
func audioChecked(_ value: OSStatus, _ operation: String) throws {
    if value != noErr { throw AudioFailure("\(operation): OSStatus \(value)") }
}
func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func deviceNumber(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
    var key = address(selector), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
    try audioChecked(AudioObjectGetPropertyData(object, &key, 0, nil, &size, &value), "read selected device property")
    return value
}
func deviceString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var key = address(selector), size = UInt32(MemoryLayout<UnsafeRawPointer?>.size), value: UnsafeRawPointer?
    try audioChecked(AudioObjectGetPropertyData(object, &key, 0, nil, &size, &value), "read selected device identity")
    guard let value else { throw AudioFailure("selected device identity is unavailable") }
    return Unmanaged<CFString>.fromOpaque(value).takeRetainedValue() as String
}
func outputChannels(_ object: AudioObjectID) throws -> Int {
    var key = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput), size: UInt32 = 0
    try audioChecked(AudioObjectGetPropertyDataSize(object, &key, 0, nil, &size), "read output configuration size")
    guard size >= MemoryLayout<AudioBufferList>.size else { throw AudioFailure("output configuration is unavailable") }
    let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    try audioChecked(AudioObjectGetPropertyData(object, &key, 0, nil, &size, memory), "read output configuration")
    return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
}
struct OutputDevice {
    let object: AudioObjectID
    let uid: String
    let name: String
    let channels: Int
    var json: [String: Any] { ["id": uid, "name": name, "outputs": channels] }
    init(_ requested: String?) throws {
        var object = AudioObjectID(kAudioObjectUnknown)
        if let requested {
            var key = address(kAudioHardwarePropertyTranslateUIDToDevice), uid = requested as CFString
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            try withUnsafePointer(to: &uid) { pointer in
                try audioChecked(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &key,
                    UInt32(MemoryLayout<CFString>.size), pointer, &size, &object), "resolve selected output UID")
            }
        } else { object = try deviceNumber(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) }
        guard object != kAudioObjectUnknown else { throw AudioFailure("selected audio output is unavailable") }
        self.object = object
        uid = try deviceString(object, kAudioDevicePropertyDeviceUID)
        name = try deviceString(object, kAudioObjectPropertyName)
        channels = try outputChannels(object)
        guard channels > 0, requested == nil || requested == uid else { throw AudioFailure("selected device has no matching audio output") }
    }
}
func audioEmit(_ value: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10)
    try FileHandle.standardOutput.write(contentsOf: data)
}
func report(_ value: String) { try? FileHandle.standardError.write(contentsOf: Data((value + "\n").utf8)) }
func futureHost(_ seconds: Double, from origin: UInt64) throws -> UInt64 {
    guard seconds.isFinite, seconds >= 0, seconds < AVAudioTime.seconds(forHostTime: UInt64.max - origin) else {
        throw AudioFailure("region exceeds the native host timestamp range")
    }
    let (result, overflow) = origin.addingReportingOverflow(AVAudioTime.hostTime(forSeconds: seconds))
    guard !overflow else { throw AudioFailure("region exceeds the native host timestamp range") }
    return result
}
struct Asset: Decodable {
    let id: String
    let path: String
    let sha256: String
    let sampleRate: Double
    let channels: AVAudioChannelCount
    let frames: AVAudioFramePosition
}
struct CaptureAudioChannel: Decodable {
    let input: AVAudioChannelCount
    let output: AVAudioChannelCount
}
struct CalibrationOutput: Decodable {
    let id: String
    let sampleRate: Double
    let renderQuantum: AVAudioFrameCount
    func validate(deviceUID: String, rate: Double, quantum: AVAudioFrameCount) throws {
        guard !id.isEmpty, sampleRate.isFinite, sampleRate > 0, renderQuantum > 0,
              id == deviceUID, sampleRate == rate, renderQuantum == quantum else {
            throw AudioFailure("calibration output device, sample rate or render quantum changed; remeasure or choose a manual offset")
        }
    }
}
struct Region: Decodable {
    let id: String
    let asset: String
    let startSeconds: Double
    let offsetFrames: AVAudioFramePosition
    let frameCount: AVAudioFramePosition
    let repetitions: AVAudioFramePosition
    let captureClock: CaptureAudioClock?
    var component: CaptureRegionComponent? = nil
    var audioChannel: CaptureAudioChannel? = nil
    var calibrationOutput: CalibrationOutput? = nil
    enum CodingKeys: String, CodingKey { case id, asset, startSeconds, offsetFrames, frameCount, captureClock, component, audioChannel, calibrationOutput; case repetitions = "repeat" }
    func totalFrames() throws -> AVAudioFramePosition {
        let (total, overflow) = frameCount.multipliedReportingOverflow(by: repetitions)
        guard frameCount > 0, repetitions > 0, !overflow, total > 0 else { throw AudioFailure("region exceeds the native frame timeline") }
        return total
    }
}
struct Plan: Decodable {
    let schemaVersion: Int
    let kind: String
    let duration: Double
    let assets: [Asset]
    let regions: [Region]
    let midi: Timeline?
    let ump: UmpTimeline?
    let umpRegions: UmpArrangement?
    var captured: Bool { kind == "capture-session" }
    var capturedAudio: Bool { kind == "capture-audio-arrangement" }
    var pairedRegions: Bool { kind == "capture-arrangement" }
    var hybrid: Bool { kind == "hybrid-arrangement" }
    var clocked: Bool { capturedAudio || pairedRegions || hybrid }
    var mixed: Bool { kind == "mixed-arrangement" }
    func validate() throws {
        guard (schemaVersion == 1 && kind == "wave-arrangement" && midi == nil && ump == nil && umpRegions == nil
               || schemaVersion == 2 && mixed && midi?.schemaVersion == 3 && ump == nil && umpRegions == nil
               || schemaVersion == 3 && captured && midi == nil && ump?.schemaVersion == 4 && umpRegions == nil
               || schemaVersion == 4 && capturedAudio && midi == nil && ump == nil && umpRegions == nil
               || schemaVersion == 5 && pairedRegions && midi == nil && ump == nil && umpRegions?.schemaVersion == 1
               || schemaVersion == 6 && hybrid && midi?.schemaVersion == 3 && ump == nil && umpRegions?.schemaVersion == 1), duration.isFinite, duration > 0,
              (!regions.isEmpty || (captured || clocked) && assets.isEmpty), Set(assets.map(\.id)).count == assets.count, Set(regions.map(\.id)).count == regions.count else { throw AudioFailure("invalid WAV arrangement plan") }
        for asset in assets {
            guard !asset.id.isEmpty, !asset.path.isEmpty, asset.sampleRate.isFinite, asset.sampleRate > 0,
                  asset.channels > 0, asset.frames >= 0 else { throw AudioFailure("invalid WAV source identity or format") }
        }
        var end: Double = 0
        for region in regions {
            guard !region.id.isEmpty, region.startSeconds.isFinite, region.startSeconds >= 0, region.offsetFrames >= 0,
                  region.frameCount > 0, region.repetitions > 0,
                  let asset = assets.first(where: { $0.id == region.asset }),
                  region.frameCount <= asset.frames, region.offsetFrames <= asset.frames - region.frameCount else { throw AudioFailure("invalid region source bounds") }
            guard region.captureClock == nil || clocked else { throw AudioFailure("captured audio clock requires an explicit captured audio plan") }
            guard region.component == nil || region.component == .audio && region.captureClock != nil else { throw AudioFailure("invalid captured audio component") }
            if let channel = region.audioChannel {
                guard region.component == .audio, channel.input > 0, channel.input <= asset.channels, channel.output > 0 else {
                    throw AudioFailure("invalid captured audio channel routing")
                }
            }
            if let calibrated = region.calibrationOutput {
                guard region.component == .audio, region.audioChannel != nil else { throw AudioFailure("calibration requires a routed audio component") }
                try calibrated.validate(deviceUID: calibrated.id, rate: calibrated.sampleRate, quantum: calibrated.renderQuantum)
            }
            let total: AVAudioFramePosition
            if let clock = region.captureClock {
                total = try clock.layout(rate: asset.sampleRate, offsetFrames: region.offsetFrames,
                                         frameCount: region.frameCount, repetitions: region.repetitions).totalFrames
            } else { total = try region.totalFrames() }
            let regionEnd = region.startSeconds + Double(total) / asset.sampleRate
            guard regionEnd.isFinite, regionEnd > region.startSeconds else { throw AudioFailure("region time is not representable") }
            // The plan duration is the exact clock end. A captured end rounds up
            // to a whole frame of its own source, never of another asset.
            guard !clocked || regionEnd <= duration || regionEnd - duration < 1 / asset.sampleRate else {
                throw AudioFailure("captured audio exceeds its arrangement duration")
            }
            end = max(end, regionEnd)
        }
        // Float arithmetic may differ by a final ULP, never by a source sample.
        let sample = assets.map { 1 / $0.sampleRate }.min() ?? 0
        if !clocked, let midi {
            try midi.validate()
            let midiEnd = midi.regions.map(\.end).max() ?? 0
            guard midi.duration == duration, abs(max(end, midiEnd) - duration) < sample else { throw AudioFailure("mixed duration does not match its source regions") }
        } else if let ump {
            let events = try ump.events(), midiEnd = events.map(\.seconds).max() ?? 0
            guard ump.duration == duration, abs(max(end, midiEnd) - duration) < (sample > 0 ? sample : 1e-9) else { throw AudioFailure("capture duration does not match its source clocks") }
        } else if clocked {
            if hybrid, let midi, let umpRegions {
                guard midi.duration == duration else { throw AudioFailure("hybrid SMF duration differs from the common clock") }
                _ = try HybridMidiTransport(midi: midi, ump: umpRegions)
            }
            if let umpRegions {
                guard umpRegions.duration == duration else { throw AudioFailure("captured MIDI duration differs from the paired clock") }
                _ = try UmpRegionTransport(timeline: umpRegions)
                for region in regions {
                    guard let clock = region.captureClock else { continue }
                    if region.component == .audio {
                        guard !umpRegions.regions.contains(where: { $0.id == region.id }) else { throw AudioFailure("separated audio cannot silently pair with UMP") }
                        if let source = umpRegions.sources.first(where: { $0.id == region.asset }) {
                            guard source.timeline.clock.origin == clock.origin,
                                  source.timeline.clock.numer == clock.numer, source.timeline.clock.denom == clock.denom else { throw AudioFailure("separated components disagree on their original source clock") }
                        }
                        continue
                    }
                    guard let notes = umpRegions.regions.first(where: { $0.id == region.id }),
                          let source = umpRegions.sources.first(where: { $0.id == notes.source }),
                          notes.component == nil, notes.source == region.asset, notes.startSeconds == region.startSeconds,
                          notes.offset == clock.offset, notes.extent == clock.extent,
                          notes.repeatCount == UInt64(region.repetitions),
                          source.timeline.clock.origin == clock.origin,
                          source.timeline.clock.numer == clock.numer, source.timeline.clock.denom == clock.denom else {
                        throw AudioFailure("paired WAV and UMP regions disagree on their source identity or clock")
                    }
                }
                guard !umpRegions.regions.contains(where: { notes in notes.component == .midi && regions.contains(where: { $0.id == notes.id }) }) else { throw AudioFailure("separated MIDI cannot silently pair with WAV") }
            }
        } else {
            guard abs(end - duration) < sample else { throw AudioFailure("duration does not match region sources") }
        }
    }
}
final class Voice {
    let region: Region
    let asset: Asset
    let file: AVAudioFile
    let format: AVAudioFormat
    let player = AVAudioPlayerNode()
    let queue: DispatchQueue
    let buffers: [AVAudioPCMBuffer]
    let scratch: AVAudioPCMBuffer
    let cached: AVAudioPCMBuffer?
    let capacity: AVAudioFrameCount
    let total: AVAudioFramePosition
    let captureLayout: CaptureAudioLayout?
    var generation: UInt64 = 0 // only the stream queue accesses these fields
    var cursor: AVAudioFramePosition = 0
    var origin: AVAudioFramePosition = 0
    init(region: Region, asset: Asset, capacity: AVAudioFrameCount, outputChannels: AVAudioChannelCount, outputLayout: AVAudioChannelLayout? = nil) throws {
        self.region = region; self.asset = asset; self.capacity = capacity
        queue = DispatchQueue(label: "music.arrangement.stream.\(region.id)", qos: .userInitiated)
        captureLayout = try region.captureClock?.layout(rate: asset.sampleRate, offsetFrames: region.offsetFrames,
                                                       frameCount: region.frameCount, repetitions: region.repetitions)
        total = try captureLayout?.totalFrames ?? region.totalFrames()
        file = try AVAudioFile(forReading: URL(fileURLWithPath: asset.path), commonFormat: .pcmFormatFloat32, interleaved: false)
        let sourceFormat = file.processingFormat
        guard file.length == asset.frames, sourceFormat.sampleRate == asset.sampleRate, sourceFormat.channelCount == asset.channels,
              capacity > 0 else { throw AudioFailure("WAV source format changed") }
        if let channel = region.audioChannel {
            guard region.component == .audio, channel.input > 0, channel.input <= asset.channels,
                  channel.output > 0, channel.output <= outputChannels else {
                throw AudioFailure("selected captured channel is unavailable on source or output")
            }
            let layout: AVAudioChannelLayout
            if let actual = outputLayout { layout = actual }
            else {
                // Count-only AVAudioFormat initializers support at most stereo.
                // DiscreteInOrder encodes its count in the low UInt16 bits.
                guard outputChannels <= UInt32(UInt16.max) else { throw AudioFailure("output channel count exceeds the native discrete layout range") }
                let tag = outputChannels == 1 ? kAudioChannelLayoutTag_Mono : outputChannels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_DiscreteInOrder | outputChannels
                guard let inferred = AVAudioChannelLayout(layoutTag: tag) else { throw AudioFailure("selected output channel layout is unavailable") }
                layout = inferred
            }
            guard layout.channelCount == outputChannels else { throw AudioFailure("selected output channel layout disagrees with its format") }
            format = AVAudioFormat(standardFormatWithSampleRate: asset.sampleRate, channelLayout: layout)
        } else { format = sourceFormat }
        func buffer(_ count: AVAudioFrameCount, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
            guard let value = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { throw AudioFailure("cannot allocate audio stream buffer") }
            return value
        }
        buffers = try [buffer(capacity, format: format), buffer(capacity, format: format)]
        scratch = try buffer(capacity, format: sourceFormat)
        if region.frameCount <= AVAudioFramePosition(capacity) {
            let period = try buffer(AVAudioFrameCount(region.frameCount), format: sourceFormat)
            file.framePosition = region.offsetFrames
            var written: AVAudioFrameCount = 0
            while written < AVAudioFrameCount(region.frameCount) {
                try file.read(into: scratch, frameCount: AVAudioFrameCount(region.frameCount) - written)
                let count = scratch.frameLength
                guard count > 0, let target = period.floatChannelData, let source = scratch.floatChannelData else { throw AudioFailure("WAV source did not supply its period") }
                for channel in 0..<Int(asset.channels) { memcpy(target[channel].advanced(by: Int(written)), source[channel], Int(count) * MemoryLayout<Float>.size) }
                written += count
            }
            period.frameLength = written
            cached = period
        } else { cached = nil }
    }
    func fill(_ target: AVAudioPCMBuffer) throws -> Bool {
        guard cursor < total else { return false }
        guard let output = target.floatChannelData else { throw AudioFailure("audio output is not planar float") }
        var written: AVAudioFrameCount = 0
        while written < capacity && cursor < total {
            let remaining = min(AVAudioFramePosition(capacity - written), total - cursor)
            let span = captureLayout?.span(at: cursor, maximum: remaining)
                ?? (source: cursor % region.frameCount, count: min(remaining, region.frameCount - cursor % region.frameCount))
            var count = AVAudioFrameCount(span.count)
            guard count > 0 else { throw AudioFailure("captured audio clock did not advance") }
            guard let local = span.source else {
                for channel in 0..<Int(format.channelCount) { memset(output[channel].advanced(by: Int(written)), 0, Int(count) * MemoryLayout<Float>.size) }
                written += count; cursor += AVAudioFramePosition(count); continue
            }
            let input: AVAudioPCMBuffer
            let offset: Int
            if let cached { input = cached; offset = Int(local) }
            else {
                file.framePosition = region.offsetFrames + local
                try file.read(into: scratch, frameCount: count)
                guard scratch.frameLength > 0, scratch.frameLength <= count else { throw AudioFailure("WAV stream ended before its declared frames") }
                count = scratch.frameLength
                input = scratch; offset = 0
            }
            guard let samples = input.floatChannelData else { throw AudioFailure("WAV decoder is not planar float") }
            for channel in 0..<Int(format.channelCount) {
                if let selected = region.audioChannel {
                    if channel == Int(selected.output) - 1 {
                        memcpy(output[channel].advanced(by: Int(written)), samples[Int(selected.input) - 1].advanced(by: offset), Int(count) * MemoryLayout<Float>.size)
                    } else { memset(output[channel].advanced(by: Int(written)), 0, Int(count) * MemoryLayout<Float>.size) }
                } else { memcpy(output[channel].advanced(by: Int(written)), samples[channel].advanced(by: offset), Int(count) * MemoryLayout<Float>.size) }
            }
            written += count; cursor += AVAudioFramePosition(count)
        }
        target.frameLength = written
        return written > 0
    }
    func enqueue(_ buffer: AVAudioPCMBuffer, expected: UInt64, finished: @escaping () -> Void, failed: @escaping (Error) -> Void) throws {
        let scheduled = cursor - origin
        guard generation == expected, try fill(buffer) else { return }
        if player.isPlaying, let render = player.lastRenderTime, let time = player.playerTime(forNodeTime: render), time.sampleTime > scheduled {
            throw AudioFailure("audio source missed its next buffer frame; playback stopped rather than stretching the region")
        }
        let final = cursor == total
        player.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: scheduled, atRate: asset.sampleRate),
            completionCallbackType: final ? .dataPlayedBack : .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.generation == expected else { return }
                if final { DispatchQueue.main.async(execute: finished) }
                else {
                    do { try self.enqueue(buffer, expected: expected, finished: finished, failed: failed) }
                    catch { DispatchQueue.main.async { failed(error) } }
                }
            }
        }
    }
    func prepare(from seconds: Double, finished: @escaping () -> Void, failed: @escaping (Error) -> Void) throws -> Bool {
        try queue.sync {
            generation &+= 1
            let skipped = max(0, seconds - region.startSeconds) * asset.sampleRate
            if skipped >= Double(total) { cursor = total; return false }
            cursor = AVAudioFramePosition(skipped.rounded(.down)); origin = cursor
            let expected = generation
            for buffer in buffers { try enqueue(buffer, expected: expected, finished: finished, failed: failed) }
            return true
        }
    }
    func stop() { queue.sync { generation &+= 1 }; player.stop() }
}
enum AudioCommand: Decodable {
    case pause, resume, seek(Double), status, stop, recordingEpoch(String)
    enum Keys: String, CodingKey { case kind, seconds, request }
    enum Kind: String, Decodable { case pause, resume, seek, status, stop, recordingEpoch }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self), kind = try values.decode(Kind.self, forKey: .kind)
        guard kind == .seek || !values.contains(.seconds) else { throw AudioFailure("seconds is only valid for seek") }
        switch kind {
        case .pause: self = .pause
        case .resume: self = .resume
        case .seek: self = .seek(try values.decode(Double.self, forKey: .seconds))
        case .status: self = .status
        case .stop: self = .stop
        case .recordingEpoch:
            let request = try values.decode(String.self, forKey: .request)
            guard UUID(uuidString: request) != nil else { throw AudioFailure("invalid recording epoch request") }
            self = .recordingEpoch(request)
        }
    }
}
final class ArrangementTransport {
    enum State { case prepared, playing, paused, stopped }
    let plan: Plan
    let device: OutputDevice
    let engine = AVAudioEngine()
    let capacity: AVAudioFrameCount
    let renderQuantum: AVAudioFrameCount
    let renderChannels: AVAudioChannelCount
    var voices: [Voice] = []
    var active = Set<String>()
    var horizon: DispatchSourceTimer?
    var horizonEnded = false
    var state = State.prepared
    var position: Double = 0
    var anchor: UInt64 = 0
    var generation: UInt64 = 0
    var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    var signals: [DispatchSourceSignal] = []
    var configuration: NSObjectProtocol?
    var midi: (any CoordinatedMidiTransport)?
    var midiEnded = false
    init(plan: Plan, output: String?) throws {
        try plan.validate(); self.plan = plan; device = try OutputDevice(output)
        try engine.outputNode.auAudioUnit.setDeviceID(device.object)
        renderQuantum = engine.outputNode.auAudioUnit.maximumFramesToRender
        guard renderQuantum > 0 else { throw AudioFailure("output render quantum is unavailable") }
        let block = AVAudioFrameCount(64 * 1024 / MemoryLayout<Float>.size)
        capacity = ((block - 1) / renderQuantum + 1) * renderQuantum
        for asset in plan.assets {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: asset.path))
            defer { try? file.close() }
            var hash = SHA256()
            // Fixed streaming IO block, not a source-size or duration limit.
            while try autoreleasepool(invoking: {
                guard let bytes = try file.read(upToCount: 64 * 1024), !bytes.isEmpty else { return false }
                hash.update(data: bytes)
                return true
            }) {}
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == asset.sha256 else { throw AudioFailure("WAV source changed before native admission") }
        }
        let destinationFormat = engine.outputNode.outputFormat(forBus: 0)
        renderChannels = destinationFormat.channelCount
        guard renderChannels > 0, Int(renderChannels) <= device.channels else { throw AudioFailure("selected audio graph output channels are unavailable") }
        for region in plan.regions {
            try region.calibrationOutput?.validate(deviceUID: device.uid, rate: destinationFormat.sampleRate, quantum: renderQuantum)
        }
        for region in plan.regions {
            guard let asset = plan.assets.first(where: { $0.id == region.asset }) else { throw AudioFailure("missing WAV source") }
            let voice = try Voice(region: region, asset: asset, capacity: capacity, outputChannels: renderChannels, outputLayout: destinationFormat.channelLayout)
            voices.append(voice); engine.attach(voice.player)
            engine.connect(voice.player, to: engine.mainMixerNode, format: voice.format)
        }
        if plan.hybrid, let notes = plan.midi, let captured = plan.umpRegions {
            let transport = try HybridMidiTransport(midi: notes, ump: captured)
            midi = transport; try transport.prepare()
            transport.onCoordinatedFailure = { [weak self] reason, error in self?.finish(reason: reason, error: error) }
            transport.onCoordinatedEnd = { [weak self] in self?.midiReachedEnd() }
        } else if let timeline = plan.umpRegions {
            let transport = try UmpRegionTransport(timeline: timeline)
            midi = transport; try transport.prepare()
            transport.onCoordinatedFailure = { [weak self] reason, error in self?.finish(reason: reason, error: error) }
            transport.onCoordinatedEnd = { [weak self] in self?.midiReachedEnd() }
        } else if let timeline = plan.ump {
            let transport = try UmpTransport(timeline: timeline)
            midi = transport; try transport.prepare()
            transport.onCoordinatedFailure = { [weak self] reason, error in self?.finish(reason: reason, error: error) }
            transport.onCoordinatedEnd = { [weak self] in self?.midiReachedEnd() }
        } else if let timeline = plan.midi {
            guard let uid = timeline.bindings.first?.destination else { throw AudioFailure("missing mixed MIDI destination") }
            let transport = try MidiTransport(timeline: timeline, uid: uid, coordinated: true)
            midi = transport; try transport.prepare()
            transport.onCoordinatedFailure = { [weak self] reason, error in self?.finish(reason: reason, error: error) }
            transport.onCoordinatedEnd = { [weak self] in self?.midiReachedEnd() }
        }
    }
    var completed: Bool { active.isEmpty && (midi == nil || midiEnded) && (!plan.clocked || horizonEnded) }
    func midiReachedEnd() {
        guard state != .stopped else { return }
        midiEnded = true
        if completed { finish(reason: "finished") }
    }
    func checkOutput() throws {
        let alive = try deviceNumber(device.object, kAudioDevicePropertyDeviceIsAlive)
        guard alive != 0, try outputChannels(device.object) >= Int(renderChannels),
              engine.outputNode.outputFormat(forBus: 0).channelCount == renderChannels, try deviceString(device.object, kAudioDevicePropertyDeviceUID) == device.uid,
              engine.outputNode.auAudioUnit.deviceID == device.object else { throw AudioFailure("selected output is unavailable or changed") }
        if state == .playing && !engine.isRunning { throw AudioFailure("audio engine stopped after output configuration changed") }
        for region in plan.regions {
            try region.calibrationOutput?.validate(deviceUID: device.uid, rate: engine.outputNode.outputFormat(forBus: 0).sampleRate,
                                                  quantum: engine.outputNode.auAudioUnit.maximumFramesToRender)
        }
    }
    func currentTime() -> Double {
        guard state == .playing, let time = engine.outputNode.lastRenderTime, time.isHostTimeValid, time.hostTime > anchor else { return position }
        return min(plan.duration, position + AVAudioTime.seconds(forHostTime: time.hostTime - anchor))
    }
    func snapshot(_ kind: String) -> [String: Any] {
        var value: [String: Any] = ["kind": kind, "currentTime": currentTime(), "duration": plan.duration, "device": device.json,
         "loop": false, "format": plan.kind, "streamBufferFrames": capacity, "regions": voices.count]
        if let midi { value["bindings"] = midi.snapshot(kind)["bindings"] }
        do {
            var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
            var clock: [String: Any] = ["kind": "mach-host-time", "anchor": String(anchor), "position": position,
                "numer": timebase.numer, "denom": timebase.denom,
                "renderQuantum": renderQuantum, "sampleRate": engine.outputNode.outputFormat(forBus: 0).sampleRate,
                "presentationLatency": engine.outputNode.presentationLatency]
            if let midi { clock["midiAnchorNanoseconds"] = String(midi.anchor); clock["midiPosition"] = midi.position(at: DispatchTime.now().uptimeNanoseconds) }
            value["clock"] = clock
        }
        return value
    }
    func publish() {
        do { try audioEmit(snapshot(state == .playing ? "playing" : "paused")) }
        catch { finish(reason: "event-output-failed", error: error, publish: false) }
    }
    func stopVoices() { horizon?.cancel(); horizon = nil; horizonEnded = false; generation &+= 1; for voice in voices { voice.stop() }; active.removeAll() }
    func schedule(from seconds: Double, playing: Bool) throws {
        guard state != .stopped else { return }
        if seconds >= plan.duration { position = plan.duration; finish(reason: "finished"); return }
        engine.pause(); stopVoices(); position = seconds
        try midi?.stageCoordinated(at: seconds); midiEnded = false
        let expected = generation
        for voice in voices {
            let admitted = try voice.prepare(from: seconds, finished: { [weak self] in
                guard let self, self.generation == expected, self.state == .playing else { return }
                self.active.remove(voice.region.id)
                if self.completed { self.finish(reason: "finished") }
            }, failed: { [weak self] error in
                guard let self, self.generation == expected, self.state != .stopped else { return }
                self.finish(reason: "source-read-failed", error: error)
            })
            if admitted { active.insert(voice.region.id) }
        }
        state = .paused
        if playing { try run() }
    }
    func run() throws {
        guard state != .stopped else { return }
        guard position < plan.duration, !active.isEmpty || midi != nil || plan.clocked else { position = plan.duration; finish(reason: "finished"); return }
        try checkOutput(); engine.prepare(); try engine.start()
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate, latency = engine.outputNode.presentationLatency
        guard rate.isFinite, rate > 0, latency.isFinite, latency >= 0 else { throw AudioFailure("output clock is unavailable") }
        // A node may already have rendered beyond wall-clock now. Apple defines
        // play(at:) before lastRenderTime as immediate playback, so reserve the
        // common lead beyond every active render frontier, not just wall time.
        var frontier = mach_absolute_time()
        let renderTimes = voices.filter({ active.contains($0.region.id) }).map({ $0.player.lastRenderTime })
        if !renderTimes.isEmpty {
            for candidate in [engine.outputNode.lastRenderTime] + renderTimes {
                guard let time = candidate, time.isHostTimeValid else { throw AudioFailure("audio render clock is unavailable at start") }
                frontier = max(frontier, time.hostTime)
            }
        }
        let lead = Double(renderQuantum) / rate * Double(active.count + 1) + latency
        anchor = try futureHost(lead, from: frontier)
        _ = try futureHost(plan.duration - position, from: anchor)
        for voice in voices where active.contains(voice.region.id) {
            let when = try futureHost(max(0, voice.region.startSeconds - position), from: anchor)
            guard let render = voice.player.lastRenderTime, render.isHostTimeValid, render.hostTime < when else {
                throw AudioFailure("audio node passed its common start deadline")
            }
            voice.player.play(at: AVAudioTime(hostTime: when))
        }
        if let midi { try midi.runCoordinated(anchorNanoseconds: AudioConvertHostTimeToNanos(anchor)) }
        guard mach_absolute_time() < anchor else { throw AudioFailure("audio graph missed its common start deadline") }
        state = .playing; try checkOutput()
        if plan.clocked {
            let expected = generation, end = try futureHost(plan.duration - position, from: anchor)
            let timer = DispatchSource.makeTimerSource(queue: .main); horizon = timer
            timer.schedule(deadline: DispatchTime(uptimeNanoseconds: AudioConvertHostTimeToNanos(end)), leeway: .nanoseconds(0))
            timer.setEventHandler { [weak self] in
                guard let self, self.generation == expected, self.state == .playing else { return }
                self.horizonEnded = true; self.horizon?.cancel(); self.horizon = nil
                if self.completed { self.finish(reason: "finished") }
            }
            timer.resume()
        }
    }
    func monitor(_ object: AudioObjectID, _ original: AudioObjectPropertyAddress) throws {
        var key = original
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.state != .stopped else { return }
            do { try self.checkOutput() } catch { self.finish(reason: "output-unavailable", error: error) }
        }
        try audioChecked(AudioObjectAddPropertyListenerBlock(object, &key, .main, listener), "observe selected output")
        listeners.append((object, key, listener))
    }
    func start() throws {
        try checkOutput()
        try monitor(device.object, address(kAudioDevicePropertyDeviceIsAlive))
        try monitor(device.object, address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput))
        try monitor(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices))
        configuration = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.state != .stopped else { return }
            do { try self.checkOutput() } catch { self.finish(reason: "output-configuration-changed", error: error) }
        }
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.finish(reason: "signal") }; source.resume(); signals.append(source)
        }
        try schedule(from: 0, playing: true); publish()
    }
    func receive(_ line: String) {
        guard state != .stopped else { return }
        do {
            try checkOutput()
            let command = try JSONDecoder().decode(AudioCommand.self, from: Data(line.utf8))
            do {
                switch command {
                case .pause: if state == .playing {
                    let time = currentTime()
                    if time >= plan.duration { position = plan.duration; finish(reason: "finished"); return }
                    engine.pause(); stopVoices(); position = time; state = .paused
                    try midi?.stageCoordinated(at: time)
                }
                case .resume: if state == .paused { try schedule(from: position, playing: true) }
                case .seek(let seconds):
                    guard seconds.isFinite, seconds >= 0, seconds <= plan.duration else { throw AudioFailure("seek outside arrangement duration") }
                    if seconds == plan.duration { position = seconds; finish(reason: "finished"); return }
                    try schedule(from: seconds, playing: state == .playing)
                case .status: break
                case .recordingEpoch(let request):
                    var event = snapshot(state == .playing ? "playing" : "paused")
                    event["recordingRequest"] = request; try audioEmit(event); return
                case .stop: finish(reason: "stop"); return
                }
            } catch {
                // A rejected pause/resume/seek is a command error: report it and
                // keep the transport running instead of stopping playback.
                report(String(describing: error))
                try? audioEmit(["kind": "error", "message": String(describing: error)])
                if state != .stopped { publish() }
                return
            }
            }
            if state != .stopped { publish() }
        } catch { finish(reason: "command-failed", error: error) }
    }
    func finish(reason: String, error: Error? = nil, publish: Bool = true) {
        guard state != .stopped else { return }
        var event = snapshot("stopped"), finalError = error
        if reason == "finished" { event["currentTime"] = plan.duration }
        state = .stopped; stopVoices(); engine.stop()
        midi?.finish(reason: reason, error: finalError, publish: false)
        finalError = finalError ?? midi?.terminalFailure
        if let configuration { NotificationCenter.default.removeObserver(configuration) }; configuration = nil
        for (object, original, listener) in listeners { var key = original; AudioObjectRemovePropertyListenerBlock(object, &key, .main, listener) }
        listeners.removeAll(); for source in signals { source.cancel() }; signals.removeAll()
        var failure = finalError != nil; event["reason"] = reason; event["success"] = !failure
        if let finalError { report(String(describing: finalError)) }
        if publish {
            do { if let finalError { try audioEmit(["kind": "error", "message": String(describing: finalError)]) }; try audioEmit(event) }
            catch { failure = true; report("audio event output failed: \(error)") }
        }
        exit(failure ? 1 : 0)
    }
}
struct Options {
    var file: String?
    var output: String?
    init() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "play" else { throw AudioFailure("usage: music-arrangement play --file PLAN [--output UID]") }
        args.removeFirst()
        while !args.isEmpty {
            switch args.removeFirst() {
            case "--file": guard file == nil, !args.isEmpty else { throw AudioFailure("--file requires one plan") }; file = args.removeFirst()
            case "--output": guard output == nil, !args.isEmpty else { throw AudioFailure("--output requires one UID") }; output = args.removeFirst()
            default: throw AudioFailure("unknown arrangement playback option")
            }
        }
        guard let file, !file.isEmpty else { throw AudioFailure("missing arrangement plan") }
        if let output, output.isEmpty { throw AudioFailure("missing output UID") }
    }
}
#if !ARRANGEMENT_LIBRARY
@main enum ArrangementCommandLine {
static func main() {
_ = signal(SIGPIPE, SIG_IGN)
do {
    let options = try Options()
    let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: URL(fileURLWithPath: options.file!)))
    let transport = try ArrangementTransport(plan: plan, output: options.output)
    do { try transport.start() } catch { transport.finish(reason: "start-failed", error: error) }
    DispatchQueue.global().async {
        while let line = readLine() { DispatchQueue.main.async { transport.receive(line) } }
        DispatchQueue.main.async { transport.finish(reason: "eof") }
    }
    withExtendedLifetime(transport) { RunLoop.main.run() }
} catch {
    report(String(describing: error))
    do { try audioEmit(["kind": "error", "message": String(describing: error)]) } catch { report("audio event output failed: \(error)") }
    exit(1)
}

}
}

#endif
