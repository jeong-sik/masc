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

// A parent can close its event pipe while recording still owns files. Convert
// that loss into a throwing write so Capture can finalize a failed session.
let protectOutputPipe: Void = { _ = signal(SIGPIPE, SIG_IGN) }()

func emit(_ value: [String: Any]) throws {
    _ = protectOutputPipe
    try FileHandle.standardOutput.write(contentsOf: encoded(value))
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

// AVAudioFormat.h: the channel-count initializers return nil above two
// channels, so a wider stream carries a DiscreteInOrder layout. The mixer
// copies discrete channel N to output channel N, but renders a discrete
// source into an unlabelled mono/stereo output as silence. A monitor output
// fed by a wider input is therefore discrete as well.
let unlabelledChannelLimit = 2

func floatStreamFormat(sampleRate: Double, channels: Int, discrete: Bool) -> AVAudioFormat? {
    guard discrete else {
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                             channels: AVAudioChannelCount(channels), interleaved: false)
    }
    // DiscreteInOrder keeps its channel count in the low 16 bits of the tag.
    guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)),
          layout.channelCount == AVAudioChannelCount(channels) else {
        return nil
    }
    return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
}

func captureStreamFormat(sampleRate: Double, inputs: Int) -> AVAudioFormat? {
    floatStreamFormat(sampleRate: sampleRate, channels: inputs, discrete: inputs > unlabelledChannelLimit)
}

