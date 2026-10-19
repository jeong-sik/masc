import Foundation
import CoreMIDI

// The effect owner pins destinations and retains uncertain acquisitions. Source
// and region schedulers own their clocks; releasing one scope keeps the shared
// port and other channels alive.
struct UmpChannel: Hashable {
    let source: String
    let channel: UInt32
    init(source: String, channel: UInt32) { self.source = source; self.channel = channel }
    init(_ event: UmpEvent) { source = event.source; channel = event.words[0] & 0x0f0f0000 }
    func contains(_ address: UmpAddress) -> Bool { source == address.source && channel == address.channel }
}
final class UmpOutput {
    let bindings: [UmpBinding]
    var closed = false
    var onFailure: ((Error) -> Void)?
    var footprint = UmpFootprint()
    var client = MIDIClientRef(), port = MIDIPortRef()
    var selected: [String: Destination] = [:]
    // Keys include physical endpoint, group, channel, message dialect and note.
    // Retain uncertain acquisitions/releases until a successful cleanup send.
    struct Key: Hashable { let source: String; let prefix: UInt32; let number: UInt32 }
    var held: [Key: Int] = [:], pedals = Set<Key>()
    var exclusive = Set<Key>()
    init(bindings: [UmpBinding]) { self.bindings = bindings }
    func prepare() throws {
        guard Thread.isMainThread else { throw MidiFailure("UMP preparation requires the main lifecycle") }
        do {
            try checked(MIDIClientCreateWithBlock("MASC captured UMP output" as CFString, &client, { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed else { return }
                    do { try self.checkDestinations() } catch { self.onFailure?(error) }
                }
            }), "create UMP output client")
            for binding in bindings { selected[binding.source] = try selectedDestination(uid: binding.destination) }
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
    // Drain one already-active copy when its callback crosses a boundary. Raw
    // releases for acquired instances retain their velocities/attributes. Notes
    // never acquired by this owner stay silent, including FIFO overlaps on one
    // pitch. No skipped copies or repeated message arrays are materialized.
    func drain(_ events: ArraySlice<UmpEvent>) throws {
        var voices = held.mapValues { Array(repeating: true, count: $0) }
        for event in events {
            let word = event.words[0]
            let key = Key(source: event.source, prefix: word & 0xff0f0000, number: (word >> 8) & 127)
            switch UmpMessage(event).action {
            case .on:
                voices[key, default: []].append(false)
            case .off:
                guard var queue = voices[key], !queue.isEmpty else { continue }
                let acquired = queue.removeFirst(); voices[key] = queue
                if acquired, (held[key] ?? 0) > 0 { try apply(event) }
            case .kill, .release:
                try apply(event)
                voices = voices.filter { !($0.key.source == key.source && $0.key.prefix == key.prefix) }
            default: try apply(event)
            }
        }
    }
    func silence(in scope: Set<UmpChannel>? = nil) throws {
        func owns(_ key: Key) -> Bool { scope == nil || scope!.contains(UmpChannel(source: key.source, channel: key.prefix & 0x0f0f0000)) }
        var failure: Error?
        for key in exclusive where owns(key) {
            let words: [UInt32] = key.prefix >> 28 == 3 ? [key.prefix | 0x00300000, 0]
                : [key.prefix | 0x00300000 | key.number << 8, 0, 0, 0]
            do { try send(words, source: key.source); exclusive.remove(key) } catch { failure = failure ?? error }
        }
        for (key, count) in held where owns(key) {
            for _ in 0..<count {
                let words: [UInt32] = key.prefix >> 28 == 4 ? [key.prefix | 0x00800000 | key.number << 8, 0] : [key.prefix | 0x00800000 | key.number << 8]
                do {
                    try send(words, source: key.source)
                    let remaining = (held[key] ?? 1) - 1
                    if remaining > 0 { held[key] = remaining } else { held.removeValue(forKey: key) }
                } catch { failure = failure ?? error; break }
            }
        }
        for key in pedals where owns(key) {
            let words: [UInt32] = key.prefix >> 28 == 4 ? [key.prefix | 0x00b00000 | key.number << 8, 0] : [key.prefix | 0x00b00000 | key.number << 8]
            do { try send(words, source: key.source); pedals.remove(key) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }
    func prior(in scope: Set<UmpChannel>) -> UmpFootprint {
        var value = footprint
        value.touched = value.touched.filter { field in scope.contains { $0.contains(field.address) } }
        value.addresses = value.addresses.filter { address in scope.contains { $0.contains(address) } }
        return value
    }
    func snapshot() -> [[String: Any]] {
        var destinations: [String] = []
        for binding in bindings where !destinations.contains(binding.destination) { destinations.append(binding.destination) }
        return destinations.enumerated().compactMap { port, uid in
            guard let destination = selected.values.first(where: { String($0.uid) == uid }) else { return nil }
            return ["port": port, "device": ["kind": "midi", "protocol": 2, "id": uid, "name": destination.name]]
        }
    }
    func close() throws {
        guard !closed else { return }
        closed = true
        defer {
            if port != 0 { MIDIPortDispose(port); port = 0 }
            if client != 0 { MIDIClientDispose(client); client = 0 }
        }
        try silence()
    }
}
