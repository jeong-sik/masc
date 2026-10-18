import Foundation
import CoreMIDI

// Both native MIDI owners run on the audio owner's main lifecycle. Their
// protocols and state models remain distinct; no UMP is translated to bytes.
protocol CoordinatedMidiTransport: AnyObject {
    var anchor: UInt64 { get }
    var terminalFailure: Error? { get }
    var onCoordinatedFailure: ((String, Error?) -> Void)? { get set }
    var onCoordinatedEnd: (() -> Void)? { get set }
    func prepare() throws
    func stageCoordinated(at seconds: Double) throws
    func runCoordinated(anchorNanoseconds: UInt64) throws
    func position(at host: UInt64) -> Double
    func snapshot(_ kind: String) -> [String: Any]
    func finish(reason: String, error: Error?, publish: Bool)
}
extension MidiTransport: CoordinatedMidiTransport {}

struct UmpClock: Decodable {
    let origin: String
    let numer: UInt32
    let denom: UInt32
    func seconds(_ host: String) throws -> Double {
        guard let start = UInt64(origin), String(start) == origin,
              let time = UInt64(host), String(time) == host, time >= start, numer > 0, denom > 0 else { throw MidiFailure("invalid captured UMP clock") }
        let delta = time - start, divisor = UInt64(denom)
        return (Double(delta / divisor) * Double(numer) + Double(delta % divisor) * Double(numer) / Double(denom)) / 1e9
    }
}
struct UmpBinding: Decodable { let source: String; let destination: String }
struct UmpPacket: Decodable {
    let kind: String
    let protocolID: Int
    let hostTime: String
    let source: String
    let timestampOrigin: String
    let words: [UInt32]
    enum CodingKeys: String, CodingKey { case kind, hostTime, source, timestampOrigin, words; case protocolID = "protocol" }
}
struct UmpEvent {
    let seconds: Double
    let source: String
    let words: [UInt32]
}
struct UmpTimeline: Decodable {
    let schemaVersion: Int
    let duration: Double
    let clock: UmpClock
    let bindings: [UmpBinding]
    let packets: [UmpPacket]
    func events() throws -> [UmpEvent] {
        guard schemaVersion == 4, duration.isFinite, duration > 0, duration * 1e9 < Double(UInt64.max),
              !packets.isEmpty, !bindings.isEmpty, Set(bindings.map(\.source)).count == bindings.count else { throw MidiFailure("invalid captured UMP timeline") }
        _ = try clock.seconds(clock.origin)
        var endpointSources: [String: Set<String>] = [:], groupSources: [String: Set<String>] = [:]
        var exclusiveGroups = Set<String>(), exclusiveEndpoints = Set<String>()
        var used = Set<String>(), owners: [String: String] = [:], result: [(Int, UmpEvent)] = []
        for binding in bindings {
            guard !binding.source.isEmpty, let uid = Int32(binding.destination), String(uid) == binding.destination else { throw MidiFailure("invalid UMP source destination") }
        }
        let sizes = [1,1,1,2,2,4,1,1,2,2,2,3,3,4,4,4]
        for packet in packets {
            guard packet.kind == "midi", packet.protocolID == 2, ["packet", "received"].contains(packet.timestampOrigin),
                  let binding = bindings.first(where: { $0.source == packet.source }), !packet.words.isEmpty else { throw MidiFailure("invalid or unbound captured UMP packet") }
            let seconds = try clock.seconds(packet.hostTime)
            guard seconds.isFinite, seconds <= duration else { throw MidiFailure("UMP packet lies outside capture duration") }
            used.insert(packet.source)
            var offset = 0
            while offset < packet.words.count {
                let word = packet.words[offset], type = Int(word >> 28), count = sizes[type]
                guard offset + count <= packet.words.count else { throw MidiFailure("truncated captured UMP message") }
                endpointSources[binding.destination, default: []].insert(packet.source)
                let group = "\(binding.destination)/\((word >> 24) & 15)"
                if [1,2,3,4,5,13].contains(type) { groupSources[group, default: []].insert(packet.source) }
                if [1,3,5,13].contains(type) { exclusiveGroups.insert(group) }
                else if type != 2 && type != 4 { exclusiveEndpoints.insert(binding.destination) }
                if type == 2 || type == 4 {
                    let address = "\(binding.destination)/\((word >> 24) & 15)/\((word >> 16) & 15)"
                    guard owners[address] == nil || owners[address] == packet.source else { throw MidiFailure("captured sources share a destination/group/channel; select independent source outputs") }
                    owners[address] = packet.source
                }
                result.append((result.count, UmpEvent(seconds: seconds, source: packet.source, words: Array(packet.words[offset..<(offset + count)]))))
                offset += count
            }
        }
        guard exclusiveGroups.allSatisfy({ (groupSources[$0]?.count ?? 0) == 1 }),
              exclusiveEndpoints.allSatisfy({ (endpointSources[$0]?.count ?? 0) == 1 }) else {
            throw MidiFailure("captured system/SysEx/group state requires independent source outputs")
        }
        guard used == Set(bindings.map(\.source)) else { throw MidiFailure("UMP bindings must match captured sources") }
        return result.sorted { $0.1.seconds == $1.1.seconds ? $0.0 < $1.0 : $0.1.seconds < $1.1.seconds }.map { $0.1 }
    }
}

