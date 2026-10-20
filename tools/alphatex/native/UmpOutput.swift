import Foundation
import CoreMIDI

enum UmpNativeProtocol: Int32 { case midi1 = 1, midi2 = 2 }
func umpNativeProtocol(_ uid: String) throws -> UmpNativeProtocol {
    let destination = try selectedDestination(uid: uid)
    var value: Int32 = 0
    try checked(MIDIObjectGetIntegerProperty(destination.endpoint, kMIDIPropertyProtocolID, &value), "read MIDI destination protocol")
    guard let result = UmpNativeProtocol(rawValue: value) else { throw MidiFailure("unknown MIDI destination protocol") }
    return result
}

// UMP v1.1.2 Appendix D.1.3: canonical min-center-max upscaling. An inverse
// is admitted only when every bit agrees; arbitrary precision is never rounded.
func umpScaleUp(_ value: UInt32, from: Int, to: Int) -> UInt32 {
    var result = value << (to - from)
    if value > UInt32(1 << (from - 1)) {
        var repeated = (value & UInt32((1 << (from - 1)) - 1)) << (to - 2 * from + 1)
        while repeated != 0 { result |= repeated; repeated >>= from - 1 }
    }
    return result
}
func umpExactDown(_ value: UInt32, from: Int, to: Int) throws -> UInt32 {
    let result = value >> (from - to)
    guard umpScaleUp(result, from: to, to: from) == value else { throw MidiFailure("captured MIDI precision requires a native MIDI 2.0 output") }
    return result
}

// Project one message to group-zero MIDI1 UMP. Returning several words is one
// atomic due batch (bank MSB, bank LSB, program), not repeated source events.
func umpMidi1Words(_ words: [UInt32]) throws -> [UInt32] {
    guard let word = words.first, words.count == umpMessageWordCounts[Int(word >> 28)] else { throw MidiFailure("invalid UMP wire projection") }
    let type = word >> 28, status = word >> 20 & 15, byte = word >> 8 & 255
    let prefix: UInt32 = 0x20000000 | (word & 0x00ff0000)
    switch type {
    case 1:
        let system = word >> 16 & 255, data = word & 0xffff
        guard ([0xf1, 0xf3].contains(system) && data & 0x80ff == 0
          || system == 0xf2 && data & 0x8080 == 0
          || [0xf6, 0xf8, 0xfa, 0xfb, 0xfc, 0xfe, 0xff].contains(system) && data == 0) else { throw MidiFailure("invalid MIDI1 system message") }
        return [word & 0xf0ffffff]
    case 2:
        guard (8...14).contains(status), byte < 128, word & 0x80 == 0,
          ![12,13].contains(status) || word & 255 == 0 else { throw MidiFailure("invalid MIDI1 channel message") }
        return [word & 0xf0ffffff]
    case 3:
        let count = Int(word >> 16 & 15)
        let bytes = [word >> 8 & 255, word & 255, words[1] >> 24, words[1] >> 16 & 255, words[1] >> 8 & 255, words[1] & 255]
        guard status <= 3, count <= 6, bytes.prefix(count).allSatisfy({ $0 < 128 }), bytes.dropFirst(count).allSatisfy({ $0 == 0 }) else { throw MidiFailure("invalid MIDI1 SysEx7 message") }
        return [word & 0xf0ffffff, words[1]]
    case 4:
        let data = words[1]
        switch status {
        case 8,9:
            guard byte < 128, word & 255 == 0, data & 0xffff == 0 else { throw MidiFailure("captured note attributes require a native MIDI 2.0 output") }
            let velocity = try umpExactDown(data >> 16, from: 16, to: 7)
            guard status != 9 || velocity > 0 else { throw MidiFailure("MIDI2 zero-velocity Note On cannot be represented faithfully by MIDI1") }
            return [prefix | byte << 8 | velocity]
        case 10,11:
            guard byte < 128, word & 255 == 0 else { throw MidiFailure("invalid captured MIDI2 controller fields") }
            guard status != 11 || ![0,6,32,38,96,97,98,99,100,101].contains(byte) else { throw MidiFailure("captured compound controller state requires a native MIDI 2.0 output") }
            return [try prefix | byte << 8 | umpExactDown(data, from: 32, to: 7)]
        case 12:
            guard word & 0xfffe == 0, data & 0x80ff8080 == 0, word & 1 != 0 || data & 0xffff == 0 else { throw MidiFailure("invalid captured MIDI2 program fields") }
            let program = 0x20c00000 | word & 0x000f0000 | data >> 16 & 0x7f00
            return word & 1 == 0 ? [program] : [0x20b00000 | word & 0x000f0000 | data >> 8 & 127,
                0x20b02000 | word & 0x000f0000 | data & 127, program]
        case 13:
            guard word & 0xffff == 0 else { throw MidiFailure("invalid captured MIDI2 pressure fields") }
            return [try prefix | umpExactDown(data, from: 32, to: 7) << 8]
        case 14:
            guard word & 0xffff == 0 else { throw MidiFailure("invalid captured MIDI2 pitch fields") }
            let bend = try umpExactDown(data, from: 32, to: 14)
            return [prefix | (bend & 127) << 8 | bend >> 7]
        default: throw MidiFailure("captured per-note or compound MIDI2 state requires a native MIDI 2.0 output")
        }
    default: throw MidiFailure("captured UMP message has no faithful MIDI1 wire representation")
    }
}