func monitorStreamFormat(sampleRate: Double, inputs: Int, outputs: Int) -> AVAudioFormat? {
    floatStreamFormat(sampleRate: sampleRate, channels: outputs,
                      discrete: inputs > unlabelledChannelLimit || outputs > unlabelledChannelLimit)
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
    let directory: URL?
    let monitorOutput: AudioDevice?
    let input: AudioDevice
    let sources: [MidiSource]
    let hostClock: mach_timebase_info_data_t
    let engine = AVAudioEngine()
    let writer = DispatchQueue(label: "masc.music.writer")
    let state = NSLock()
    let callbacks = DispatchGroup()
    var accepting = false
    var stopping = false
    var finished = false
    var createdDirectory = false
    var tapInstalled = false
    var configurationObserver: NSObjectProtocol?
    var deviceAliveListener: AudioObjectPropertyListenerBlock?
    var outputAliveListener: AudioObjectPropertyListenerBlock?
    var aggregate: AudioObjectID = 0
    var routeDevice: AudioObjectID { aggregate == 0 ? input.object : aggregate }
    var monitoringSnapshot: [String: Any] = ["state": "off"]
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
    var nextAudioSample: AVAudioFramePosition? // same producer; reset only with a new Capture
    var slots: DispatchSemaphore?
    let midiSlots = DispatchSemaphore(value: 1024)

    init(directory: URL?, input: AudioDevice, sources: [MidiSource], monitorOutput: AudioDevice? = nil) {
        _ = protectOutputPipe
        self.directory = directory; self.input = input; self.sources = sources; self.monitorOutput = monitorOutput
        var clock = mach_timebase_info_data_t()
        mach_timebase_info(&clock)
        hostClock = clock
    }

    // Enter under the same lock that closes admission. Teardown must wait for
    // admitted producers to enqueue their final write before draining writer.
    func beginCallback() -> Bool {
        state.lock(); defer { state.unlock() }
        guard accepting else { return false }
        callbacks.enter()
        return true
    }

    func fail(_ message: String) {
        state.lock()
        guard !finished else { state.unlock(); return }
        if firstFailure == nil { firstFailure = message }
        accepting = false
        state.unlock()
        DispatchQueue.main.async { self.stop() }
    }

    func publish(_ value: [String: Any]) {
        do { try emit(value) }
        catch { fail("capture event output failed: \(error)") }
    }

    func interrupted(_ message: String) {
        state.lock()
        // Notifications already queued when observers are removed must not
        // turn an operator's ordinary stop into a hardware failure.
        guard !stopping && !finished else { state.unlock(); return }
        if firstFailure == nil { firstFailure = message }
        accepting = false
        state.unlock()
        DispatchQueue.main.async { self.stop() }
    }

    func checkInputAlive() throws {
        var key = address(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try checked(AudioObjectGetPropertyData(input.object, &key, 0, nil, &size, &alive),
                    "read selected input device state")
        guard alive != 0 else { throw SessionFailure("selected input device is no longer alive") }
        guard try audioString(input.object, kAudioDevicePropertyDeviceUID) == input.uid else {
            throw SessionFailure("selected input device identity changed")
        }
    }

    func checkInputConfiguration() throws {
        try checkInputAlive()
        guard engine.isRunning else { throw SessionFailure("audio engine stopped during recording") }
        let node = engine.inputNode
        guard node.audioUnit != nil, node.auAudioUnit.deviceID == routeDevice else {
            throw SessionFailure("audio engine changed the selected input device")
        }
        if let output = monitorOutput {
            var key = address(kAudioDevicePropertyDeviceIsAlive)
            var alive: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
            try checked(AudioObjectGetPropertyData(output.object, &key, 0, nil, &size, &alive), "read monitor output state")
            guard alive != 0, engine.outputNode.auAudioUnit.deviceID == routeDevice else {
                throw SessionFailure("selected monitoring output is unavailable or changed")
            }
            guard try audioString(output.object, kAudioDevicePropertyDeviceUID) == output.uid else {
                throw SessionFailure("selected monitoring output identity changed")
            }
        }
        if aggregate != 0, let output = monitorOutput, let unit = node.audioUnit {
            for (bus, expected) in [(UInt32(1), (0..<input.inputs).map(Int32.init)),
                                    (UInt32(0), [Int32](repeating: -1, count: input.outputs) + (0..<output.outputs).map(Int32.init))] {
                var size: UInt32 = 0
                try checked(AudioUnitGetPropertyInfo(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, bus, &size, nil), "read monitor channel map size")
                guard Int(size) == expected.count * MemoryLayout<Int32>.size else { throw SessionFailure("monitor channel map size changed") }
                var actual = [Int32](repeating: -1, count: expected.count)
                try checked(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, bus, &actual, &size), "read monitor channel map")
                guard actual == expected else { throw SessionFailure("monitor channel map changed") }
            }
        }
        let hardware = node.inputFormat(forBus: 0)
        guard let format, hardware.sampleRate == format.sampleRate,
              hardware.channelCount == (aggregate == 0 ? input.inputs : input.inputs + (monitorOutput?.inputs ?? 0)) else {
            throw SessionFailure("selected audio input sample rate or channel count changed")
        }
    }

    func validateConfigurationChange() {
        // Graph setup can notify synchronously from engine.start(). Validate
        // its resulting state on the lifecycle queue after start returns;
        // a notification alone does not establish that capture was interrupted.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state.lock()
            let active = !self.stopping && !self.finished
            self.state.unlock()
            guard active else { return }
            do { try self.checkInputConfiguration() }
            catch { self.interrupted("audio engine configuration interrupted recording: \(error)") }
        }
    }

    func monitorInput() throws {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                self?.validateConfigurationChange()
            }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            do { try self.checkInputAlive() }
            catch { self.interrupted("selected audio input became unavailable: \(error)") }
        }
        var key = address(kAudioDevicePropertyDeviceIsAlive)
        try checked(AudioObjectAddPropertyListenerBlock(input.object, &key, .main, listener),
                    "observe selected audio input state")
        deviceAliveListener = listener
        if let output = monitorOutput {
            let outputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.validateConfigurationChange()
            }
            try checked(AudioObjectAddPropertyListenerBlock(output.object, &key, .main, outputListener),
                        "observe selected monitoring output")
            outputAliveListener = outputListener
        }
        try checkInputAlive()
    }

    var monitoring: [String: Any] {
        guard let output = monitorOutput else { return ["state": "off"] }
        return ["state": "active", "input": input.json, "output": output.json,
                "sampleRate": format?.sampleRate ?? 0, "channels": format?.channelCount ?? 0,
                "latency": ["kind": "device-reported", "inputSeconds": engine.inputNode.presentationLatency,
                            "outputSeconds": engine.outputNode.presentationLatency]]
    }

    func checkMidiSourcesOnline() throws {
        for source in sources {
            var offline: Int32 = 0
            let status = MIDIObjectGetIntegerProperty(source.endpoint, kMIDIPropertyOffline, &offline)
            // Virtual endpoints need not publish the physical-device property.
            if status == kMIDIUnknownProperty { continue }
            try checked(status, "read selected MIDI source state")
            guard offline == 0 else { throw SessionFailure("selected MIDI source is offline: \(source.name)") }
        }
    }

    func handle(_ name: String) throws -> FileHandle {
        guard let directory else { throw SessionFailure("monitor-only session cannot create recording files") }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw SessionFailure("cannot create \(name)")
        }
        return try FileHandle(forWritingTo: url)
    }

    func start() throws {
        guard Thread.isMainThread else { throw SessionFailure("recording lifecycle must start on the main thread") }
        do { try startResources() }
        catch {
            state.lock()
            if firstFailure == nil { firstFailure = "cannot start recording: \(error)" }
            state.unlock()
            // The caller reports the start error. Finalize only resources we
            // own, including a failed manifest for a directory we created.
            stop(exitProcess: false)
            throw error
        }
    }

    private func startResources() throws {
        if let directory {
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                throw SessionFailure("session directory already exists; recordings are never overwritten")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            createdDirectory = true
            midi = try handle("midi.ump.jsonl")
            blocks = try handle("audio-blocks.jsonl")
        }
        let node = engine.inputNode
        guard node.audioUnit != nil else { throw SessionFailure("audio input unit is unavailable") }
        if let output = monitorOutput, output.object != input.object {
            // AVAudioEngine has one I/O unit. Two selected devices require a
            // private aggregate; neither system default nor peer channels change.
            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MASC input monitoring",
                kAudioAggregateDeviceUIDKey: "masc-input-" + UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: 1,
                kAudioAggregateDeviceMainSubDeviceKey: output.uid,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: input.uid, kAudioSubDeviceDriftCompensationKey: 1],
                    [kAudioSubDeviceUIDKey: output.uid]]]
            try checked(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate), "create private input/output route")
        }
        if monitorOutput != nil { try engine.outputNode.auAudioUnit.setDeviceID(routeDevice) }
        try node.auAudioUnit.setDeviceID(routeDevice)
        guard node.auAudioUnit.deviceID == routeDevice else {
            throw SessionFailure("audio engine did not select the requested input device")
        }
        let hardware = node.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let captureFormat = captureStreamFormat(sampleRate: hardware.sampleRate, inputs: input.inputs) else {
            throw SessionFailure("input device has no usable audio stream")
        }
        format = captureFormat
        if let output = monitorOutput {
            guard engine.outputNode.auAudioUnit.deviceID == routeDevice else {
                throw SessionFailure("audio engine did not select the requested monitoring output")
            }
            engine.connect(node, to: engine.mainMixerNode, format: captureFormat)
            guard let outputFormat = monitorStreamFormat(sampleRate: hardware.sampleRate,
                                                         inputs: input.inputs, outputs: output.outputs) else {
                throw SessionFailure("monitor output has no usable audio stream")
            }
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
            if aggregate != 0 {
                guard let unit = node.audioUnit else { throw SessionFailure("monitor I/O unit is unavailable") }
                var inputMap = (0..<input.inputs).map(Int32.init)
                try checked(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1,
                    &inputMap, UInt32(inputMap.count * MemoryLayout<Int32>.size)), "select aggregate input channels")
                var outputMap = [Int32](repeating: -1, count: input.outputs) + (0..<output.outputs).map(Int32.init)
                try checked(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 0,
                    &outputMap, UInt32(outputMap.count * MemoryLayout<Int32>.size)), "select aggregate output channels")
            }
        }
        if let directory {
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
            tapInstalled = true
        }
        try monitorInput()
        requestedHost = mach_absolute_time()
        if !sources.isEmpty {
            try checked(MIDIClientCreateWithBlock("MASC music recording" as CFString, &client, { [weak self] notification in
                guard let self else { return }
                switch notification.pointee.messageID {
                case .msgObjectRemoved:
                    let removed = UnsafeRawPointer(notification).assumingMemoryBound(to: MIDIObjectAddRemoveNotification.self)
                        .pointee.child
                    if self.sources.contains(where: { $0.endpoint == removed }) {
                        self.interrupted("selected MIDI source was removed; recording interrupted")
                    }
                case .msgPropertyChanged:
                    let change = UnsafeRawPointer(notification).assumingMemoryBound(to: MIDIObjectPropertyChangeNotification.self)
                        .pointee
                    if change.propertyName.takeUnretainedValue() == kMIDIPropertyOffline {
                        do { try self.checkMidiSourcesOnline() }
                        catch { self.interrupted("selected MIDI input became unavailable: \(error)") }
                    }
                default: break
                }
            }), "create MIDI client")
            try checked(MIDIInputPortCreateWithProtocol(client, "MASC recording input" as CFString,
                MIDIProtocolID._2_0, &port, { [weak self] list, connection in
                    self?.acceptMidi(list, connection)
                }), "create MIDI input port")
            for source in sources {
                try checked(MIDIPortConnectSource(port, source.endpoint,
                    UnsafeMutableRawPointer(bitPattern: UInt(source.endpoint))), "connect MIDI input")
            }
            try checkMidiSourcesOnline()
        }
        // Publish the common clock before admission opens. Callbacks can run
        // inside engine.start(), and must never overtake this session header.
        writer.sync {
            if let directory {
                publish(["kind": "recording", "directory": directory.path, "sampleRate": captureFormat.sampleRate,
                  "channels": captureFormat.channelCount, "input": input.json, "midiSources": sources.map(\.json),
                  "clock": ["kind": "mach-host-time", "numer": hostClock.numer, "denom": hostClock.denom,
                            "requestedStart": String(requestedHost)]])
            }
        }
        state.lock()
        let failure = firstFailure
        if failure == nil { accepting = true }
        state.unlock()
        if let failure { throw SessionFailure(failure) }
        try engine.start()
        try checkInputConfiguration()
        state.lock(); let startFailure = firstFailure; state.unlock()
        if let startFailure { throw SessionFailure(startFailure) }
        if monitorOutput != nil {
            monitoringSnapshot = monitoring
            publish(["kind": "monitoring", "monitoring": monitoringSnapshot])
        }
    }

    func acceptAudio(_ incoming: AVAudioPCMBuffer, _ time: AVAudioTime) {
        guard beginCallback() else { return }
        defer { callbacks.leave() }
        guard let slots else { fail("audio capture buffers are unavailable"); return }
        guard time.isHostTimeValid, time.isSampleTimeValid else { fail("audio block has no hardware clock timestamp"); return }
        if let expected = nextAudioSample, expected != time.sampleTime {
            fail("audio device sample timeline is discontinuous: expected \(expected), received \(time.sampleTime)")
            return
        }
        let (nextSample, overflow) = time.sampleTime.addingReportingOverflow(AVAudioFramePosition(incoming.frameLength))
        guard !overflow else { fail("audio device sample timeline overflowed"); return }
        guard slots.wait(timeout: .now()) == .success else { fail("audio writer overrun; recording stopped without hiding lost input"); return }
        let buffer = pool[poolIndex]; poolIndex = (poolIndex + 1) % pool.count
        guard incoming.format.sampleRate == buffer.format.sampleRate,
              incoming.format.channelCount == buffer.format.channelCount,
              incoming.format.commonFormat == .pcmFormatFloat32,
              !incoming.format.isInterleaved,
              incoming.frameLength <= buffer.frameCapacity,
              let from = incoming.floatChannelData, let to = buffer.floatChannelData else {
            slots.signal(); fail("audio input format changed or exceeded its capture-buffer capacity"); return
        }
        nextAudioSample = nextSample
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
                self.publish(row)
            } catch { self.fail("audio write failed: \(error)") }
        }
    }

    func acceptMidi(_ list: UnsafePointer<MIDIEventList>, _ connection: UnsafeMutableRawPointer?) {
        guard beginCallback() else { return }
        defer { callbacks.leave() }
        guard let connection else { fail("MIDI callback has no selected source identity"); return }
        let endpoint = MIDIEndpointRef(UInt(bitPattern: connection))
        guard let source = sources.first(where: { $0.endpoint == endpoint }) else { return }
        let rawList = UnsafeRawPointer(list)
        let packetCount = rawList.loadUnaligned(fromByteOffset: MemoryLayout<MIDIEventList>.offset(of: \.numPackets)!, as: UInt32.self)
        let midiProtocol = rawList.loadUnaligned(fromByteOffset: MemoryLayout<MIDIEventList>.offset(of: \.protocol)!, as: UInt32.self)
        var packet = rawList.advanced(by: MemoryLayout<MIDIEventList>.offset(of: \.packet)!)
        for _ in 0..<packetCount {
            guard midiSlots.wait(timeout: .now()) == .success else { fail("MIDI writer overrun; recording stopped without hiding lost input"); return }
            // CoreMIDI packets are variable-length despite the C declaration's
            // words[64]. Copying packet.pointee reads past short allocations.
            let timestamp = packet.loadUnaligned(fromByteOffset: MemoryLayout<MIDIEventPacket>.offset(of: \.timeStamp)!, as: MIDITimeStamp.self)
            let wordCount = packet.loadUnaligned(fromByteOffset: MemoryLayout<MIDIEventPacket>.offset(of: \.wordCount)!, as: UInt32.self)
            let words = packet.advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \.words)!)
                .assumingMemoryBound(to: UInt32.self)
            let copied = Array(UnsafeBufferPointer(start: words, count: Int(wordCount)))
            let receivedHost = mach_absolute_time()
            let row: [String: Any] = ["kind": "midi", "source": String(source.uid),
                "protocol": midiProtocol, "hostTime": String(timestamp == 0 ? receivedHost : timestamp),
                "timestampOrigin": timestamp == 0 ? "received" : "packet", "words": copied]
            writer.async {
                defer { self.midiSlots.signal() }
                do {
                    try self.midi?.write(contentsOf: encoded(row))
                    self.midiPackets += 1
                    self.publish(row)
                } catch { self.fail("MIDI write failed: \(error)") }
            }
            packet = UnsafeRawPointer(words.advanced(by: Int(wordCount)))
        }
    }

    func stop(exitProcess: Bool = true) {
        // Audio/MIDI callbacks and writer failures only schedule this method.
        // Never drain a queue from itself or exit from inside a writer block.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.stop(exitProcess: exitProcess) }
            return
        }
        state.lock()
        if stopping || finished { state.unlock(); return }
        let wasAccepting = accepting
        stopping = true; accepting = false
        state.unlock()
        if wasAccepting {
            // A pending main-queue device notification must not let an
            // operator stop publish an already interrupted capture as success.
            do { try checkInputConfiguration(); try checkMidiSourcesOnline() }
            catch { fail("capture device became unavailable: \(error)") }
        }
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        if let listener = deviceAliveListener {
            var key = address(kAudioDevicePropertyDeviceIsAlive)
            AudioObjectRemovePropertyListenerBlock(input.object, &key, .main, listener)
            deviceAliveListener = nil
        }
        if let listener = outputAliveListener, let output = monitorOutput {
            var key = address(kAudioDevicePropertyDeviceIsAlive)
            AudioObjectRemovePropertyListenerBlock(output.object, &key, .main, listener)
            outputAliveListener = nil
        }
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        callbacks.wait()
        if aggregate != 0 {
            let owned = aggregate
            do {
                try checked(AudioHardwareDestroyAggregateDevice(owned), "destroy private input/output route")
                aggregate = 0
            }
            catch { fail("monitor route cleanup failed: \(error)") }
        }
        writer.sync {
            audio = nil // finalize the WAVE container before publishing its manifest
            for handle in [midi, blocks] {
                do { try handle?.synchronize() }
                catch { self.fail("cannot synchronize recording data: \(error)") }
                do { try handle?.close() }
                catch { self.fail("cannot close recording data: \(error)") }
            }
            midi = nil; blocks = nil
            guard createdDirectory, let directory else {
                state.lock(); let failure = firstFailure; state.unlock()
                do { try emit(["kind": "stopped", "session": ["state": failure == nil ? "monitored" : "failed",
                                  "failure": failure as Any? ?? NSNull()]]) }
                catch { self.fail("monitor event output failed: \(error)") }
                return
            }
            do {
                state.lock(); let failure = firstFailure; state.unlock()
                var manifest: [String: Any] = ["schemaVersion": 1, "state": failure == nil ? "recorded" : "failed",
                    "failure": failure as Any? ?? NSNull(), "clock": ["kind": "mach-host-time",
                        "numer": hostClock.numer, "denom": hostClock.denom, "requestedStart": String(requestedHost),
                        "firstAudioHostTime": firstAudioHost.map(String.init) as Any? ?? NSNull()],
                    "sampleRate": format?.sampleRate ?? 0, "channels": format?.channelCount ?? 0,
                    "audioFrames": String(frames), "midiPacketCount": String(midiPackets),
                    "audio": "audio.wav", "audioBlocks": "audio-blocks.jsonl", "midi": "midi.ump.jsonl",
                    "input": input.json, "midiSources": sources.map(\.json), "monitoring": monitoringSnapshot]
                try encoded(manifest).write(to: directory.appendingPathComponent("session.json"), options: [.atomic])
                do { try emit(["kind": "stopped", "directory": directory.path, "session": manifest]) }
                catch {
                    self.fail("capture event output failed: \(error)")
                    state.lock(); let failure = firstFailure; state.unlock()
                    manifest["state"] = "failed"
                    manifest["failure"] = failure as Any? ?? NSNull()
                    // Do not recursively publish another event to the same
                    // broken pipe. Preserve failure even if this was the first
                    // output error, during the final acknowledgement itself.
                    try encoded(manifest).write(to: directory.appendingPathComponent("session.json"), options: [.atomic])
                }
            } catch {
                self.fail("cannot finalize recording manifest: \(error)")
                try? emit(["kind": "error", "message": "cannot finalize recording: \(error)"])
            }
        }
        state.lock(); finished = true; let failed = firstFailure != nil; state.unlock()
        if exitProcess { exit(failed ? 1 : 0) }
    }
}

