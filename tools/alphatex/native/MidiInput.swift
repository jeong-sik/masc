import Foundation
import CoreMIDI

struct InputFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
func inputChecked(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw InputFailure("\(operation): OSStatus \(status)") }
}
func inputEmit(_ value: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    data.append(10); try FileHandle.standardOutput.write(contentsOf: data)
}

// The callback only reserves/copies input. One packet is exposed at a time;
// its words remain reserved until the consumer acknowledges its decision.
// 256 KiB bounds the actual callback/handoff/consumer backlog, not session life.
final class MidiInput {
    enum Phase { case idle, running, draining, closed }
    struct Packet { let ordinal: UInt64; let host: UInt64; let origin: String; let words: [UInt32] }
    static let maximumPendingWords = 65_536
    let uid: Int32, endpoint: MIDIEndpointRef, name: String
    let lock = NSLock(), callbacks = DispatchGroup()
    var client = MIDIClientRef(), port = MIDIPortRef()
    var phase = Phase.idle, accepting = false, handoffsSettled = false
    var pendingWords = 0, nextOrdinal: UInt64 = 0, acknowledged: UInt64 = 0
    private var failureStorage: Error?
    var failure: Error? { lock.lock(); defer { lock.unlock() }; return failureStorage }
    var pending: [Packet] = [], inFlight: Packet?
    var onEvent: ([String: Any]) throws -> Void = inputEmit
    var onClosed: ((Error?) -> Void)?
    init(source: String) throws {
        guard let uid = Int32(source), String(uid) == source else { throw InputFailure("choose an exact MIDI source UID") }
        var object = MIDIObjectRef(), type = MIDIObjectType.other
        try inputChecked(MIDIObjectFindByUniqueID(uid, &object, &type), "find selected MIDI input")
        guard object != 0, type == .source else { throw InputFailure("selected MIDI object is not a source") }
        self.uid = uid; endpoint = object
        var value: Unmanaged<CFString>?
        try inputChecked(MIDIObjectGetStringProperty(object, kMIDIPropertyName, &value), "read MIDI input name")
        name = value?.takeRetainedValue() as String? ?? source
        try checkSource()
    }
    func checkSource() throws {
        var object = MIDIObjectRef(), type = MIDIObjectType.other
        try inputChecked(MIDIObjectFindByUniqueID(uid, &object, &type), "check selected MIDI input")
        guard object == endpoint, type == .source else { throw InputFailure("selected MIDI input was removed or changed") }
        var identity: Int32 = 0, offline: Int32 = 0
        try inputChecked(MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &identity), "check MIDI source identity")
        guard identity == uid else { throw InputFailure("selected MIDI input identity changed") }
        let status = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
        if status != kMIDIUnknownProperty {
            try inputChecked(status, "check MIDI source state")
            guard offline == 0 else { throw InputFailure("selected MIDI input is offline") }
        }
    }
    func start() throws {
        guard Thread.isMainThread, phase == .idle else { throw InputFailure("invalid MIDI input startup") }
        try inputChecked(MIDIClientCreateWithBlock("MASC note input" as CFString, &client, { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.phase == .running else { return }
                do { try self.checkSource() } catch { self.abort(error) }
            }
        }), "create MIDI input client")
        try inputChecked(MIDIInputPortCreateWithProtocol(client, "MASC note input" as CFString, ._2_0, &port,
            { [weak self] list, context in self?.receive(list, context: context) }), "create MIDI input port")
        lock.lock(); accepting = true; lock.unlock()
        try inputChecked(MIDIPortConnectSource(port, endpoint, UnsafeMutableRawPointer(bitPattern: UInt(endpoint))), "connect selected MIDI source")
        try checkSource()
        phase = .running
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        guard timebase.numer > 0, timebase.denom > 0 else { throw InputFailure("MIDI host clock is unavailable") }
        try onEvent(["kind": "midi-input", "schemaVersion": 1, "protocol": 2,
                     "source": ["id": String(uid), "name": name],
                     "clock": ["kind": "mach-host-time", "numer": timebase.numer, "denom": timebase.denom]])
    }
    func receive(_ list: UnsafePointer<MIDIEventList>, context: UnsafeMutableRawPointer?) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        callbacks.enter(); lock.unlock()
        defer { callbacks.leave() }
        let raw = UnsafeRawPointer(list)
        let protocolID = raw.loadUnaligned(fromByteOffset: MemoryLayout<MIDIEventList>.offset(of: \.protocol)!, as: UInt32.self)
        let count = raw.loadUnaligned(fromByteOffset: MemoryLayout<MIDIEventList>.offset(of: \.numPackets)!, as: UInt32.self)
        guard protocolID == MIDIProtocolID._2_0.rawValue, context.map({ MIDIEndpointRef(UInt(bitPattern: $0)) }) == endpoint else {
            fail(InputFailure("unbound MIDI input callback or protocol")); return
        }
        var packet = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIEventList>.offset(of: \.packet)!)
        for _ in 0..<count {
            let count = Int(packet.loadUnaligned(fromByteOffset: MemoryLayout<MIDIEventPacket>.offset(of: \.wordCount)!, as: UInt32.self))
            let host = packet.loadUnaligned(fromByteOffset: MemoryLayout<MIDIEventPacket>.offset(of: \.timeStamp)!, as: MIDITimeStamp.self)
            let words = packet.advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \.words)!).assumingMemoryBound(to: UInt32.self)
            if count > 0 {
                lock.lock()
                guard accepting else { lock.unlock(); return }
                guard count <= Self.maximumPendingWords - pendingWords, nextOrdinal < UInt64.max else {
                    lock.unlock(); fail(InputFailure("MIDI input backlog exhausted; input stopped without hiding lost data")); return
                }
                let copied = Packet(ordinal: nextOrdinal, host: host == 0 ? mach_absolute_time() : host,
                                    origin: host == 0 ? "received" : "packet", words: Array(UnsafeBufferPointer(start: words, count: count)))
                nextOrdinal += 1; pendingWords += count
                // Enqueue while holding the admission lock: callback order and
                // ordinal order stay identical even across CoreMIDI threads.
                DispatchQueue.main.async { self.accept(copied) }
                lock.unlock()
            }
            packet = UnsafeRawPointer(MIDIEventPacketNext(packet.assumingMemoryBound(to: MIDIEventPacket.self)))
        }
    }
    func release(_ packet: Packet) { lock.lock(); pendingWords -= packet.words.count; lock.unlock() }
    func accept(_ packet: Packet) {
        if failure != nil { release(packet); finishIfDrained(); return }
        pending.append(packet); pump()
    }
    func pump() {
        guard phase != .closed, inFlight == nil, !pending.isEmpty, failure == nil else { finishIfDrained(); return }
        let packet = pending.removeFirst(); inFlight = packet
        do {
            if phase == .running { try checkSource() }
            try onEvent(["kind": "midi", "source": String(uid), "protocol": 2,
                         "ordinal": String(packet.ordinal), "hostTime": String(packet.host),
                         "timestampOrigin": packet.origin, "words": packet.words])
        } catch { abort(error) }
    }
    func acknowledge(_ ordinal: String) throws {
        guard let packet = inFlight, ordinal == String(packet.ordinal), failure == nil else { throw InputFailure("unexpected MIDI input acknowledgement") }
        inFlight = nil; acknowledged += 1; release(packet); pump()
    }
    func fail(_ error: Error) {
        lock.lock(); if failureStorage == nil { failureStorage = error }; accepting = false; lock.unlock()
        DispatchQueue.main.async { self.abort(error) }
    }
    func abort(_ error: Error) {
        guard phase != .closed else { return }
        lock.lock(); if failureStorage == nil { failureStorage = error }; lock.unlock()
        stop()
        if let packet = inFlight { inFlight = nil; release(packet) }
        for packet in pending { release(packet) }; pending.removeAll()
        finishIfDrained()
    }
    func stop() {
        guard phase != .closed, phase != .draining else { return }
        phase = .draining
        lock.lock(); accepting = false; lock.unlock()
        var cleanupFailure: Error?
        if port != 0 {
            let status = MIDIPortDispose(port); port = 0
            if status != noErr { cleanupFailure = InputFailure("dispose MIDI input port: OSStatus \(status)") }
        }
        if client != 0 {
            let status = MIDIClientDispose(client); client = 0
            if status != noErr, cleanupFailure == nil { cleanupFailure = InputFailure("dispose MIDI input client: OSStatus \(status)") }
        }
        if let error = cleanupFailure { lock.lock(); if failureStorage == nil { failureStorage = error }; lock.unlock() }
        callbacks.wait()
        // Every admitted callback queued its handoff before this barrier.
        DispatchQueue.main.async {
            self.handoffsSettled = true
            if let error = self.failure { self.abort(error) } else { self.pump() }
        }
    }
    func finishIfDrained() {
        guard phase == .draining, handoffsSettled, pending.isEmpty, inFlight == nil else { return }
        lock.lock(); let words = pendingWords; lock.unlock()
        guard words == 0 else { return }
        phase = .closed
        do { try onEvent(["kind": "stopped", "source": String(uid), "success": failure == nil,
                          "admittedPackets": String(nextOrdinal), "acknowledgedPackets": String(acknowledged),
                          "discardedPackets": String(nextOrdinal - acknowledged), "pendingWords": words,
                          "error": failure.map { String(describing: $0) } as Any? ?? NSNull()]) }
        catch { onClosed?(error); return }
        onClosed?(failure)
    }
}

