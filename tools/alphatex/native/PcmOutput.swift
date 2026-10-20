import Foundation
import AVFoundation
import CoreAudio

private func checked(_ status: OSStatus, _ message: String) throws {
    guard status == noErr else { throw PcmFailure("\(message): OSStatus \(status)") }
}
private func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
private func deviceString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var key = address(selector), size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
    var value: UnsafeRawPointer?
    try checked(AudioObjectGetPropertyData(object, &key, 0, nil, &size, &value), "read PCM output identity")
    guard let value else { throw PcmFailure("PCM output identity unavailable") }
    return Unmanaged<CFString>.fromOpaque(value).takeRetainedValue() as String
}
private func deviceNumber(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
    var key = address(selector), size = UInt32(MemoryLayout<UInt32>.size), value: UInt32 = 0
    try checked(AudioObjectGetPropertyData(object, &key, 0, nil, &size, &value), "read PCM output property")
    return value
}
private func selectedDevice(_ uid: String?) throws -> AudioObjectID {
    if let uid {
        var key = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        try checked(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &key, 0, nil, &size), "list PCM outputs")
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try checked(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &key, 0, nil, &size, &devices), "read PCM outputs")
        guard let found = try devices.first(where: { try deviceString($0, kAudioDevicePropertyDeviceUID) == uid }) else { throw PcmFailure("selected PCM output unavailable") }
        return found
    }
    return try deviceNumber(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
}
private func emit(_ value: [String: Any]) throws {
    var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); bytes.append(10)
    try FileHandle.standardOutput.write(contentsOf: bytes)
}
private enum PcmCommand: Decodable {
    case block(UInt64, Data), stop
    enum Keys: String, CodingKey { case kind, id, pcm }
    enum Kind: String, Decodable { case block, stop }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .stop: self = .stop
        case .block:
            let encoded = try c.decode(String.self, forKey: .pcm)
            guard let data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded else { throw PcmFailure("invalid canonical PCM base64") }
            let text = try c.decode(String.self, forKey: .id)
            guard let id = UInt64(text), String(id) == text else { throw PcmFailure("invalid PCM block identity") }
            self = .block(id, data)
        }
    }
}

@available(macOS 15.0, *)
private final class PcmOutput {
    enum State { case prepared, playing, stopped }
    let engine = AVAudioEngine()
    let device: AudioObjectID
    let uid: String
    let name: String
    let frames: UInt32
    let rate: Double
    let channels: AVAudioChannelCount
    let ring: PcmRing
    let notifications = DispatchSource.makeUserDataAddSource(queue: .main)
    var node: AVAudioSourceNode!
    var state = State.prepared
    var requested: UInt64 = 0
    var pending: UInt64?
    var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    var signals: [DispatchSourceSignal] = []
    var configuration: NSObjectProtocol?