func option(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

#if !MUSIC_INPUT_LIBRARY
@main enum MusicInputMain {
static func main() {
do {
    switch CommandLine.arguments.dropFirst().first {
    case "devices":
        try emit(["kind": "devices", "audio": try audioDevices().map(\.json), "midi": try midiSources().map(\.json)])
    case "record", "monitor":
        let recording = CommandLine.arguments[1] == "record"
        guard let uid = option("--input"), !recording || option("--directory") != nil else {
            throw SessionFailure("record requires --input UID and --directory NEW_PATH; monitor requires --input UID and --monitor-output UID")
        }
        let selectedOutput: AudioDevice?
        if let output = option("--monitor-output") {
            guard let found = try audioDevices().first(where: { $0.uid == output && $0.outputs > 0 }) else {
                throw SessionFailure("selected monitoring output is unavailable")
            }
            selectedOutput = found
        } else { selectedOutput = nil }
        guard recording || selectedOutput != nil else { throw SessionFailure("monitor requires --monitor-output UID") }
        guard let input = try audioDevices().first(where: { $0.uid == uid && $0.inputs > 0 }) else {
            throw SessionFailure("selected input device is unavailable")
        }
        let midiSelection = recording ? (option("--midi") ?? "all") : "none"
        let available = try midiSources()
        let selected: [MidiSource]
        switch midiSelection {
        case "none": selected = []
        case "all": selected = available
        default:
            selected = available.filter { String($0.uid) == midiSelection }
            if selected.isEmpty { throw SessionFailure("selected MIDI input is unavailable") }
        }
        let capture = Capture(directory: recording ? option("--directory").map { URL(fileURLWithPath: $0) } : nil,
                              input: input, sources: selected, monitorOutput: selectedOutput)
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { capture.stop() }
            source.resume(); capture.signalSources.append(source)
        }
        try capture.start()
        DispatchQueue.global().async {
            while let line = readLine() {
                if line == "stop" { DispatchQueue.main.async { capture.stop() }; return }
            }
            DispatchQueue.main.async { capture.stop() }
        }
        RunLoop.main.run()
    default:
        throw SessionFailure("usage: masc-music-native devices | record --input UID --directory NEW_PATH [--midi all|none|UID] [--monitor-output UID] | monitor --input UID --monitor-output UID")
    }
} catch {
    try? emit(["kind": "error", "message": String(describing: error)])
    exit(1)
}

}
}
#endif
