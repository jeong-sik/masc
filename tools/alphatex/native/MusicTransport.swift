// One AVAudioEngine/AVAudioPlayerNode owns the WAV and every loop iteration.
// Playback, completion handling and teardown run on the main lifecycle.
import Foundation
import AVFoundation
import CoreAudio

struct TransportFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func checked(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw TransportFailure("\(operation): OSStatus \(status)") }
}
func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func deviceString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var key = address(selector), size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
    var value: UnsafeRawPointer?
    try checked(AudioObjectGetPropertyData(object, &key, 0, nil, &size, &value), "read audio device identity")
    guard let value else { throw TransportFailure("audio device identity is unavailable") }
    return Unmanaged<CFString>.fromOpaque(value).takeRetainedValue() as String
}
func outputChannels(_ object: AudioObjectID) throws -> Int {
    var key = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    try checked(AudioObjectGetPropertyDataSize(object, &key, 0, nil, &size), "read output configuration size")
    guard size >= MemoryLayout<AudioBufferList>.size else { throw TransportFailure("output configuration is unavailable") }
    let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    try checked(AudioObjectGetPropertyData(object, &key, 0, nil, &size, memory), "read output configuration")
    return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        .reduce(0) { $0 + Int($1.mNumberChannels) }
}
struct OutputDevice {
    let object: AudioObjectID
    let uid: String
    let name: String
    let outputs: Int
    var json: [String: Any] { ["id": uid, "name": name, "outputs": outputs] }
}
func selectedOutput(_ uid: String?) throws -> OutputDevice {
    let object: AudioObjectID
    if let uid {
        var key = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        try checked(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &key, 0, nil, &size), "list output devices")
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try checked(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &key, 0, nil, &size, &ids), "read output devices")
        guard let found = try ids.first(where: { try deviceString($0, kAudioDevicePropertyDeviceUID) == uid }) else {
            throw TransportFailure("selected output device is unavailable: \(uid)")
        }
        object = found
    } else {
        var key = address(kAudioHardwarePropertyDefaultOutputDevice), value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try checked(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &key, 0, nil, &size, &value), "resolve default output device")
        object = value
    }
    let device = OutputDevice(object: object, uid: try deviceString(object, kAudioDevicePropertyDeviceUID),
        name: try deviceString(object, kAudioObjectPropertyName), outputs: try outputChannels(object))
    guard device.outputs > 0 else { throw TransportFailure("selected device has no audio output") }
    return device
}
func emit(_ value: [String: Any]) throws {
    var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    bytes.append(10)
    try FileHandle.standardOutput.write(contentsOf: bytes)
}
func reportStderr(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
}

enum Command: Decodable {
    case pause, resume, seek(Double), status, stop
    enum Keys: String, CodingKey { case kind, seconds }
    enum Kind: String, Decodable { case pause, resume, seek, status, stop }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        if kind != .seek && values.contains(.seconds) { throw TransportFailure("seconds is only valid for seek") }
        switch kind {
        case .pause: self = .pause
        case .resume: self = .resume
        case .seek: self = .seek(try values.decode(Double.self, forKey: .seconds))
        case .status: self = .status
        case .stop: self = .stop
        }
    }
}

// Decode only the admitted source frame window. This retains the original VST
// render and lets pause/seek/loop positions remain local to that window.
func readAudioWindow(_ audio: AVAudioFile, offsetFrames: Int64 = 0, frameCount: Int64? = nil) throws -> AVAudioPCMBuffer {
    guard offsetFrames >= 0, offsetFrames <= audio.length else { throw TransportFailure("audio window starts outside its source") }
    let count = frameCount ?? (audio.length - offsetFrames)
    guard count > 0, count <= audio.length - offsetFrames,
          let capacity = AVAudioFrameCount(exactly: count),
          let decoded = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: capacity) else {
        throw TransportFailure("audio window exceeds its source or PCM buffer resource")
    }
    audio.framePosition = offsetFrames
    try audio.read(into: decoded, frameCount: capacity)
    guard decoded.frameLength == capacity else { throw TransportFailure("audio decode did not supply all declared window frames") }
    return decoded
}

final class Transport {
    enum State { case prepared, playing, paused, stopped }
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let buffer: AVAudioPCMBuffer
    let device: OutputDevice
    let loop: Bool
    let duration: Double
    let frameRange: [String: Int64]?
    var state = State.prepared
    var originFrame: AVAudioFramePosition = 0
    var pausedFrame: AVAudioFramePosition = 0
    var generation: UInt64 = 0
    var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    var signals: [DispatchSourceSignal] = []
    var configurationObserver: NSObjectProtocol?

