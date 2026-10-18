// CoreAudio and CoreMIDI share the mach host clock. Keep the original clock
// observations beside every audio block and UMP packet; do not infer musical
// timing from the UI timer or callback delivery time.
import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMIDI

struct SessionFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func checked(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw SessionFailure("\(operation): OSStatus \(status)") }
}

func encoded(_ value: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    data.append(10)
    return data
}

func emit(_ value: [String: Any]) {
    if let data = try? encoded(value) { FileHandle.standardOutput.write(data) }
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func audioString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var key = address(selector)
    var value: UnsafeRawPointer? = nil
    var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
    try checked(AudioObjectGetPropertyData(object, &key, 0, nil, &size, &value), "read audio device string")
    guard let value else { throw SessionFailure("audio device string is unavailable") }
    return Unmanaged<CFString>.fromOpaque(value).takeRetainedValue() as String
}

func channels(_ object: AudioObjectID, _ scope: AudioObjectPropertyScope) throws -> Int {
    var key = address(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    try checked(AudioObjectGetPropertyDataSize(object, &key, 0, nil, &size), "read audio stream configuration size")
    let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    try checked(AudioObjectGetPropertyData(object, &key, 0, nil, &size, memory), "read audio stream configuration")
    return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        .reduce(0) { $0 + Int($1.mNumberChannels) }
}

struct AudioDevice {
    let object: AudioObjectID
    let uid: String
    let name: String
    let inputs: Int
    let outputs: Int
    var json: [String: Any] { ["id": uid, "name": name, "inputs": inputs, "outputs": outputs] }
}

func audioDevices() throws -> [AudioDevice] {
    var key = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    try checked(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &key, 0, nil, &size), "list audio devices")
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    try checked(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &key, 0, nil, &size, &ids), "read audio devices")
    return try ids.map { id in
        AudioDevice(object: id, uid: try audioString(id, kAudioDevicePropertyDeviceUID),
                    name: try audioString(id, kAudioObjectPropertyName),
                    inputs: try channels(id, kAudioObjectPropertyScopeInput),
                    outputs: try channels(id, kAudioObjectPropertyScopeOutput))
    }
}

struct MidiSource {
    let endpoint: MIDIEndpointRef
    let uid: Int32
    let name: String
    var json: [String: Any] { ["id": String(uid), "name": name] }
}

func midiSources() throws -> [MidiSource] {
    try (0..<MIDIGetNumberOfSources()).map { index in
        let endpoint = MIDIGetSource(index)
        var uid: Int32 = 0
        var name: Unmanaged<CFString>?
        try checked(MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid), "read MIDI source identity")
        try checked(MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name), "read MIDI source name")
        guard let name else { throw SessionFailure("MIDI source name is unavailable") }
        return MidiSource(endpoint: endpoint, uid: uid, name: name.takeRetainedValue() as String)
    }
}

// File handles and JSON encoding belong exclusively to the writer queue.
// A bounded pool prevents a slow disk from growing the capture queue forever.
// Saturation is an explicit failed recording, never a silently dropped block.
final class Capture {
    let directory: URL
    let input: AudioDevice
    let sources: [MidiSource]
    let engine = AVAudioEngine()
    let writer = DispatchQueue(label: "masc.music.writer")
    let state = NSLock()
    var accepting = false
    var finished = false
    var firstFailure: String?
    var audio: AVAudioFile?
    var midi: FileHandle?
    var blocks: FileHandle?
    var frames: UInt64 = 0
    var midiPackets: UInt64 = 0
    var requestedHost: UInt64 = 0
    var firstAudioHost: UInt64?
    var client = MIDIClientRef()
    var port = MIDIPortRef()
    var signalSources: [DispatchSourceSignal] = []
    var format: AVAudioFormat?
    var pool: [AVAudioPCMBuffer] = []
    var poolIndex = 0 // one audio-tap producer
    var slots: DispatchSemaphore?
    let midiSlots = DispatchSemaphore(value: 1024)

    init(directory: URL, input: AudioDevice, sources: [MidiSource]) {
        self.directory = directory; self.input = input; self.sources = sources
    }

    func armed() -> Bool {
        state.lock(); defer { state.unlock() }
        return accepting
    }

    func fail(_ message: String) {
        state.lock()
        if firstFailure == nil { firstFailure = message }
        accepting = false
        state.unlock()
        DispatchQueue.main.async { self.stop() }
    }