    init(output: String?) throws {
        device = try selectedDevice(output)
        uid = try deviceString(device, kAudioDevicePropertyDeviceUID)
        name = try deviceString(device, kAudioObjectPropertyName)
        try engine.outputNode.auAudioUnit.setDeviceID(device)
        let destination = engine.outputNode.outputFormat(forBus: 0)
        rate = destination.sampleRate
        channels = destination.channelCount
        frames = try deviceNumber(device, kAudioDevicePropertyBufferFrameSize)
        guard rate.isFinite, rate > 0, rate.rounded() == rate, frames > 0,
              frames <= 1 << 24, destination.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { throw PcmFailure("selected output has no supported PCM format") }
        // Double buffering limits queued live latency; reserve the AU's maximum
        // render quantum too, so callback memory always covers its API bound.
        ring = try PcmRing(capacity: 2 * Int(max(frames, engine.outputNode.auAudioUnit.maximumFramesToRender)))
        let queue = ring, wake = notifications
        node = AVAudioSourceNode(format: format) { silent, _, count, output in
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            guard buffers.count == 2, buffers.allSatisfy({ $0.mNumberChannels == 1 && $0.mDataByteSize >= count * 4 }),
                  let left = buffers[0].mData, let right = buffers[1].mData else {
                queue.fault.store(2, ordering: .releasing); wake.add(data: 1)
                return kAudio_ParamError
            }
            queue.render(frames: Int(count), left: left.assumingMemoryBound(to: Float.self), right: right.assumingMemoryBound(to: Float.self))
            silent.pointee = ObjCBool(queue.stopped.load(ordering: .acquiring))
            wake.add(data: 1)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }
    func check() throws {
        guard try deviceNumber(device, kAudioDevicePropertyDeviceIsAlive) != 0,
              try deviceString(device, kAudioDevicePropertyDeviceUID) == uid,
              try deviceNumber(device, kAudioDevicePropertyBufferFrameSize) == frames,
              engine.outputNode.auAudioUnit.deviceID == device,
              engine.outputNode.outputFormat(forBus: 0).sampleRate == rate,
              engine.outputNode.outputFormat(forBus: 0).channelCount == channels else { throw PcmFailure("selected PCM output changed or disappeared") }
        if state == .playing && !engine.isRunning { throw PcmFailure("PCM output engine stopped") }
        if ring.fault.load(ordering: .acquiring) != 0 { throw PcmFailure("PCM output underrun or render format failure") }
    }
    func monitor(_ object: AudioObjectID, _ original: AudioObjectPropertyAddress) throws {
        var key = original
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.state != .stopped else { return }
            do { try self.check() } catch { self.finish(error) }
        }
        try checked(AudioObjectAddPropertyListenerBlock(object, &key, .main, listener), "observe PCM output")
        listeners.append((object, original, listener))
    }
    func start() throws {
        try check()
        notifications.setEventHandler { [weak self] in
            guard let self, self.state != .stopped else { return }
            do { try self.check(); try self.request() } catch { self.finish(error) }
        }
        notifications.resume()
        try monitor(device, address(kAudioDevicePropertyDeviceIsAlive))
        try monitor(device, address(kAudioDevicePropertyBufferFrameSize))
        try monitor(device, address(kAudioDevicePropertyNominalSampleRate))
        try monitor(device, address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput))
        try monitor(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices))
        configuration = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.state != .stopped else { return }
            do { try self.check() } catch { self.finish(error) }
        }
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: number, queue: .main)
            s.setEventHandler { [weak self] in self?.finish(PcmFailure("PCM output interrupted")) }
            s.resume(); signals.append(s)
        }
        try emit(["kind": "ready", "schemaVersion": 1, "device": ["id": uid, "name": name],
                  "sampleRate": rate, "blockFrames": frames, "prefillFrames": frames * 2])
        try request()
    }
    func request() throws {
        guard state != .stopped, pending == nil, ring.available <= UInt64(frames) else { return }
        guard requested < UInt64.max else { throw PcmFailure("PCM request identity exhausted") }
        requested += 1; pending = requested
        try emit(["kind": "need", "id": String(requested), "frames": frames,
                  "startFrame": String(ring.written.load(ordering: .acquiring))])
    }
    func receive(_ line: String) {
        guard state != .stopped else { return }
        do {
            try check()
            switch try JSONDecoder().decode(PcmCommand.self, from: Data(line.utf8)) {
            case .stop: finish(); return
            case .block(let id, let data):
                guard pending == id, data.count == Int(frames) * 2 * 4 else { throw PcmFailure("unexpected PCM block identity/size") }
                let samples = data.withUnsafeBytes { bytes in
                    stride(from: 0, to: data.count, by: 4).map { offset in
                        Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                    }
                }
                try ring.append(samples); pending = nil
                if state == .prepared && ring.available == UInt64(frames) * 2 {
                    state = .playing
                    engine.prepare(); try engine.start(); try check()
                    try emit(["kind": "playing"])
                }
                try request()
            }
        } catch { finish(error) }
    }
    func finish(_ failure: Error? = nil) {
        guard state != .stopped else { return }
        state = .stopped; ring.stopped.store(true, ordering: .releasing)
        engine.stop()
        let error = failure ?? (ring.fault.load(ordering: .acquiring) == 0 ? nil : PcmFailure("PCM output underrun or render format failure"))
        if let configuration { NotificationCenter.default.removeObserver(configuration) }
        for (object, original, listener) in listeners {
            var key = original; AudioObjectRemovePropertyListenerBlock(object, &key, .main, listener)
        }
        for s in signals { s.cancel() }
        notifications.cancel()
        do {
            if let error { try emit(["kind": "error", "message": String(describing: error)]) }
            try emit(["kind": "stopped", "success": error == nil,
                      "admittedFrames": String(ring.written.load(ordering: .acquiring)),
                      "renderedFrames": String(ring.read.load(ordering: .acquiring)),
                      "discardedFrames": String(ring.available),
                      "underrunFrames": String(ring.missing.load(ordering: .acquiring))])
            exit(error == nil ? 0 : 1)
        } catch { exit(1) }
    }
}

@main private struct PcmMain {
    static func main() {
        _ = signal(SIGPIPE, SIG_IGN)
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.isEmpty || (args.count == 2 && args[0] == "--output" && !args[1].isEmpty) else { throw PcmFailure("usage: music-pcm-output [--output UID]") }
            if #available(macOS 15.0, *) {
                let output = try PcmOutput(output: args.isEmpty ? nil : args[1])
                do { try output.start() } catch { output.finish(error) }
                DispatchQueue.global().async {
                    while let line = readLine() { DispatchQueue.main.async { output.receive(line) } }
                    DispatchQueue.main.async { output.finish(PcmFailure("PCM input closed without stop")) }
                }
                withExtendedLifetime(output) { RunLoop.main.run() }
            } else { throw PcmFailure("PCM output requires macOS 15 or newer") }
        } catch {
            try? emit(["kind": "error", "message": String(describing: error)])
            exit(1)
        }
    }
}