struct UmpMidi1Profile {
    var groups = Set<UInt32>()
    var failure: Error?
    var dialects: [UInt32: UInt32] = [:]
    mutating func observe(_ event: UmpEvent) {
        groups.insert(event.words[0] >> 24 & 15)
        do {
            _ = try umpMidi1Words(event.words)
            let word = event.words[0], type = word >> 28, channel = word & 0x0f0f0000
            if type == 2 || type == 4 {
                if let prior = dialects[channel], prior != type { throw MidiFailure("mixed captured channel dialects require a native MIDI 2.0 output") }
                dialects[channel] = type
            }
        } catch { failure = failure ?? error }
    }
    func validate() throws {
        if let failure { throw failure }
        guard groups.count <= 1 else { throw MidiFailure("independent captured UMP groups require separate MIDI1 outputs") }
    }
}

// The effect owner pins destinations and retains uncertain acquisitions. Source
// and region schedulers own their clocks; releasing one scope keeps the shared
// port and other channels alive.
struct UmpChannel: Hashable {
    let source: String
    let channel: UInt32
    init(source: String, channel: UInt32) { self.source = source; self.channel = channel }
    init(_ event: UmpEvent) { source = event.source; channel = event.words[0] & 0x0f0f0000 }
    // Only MIDI 1.0 and MIDI 2.0 channel-voice words address a channel; a
    // utility or system word's low status bits are not one.
    init?(voice event: UmpEvent) {
        let dialect = event.words[0] >> 28
        guard dialect == 2 || dialect == 4 else { return nil }
        self.init(event)
    }
    func contains(_ address: UmpAddress) -> Bool { source == address.source && channel == address.channel }
}
final class UmpOutput {
    let bindings: [UmpBinding]
    var closed = false
    var onFailure: ((Error) -> Void)?
    var footprint = UmpFootprint()
    var client = MIDIClientRef(), port = MIDIPortRef()
    var selected: [String: Destination] = [:]
    var nativeProtocols: [String: UmpNativeProtocol] = [:]
    let compatibleEvents: [UmpEvent]?
    // Keys include physical endpoint, group, channel, message dialect and note.
    // Retain uncertain acquisitions/releases until a successful cleanup send.
    struct Key: Hashable { let source: String; let prefix: UInt32; let number: UInt32 }
    var held: [Key: Int] = [:], pedals = Set<Key>()
    var exclusive = Set<Key>()
    init(bindings: [UmpBinding], compatibleEvents: [UmpEvent]? = nil) { self.bindings = bindings; self.compatibleEvents = compatibleEvents }
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
            var profiles: [String: UmpMidi1Profile] = [:]
            for event in compatibleEvents ?? [] {
                guard let binding = bindings.first(where: { $0.source == event.source }) else { throw MidiFailure("unbound MIDI1 compatibility profile") }
                profiles[binding.destination, default: UmpMidi1Profile()].observe(event)
            }
            for binding in bindings {
                let wire = try umpNativeProtocol(binding.destination)
                if wire == .midi1 {
                    guard compatibleEvents != nil else { throw MidiFailure("open-ended UMP input requires a native MIDI 2.0 output") }
                    try (profiles[binding.destination] ?? UmpMidi1Profile()).validate()
                }
                nativeProtocols[binding.destination] = wire
            }
            try checkDestinations()
            try checked(MIDIOutputPortCreate(client, "MASC captured UMP output" as CFString, &port), "create UMP output port")
        } catch {
            if port != 0 { MIDIPortDispose(port); port = 0 }
            if client != 0 { MIDIClientDispose(client); client = 0 }
            selected.removeAll(); nativeProtocols.removeAll(); throw error
        }
    }
    func checkDestinations() throws {
        for destination in selected.values {
            try checkPinnedDestination(destination)
            var protocolID: Int32 = 0
            try checked(MIDIObjectGetIntegerProperty(destination.endpoint, kMIDIPropertyProtocolID, &protocolID), "read selected UMP protocol")
            guard protocolID == nativeProtocols[String(destination.uid)]?.rawValue else { throw MidiFailure("selected capture output changed its native MIDI protocol") }
        }
    }
    func send(_ words: [UInt32], source: String) throws {
        guard let destination = selected[source], !words.isEmpty, words.count <= 4 else { throw MidiFailure("invalid UMP send owner or message size") }
        try checkPinnedDestination(destination)
        guard let wire = nativeProtocols[String(destination.uid)], try umpNativeProtocol(String(destination.uid)) == wire else { throw MidiFailure("captured output protocol changed before send") }
        let payload = try wire == .midi1 ? umpMidi1Words(words) : words
        let capacity = MemoryLayout<MIDIEventList>.size
        let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<MIDIEventList>.alignment)
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: MIDIEventList.self), packet = MIDIEventListInit(list, wire == .midi1 ? ._1_0 : ._2_0)
        try payload.withUnsafeBufferPointer { buffer in
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
            return ["port": port, "device": ["kind": "midi", "protocol": 2, "nativeProtocol": nativeProtocols[uid]!.rawValue, "id": uid, "name": destination.name]]
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