    func handle(_ name: String) throws -> FileHandle {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw SessionFailure("cannot create \(name)")
        }
        return try FileHandle(forWritingTo: url)
    }

    func start() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw SessionFailure("session directory already exists; recordings are never overwritten")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        midi = try handle("midi.ump.jsonl")
        blocks = try handle("audio-blocks.jsonl")
        let node = engine.inputNode
        guard node.audioUnit != nil else { throw SessionFailure("audio input unit is unavailable") }
        try node.auAudioUnit.setDeviceID(input.object)
        guard node.auAudioUnit.deviceID == input.object else {
            throw SessionFailure("audio engine did not select the requested input device")
        }
        let hardware = node.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let captureFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: hardware.sampleRate,
                                               channels: hardware.channelCount, interleaved: false) else {
            throw SessionFailure("input device has no usable audio stream")
        }
        format = captureFormat
        audio = try AVAudioFile(forWriting: directory.appendingPathComponent("audio.wav"),
            settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: captureFormat.sampleRate,
                       AVNumberOfChannelsKey: captureFormat.channelCount, AVLinearPCMBitDepthKey: 32,
                       AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false],
            commonFormat: .pcmFormatFloat32, interleaved: false)
        // AVAudioNode.h documents tap buffers in the 100..400 ms range.
        // A tap groups multiple audio-unit render slices; MaximumFramesPerSlice
        // is therefore not the capacity of a tap buffer.
        let maxFrames = AVAudioFrameCount(ceil(captureFormat.sampleRate * 0.4))
        let requestedFrames = AVAudioFrameCount(ceil(captureFormat.sampleRate * 0.1))
        // One second of the device's maximum-size blocks is an explicit disk
        // writer buffer, not a recording-duration or product-behavior limit.
        let capacity = max(2, Int(ceil(captureFormat.sampleRate / Double(maxFrames))))
        slots = DispatchSemaphore(value: capacity)
        pool = try (0..<capacity).map { _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: maxFrames) else {
                throw SessionFailure("cannot allocate audio capture buffer")
            }
            return buffer
        }
        node.installTap(onBus: 0, bufferSize: requestedFrames, format: captureFormat) { [weak self] buffer, time in
            self?.acceptAudio(buffer, time)
        }
        requestedHost = mach_absolute_time()
        state.lock(); accepting = true; state.unlock()
        if !sources.isEmpty {
            try checked(MIDIClientCreateWithBlock("MASC music recording" as CFString, &client, nil), "create MIDI client")
            try checked(MIDIInputPortCreateWithProtocol(client, "MASC recording input" as CFString,
                MIDIProtocolID._2_0, &port, { [weak self] list, connection in
                    self?.acceptMidi(list, connection)
                }), "create MIDI input port")
            for source in sources {
                try checked(MIDIPortConnectSource(port, source.endpoint,
                    UnsafeMutableRawPointer(bitPattern: UInt(source.endpoint))), "connect MIDI input")
            }
        }
        try engine.start()
        emit(["kind": "recording", "directory": directory.path, "sampleRate": captureFormat.sampleRate,
              "channels": captureFormat.channelCount, "input": input.json, "midiSources": sources.map(\.json)])
    }

    func acceptAudio(_ incoming: AVAudioPCMBuffer, _ time: AVAudioTime) {
        guard armed(), let slots else { return }
        guard time.isHostTimeValid, time.isSampleTimeValid else { fail("audio block has no hardware clock timestamp"); return }
        guard slots.wait(timeout: .now()) == .success else { fail("audio writer overrun; recording stopped without hiding lost input"); return }
        let buffer = pool[poolIndex]; poolIndex = (poolIndex + 1) % pool.count
        guard incoming.frameLength <= buffer.frameCapacity,
              let from = incoming.floatChannelData, let to = buffer.floatChannelData else {
            slots.signal(); fail("audio unit exceeded its advertised float-buffer capacity"); return
        }
        buffer.frameLength = incoming.frameLength
        for channel in 0..<Int(incoming.format.channelCount) {
            memcpy(to[channel], from[channel], Int(incoming.frameLength) * MemoryLayout<Float>.size)
        }
        let host = time.hostTime, sample = time.sampleTime
        writer.async {
            defer { slots.signal() }
            do {
                try self.audio?.write(from: buffer)
                let count = Int(buffer.frameLength)
                let peaks = (0..<Int(buffer.format.channelCount)).map { channel -> [Float] in
                    var low: Float = 0, high: Float = 0
                    for index in 0..<count {
                        let value = to[channel][index]
                        low = min(low, value); high = max(high, value)
                    }
                    return [low, high]
                }
                let row: [String: Any] = ["kind": "audio", "hostTime": String(host),
                    "deviceSampleTime": String(sample), "frameOffset": String(self.frames),
                    "frameCount": count, "peaks": peaks]
                try self.blocks?.write(contentsOf: encoded(row))
                self.firstAudioHost = self.firstAudioHost ?? host
                self.frames += UInt64(count)
                emit(row)
            } catch { self.fail("audio write failed: \(error)") }
        }
    }

    func acceptMidi(_ list: UnsafePointer<MIDIEventList>, _ connection: UnsafeMutableRawPointer?) {
        guard armed(), let connection else { return }
        let endpoint = MIDIEndpointRef(UInt(bitPattern: connection))
        guard let source = sources.first(where: { $0.endpoint == endpoint }) else { return }
        var packet = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIEventList>.offset(of: \.packet)!)
            .assumingMemoryBound(to: MIDIEventPacket.self)
        for _ in 0..<list.pointee.numPackets {
            guard midiSlots.wait(timeout: .now()) == .success else { fail("MIDI writer overrun; recording stopped without hiding lost input"); return }
            let value = packet.pointee
            let words = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \.words)!)
                .assumingMemoryBound(to: UInt32.self)
            let copied = Array(UnsafeBufferPointer(start: words, count: Int(value.wordCount)))
            let receivedHost = mach_absolute_time()
            let timestamp = value.timeStamp
            let row: [String: Any] = ["kind": "midi", "source": String(source.uid),
                "protocol": list.pointee.protocol.rawValue, "hostTime": String(timestamp == 0 ? receivedHost : timestamp),
                "timestampOrigin": timestamp == 0 ? "received" : "packet", "words": copied]
            writer.async {
                defer { self.midiSlots.signal() }
                do {
                    try self.midi?.write(contentsOf: encoded(row))
                    self.midiPackets += 1
                    emit(row)
                } catch { self.fail("MIDI write failed: \(error)") }
            }
            packet = UnsafePointer(MIDIEventPacketNext(packet))
        }
    }

    func stop() {
        state.lock()
        if finished { state.unlock(); return }
        finished = true; accepting = false
        state.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        writer.sync {
            audio = nil // finalize the WAVE container before publishing its manifest
            do {
                try midi?.close(); try blocks?.close()
                var clock = mach_timebase_info_data_t()
                mach_timebase_info(&clock)
                let manifest: [String: Any] = ["schemaVersion": 1, "state": firstFailure == nil ? "recorded" : "failed",
                    "failure": firstFailure as Any? ?? NSNull(), "clock": ["kind": "mach-host-time",
                        "numer": clock.numer, "denom": clock.denom, "requestedStart": String(requestedHost),
                        "firstAudioHostTime": firstAudioHost.map(String.init) as Any? ?? NSNull()],
                    "sampleRate": format?.sampleRate ?? 0, "channels": format?.channelCount ?? 0,
                    "audioFrames": String(frames), "midiPacketCount": String(midiPackets),
                    "audio": "audio.wav", "audioBlocks": "audio-blocks.jsonl", "midi": "midi.ump.jsonl",
                    "input": input.json, "midiSources": sources.map(\.json)]
                try encoded(manifest).write(to: directory.appendingPathComponent("session.json"), options: [.atomic])
                emit(["kind": "stopped", "directory": directory.path, "session": manifest])
            } catch { emit(["kind": "error", "message": "cannot finalize recording: \(error)"]) }
        }
        exit(firstFailure == nil ? 0 : 1)
    }
}