#if !MIDI_INPUT_LIBRARY
@main enum MidiInputMain {
    struct Command: Decodable {
        enum Kind: String, Decodable { case ack, stop }
        let kind: Kind
        let ordinal: String?
    }
    static func main() {
        _ = signal(SIGPIPE, SIG_IGN)
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 2, args[0] == "--source" else { throw InputFailure("usage: music-midi-input --source MIDI_UID") }
            let owner = try MidiInput(source: args[1])
            owner.onClosed = { error in exit(error == nil ? 0 : 1) }
            var signals: [DispatchSourceSignal] = []
            for number in [SIGINT, SIGTERM, SIGHUP] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { owner.abort(InputFailure("MIDI input interrupted by signal")) }; source.resume(); signals.append(source)
            }
            do { try owner.start() } catch { owner.abort(error) }
            DispatchQueue.global().async {
                while let line = readLine() {
                    DispatchQueue.main.async {
                        guard owner.phase != .closed else { return }
                        do {
                            let command = try JSONDecoder().decode(Command.self, from: Data(line.utf8))
                            switch command.kind {
                            case .ack:
                                guard let ordinal = command.ordinal else { throw InputFailure("missing MIDI input acknowledgement") }
                                try owner.acknowledge(ordinal)
                            case .stop: owner.stop()
                            }
                        } catch { owner.abort(error) }
                    }
                }
                DispatchQueue.main.async { owner.abort(InputFailure("MIDI input command stream closed")) }
            }
            withExtendedLifetime((owner, signals)) { RunLoop.main.run() }
        } catch { try? inputEmit(["kind": "error", "message": String(describing: error)]); exit(1) }
    }
}
#endif