    init(file: URL, output: String?, loop: Bool, offsetFrames: Int64 = 0, frameCount: Int64? = nil) throws {
        device = try selectedOutput(output)
        self.loop = loop
        self.frameRange = frameCount.map { ["offsetFrames": offsetFrames, "frameCount": $0] }
        let audio = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        let decoded = try readAudioWindow(audio, offsetFrames: offsetFrames, frameCount: frameCount)
        buffer = decoded
        duration = Double(decoded.frameLength) / decoded.format.sampleRate
        guard duration.isFinite, duration > 0 else { throw TransportFailure("audio file has no finite playable duration") }
        engine.attach(player)
        try engine.outputNode.auAudioUnit.setDeviceID(device.object)
        engine.connect(player, to: engine.mainMixerNode, format: decoded.format)
    }
    func checkOutput() throws {
        var key = address(kAudioDevicePropertyDeviceIsAlive), alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try checked(AudioObjectGetPropertyData(device.object, &key, 0, nil, &size, &alive), "read selected output state")
        guard alive != 0, try outputChannels(device.object) > 0,
              try deviceString(device.object, kAudioDevicePropertyDeviceUID) == device.uid else {
            throw TransportFailure("selected output device was removed or lost its audio stream")
        }
        guard engine.outputNode.auAudioUnit.deviceID == device.object else {
            throw TransportFailure("engine did not retain the selected output device")
        }
        if state == .playing || state == .paused {
            guard engine.isRunning else { throw TransportFailure("audio engine stopped after an output configuration change") }
        }
    }
    func monitor(_ object: AudioObjectID, _ key: AudioObjectPropertyAddress) throws {
        var key = key
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.state != .stopped else { return }
            do { try self.checkOutput() }
            catch { self.finish(reason: "output-unavailable", error: error) }
        }
        try checked(AudioObjectAddPropertyListenerBlock(object, &key, .main, listener), "observe output device")
        listeners.append((object, key, listener))
    }
    func schedule(from frame: AVAudioFramePosition) throws {
        generation &+= 1
        let scheduledGeneration = generation
        player.stop() // invalidates old scheduling; its completion cannot finish the new generation
        originFrame = frame
        pausedFrame = frame
        if frame > 0 {
            let remaining = AVAudioFrameCount(AVAudioFramePosition(buffer.frameLength) - frame)
            guard let tail = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: remaining),
                  let source = buffer.floatChannelData, let target = tail.floatChannelData else {
                throw TransportFailure("cannot allocate the seek-tail PCM buffer")
            }
            tail.frameLength = remaining
            for channel in 0..<Int(buffer.format.channelCount) {
                memcpy(target[channel], source[channel].advanced(by: Int(frame)), Int(remaining) * MemoryLayout<Float>.size)
            }
            if loop {
                player.scheduleBuffer(tail)
            } else {
                scheduleEnd(tail, generation: scheduledGeneration)
                return
            }
        }
        if loop {
            // Native buffer loops occur on the render timeline, without process,
            // decoder, callback or main-queue work at an iteration boundary.
            player.scheduleBuffer(buffer, at: nil, options: [.loops])
        } else { scheduleEnd(buffer, generation: scheduledGeneration) }
    }
    func scheduleEnd(_ audio: AVAudioPCMBuffer, generation expected: UInt64) {
        player.scheduleBuffer(audio, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == expected, self.state != .stopped else { return }
                self.pausedFrame = AVAudioFramePosition(self.buffer.frameLength)
                self.finish(reason: "finished")
            }
        }
    }
    func positionFrame() -> AVAudioFramePosition {
        guard state == .playing else { return pausedFrame }
        guard let render = player.lastRenderTime, let time = player.playerTime(forNodeTime: render) else { return originFrame }
        let elapsed = max(0, time.sampleTime)
        let position = originFrame + elapsed
        return loop ? position % AVAudioFramePosition(buffer.frameLength) : min(position, AVAudioFramePosition(buffer.frameLength))
    }
    func start() throws {
        try checkOutput()
        try monitor(device.object, address(kAudioDevicePropertyDeviceIsAlive))
        try monitor(device.object, address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput))
        try monitor(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices))
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.finish(reason: "signal") }
            source.resume(); signals.append(source)
        }
        try schedule(from: 0)
        engine.prepare()
        try engine.start()
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in
                guard let self, self.state != .stopped else { return }
                do { try self.checkOutput() }
                catch { self.finish(reason: "output-configuration-changed", error: error) }
            }
        player.play()
        guard player.isPlaying, engine.isRunning else { throw TransportFailure("audio engine could not start playback") }
        state = .playing
        try checkOutput()
        publish()
    }
    func snapshot(_ kind: String) -> [String: Any] {
        var value: [String: Any] = ["kind": kind, "currentTime": Double(positionFrame()) / buffer.format.sampleRate, "duration": duration,
                                  "device": device.json, "loop": loop]
        if let frameRange { value["frameRange"] = frameRange }
        return value
    }
    func publish() {
        guard state != .stopped else { return }
        do { try emit(snapshot(state == .playing ? "playing" : "paused")) }
        catch { finish(reason: "event-output-failed", error: error, publish: false) }
    }
    func receive(_ line: String) {
        guard state != .stopped else { return }
        do {
            let command = try JSONDecoder().decode(Command.self, from: Data(line.utf8))
            try checkOutput()
            switch command {
            case .pause:
                if state == .playing { pausedFrame = positionFrame(); player.pause(); state = .paused }
            case .resume:
                player.play()
                guard player.isPlaying else { throw TransportFailure("audio engine could not resume playback") }
                state = .playing
            case .seek(let seconds):
                guard seconds.isFinite, seconds >= 0, seconds <= duration else {
                    throw TransportFailure("seek seconds must be inside the audio file duration")
                }
                if seconds == duration && !loop { pausedFrame = AVAudioFramePosition(buffer.frameLength); finish(reason: "finished"); return }
                let frame = seconds == duration ? 0 : min(AVAudioFramePosition(seconds * buffer.format.sampleRate), AVAudioFramePosition(buffer.frameLength) - 1)
                let playing = state == .playing
                try schedule(from: frame)
                if playing { player.play() }
            case .status: break
            case .stop: finish(reason: "stop"); return
            }
            try checkOutput()
            publish()
        } catch { finish(reason: "command-failed", error: error) }
    }
    func finish(reason: String, error: Error? = nil, publish: Bool = true) {
        guard state != .stopped else { return }
        var stopped = snapshot("stopped")
        if reason == "finished" { stopped["currentTime"] = duration }
        state = .stopped
        generation &+= 1
        player.stop()
        engine.stop()
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer); configurationObserver = nil }
        for (object, original, listener) in listeners {
            var key = original
            AudioObjectRemovePropertyListenerBlock(object, &key, .main, listener)
        }
        listeners.removeAll()
        for source in signals { source.cancel() }
        signals.removeAll()
        var failed = error != nil
        stopped["reason"] = reason
        stopped["success"] = !failed
        if let error { reportStderr(String(describing: error)) }
        if publish {
            do {
                if let error { try emit(["kind": "error", "message": String(describing: error)]) }
                try emit(stopped)
            } catch { failed = true; reportStderr("transport event output failed: \(error)") }
        }
        exit(failed ? 1 : 0)
    }
}