func option(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

do {
    switch CommandLine.arguments.dropFirst().first {
    case "devices":
        emit(["kind": "devices", "audio": try audioDevices().map(\.json), "midi": try midiSources().map(\.json)])
    case "record":
        guard let uid = option("--input"), let path = option("--directory") else {
            throw SessionFailure("record requires --input DEVICE_UID and --directory NEW_SESSION_DIRECTORY")
        }
        guard let input = try audioDevices().first(where: { $0.uid == uid && $0.inputs > 0 }) else {
            throw SessionFailure("selected input device is unavailable")
        }
        let midiSelection = option("--midi") ?? "all"
        let available = try midiSources()
        let selected = midiSelection == "all" ? available : available.filter { String($0.uid) == midiSelection }
        if midiSelection != "all" && selected.isEmpty { throw SessionFailure("selected MIDI input is unavailable") }
        let capture = Capture(directory: URL(fileURLWithPath: path), input: input, sources: selected)
        try capture.start()
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { capture.stop() }
            source.resume(); capture.signalSources.append(source)
        }
        DispatchQueue.global().async {
            while let line = readLine() {
                if line == "stop" { DispatchQueue.main.async { capture.stop() }; return }
            }
            DispatchQueue.main.async { capture.stop() }
        }
        RunLoop.main.run()
    default:
        throw SessionFailure("usage: masc-music-native devices | record --input UID --directory NEW_PATH [--midi all|UID]")
    }
} catch {
    emit(["kind": "error", "message": String(describing: error)])
    exit(1)
}