// A complete source audition delivers every original UMP, including opaque
// system/expression data. Reconstruction additionally requires known source
// state; staging is silent and its restoration shares the audio start epoch.
final class UmpTransport: CoordinatedMidiTransport {
    let timeline: UmpTimeline
    let events: [UmpEvent]
    var anchor: UInt64 = 0
    var terminalFailure: Error?
    var onCoordinatedFailure: ((String, Error?) -> Void)?
    var onCoordinatedEnd: (() -> Void)?
    var client = MIDIClientRef(), port = MIDIPortRef()
    var selected: [String: Destination] = [:]
    var timer: DispatchSourceTimer?
    enum State { case prepared, staged, playing, ended, stopped }
    var state = State.prepared
    var index = 0
    var offset: Double = 0
    var pendingRestore = false
    var footprint = UmpFootprint()
    // Keys include physical endpoint, group, channel, message dialect and note.
    // Retain uncertain acquisitions/releases until a successful cleanup send.
    struct Key: Hashable { let source: String; let prefix: UInt32; let number: UInt32 }
    var held: [Key: Int] = [:], pedals = Set<Key>()
    var exclusive = Set<Key>()
    init(timeline: UmpTimeline) throws { self.timeline = timeline; events = try timeline.events() }
    func prepare() throws {
        guard Thread.isMainThread else { throw MidiFailure("UMP preparation requires the main lifecycle") }
        do {
            try checked(MIDIClientCreateWithBlock("MASC captured UMP output" as CFString, &client, { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.state != .stopped else { return }
                    do { try self.checkDestinations() } catch { self.finish(reason: "destination-unavailable", error: error, publish: false) }
                }
            }), "create UMP output client")
            for binding in timeline.bindings { selected[binding.source] = try selectedDestination(uid: binding.destination) }
            try checkDestinations()
            try checked(MIDIOutputPortCreate(client, "MASC captured UMP output" as CFString, &port), "create UMP output port")
        } catch {
            if port != 0 { MIDIPortDispose(port); port = 0 }
            if client != 0 { MIDIClientDispose(client); client = 0 }
            selected.removeAll(); throw error
        }
    }
    func checkDestinations() throws {
        for destination in selected.values {
            try checkPinnedDestination(destination)
            var protocolID: Int32 = 0
            try checked(MIDIObjectGetIntegerProperty(destination.endpoint, kMIDIPropertyProtocolID, &protocolID), "read selected UMP protocol")
            guard protocolID == 2 else { throw MidiFailure("selected capture output must use native MIDI 2.0; lossy protocol conversion is not selected") }
        }
    }
    func send(_ words: [UInt32], source: String) throws {
        guard let destination = selected[source], !words.isEmpty, words.count <= 4 else { throw MidiFailure("invalid UMP send owner or message size") }
        let capacity = MemoryLayout<MIDIEventList>.size
        let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<MIDIEventList>.alignment)
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: MIDIEventList.self), packet = MIDIEventListInit(list, ._2_0)
        try words.withUnsafeBufferPointer { buffer in
            guard MIDIEventListAdd(list, capacity, packet, 0, buffer.count, buffer.baseAddress!) != nil else { throw MidiFailure("UMP event list cannot hold a complete message") }
            // Only due events are submitted: no future CoreMIDI work survives stop.
            try checked(MIDISendEventList(port, destination.endpoint, list), "send captured UMP")
        }
    }
    func apply(_ event: UmpEvent) throws {
        footprint.observe(UmpMessage(event))
        let word = event.words[0], type = word >> 28, status = (word >> 20) & 15, number = (word >> 8) & 127
        let key = Key(source: event.source, prefix: word & 0xff0f0000, number: number)
        let channel = type == 2 || type == 4
        let on = channel && status == 9 && (type == 4 || word & 127 != 0)
        let off = channel && (status == 8 || type == 2 && status == 9 && word & 127 == 0)
        let pedal = channel && status == 11 && [64,66,69].contains(number)
        let pedalOn = pedal && (type == 4 ? event.words[1] >= 0x80000000 : word & 127 >= 64)
        let sysex = type == 3 || type == 5 && status <= 3
        let sxKey = Key(source: event.source, prefix: word & 0xff000000, number: type == 5 ? (word >> 8) & 255 : 0)
        if on { held[key, default: 0] += 1 }
        if pedalOn { pedals.insert(key) }
        if sysex && status == 1 { exclusive.insert(sxKey) }
        try send(event.words, source: event.source)
        if off, let count = held[key] { if count > 1 { held[key] = count - 1 } else { held.removeValue(forKey: key) } }
        if pedal && !pedalOn { pedals.remove(key) }
        if sysex && [0,3].contains(status) { exclusive.remove(sxKey) }
        if channel && status == 11 && [120,123].contains(number) {
            held = held.filter { !($0.key.source == key.source && $0.key.prefix == key.prefix) }
        }
    }
    func silence() throws {
        var failure: Error?
        for key in exclusive {
            let words: [UInt32] = key.prefix >> 28 == 3 ? [key.prefix | 0x00300000, 0]
                : [key.prefix | 0x00300000 | key.number << 8, 0, 0, 0]
            do { try send(words, source: key.source); exclusive.remove(key) } catch { failure = failure ?? error }
        }
        for (key, count) in held {
            for _ in 0..<count {
                let words: [UInt32] = key.prefix >> 28 == 4 ? [key.prefix | 0x00800000 | key.number << 8, 0] : [key.prefix | 0x00800000 | key.number << 8]
                do {
                    try send(words, source: key.source)
                    let remaining = (held[key] ?? 1) - 1
                    if remaining > 0 { held[key] = remaining } else { held.removeValue(forKey: key) }
                } catch { failure = failure ?? error; break }
            }
        }
        for key in pedals {
            let words: [UInt32] = key.prefix >> 28 == 4 ? [key.prefix | 0x00b00000 | key.number << 8, 0] : [key.prefix | 0x00b00000 | key.number << 8]
            do { try send(words, source: key.source); pedals.remove(key) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }
    func stageCoordinated(at seconds: Double) throws {
        guard Thread.isMainThread, state != .stopped, seconds.isFinite, seconds >= 0, seconds < timeline.duration else { throw MidiFailure("invalid captured UMP position or owner") }
        let original = state == .prepared && seconds == 0
        if !original { _ = try umpRestoration(events, before: seconds, replacing: footprint) }
        try checkDestinations()
        timer?.cancel(); timer = nil
        try silence()
        offset = seconds; pendingRestore = !original; state = .staged
    }
    func runCoordinated(anchorNanoseconds: UInt64) throws {
        guard state == .staged, anchorNanoseconds > DispatchTime.now().uptimeNanoseconds else { throw MidiFailure("captured UMP missed the common start deadline") }
        anchor = anchorNanoseconds; state = .playing; schedule()
    }
    func position(at host: UInt64) -> Double {
        if state == .ended { return timeline.duration }
        guard state == .playing else { return offset }
        return min(timeline.duration, offset + (host > anchor ? Double(host - anchor) / 1e9 : 0))
    }
    func schedule() {
        timer?.cancel(); timer = nil
        guard state == .playing else { return }
        let seconds = pendingRestore ? offset : index < events.count ? events[index].seconds : timeline.duration
        let when = anchor.addingReportingOverflow(UInt64(max(0, seconds - offset) * 1e9))
        guard !when.overflow else { finish(reason: "clock-overflow", error: MidiFailure("UMP deadline exceeds host clock"), publish: false); return }
        let source = DispatchSource.makeTimerSource(queue: .main); timer = source
        source.schedule(deadline: DispatchTime(uptimeNanoseconds: when.partialValue), leeway: .nanoseconds(0))
        source.setEventHandler { [weak self] in self?.tick() }; source.resume()
    }
    func tick() {
        guard state == .playing else { return }
        do {
            try checkDestinations()
            let host = DispatchTime.now().uptimeNanoseconds
            guard host >= anchor else { schedule(); return }
            let seconds = position(at: host)
            if pendingRestore {
                // Reconstruct the current phase if the callback was delayed:
                // notes that ended between staging and this epoch stay silent.
                let restored = try umpRestoration(events, before: seconds, replacing: footprint)
                pendingRestore = false; index = restored.nextIndex
                for event in restored.events { try apply(event) }
            }
            while index < events.count && events[index].seconds <= seconds { try apply(events[index]); index += 1 }
            if index == events.count && seconds >= timeline.duration {
                timer?.cancel(); timer = nil; try silence(); state = .ended; onCoordinatedEnd?(); return
            }
            schedule()
        } catch { finish(reason: "ump-playback-failed", error: error, publish: false) }
    }
    func snapshot(_ kind: String) -> [String: Any] {
        var destinations: [String] = []
        for binding in timeline.bindings where !destinations.contains(binding.destination) { destinations.append(binding.destination) }
        return ["bindings": destinations.enumerated().compactMap { port, uid -> [String: Any]? in
            guard let destination = selected.values.first(where: { String($0.uid) == uid }) else { return nil }
            return ["port": port, "device": ["kind": "midi", "protocol": 2, "id": uid, "name": destination.name]]
        }]
    }
    func finish(reason: String, error: Error?, publish: Bool) {
        guard state != .stopped else { return }
        state = .stopped; timer?.cancel(); timer = nil
        var failure = error
        do { try silence() } catch { failure = failure ?? error }
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        terminalFailure = failure; onCoordinatedFailure?(reason, failure)
    }
}