struct Options {
    var file: String?
    var output: String?
    var loop = false
    var offsetFrames: Int64?
    var frameCount: Int64?
    init() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "play" else { throw TransportFailure("usage: music-transport play --file WAV [--output UID] [--loop]") }
        args.removeFirst()
        while !args.isEmpty {
            switch args.removeFirst() {
            case "--file":
                guard file == nil, !args.isEmpty else { throw TransportFailure("--file requires one WAV path") }
                file = args.removeFirst()
            case "--output":
                guard output == nil, !args.isEmpty else { throw TransportFailure("--output requires one device UID") }
                output = args.removeFirst()
            case "--loop":
                guard !loop else { throw TransportFailure("duplicate --loop option") }
                loop = true
            case "--offset-frames":
                guard offsetFrames == nil, !args.isEmpty, let value = Int64(args.removeFirst()), value >= 0 else { throw TransportFailure("--offset-frames requires a nonnegative frame position") }
                offsetFrames = value
            case "--frame-count":
                guard frameCount == nil, !args.isEmpty, let value = Int64(args.removeFirst()), value > 0 else { throw TransportFailure("--frame-count requires a positive frame count") }
                frameCount = value
            default: throw TransportFailure("unknown transport option")
            }
        }
        guard let file, !file.isEmpty else { throw TransportFailure("--file requires a WAV path") }
        if let output, output.isEmpty { throw TransportFailure("--output requires a device UID") }
        guard (offsetFrames == nil) == (frameCount == nil) else { throw TransportFailure("audio window requires both offset and frame count") }
    }
}

_ = signal(SIGPIPE, SIG_IGN)
do {
    let options = try Options()
    let transport = try Transport(file: URL(fileURLWithPath: options.file!), output: options.output, loop: options.loop,
                                  offsetFrames: options.offsetFrames ?? 0, frameCount: options.frameCount)
    do { try transport.start() }
    catch { transport.finish(reason: "start-failed", error: error) }
    DispatchQueue.global().async {
        while let line = readLine() { DispatchQueue.main.async { transport.receive(line) } }
        DispatchQueue.main.async { transport.finish(reason: "eof") }
    }
    withExtendedLifetime(transport) { RunLoop.main.run() }
} catch {
    reportStderr(String(describing: error))
    do { try emit(["kind": "error", "message": String(describing: error)]) }
    catch { reportStderr("transport event output failed: \(error)") }
    exit(1)
}
