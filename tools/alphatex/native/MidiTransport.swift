import Foundation
import CoreMIDI

struct MidiFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
func checked(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw MidiFailure("\(operation): OSStatus \(status)") }
}
func emit(_ value: [String: Any]) throws {
    var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    bytes.append(10); try FileHandle.standardOutput.write(contentsOf: bytes)
}
func diagnostic(_ error: Error) {
    try? FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
}
struct Destination {
    let endpoint: MIDIEndpointRef
    let uid: Int32
    let name: String
    var json: [String: Any] { ["kind": "midi", "id": String(uid), "name": name, "protocol": 1] }
}
func destinations() throws -> [Destination] {
    try (0..<MIDIGetNumberOfDestinations()).map { index in
        let endpoint = MIDIGetDestination(index)
        var uid: Int32 = 0, name: Unmanaged<CFString>?
        try checked(MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid), "read MIDI destination identity")
        try checked(MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name), "read MIDI destination name")
        guard let name else { throw MidiFailure("MIDI destination name is unavailable") }
        return Destination(endpoint: endpoint, uid: uid, name: name.takeRetainedValue() as String)
    }
}
func selectedDestination(uid: String) throws -> Destination {
    guard let identity = Int32(uid), String(identity) == uid else { throw MidiFailure("MIDI destination requires its exact unique ID") }
    var object = MIDIObjectRef(), type = MIDIObjectType.other
    try checked(MIDIObjectFindByUniqueID(identity, &object, &type), "find selected MIDI destination")
    guard object != 0, type == .destination else { throw MidiFailure("selected MIDI object is not a destination") }
    var name: Unmanaged<CFString>?
    try checked(MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &name), "read selected MIDI destination name")
    guard let name else { throw MidiFailure("selected MIDI destination name is unavailable") }
    let selected = Destination(endpoint: object, uid: identity, name: name.takeRetainedValue() as String)
    try checkPinnedDestination(selected)
    return selected
}
func checkPinnedDestination(_ selected: Destination) throws {
    // A lookup/listing of unrelated endpoints may race their removal. Validate
    // only the selected reference, including reuse with a different identity.
    var identity: Int32 = 0
    try checked(MIDIObjectGetIntegerProperty(selected.endpoint, kMIDIPropertyUniqueID, &identity), "read selected MIDI destination identity")
    guard identity == selected.uid else { throw MidiFailure("selected MIDI destination was removed or changed") }
    var offline: Int32 = 0
    let status = MIDIObjectGetIntegerProperty(selected.endpoint, kMIDIPropertyOffline, &offline)
    if status != kMIDIUnknownProperty {
        try checked(status, "read selected MIDI destination state")
        guard offline == 0 else { throw MidiFailure("selected MIDI destination is offline") }
    }
}
struct Event: Decodable, Equatable {
    enum Kind: String, Decodable { case program, control, on, off }
    let kind: Kind
    let seconds: Double
    let channel: UInt8
    let program: UInt8?
    let controller: UInt8?
    let value: UInt8?
    let pitch: UInt8?
    let velocity: UInt8?
    func bytes() throws -> [UInt8] {
        guard seconds.isFinite, seconds >= 0, channel < 16 else { throw MidiFailure("invalid MIDI event position or channel") }
        switch kind {
        case .program:
            guard let program, program < 128 else { throw MidiFailure("invalid MIDI program") }
            return [0xc0 | channel, program]
        case .control:
            // These are the controls present in the editable project schema.
            // A richer MIDI source must extend that schema before projection.
            guard let controller, [7, 10].contains(controller), let value, value < 128 else {
                throw MidiFailure("unsupported project controller (volume/pan required)")
            }
            return [0xb0 | channel, controller, value]
        case .on:
            guard let pitch, pitch < 128, let velocity, velocity > 0, velocity < 128 else { throw MidiFailure("invalid MIDI note-on") }
            return [0x90 | channel, pitch, velocity]
        case .off:
            guard let pitch, pitch < 128 else { throw MidiFailure("invalid MIDI note-off") }
            return [0x80 | channel, pitch, 0]
        }
    }
    var key: UInt16 { UInt16(channel) << 8 | UInt16(pitch ?? controller ?? 0) }
}
// SMF F7 escapes can contain running status, real-time bytes or a partial
// message. CoreMIDI receives complete short messages with explicit status;
// SysEx fragments retain their source boundaries and timing.
struct WireState {
    var running: UInt8?, pending: [UInt8] = [], required = 0
    var exclusive = false
    mutating func feed(_ bytes: [UInt8]) throws -> [[UInt8]] {
        var messages: [[UInt8]] = [], sysex: [UInt8] = []
        for byte in bytes {
            if byte >= 0xf8 {
                if !sysex.isEmpty { messages.append(sysex); sysex = [] }
                messages.append([byte]); continue
            }
            if exclusive {
                if byte == 0xf7 { sysex.append(byte); exclusive = false; messages.append(sysex); sysex = [] }
                else if byte < 0x80 { sysex.append(byte) }
                else { throw MidiFailure("non-real-time status interrupts source SysEx") }
                continue
            }
            if byte >= 0x80 {
                guard pending.isEmpty else { throw MidiFailure("status interrupts an incomplete source MIDI message") }
                if byte == 0xf0 { running = nil; exclusive = true; sysex.append(byte); continue }
                if byte < 0xf0 {
                    running = byte; required = [0xc0, 0xd0].contains(byte & 0xf0) ? 2 : 3
                } else {
                    running = nil
                    switch byte {
                    case 0xf1, 0xf3: required = 2
                    case 0xf2: required = 3
                    case 0xf6: messages.append([byte]); continue
                    default: throw MidiFailure("undefined or unmatched source MIDI system status")
                    }
                }
                pending = [byte]
            } else {
                if pending.isEmpty {
                    guard let running else { throw MidiFailure("source MIDI data has no wire running status") }
                    pending = [running]; required = [0xc0, 0xd0].contains(running & 0xf0) ? 2 : 3
                }
                pending.append(byte)
                if pending.count == required { messages.append(pending); pending = [] }
            }
        }
        if !sysex.isEmpty { messages.append(sysex) }
        return messages
    }
    func complete() throws {
        guard !exclusive, pending.isEmpty else { throw MidiFailure("source ends inside a MIDI wire message") }
    }
}
// Reconstruction retains channel-message order for bank/program and RPN writes.
// It never replays opaque device commands or invents an unknown initial value.
struct ChaseField: Hashable {
    enum Kind: Hashable { case controller(UInt8), program, bend, pressure, poly(UInt8), parameter(UInt16, UInt8) }
    let port: Int
    let channel: UInt8
    let kind: Kind
}
struct ChaseProgram: Equatable {
    let bankMSB: UInt8?, bankLSB: UInt8?
    let number: UInt8
}
struct ChaseNote {
    let pitch: UInt8
    let velocity: UInt8
    let program: ChaseProgram?
    var origin: Int? = nil
    var held = true
    var captured = false
    var release: UInt8 = 0
    var releaseStatus: UInt8 = 0x80
}
struct ChaseChannel {
    var notes: [ChaseNote] = []
    var bankMSB: UInt8?, bankLSB: UInt8?
    var program: ChaseProgram?
    var sustain: UInt8 = 0, sostenuto: UInt8 = 0
    var pressure: UInt8?
    var poly: [UInt8: UInt8] = [:]
    var rpnMSB: UInt8?, rpnLSB: UInt8?
    var nrpn = false
    var parameters: [UInt16: Set<UInt8>] = [:]
    mutating func prune() {
        notes.removeAll { !$0.held && sustain < 64 && !(sostenuto >= 64 && $0.captured) }
    }
}
enum ChaseObstacle: String, Hashable {
    case system = "opaque SysEx or system messages"
    case mode = "channel mode changes"
    case hold2 = "Hold 2 pedal"
    case velocity = "high resolution velocity prefix"
    case nrpn = "device-specific NRPN data"
    case parameter = "incomplete or unsupported RPN state"
    case relative = "relative parameter data without an absolute baseline"
}
struct SourceChase {
    var channels: [Int: ChaseChannel] = [:]
    var history: [(Int, [UInt8])] = []
    var touched = Set<ChaseField>(), known = Set<ChaseField>()
    var obstacles = Set<ChaseObstacle>()
    mutating func observe(_ bytes: [UInt8], port: Int, origin: Int? = nil) {
        guard let status = bytes.first else { return }
        guard status < 0xf0 else { obstacles.insert(.system); return }
        let channel = status & 15, key = port << 8 | Int(channel), type = status & 0xf0
        var state = channels[key] ?? ChaseChannel()
        func field(_ kind: ChaseField.Kind) -> ChaseField { ChaseField(port: port, channel: channel, kind: kind) }
        func mark(_ kind: ChaseField.Kind) { let value = field(kind); touched.insert(value); known.insert(value) }
        switch type {
        case 0x90 where bytes[2] > 0:
            state.notes.append(ChaseNote(pitch: bytes[1], velocity: bytes[2], program: state.program, origin: origin))
        case 0x80, 0x90:
            if let index = state.notes.firstIndex(where: { $0.pitch == bytes[1] && $0.held }) {
                state.notes[index].held = false
                state.notes[index].release = bytes[2]
                state.notes[index].releaseStatus = status
            }
            state.prune()
        case 0xa0:
            state.poly[bytes[1]] = bytes[2]; mark(.poly(bytes[1]))
        case 0xd0:
            state.pressure = bytes[1]; mark(.pressure)
        case 0xc0:
            state.program = ChaseProgram(bankMSB: state.bankMSB, bankLSB: state.bankLSB, number: bytes[1])
            history.append((port, bytes)); mark(.program)
        case 0xe0:
            history.append((port, bytes)); mark(.bend)
        case 0xb0:
            let cc = bytes[1], value = bytes[2]
            if cc < 120 && ![6, 38, 96, 97].contains(cc) { mark(.controller(cc)) }
            switch cc {
            case 0, 32:
                if cc == 0 { state.bankMSB = value } else { state.bankLSB = value }
                history.append((port, bytes))
            case 64:
                state.sustain = value; state.prune()
            case 66:
                if state.sostenuto < 64 && value >= 64 {
                    for index in state.notes.indices where state.notes[index].held { state.notes[index].captured = true }
                }
                state.sostenuto = value
                if value < 64 { for index in state.notes.indices { state.notes[index].captured = false } }
                state.prune()
            case 69:
                if value >= 64 { obstacles.insert(.hold2) }
                history.append((port, bytes))
            case 88:
                obstacles.insert(.velocity)
            case 120:
                state.notes.removeAll(); history.append((port, bytes))
            case 121:
                state.sustain = 0; state.sostenuto = 0
                for index in state.notes.indices { state.notes[index].captured = false }
                state.prune(); state.pressure = 0; state.poly.removeAll()
                state.rpnMSB = 127; state.rpnLSB = 127; state.nrpn = false
                // The source reset establishes these values, including pressure
                // for every key. Parameter data, volume, pan and program persist.
                mark(.pressure); mark(.bend)
                for pitch: UInt8 in 0...127 { mark(.poly(pitch)) }
                for controller: UInt8 in [1, 11, 64, 65, 66, 67, 98, 99, 100, 101] { mark(.controller(controller)) }
                history.append((port, bytes))
            case 123:
                // This mode has no per-note release byte. Chase its implicit
                // offs at neutral velocity 64, retaining earlier explicit offs.
                for index in state.notes.indices where state.notes[index].held {
                    state.notes[index].held = false
                    state.notes[index].release = 64
                    state.notes[index].releaseStatus = 0x80 | channel
                }
                state.prune()
            case 122, 124...127:
                obstacles.insert(.mode)
            case 98, 99:
                state.nrpn = true; history.append((port, bytes))
            case 100, 101:
                state.nrpn = false
                if cc == 100 { state.rpnLSB = value } else { state.rpnMSB = value }
                history.append((port, bytes))
            case 6, 38, 96, 97:
                history.append((port, bytes))
                if state.nrpn { obstacles.insert(.nrpn) }
                else if let high = state.rpnMSB, let low = state.rpnLSB, high == 127 && low == 127 {
                    // Null RPN selection makes Data Entry ineffectual.
                } else if let high = state.rpnMSB, let low = state.rpnLSB, high == 0 && low <= 5 {
                    let id = UInt16(high) << 7 | UInt16(low)
                    if cc == 6 || cc == 38 {
                        state.parameters[id, default: []].insert(cc)
                        mark(.parameter(id, cc))
                    } else {
                        for component: UInt8 in [6, 38] { touched.insert(field(.parameter(id, component))) }
                        if state.parameters[id] != Set([6,38]) { obstacles.insert(.relative) }
                    }
                } else { obstacles.insert(.parameter) }
            default:
                history.append((port, bytes))
            }
        default: break
        }
        channels[key] = state
    }
    func bootstrap(replacing previous: SourceChase, notes: Bool = true) throws -> [(Int, [UInt8])] {
        let unsafe = obstacles.union(previous.obstacles)
        guard unsafe.isEmpty else {
            throw MidiFailure("source state reconstruction requires support for " + unsafe.map(\.rawValue).sorted().joined(separator: ", "))
        }
        guard previous.touched.isSubset(of: known) else {
            throw MidiFailure("source seek cannot restore an initial channel value absent from the source prefix")
        }
        // Replaying the final program before every held Note On would change
        // voices that began under an earlier patch, including pedal-held notes.
        // Refuse that reconstruction until per-note patch replay is supported.
        guard channels.values.allSatisfy({ state in state.notes.allSatisfy { $0.program == state.program } }) else {
            throw MidiFailure("source state reconstruction cannot restore held notes across program or bank changes")
        }
        var result = history
        if notes {
            for key in channels.keys.sorted() {
                let state = channels[key]!, port = key >> 8, channel = UInt8(key & 15)
                // silence() already releases owned keys/pedals. Restore the captured
                // set before switching sostenuto on; later keys must remain outside it.
                for note in state.notes where note.captured { result.append((port, [0x90 | channel, note.pitch, note.velocity])) }
                if known.contains(ChaseField(port: port, channel: channel, kind: .controller(66))) { result.append((port, [0xb0 | channel, 66, state.sostenuto])) }
                if known.contains(ChaseField(port: port, channel: channel, kind: .controller(64))) { result.append((port, [0xb0 | channel, 64, state.sustain])) }
                for note in state.notes where !note.captured { result.append((port, [0x90 | channel, note.pitch, note.velocity])) }
                for note in state.notes where !note.held { result.append((port, [note.releaseStatus, note.pitch, note.release])) }
                if let pressure = state.pressure { result.append((port, [0xd0 | channel, pressure])) }
                for pitch in state.poly.keys.sorted() { result.append((port, [0xa0 | channel, pitch, state.poly[pitch]!])) }
            }
        }
        return result
    }
}

struct WireEvent: Decodable {
    let seconds: Double
    let port: Int
    let bytes: [UInt8]
}
struct Binding: Decodable {
    let port: Int
    let destination: String
}

struct MidiRegionSource: Decodable { let id: String; let timeline: Timeline }
struct MidiRegionSpec: Decodable {
    let id: String, source: String
    let startSeconds: Double, sourceStart: Double, sourceEnd: Double
    let repeatCount: Int
}
struct MidiRegionEntry {
    let model: SourceChase, next: Int, safeKnown: Set<ChaseField>
}
func midiRegionEntry(_ events: [WireEvent], at seconds: Double, boundary: (before: Int, through: Int)? = nil) -> MidiRegionEntry {
    var prefix = SourceChase(), next = 0
    while next < events.count && (boundary.map { next < $0.before } ?? (events[next].seconds < seconds)) {
        let event = events[next]; prefix.observe(event.bytes, port: event.port, origin: next); next += 1
    }
    let entryBoundary = boundary
    var through = prefix, firstSound: [Int: Set<ChaseField>] = [:], boundary = next
    for (address, state) in prefix.channels where !state.notes.isEmpty { firstSound[address] = prefix.known }
    while boundary < events.count && (entryBoundary.map { boundary < $0.through } ?? (events[boundary].seconds == seconds)) {
        let event = events[boundary]
        if event.bytes[0] & 0xf0 == 0x90 && event.bytes[2] > 0 {
            let address = event.port << 8 | Int(event.bytes[0] & 15)
            if firstSound[address] == nil { firstSound[address] = through.known }
        }
        through.observe(event.bytes, port: event.port, origin: boundary); boundary += 1
    }
    let safe = through.known.filter { field in
        firstSound[field.port << 8 | Int(field.channel)].map { $0.contains(field) } ?? true
    }
    return MidiRegionEntry(model: prefix, next: next, safeKnown: safe)
}
struct MidiRegion {
    let spec: MidiRegionSpec
    let events: [WireEvent]
    let addresses: Set<Int>
    let startKnown: Set<ChaseField>, endTouched: Set<ChaseField>
    let obstacles: Set<ChaseObstacle>
    let sourceDuration: Double
    // Region boundaries are compared and scheduled on an exact integer-nanosecond
    // grid. A start taken from a project position and an end accumulated from a
    // source span must not disagree by a rounding ulp, or two exactly abutting
    // regions read as an overlap and the whole arrangement is refused.
    var startNanoseconds: Int64 { Int64((spec.startSeconds * 1e9).rounded()) }
    var durationNanoseconds: Int64 { Int64((spec.sourceEnd * 1e9).rounded()) - Int64((spec.sourceStart * 1e9).rounded()) }
    var endNanoseconds: Int64 { startNanoseconds + durationNanoseconds * Int64(spec.repeatCount) }
    var duration: Double { Double(durationNanoseconds) / 1e9 }
    var end: Double { Double(endNanoseconds) / 1e9 }
    func startSeconds(copy: Int) -> Double { Double(startNanoseconds + Int64(copy) * durationNanoseconds) / 1e9 }
    init(spec: MidiRegionSpec, sourceDuration: Double, events: [WireEvent]) throws {
        guard spec.startSeconds.isFinite, spec.startSeconds >= 0, spec.sourceStart.isFinite, spec.sourceStart >= 0,
              spec.sourceEnd.isFinite, spec.sourceEnd > spec.sourceStart, spec.sourceEnd <= sourceDuration,
              spec.repeatCount > 0, spec.repeatCount <= 9_007_199_254_740_991,
              spec.startSeconds + (spec.sourceEnd - spec.sourceStart) > spec.startSeconds,
              (spec.startSeconds + (spec.sourceEnd - spec.sourceStart) * Double(spec.repeatCount)).isFinite else { throw MidiFailure("MIDI regions require representable positive source spans and finite repeat counts") }
        guard spec.startSeconds * 1e9 < Double(Int64.max), spec.sourceEnd * 1e9 < Double(Int64.max) else { throw MidiFailure("MIDI region span exceeds the nanosecond grid") }
        let gridStart = Int64((spec.startSeconds * 1e9).rounded())
        let gridSpan = Int64((spec.sourceEnd * 1e9).rounded()) - Int64((spec.sourceStart * 1e9).rounded())
        guard gridSpan > 0, Int64(spec.repeatCount) <= (Int64.max - gridStart) / gridSpan else { throw MidiFailure("MIDI region span exceeds the nanosecond grid") }
        self.spec = spec; self.events = events; self.sourceDuration = sourceDuration
        var end = SourceChase(), addresses = Set<Int>()
        for event in events where event.seconds < spec.sourceEnd || event.seconds == spec.sourceEnd && spec.sourceEnd == sourceDuration {
            end.observe(event.bytes, port: event.port)
            if let status = event.bytes.first, status < 0xf0 { addresses.insert(event.port << 8 | Int(status & 15)) }
        }
        obstacles = end.obstacles
        self.addresses = addresses; startKnown = midiRegionEntry(events, at: spec.sourceStart).safeKnown; endTouched = end.touched
    }
    func includes(_ seconds: Double) -> Bool { seconds < spec.sourceEnd || seconds == spec.sourceEnd && spec.sourceEnd == sourceDuration }
}
struct MidiRegionCursor {
    var copy = 0, index = 0, active = false
}
struct MidiRegionAction {
    enum Kind: Int { case endpointEvent, end, begin, event }
    let seconds: Double, region: Int, kind: Kind
}
extension SourceChase {
    func scoped(to addresses: Set<Int>) -> SourceChase {
        var value = self
        value.channels = channels.filter { addresses.contains($0.key) }
        value.history = history.filter { addresses.contains($0.0 << 8 | Int($0.1[0] & 15)) }
        value.known = known.filter { addresses.contains($0.port << 8 | Int($0.channel)) }
        value.touched = touched.filter { addresses.contains($0.port << 8 | Int($0.channel)) }
        return value
    }
    mutating func replace(_ model: SourceChase, addresses: Set<Int>) {
        let outside = Set(channels.keys).subtracting(addresses)
        var value = scoped(to: outside)
        let replacement = model.scoped(to: addresses)
        value.channels.merge(replacement.channels) { _, new in new }
        value.history.append(contentsOf: replacement.history)
        value.known.formUnion(replacement.known); value.touched.formUnion(replacement.touched)
        self = value
    }
}

struct Timeline: Decodable {
    let schemaVersion: Int
    let duration: Double
    let events: [Event]
    let wireEvents: [WireEvent]
    let bindings: [Binding]
    let regions: [MidiRegion]
    var source: Bool { schemaVersion != 1 }
    var arrangement: Bool { schemaVersion == 3 }
    enum Keys: String, CodingKey { case schemaVersion, duration, events, bindings, sources, regions }
    init(schemaVersion: Int, duration: Double, events: [Event]) {
        self.schemaVersion = schemaVersion; self.duration = duration; self.events = events
        wireEvents = []; bindings = []; regions = []
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        duration = try values.decode(Double.self, forKey: .duration)
        switch schemaVersion {
        case 1:
            events = try values.decode([Event].self, forKey: .events); wireEvents = []; bindings = []; regions = []
            guard !values.contains(.bindings) else { throw MidiFailure("phrase timeline cannot contain source bindings") }
        case 2:
            events = []; wireEvents = try values.decode([WireEvent].self, forKey: .events)
            bindings = try values.decode([Binding].self, forKey: .bindings); regions = []
        case 3:
            events = []; wireEvents = []
            let sources = try values.decode([MidiRegionSource].self, forKey: .sources)
            let specifications = try values.decode([MidiRegionSpec].self, forKey: .regions)
            var outputs: [String] = []
            for source in sources {
                guard source.timeline.schemaVersion == 2 else { throw MidiFailure("arrangement requires retained source timelines") }
                try source.timeline.validate()
                for binding in source.timeline.bindings where !outputs.contains(binding.destination) { outputs.append(binding.destination) }
            }
            bindings = outputs.enumerated().map { Binding(port: $0.offset, destination: $0.element) }
            var compiled: [MidiRegion] = []
            guard Set(sources.map(\.id)).count == sources.count, Set(specifications.map(\.id)).count == specifications.count else { throw MidiFailure("duplicate MIDI arrangement identity") }
            var sourceMessages: [String: [WireEvent]] = [:]
            for source in sources {
                var decoders: [Int: WireState] = [:], messages: [WireEvent] = []
                for event in source.timeline.wireEvents {
                    var decoder = decoders[event.port] ?? WireState()
                    let uid = source.timeline.bindings.first(where: { $0.port == event.port })!.destination
                    let physicalPort = outputs.firstIndex(of: uid)!
                    for bytes in try decoder.feed(event.bytes) { messages.append(WireEvent(seconds: event.seconds, port: physicalPort, bytes: bytes)) }
                    decoders[event.port] = decoder
                }
                sourceMessages[source.id] = messages
            }
            for spec in specifications {
                guard let source = sources.first(where: { $0.id == spec.source }), let messages = sourceMessages[spec.source] else { throw MidiFailure("missing MIDI region source") }
                compiled.append(try MidiRegion(spec: spec, sourceDuration: source.timeline.duration, events: messages))
            }
            regions = compiled
        default: throw MidiFailure("unknown MIDI timeline schema")
        }
    }
    func validate(looping: Bool = false, cycle: MidiCycle? = nil) throws {
        guard duration.isFinite, source ? duration >= 0 : duration > 0,
              duration * 1e9 < Double(UInt64.max) else { throw MidiFailure("invalid MIDI timeline duration") }
        if arrangement {
            guard !regions.isEmpty, regions.allSatisfy({ $0.end <= duration }) else { throw MidiFailure("invalid MIDI arrangement duration") }
            if let cycle { try cycle.validate(timeline: self) } else {
                let obstacles = regions.reduce(into: Set<ChaseObstacle>()) { $0.formUnion($1.obstacles) }
                guard obstacles.isEmpty else { throw MidiFailure("MIDI region reconstruction requires support for " + obstacles.map(\.rawValue).sorted().joined(separator: ", ")) }
                var mutations = Set<ChaseField>()
                if looping { for region in regions { mutations.formUnion(region.endTouched) } }
                for region in regions.sorted(by: { $0.spec.startSeconds < $1.spec.startSeconds }) {
                    let previous = mutations.filter { region.addresses.contains($0.port << 8 | Int($0.channel)) }
                    guard previous.isSubset(of: region.startKnown), region.spec.repeatCount == 1 || region.endTouched.isSubset(of: region.startKnown) else {
                        throw MidiFailure("MIDI region needs an explicit source baseline for previously changed channel fields")
                    }
                    mutations.formUnion(region.endTouched)
                }
            }
            let scopes = try regions.map { try cycle?.window($0).scope ?? $0.addresses }
            for (index, first) in regions.enumerated() {
                let cycleStart = Int64(((cycle?.start ?? 0) * 1e9).rounded())
                let cycleEnd = Int64(((cycle?.end ?? duration) * 1e9).rounded())
                for (other, second) in regions.enumerated().dropFirst(index + 1) where max(first.startNanoseconds, second.startNanoseconds, cycleStart) < min(first.endNanoseconds, second.endNanoseconds, cycleEnd) {
                    guard scopes[index].isDisjoint(with: scopes[other]) else { throw MidiFailure("overlapping MIDI regions own the same destination/channel") }
                }
            }
            return
        }
        var previous = 0.0
        for event in events {
            _ = try event.bytes()
            guard event.seconds >= previous, event.seconds <= duration else { throw MidiFailure("MIDI events must be ordered inside the timeline") }
            previous = event.seconds
        }
        var decoders: [Int: WireState] = [:]
        var destinations = Set<String>()
        for binding in bindings {
            guard binding.port >= 0, binding.port < 128, let uid = Int32(binding.destination), String(uid) == binding.destination,
                  decoders[binding.port] == nil, destinations.insert(binding.destination).inserted else {
                throw MidiFailure("source ports require unique explicit destination bindings")
            }
            decoders[binding.port] = WireState()
        }
        var used = Set<Int>()
        for event in wireEvents {
            guard event.seconds.isFinite, event.seconds >= previous, event.seconds <= duration,
                  !event.bytes.isEmpty, var decoder = decoders[event.port] else {
                throw MidiFailure("invalid or unbound source MIDI wire event")
            }
            _ = try decoder.feed(event.bytes); decoders[event.port] = decoder
            used.insert(event.port); previous = event.seconds
        }
        if source {
            guard !wireEvents.isEmpty, used == Set(bindings.map(\.port)) else { throw MidiFailure("source bindings must match used MIDI ports") }
            for decoder in decoders.values { try decoder.complete() }
        }
    }
}

enum Command: Decodable {
    case pause, resume, seek(Double), status, stop, recordingEpoch(String)
    enum Keys: String, CodingKey { case kind, seconds, request }
    enum Kind: String, Decodable { case pause, resume, seek, status, stop, recordingEpoch }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        if kind != .seek && values.contains(.seconds) { throw MidiFailure("seconds is only valid for seek") }
        switch kind {
        case .pause: self = .pause
        case .resume: self = .resume
        case .seek: self = .seek(try values.decode(Double.self, forKey: .seconds))
        case .status: self = .status
        case .stop: self = .stop
        case .recordingEpoch:
            let request = try values.decode(String.self, forKey: .request)
            guard UUID(uuidString: request) != nil else { throw MidiFailure("invalid recording epoch request") }
            self = .recordingEpoch(request)
        }
    }
}
// The audio owner supplies the same authored rational period used by its PCM
// streams, expressed in nanoseconds. Original MIDI regions remain in project
// time; only the repeating clock is normalized. Deadlines always derive from
// the common epoch, never from the previous (possibly late) callback.
struct MidiCycleRegion {
    let scope: Set<Int>
    let entry: MidiRegionEntry
    let repeated: Bool
    let touched: Set<ChaseField>
}
struct MidiCycle {
    let start: Double, end: Double, duration: Double
    let period: UInt128, divisor: UInt128
    let exactStart: (numerator: UInt128, divisor: UInt128)?
    init(start: Double, end: Double, duration: Double, period: UInt128, divisor: UInt128,
         exactStart: (numerator: UInt128, divisor: UInt128)? = nil) throws {
        guard start.isFinite, start >= 0, end.isFinite, end > start,
              duration.isFinite, duration > 0, duration * 1e9 < Double(UInt64.max),
              divisor > 0, period >= divisor, exactStart == nil || exactStart!.divisor > 0 else { throw MidiFailure("invalid common MIDI cycle") }
        self.start = start; self.end = end; self.duration = duration
        var a = period, b = divisor
        while b > 0 { let remainder = a % b; a = b; b = remainder }
        self.period = period / a; self.divisor = divisor / a
        self.exactStart = exactStart
    }
    private func multiply(_ a: UInt128, _ b: UInt128) throws -> UInt128 {
        let result = a.multipliedReportingOverflow(by: b)
        guard !result.overflow else { throw MidiFailure("common MIDI cycle exceeds the host clock range") }
        return result.partialValue
    }
    private func add(_ a: UInt128, _ b: UInt128) throws -> UInt128 {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow else { throw MidiFailure("common MIDI cycle exceeds the host clock range") }
        return result.partialValue
    }
    private func nanos(_ seconds: Double, up: Bool = false) throws -> UInt128 {
        let value = (seconds * 1e9).rounded(up ? .up : .down)
        guard value.isFinite, value >= 0, value < Double(UInt64.max) else { throw MidiFailure("invalid common MIDI phase") }
        return UInt128(UInt64(value))
    }
    private func base(_ offset: Double) throws -> UInt128 {
        min(period - 1, try multiply(nanos(offset), divisor))
    }
    func phase(elapsed: UInt64, offset: Double) throws -> (index: UInt128, seconds: Double) {
        let parts = try phaseParts(elapsed: elapsed, offset: offset)
        return (parts.index, min(duration.nextDown, Double(parts.remainder) / Double(divisor) / 1e9))
    }
    func phaseParts(elapsed: UInt64, offset: Double) throws -> (index: UInt128, remainder: UInt128) {
        let product = UInt128(elapsed).multipliedFullWidth(by: divisor)
        let low = product.low.addingReportingOverflow(try base(offset))
        let high = product.high.addingReportingOverflow(low.overflow ? 1 : 0)
        guard !high.overflow, high.partialValue < period else { throw MidiFailure("common MIDI phase exceeds the host clock range") }
        let result = period.dividingFullWidth((high: high.partialValue, low: low.partialValue))
        return (result.quotient, result.remainder)
    }
    private func local(_ position: Double) throws -> UInt128 {
        position >= end ? period : min(period, try multiply(nanos(max(0, position - start), up: true), divisor))
    }
    func beforeOffset(position: Double, offset: Double) throws -> Bool { try local(position) < base(offset) }
    func deadline(position: Double, index: UInt128, offset: Double, anchor: UInt64) throws -> UInt64 {
        let target = try add(multiply(index, period), local(position)), initial = try base(offset)
        let distance = target > initial ? target - initial : 0
        let delay = distance / divisor + (distance % divisor == 0 ? 0 : 1)
        guard delay <= UInt128(UInt64.max - anchor) else { throw MidiFailure("common MIDI deadline exceeds the host clock range") }
        return anchor + UInt64(delay)
    }
    func validate(timeline: Timeline) throws {
        guard timeline.arrangement, !timeline.regions.isEmpty,
              timeline.regions.allSatisfy({ $0.end > start && $0.spec.startSeconds < end }) else {
            throw MidiFailure("common cycle requires intersecting original MIDI regions")
        }
        let windows = try timeline.regions.map { try window($0) }
        let mutations = windows.reduce(into: Set<ChaseField>()) { $0.formUnion($1.touched) }
        for (region, window) in zip(timeline.regions, windows) {
            let previous = mutations.filter { window.scope.contains($0.port << 8 | Int($0.channel)) }
            guard previous.isSubset(of: window.entry.safeKnown), !window.repeated || previous.isSubset(of: region.startKnown) else {
                throw MidiFailure("common cycle needs an explicit source baseline before sounding keys")
            }
        }
    }
    func entry(_ region: MidiRegion, copy: Int, sourceSeconds: Double, index: UInt128,
               offset: Double, anchor: UInt64, host: UInt64) throws -> MidiRegionEntry {
        let start = region.spec.startSeconds + Double(copy) * region.duration
        var before = 0, through = 0
        for event in region.events {
            let position = start + (event.seconds - region.spec.sourceStart)
            let endpoint = event.seconds == region.spec.sourceEnd && region.spec.sourceEnd == region.sourceDuration
            guard region.includes(event.seconds), position < end || endpoint && position == end else { break }
            // Original trim/window prefixes are history even when their
            // clamped deadline equals the first common epoch. For actual
            // sounding events, classify the whole native host-deadline batch.
            let beforeEntry = index == 0 ? try beforeOffset(position: position, offset: offset) : false
            let history = event.seconds < region.spec.sourceStart || position < self.start || beforeEntry
            let deadline = try deadline(position: position, index: index, offset: offset, anchor: anchor)
            if history || deadline < host { before += 1; through += 1 }
            else if deadline == host { through += 1 }
            else { break }
        }
        return midiRegionEntry(region.events, at: sourceSeconds, boundary: (before, through))
    }
    func window(_ region: MidiRegion) throws -> MidiCycleRegion {
        let from = max(start, region.spec.startSeconds), to = min(end, region.end)
        var copy = min(region.spec.repeatCount - 1, max(0, Int(floor((from - region.spec.startSeconds) / region.duration))))
        func position(_ value: Int) -> Double { region.spec.startSeconds + Double(value) * region.duration }
        if position(copy) > from { copy -= 1 }
        if copy + 1 < region.spec.repeatCount && position(copy + 1) <= from { copy += 1 }
        guard copy >= 0, position(copy) <= from, position(copy + 1) > from else { throw MidiFailure("common MIDI source loses repeat precision") }
        let source = min(region.spec.sourceEnd, region.spec.sourceStart + (from - position(copy)))
        let repeated = to > position(copy + 1)
        let host = try deadline(position: from, index: 0, offset: 0, anchor: 0)
        let entry = try entry(region, copy: copy, sourceSeconds: source, index: 0, offset: 0, anchor: 0, host: host)
        // Use the same original-position and native-deadline classification as
        // playback. Inverting a rounded source phase can swallow a due pair.
        var scope = Set(try entry.model.bootstrap(replacing: SourceChase()).map { $0.0 << 8 | Int($0.1[0] & 15) })
        var through = entry.next
        if repeated {
            let restart = midiRegionEntry(region.events, at: region.spec.sourceStart)
            scope.formUnion(try restart.model.bootstrap(replacing: SourceChase()).map { $0.0 << 8 | Int($0.1[0] & 15) })
        }
        for (eventIndex, event) in region.events.enumerated() where event.seconds >= region.spec.sourceStart && region.includes(event.seconds) {
            let absolute = position(copy) + (event.seconds - region.spec.sourceStart)
            let nativeDeadline = try deadline(position: absolute, index: 0, offset: 0, anchor: 0)
            let endpoint = event.seconds == region.spec.sourceEnd && region.spec.sourceEnd == region.sourceDuration
            let first = absolute >= start && (absolute < to || endpoint && absolute == to)
                && nativeDeadline >= host
            let laterPosition = position(copy + 1) + (event.seconds - region.spec.sourceStart)
            let later = repeated && (laterPosition < to || endpoint && laterPosition == to)
            if first || later {
                through = max(through, eventIndex + 1)
                if event.bytes[0] < 0xf0 { scope.insert(event.port << 8 | Int(event.bytes[0] & 15)) }
            }
        }
        var touched = SourceChase()
        for event in region.events.prefix(through) { touched.observe(event.bytes, port: event.port) }
        guard touched.obstacles.isEmpty else { throw MidiFailure("common MIDI reconstruction requires support for " + touched.obstacles.map(\.rawValue).sorted().joined(separator: ", ")) }
        return MidiCycleRegion(scope: scope, entry: entry, repeated: repeated, touched: touched.touched)
    }
}

final class MidiTransport {
    enum State { case prepared, playing, paused, stopped }
    let timeline: Timeline
    let selectedUID: String
    let loop: Bool
    let queue: DispatchQueue
    let groupZeroUMP: Bool
    let coordinated: Bool
    let cycle: MidiCycle?
    let regionScopes: [Set<Int>]
    var cycleIndex: UInt128 = 0
    var cycleHost: UInt64?
    var cycleLive: [Int: (copy: Int, attacks: Set<Int>)] = [:]
    var cycleAcquired: [Int: Set<Int>] = [:]
    var onCoordinatedFailure: ((String, Error?) -> Void)?
    var onCoordinatedEnd: (() -> Void)?
    var terminalFailure: Error?
    var pendingRestore = false
    var destination: Destination?
    var prepared = false // admission and resources belong to queue
    var client = MIDIClientRef(), port = MIDIPortRef()
    var state = State.prepared
    var timer: DispatchSourceTimer?
    var signals: [DispatchSourceSignal] = []
    var anchor: UInt64 = 0, offset = 0.0, index = 0
    var held: [UInt16: Event] = [:]
    var maximumLateness = 0.0
    var sourceDestinations: [Int: Destination] = [:], wireStates: [Int: WireState] = [:]
    var sourceModel = SourceChase()
    var regionCursors: [MidiRegionCursor] = []
    var sourceExclusive = Set<Int>()
    var sourceHeld: [Int: [UInt16: Int]] = [:], sourcePedals: [Int: Set<UInt16>] = [:]

    convenience init(path: String, uid: String, loop: Bool) throws {
        let timeline = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try self.init(timeline: timeline, uid: uid, loop: loop)
    }
    init(timeline: Timeline, uid: String, loop: Bool = false, coordinated: Bool = false, groupZeroUMP: Bool = false, cycle: MidiCycle? = nil) throws {
        self.timeline = timeline; self.coordinated = coordinated; self.groupZeroUMP = groupZeroUMP
        queue = coordinated ? .main : DispatchQueue(label: "masc.music.midi.transport", qos: .userInteractive)
        try timeline.validate(looping: loop && cycle == nil, cycle: cycle)
        guard !coordinated || timeline.arrangement else { throw MidiFailure("coordinated playback requires a MIDI region arrangement") }
        if timeline.source {
            guard timeline.arrangement || !loop else { throw MidiFailure("source audition plays once; loop state reconstruction is not connected") }
            guard timeline.bindings.first?.destination == uid else { throw MidiFailure("primary source destination differs from explicit bindings") }
        }
        guard let value = Int32(uid), String(value) == uid else { throw MidiFailure("MIDI destination requires its exact unique ID") }
        guard cycle == nil || coordinated && loop else { throw MidiFailure("a shared cycle requires coordinated MIDI looping") }
        guard !coordinated || !loop || cycle != nil else { throw MidiFailure("coordinated MIDI looping requires the authored common clock") }
        self.cycle = cycle
        regionScopes = try timeline.regions.map { try cycle?.window($0).scope ?? $0.addresses }
        selectedUID = uid; self.loop = loop
        regionCursors = timeline.regions.map { _ in MidiRegionCursor() }
    }
    // CoreMIDI's client is created on the main run loop. Transfer its ownership
    // before admitting notifications; resource selection and mutation use queue.
    func prepare() throws {
        guard Thread.isMainThread else { throw MidiFailure("MIDI preparation requires the main run loop") }
        var createdClient = MIDIClientRef()
        try checked(MIDIClientCreateWithBlock("MASC phrase output" as CFString, &createdClient, { [weak self] _ in
            self?.queue.async { [weak self] in self?.destinationChanged() }
        }), "create MIDI client")
        func admit() throws {
            client = createdClient
            do {
                destination = try selectedDestination(uid: selectedUID)
                for binding in timeline.bindings {
                    sourceDestinations[binding.port] = try selectedDestination(uid: binding.destination)
                    wireStates[binding.port] = WireState()
                }
                try checked(MIDIOutputPortCreate(client, "MASC phrase output" as CFString, &port), "create MIDI output port")
                try checkDestination()
                prepared = true
            } catch {
                if port != 0 { MIDIPortDispose(port); port = 0 }
                if client != 0 { MIDIClientDispose(client); client = 0 }
                destination = nil
                throw error
            }
        }
        if coordinated { try admit() } else { try queue.sync(execute: admit) }
    }
    func destinationChanged() {
        guard prepared, state != .stopped else { return }
        do { try checkDestination() }
        catch { finish(reason: "destination-unavailable", error: error) }
    }
    func checkDestination() throws {
        guard let destination else { throw MidiFailure("MIDI destination has not been selected") }
        for selected in timeline.source ? Array(sourceDestinations.values) : [destination] {
            try checkPinnedDestination(selected)
            if groupZeroUMP {
                var groups: Int32 = 0
                let status = MIDIObjectGetIntegerProperty(selected.endpoint, kMIDIPropertyUMPActiveGroupBitmap, &groups)
                if status == noErr && groups & 1 == 0 { throw MidiFailure("selected hybrid SMF output does not support explicit group zero") }
                if status != noErr && status != kMIDIUnknownProperty { try checked(status, "read hybrid SMF output groups") }
            }
        }
    }
    func send(_ bytes: [UInt8]) throws {
        guard let destination else { throw MidiFailure("MIDI destination has not been selected") }
        try sendWire(bytes, to: destination)
    }
    func sendWire(_ bytes: [UInt8], to destination: Destination) throws {
        if groupZeroUMP {
            guard let status = bytes.first, status >= 0x80, status < 0xf0,
                  bytes.count == ([0xc0, 0xd0].contains(status & 0xf0) ? 2 : 3), bytes.dropFirst().allSatisfy({ $0 < 128 }) else {
                throw MidiFailure("hybrid SMF requires complete MIDI1 channel messages")
            }
            // MIDI1 UMP retains the exact channel/data bytes with explicit
            // group zero. CoreMIDI performs native endpoint protocol delivery.
            var word = UInt32(0x20000000) | UInt32(status) << 16 | UInt32(bytes[1]) << 8
            if bytes.count == 3 { word |= UInt32(bytes[2]) }
            let capacity = MemoryLayout<MIDIEventList>.size
            let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<MIDIEventList>.alignment)
            defer { storage.deallocate() }
            let list = storage.assumingMemoryBound(to: MIDIEventList.self), packet = MIDIEventListInit(list, ._1_0)
            try withUnsafePointer(to: &word) { data in
                let added = MIDIEventListAdd(list, capacity, packet, 0, 1, data)
                guard UInt(bitPattern: added) != 0 else { throw MidiFailure("hybrid MIDI1 UMP does not fit its event list") }
                try checked(MIDISendEventList(port, destination.endpoint, list), "send hybrid SMF MIDI1 UMP")
            }
            return
        }
        // Apple limits each MIDIPacketList to 65536 bytes. Include actual ABI
        // header offsets, check every Add result, split only long SysEx data.
        let capacity = 65536
        let overhead = MemoryLayout<MIDIPacketList>.offset(of: \.packet)! + MemoryLayout<MIDIPacket>.offset(of: \.data)!
        let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: MIDIPacketList.self)
        var offset = 0
        while offset < bytes.count {
            let count = min(capacity - overhead, bytes.count - offset)
            let packet = MIDIPacketListInit(list)
            try bytes.withUnsafeBufferPointer { data in
                let added = MIDIPacketListAdd(list, capacity, packet, 0, count, data.baseAddress!.advanced(by: offset))
                guard UInt(bitPattern: added) != 0 else {
                    throw MidiFailure("MIDI packet list could not hold source bytes")
                }
                // Due messages only: no future shared-port work survives stop.
                try checked(MIDISend(port, destination.endpoint, list), "send MIDI event")
            }
            offset += count
        }
    }
    func sourceApply(_ event: WireEvent) throws {
        guard var decoder = wireStates[event.port] else {
            throw MidiFailure("source MIDI port is not prepared")
        }
        let messages = try decoder.feed(event.bytes)
        // Keep decoder progress even if the endpoint fails mid-fragment, so
        // cleanup closes an exclusive stream before sending channel note-offs.
        wireStates[event.port] = decoder
        for bytes in messages {
            sourceModel.observe(bytes, port: event.port)
            try sourceSend(bytes, port: event.port)
        }
    }
    func sourceSend(_ bytes: [UInt8], port sourcePort: Int) throws {
        guard let destination = sourceDestinations[sourcePort] else { throw MidiFailure("source MIDI port is not prepared") }
        // Acquire ownership before sending: a failed OSStatus cannot prove
        // that the endpoint did not receive a note or pedal-on. Release it
        // only after success, so failure cleanup retries uncertain releases.
        if let status = bytes.first {
            let channel = UInt16(status & 15), type = status & 0xf0
            if bytes.count == 3 && type == 0x90 && bytes[2] > 0 {
                let key = channel << 8 | UInt16(bytes[1]), count = sourceHeld[sourcePort]?[key] ?? 0
                sourceHeld[sourcePort, default: [:]][key] = count + 1
            } else if bytes.count == 3 && type == 0xb0 && [64, 66, 69].contains(bytes[1]) && bytes[2] >= 64 {
                sourcePedals[sourcePort, default: []].insert(channel << 8 | UInt16(bytes[1]))
            }
        }
        if bytes.first == 0xf0 { sourceExclusive.insert(sourcePort) }
        try sendWire(bytes, to: destination)
        if let status = bytes.first {
            let channel = UInt16(status & 15), type = status & 0xf0
            if status == 0xff { sourceHeld[sourcePort] = [:]; sourcePedals[sourcePort] = [] }
            else if bytes.count == 3 && (type == 0x80 || type == 0x90 && bytes[2] == 0) {
                let key = channel << 8 | UInt16(bytes[1]), count = sourceHeld[sourcePort]?[key] ?? 0
                sourceHeld[sourcePort, default: [:]][key] = max(0, count - 1)
            } else if bytes.count == 3 && type == 0xb0 {
                let controller = bytes[1], key = channel << 8 | UInt16(controller)
                if [64, 66, 69].contains(controller) && bytes[2] < 64 { sourcePedals[sourcePort]?.remove(key) }
                if controller == 121 { sourcePedals[sourcePort] = (sourcePedals[sourcePort] ?? []).filter { $0 >> 8 != channel } }
                if [120, 123, 124, 125, 126, 127].contains(controller) {
                    sourceHeld[sourcePort] = (sourceHeld[sourcePort] ?? [:]).filter { $0.key >> 8 != channel }
                }
            }
        }
        if bytes.contains(0xf7) { sourceExclusive.remove(sourcePort) }
    }
    func sourceSilence(addresses: Set<Int>? = nil) throws {
        var failure: Error?
        for binding in timeline.bindings {
            guard sourceDestinations[binding.port] != nil else { continue }
            var messages: [[UInt8]] = []
            if sourceExclusive.contains(binding.port) { messages.append([0xf7]) }
            for (key, count) in (sourceHeld[binding.port] ?? [:]).sorted(by: { $0.key < $1.key }) where addresses == nil || addresses!.contains(binding.port << 8 | Int(key >> 8)) {
                for _ in 0..<count { messages.append([0x80 | UInt8(key >> 8), UInt8(key & 127), 0]) }
            }
            for key in (sourcePedals[binding.port] ?? []).sorted() where addresses == nil || addresses!.contains(binding.port << 8 | Int(key >> 8)) {
                messages.append([0xb0 | UInt8(key >> 8), UInt8(key & 127), 0])
            }
            // sourceSend retains uncertain ownership on failure and releases only
            // successfully sent note-offs, pedal-offs and exclusive terminators.
            for bytes in messages { do { try sourceSend(bytes, port: binding.port) } catch { failure = failure ?? error } }
        }
        if let failure { throw failure }
        if let addresses { for address in addresses { cycleAcquired.removeValue(forKey: address) } }
        else { cycleAcquired.removeAll() }
    }
    func apply(_ event: Event) throws {
        // A failed send cannot prove the destination missed the Note On, so the
        // key is owned before sending. It is released only after a sent Note Off.
        if event.kind == .on { held[event.key] = event }
        try send(event.bytes())
        if event.kind == .off { held.removeValue(forKey: event.key) }
    }
    func silence() throws {
        if timeline.source { try sourceSilence(); return }
        var failure: Error?
        for event in held.values.sorted(by: { $0.key < $1.key }) {
            do {
                try send([0x80 | event.channel, event.pitch!, 0])
                held.removeValue(forKey: event.key)
            } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }
    func restore(at seconds: Double) throws {
        try reconcile(at: seconds, reconstruct: true)
    }
    func reconcile(at seconds: Double, reconstruct: Bool = false, observedAt: Double? = nil) throws {
        if timeline.arrangement { try reconcileRegions(at: seconds, reconstruct: reconstruct, observedAt: observedAt); return }
        if timeline.source {
            if reconstruct {
                var model = SourceChase(), decoders = Dictionary(uniqueKeysWithValues: timeline.bindings.map { ($0.port, WireState()) })
                var next = 0
                while next < timeline.wireEvents.count && timeline.wireEvents[next].seconds <= seconds {
                    let event = timeline.wireEvents[next]
                    guard var decoder = decoders[event.port] else { throw MidiFailure("source MIDI port is not prepared") }
                    for bytes in try decoder.feed(event.bytes) { model.observe(bytes, port: event.port) }
                    decoders[event.port] = decoder; next += 1
                }
                for (sourcePort, bytes) in try model.bootstrap(replacing: sourceModel) { try sourceSend(bytes, port: sourcePort) }
                sourceModel = model; wireStates = decoders; index = next
                return
            }
            // Expression, zero-length notes, note-off velocity and SysEx are an
            // ordered stream. Never reduce late source events to held-key state.
            while index < timeline.wireEvents.count && timeline.wireEvents[index].seconds <= seconds {
                try sourceApply(timeline.wireEvents[index]); index += 1
            }
            return
        }
        var programs: [UInt8: Event] = [:], controls: [UInt16: Event] = [:]
        var notes = reconstruct ? [:] : held
        if reconstruct { index = 0 }
        // Consume the complete target boundary before emitting. A fully expired
        // note interval must not be replayed when the deadline queue wakes late.
        while index < timeline.events.count && timeline.events[index].seconds <= seconds {
            let event = timeline.events[index]
            switch event.kind {
            case .program: programs[event.channel] = event
            case .control: controls[event.key] = event
            case .on: notes[event.key] = event
            case .off: notes.removeValue(forKey: event.key)
            }
            index += 1
        }
        for event in programs.values.sorted(by: { $0.channel < $1.channel }) { try apply(event) }
        for event in controls.values.sorted(by: { $0.key < $1.key }) { try apply(event) }
        for event in held.values.sorted(by: { $0.key < $1.key }) where notes[event.key] != event {
            try send([0x80 | event.channel, event.pitch!, 0])
            held.removeValue(forKey: event.key)
        }
        for event in notes.values.sorted(by: { $0.key < $1.key }) where held[event.key] != event { try apply(event) }
    }
    func regionStart(_ region: MidiRegion, copy: Int) -> Double { region.startSeconds(copy: copy) }
    func nextRegionAction() -> MidiRegionAction? {
        var selected: MidiRegionAction?
        for (index, region) in timeline.regions.enumerated() {
            let cursor = regionCursors[index]
            guard cursor.copy < region.spec.repeatCount else { continue }
            let start = regionStart(region, copy: cursor.copy)
            let action: MidiRegionAction
            if !cursor.active { action = MidiRegionAction(seconds: start, region: index, kind: .begin) }
            else if cursor.index < region.events.count && region.includes(region.events[cursor.index].seconds) {
                let event = region.events[cursor.index]
                action = MidiRegionAction(seconds: start + (event.seconds - region.spec.sourceStart), region: index,
                                          kind: event.seconds == region.spec.sourceEnd ? .endpointEvent : .event)
            } else { action = MidiRegionAction(seconds: region.startSeconds(copy: cursor.copy + 1), region: index, kind: .end) }
            if selected == nil || action.seconds < selected!.seconds
                || action.seconds == selected!.seconds && (action.kind.rawValue < selected!.kind.rawValue
                    || action.kind == selected!.kind && action.region < selected!.region) { selected = action }
        }
        return selected
    }
    func regionEntry(_ index: Int, at sourceSeconds: Double) throws -> MidiRegionEntry {
        let region = timeline.regions[index]
        guard let cycle, let host = cycleHost else { return midiRegionEntry(region.events, at: sourceSeconds) }
        return try cycle.entry(region, copy: regionCursors[index].copy, sourceSeconds: sourceSeconds,
                               index: cycleIndex, offset: offset - cycle.start, anchor: anchor, host: host)
    }
    func liveRegionAttacks(_ index: Int) throws -> Set<Int> {
        let copy = regionCursors[index].copy
        if let cached = cycleLive[index], cached.copy == copy { return cached.attacks }
        let entry = try regionEntry(index, at: timeline.regions[index].spec.sourceStart)
        let attacks = Set(entry.model.channels.values.flatMap { $0.notes.compactMap(\.origin) })
        cycleLive[index] = (copy, attacks)
        return attacks
    }
    func regionActionDue(_ action: MidiRegionAction, at seconds: Double, cut: Double?) throws -> Bool {
        if cut == nil, let cycle, let host = cycleHost {
            guard action.seconds < cycle.end else { return false }
            return try cycle.deadline(position: action.seconds, index: cycleIndex, offset: offset - cycle.start, anchor: anchor) <= host
        }
        return action.seconds <= seconds
    }
    func beginRegion(_ index: Int, at sourceSeconds: Double, notes: Bool = true) throws {
        let entry = try regionEntry(index, at: sourceSeconds), prefix = entry.model.scoped(to: regionScopes[index]), next = entry.next
        let prior = sourceModel.scoped(to: regionScopes[index])
        guard prior.touched.isSubset(of: entry.safeKnown) else { throw MidiFailure("MIDI region seek needs a source baseline before sounding keys on a previously changed channel") }
        var permitted = prior; permitted.touched.formIntersection(prefix.known)
        for (port, bytes) in try prefix.bootstrap(replacing: permitted, notes: notes) { try sourceSend(bytes, port: port) }
        if cycle != nil {
            for address in regionScopes[index] {
                cycleAcquired[address] = Set((prefix.channels[address]?.notes ?? []).filter(\.held).compactMap(\.origin))
            }
        }
        sourceModel.replace(prefix, addresses: regionScopes[index])
        regionCursors[index].active = true; regionCursors[index].index = next
    }
    func applyCycleEvent(_ event: WireEvent, origin: Int, attackAllowed: Bool) throws {
        let type = event.bytes[0] & 0xf0, address = event.port << 8 | Int(event.bytes[0] & 15)
        let attack = type == 0x90 && event.bytes[2] > 0
        let release = type == 0x80 || type == 0x90 && event.bytes[2] == 0
        let released = release ? sourceModel.channels[address]?.notes.first(where: { $0.pitch == event.bytes[1] && $0.held })?.origin : nil
        sourceModel.observe(event.bytes, port: event.port, origin: origin)
        if attack && !attackAllowed { return }
        if release && !(released.map { cycleAcquired[address]?.contains($0) == true } ?? false) { return }
        if attack { cycleAcquired[address, default: []].insert(origin) }
        try sourceSend(event.bytes, port: event.port)
        if let released, release { cycleAcquired[address]?.remove(released) }
    }
    func reconcileRegions(at seconds: Double, reconstruct: Bool, observedAt: Double? = nil, cut: Double? = nil) throws {
        if !reconstruct {
            // Drain at most the one already active copy. Entirely missed copies
            // are not audible history: skip them arithmetically to the live phase.
            // This keeps short finite repeats from monopolizing the owner queue.
            var phaseEntries: [(Int, Double)] = []
            for (index, region) in timeline.regions.enumerated() {
                let old = regionCursors[index]
                guard old.copy < region.spec.repeatCount,
                      seconds >= regionStart(region, copy: old.copy) + region.duration else { continue }
                if let cycle, let host = cycleHost,
                   try cycle.deadline(position: regionStart(region, copy: old.copy) + region.duration,
                                      index: cycleIndex, offset: offset - cycle.start, anchor: anchor) >= host {
                    // A copy that ends in this native batch is still an
                    // ordered stream, even when its virtual end is earlier
                    // than the observed fractional phase. Drain it below.
                    continue
                }
                var copy = seconds >= region.end ? region.spec.repeatCount
                    : min(region.spec.repeatCount - 1, max(0, Int(floor((seconds - region.spec.startSeconds) / region.duration))))
                if let cycle, let host = cycleHost {
                    // The latest virtual copy is not necessarily the first
                    // copy in this integer host batch. Locate its earliest
                    // intersecting end without visiting expired copies.
                    var low = old.copy, high = copy
                    while low < high {
                        let middle = low + (high - low) / 2
                        let end = regionStart(region, copy: middle) + region.duration
                        if try cycle.deadline(position: end, index: cycleIndex,
                            offset: offset - cycle.start, anchor: anchor) < host { low = middle + 1 }
                        else { high = middle }
                    }
                    copy = low
                }
                guard copy > old.copy else { continue }
                if old.active {
                    while regionCursors[index].index < region.events.count && region.includes(region.events[regionCursors[index].index].seconds) {
                        let event = region.events[regionCursors[index].index]
                        // Past attacks belong to an expired loop copy.
                        // Shared cycles match releases to the original source
                        // FIFO identity, including when older attacks were
                        // skipped. Ordered expression/pedal history and
                        // uncertain-send cleanup ownership remain intact.
                        let type = event.bytes[0] & 0xf0
                        let attack = type == 0x90 && event.bytes[2] > 0
                        let release = type == 0x80 || type == 0x90 && event.bytes[2] == 0
                        let key = UInt16(event.bytes[0] & 15) << 8 | UInt16(event.bytes[1])
                        let deadline = regionStart(region, copy: old.copy) + (event.seconds - region.spec.sourceStart)
                        let expired: Bool
                        if let cycle, let host = cycleHost {
                            expired = try cycle.deadline(position: deadline, index: cycleIndex,
                                offset: offset - cycle.start, anchor: anchor) < host
                        } else { expired = loop && deadline < (observedAt ?? seconds) }
                        if cycle != nil {
                            try applyCycleEvent(event, origin: regionCursors[index].index, attackAllowed: !expired)
                        } else {
                            sourceModel.observe(event.bytes, port: event.port)
                            if !loop || (attack ? !expired : !release || (sourceHeld[event.port]?[key] ?? 0) > 0) {
                                try sourceSend(event.bytes, port: event.port)
                            }
                        }
                        regionCursors[index].index += 1
                    }
                    try sourceSilence(addresses: regionScopes[index])
                    for address in regionScopes[index] { sourceModel.channels[address]?.notes.removeAll() }
                }
                regionCursors[index] = MidiRegionCursor(copy: copy)
                if cut == nil && copy < region.spec.repeatCount && !(old.active && copy == old.copy + 1) {
                    let source = region.spec.sourceStart + (seconds - regionStart(region, copy: copy))
                    phaseEntries.append((index, min(source, region.spec.sourceEnd)))
                }
            }
            // Every expired owner is silent before any new owner starts.
            for (index, source) in phaseEntries { try beginRegion(index, at: source) }
        }
        if reconstruct {
            regionCursors = timeline.regions.map { region in
                if seconds >= region.end { return MidiRegionCursor(copy: region.spec.repeatCount) }
                if seconds < region.spec.startSeconds { return MidiRegionCursor() }
                let copy = min(region.spec.repeatCount - 1, max(0, Int(floor((seconds - region.spec.startSeconds) / region.duration))))
                return MidiRegionCursor(copy: copy)
            }
            for (index, region) in timeline.regions.enumerated() where seconds >= region.spec.startSeconds && seconds < region.end {
                let source = region.spec.sourceStart + (seconds - regionStart(region, copy: regionCursors[index].copy))
                try beginRegion(index, at: min(source, region.spec.sourceEnd))
            }
        }
        while let action = nextRegionAction(), try regionActionDue(action, at: seconds, cut: cut) {
            let region = timeline.regions[action.region]
            switch action.kind {
            case .begin:
                if let cut, cycle == nil || action.seconds >= cut { regionCursors[action.region] = MidiRegionCursor(copy: region.spec.repeatCount) }
                else { try beginRegion(action.region, at: region.spec.sourceStart, notes: false) }
            case .end:
                try sourceSilence(addresses: regionScopes[action.region])
                for address in regionScopes[action.region] { sourceModel.channels[address]?.notes.removeAll() }
                regionCursors[action.region].active = false; regionCursors[action.region].copy += 1
            case .event, .endpointEvent:
                let event = region.events[regionCursors[action.region].index]
                if cut == nil || action.seconds < cut! || action.kind == .endpointEvent {
                    let type = event.bytes[0] & 0xf0
                    let attack = type == 0x90 && event.bytes[2] > 0
                    let release = type == 0x80 || type == 0x90 && event.bytes[2] == 0
                    let key = UInt16(event.bytes[0] & 15) << 8 | UInt16(event.bytes[1])
                    var send = true
                    if cycle != nil {
                        if let cycle, let host = cycleHost {
                            let deadline = try cycle.deadline(position: action.seconds, index: cycleIndex, offset: offset - cycle.start, anchor: anchor)
                            if attack && deadline < host {
                                send = cut == nil ? try liveRegionAttacks(action.region).contains(regionCursors[action.region].index) : false
                            }
                        }
                        try applyCycleEvent(event, origin: regionCursors[action.region].index, attackAllowed: send)
                    } else {
                        sourceModel.observe(event.bytes, port: event.port)
                        if cut != nil { send = attack ? action.seconds >= (observedAt ?? seconds) : !release || (sourceHeld[event.port]?[key] ?? 0) > 0 }
                        if send { try sourceSend(event.bytes, port: event.port) }
                    }
                }
                regionCursors[action.region].index += 1
            }
        }
    }
    func position(at host: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Double {
        guard state == .playing else { return offset }
        return offset + (host > anchor ? Double(host - anchor) / 1e9 : 0)
    }
    func restorePending(at seconds: Double) throws {
        guard timeline.arrangement else { try restore(at: offset); return }
        regionCursors = timeline.regions.map { region in
            if offset >= region.end { return MidiRegionCursor(copy: region.spec.repeatCount) }
            if offset < region.spec.startSeconds { return MidiRegionCursor() }
            let copy = min(region.spec.repeatCount - 1, max(0, Int(floor((offset - region.spec.startSeconds) / region.duration))))
            return MidiRegionCursor(copy: copy)
        }
        for (index, region) in timeline.regions.enumerated() where offset >= region.spec.startSeconds && offset < region.end {
            let start = regionStart(region, copy: regionCursors[index].copy)
            // A delayed common-epoch callback must not make an expired initial
            // copy audible. Reconciliation skips it to the current phase. Keep
            // the original boundary stream for copies that are still live.
            guard seconds < start + region.duration else { continue }
            let source = region.spec.sourceStart + (offset - start)
            try beginRegion(index, at: min(source, region.spec.sourceEnd))
        }
    }
    func schedule() throws {
        timer?.cancel(); timer = nil
        guard state == .playing else { return }
        let next = pendingRestore ? offset : timeline.arrangement ? (nextRegionAction()?.seconds ?? timeline.duration) : timeline.source ? (index < timeline.wireEvents.count ? timeline.wireEvents[index].seconds : timeline.duration)
            : (index < timeline.events.count ? timeline.events[index].seconds : timeline.duration)
        let delay = max(0, next - offset) * 1e9
        if let cycle {
            let target = pendingRestore ? offset : min(nextRegionAction()?.seconds ?? cycle.end, cycle.end)
            let deadline = try cycle.deadline(position: target, index: cycleIndex, offset: offset - cycle.start, anchor: anchor)
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline), leeway: .nanoseconds(0))
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume(); timer = source; return
        }
        guard delay < Double(UInt64.max) else { throw MidiFailure("MIDI event exceeds the host clock range") }
        let (deadline, overflow) = anchor.addingReportingOverflow(UInt64(delay))
        guard !overflow, deadline < UInt64.max else { throw MidiFailure("MIDI event exceeds the host clock range") }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline), leeway: .nanoseconds(0))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume(); timer = source
    }
    func tick() {
        guard state == .playing else { return }
        do {
            let host = DispatchTime.now().uptimeNanoseconds
            if coordinated && host < anchor { try schedule(); return }
            if let cycle {
                cycleHost = host; cycleLive.removeAll(); defer { cycleHost = nil; cycleLive.removeAll() }
                let phase = try cycle.phase(elapsed: host > anchor ? host - anchor : 0, offset: offset - cycle.start)
                let now = min(cycle.end.nextDown, cycle.start + phase.seconds)
                if phase.index != cycleIndex {
                    pendingRestore = false
                    try reconcileRegions(at: cycle.end, reconstruct: false, cut: cycle.end)
                    try silence(); cycleIndex = phase.index
                    try restore(at: now)
                } else {
                    if pendingRestore {
                        pendingRestore = false
                        // Entry is a phase reconstruction, not audible history.
                        // A late first/resume callback must not replay notes
                        // whose complete lifetime preceded the current phase.
                        try restore(at: now)
                    } else { try reconcileRegions(at: now, reconstruct: false) }
                }
                try schedule(); return
            }
            let now = position(at: host)
            if pendingRestore { pendingRestore = false; try restorePending(at: now) }
            let next = pendingRestore ? offset : timeline.arrangement ? (nextRegionAction()?.seconds ?? timeline.duration) : timeline.source ? (index < timeline.wireEvents.count ? timeline.wireEvents[index].seconds : now)
                : (index < timeline.events.count ? timeline.events[index].seconds : now)
            maximumLateness = max(maximumLateness, now - next)
            if timeline.source { try reconcile(at: min(now, timeline.duration), observedAt: now) }
            if now >= timeline.duration {
                if coordinated {
                    offset = timeline.duration; state = .paused; timer?.cancel(); timer = nil
                    try silence(); onCoordinatedEnd?(); return
                }
                if !loop { offset = timeline.duration; finish(reason: "finished"); return }
                // Resolve phase before replaying any pending events. Keep the
                // same host sample so cleanup/restoration time remains elapsed.
                offset = now.truncatingRemainder(dividingBy: timeline.duration)
                anchor = host
                try silence()
                try restore(at: offset)
            } else { try reconcile(at: now) }
            try schedule()
        } catch { finish(reason: "playback-failed", error: error) }
    }
    // The audio owner invokes these only on the main lifecycle. No MIDI is
    // sent by admission/staging; restoration is deferred to the common epoch.
    func stageCoordinated(at seconds: Double) throws {
        guard coordinated, Thread.isMainThread, prepared, state != .stopped,
              seconds.isFinite, seconds >= 0, seconds < (cycle?.duration ?? timeline.duration) else { throw MidiFailure("invalid coordinated MIDI position or owner") }
        timer?.cancel(); timer = nil; state = .paused; pendingRestore = false
        try checkDestination(); try silence(); cycleIndex = 0
        let seconds = seconds + (cycle?.start ?? 0)
        offset = seconds
        for (index, region) in timeline.regions.enumerated() where seconds >= region.spec.startSeconds && seconds < region.end {
            let copy = min(region.spec.repeatCount - 1, max(0, Int(floor((seconds - region.spec.startSeconds) / region.duration))))
            let source = min(region.spec.sourceEnd, region.spec.sourceStart + seconds - regionStart(region, copy: copy))
            let entry = midiRegionEntry(region.events, at: source), previous = sourceModel.scoped(to: regionScopes[index])
            guard previous.touched.isSubset(of: entry.safeKnown) else { throw MidiFailure("coordinated MIDI seek needs a known source baseline before sounding keys") }
            var permitted = previous; permitted.touched.formIntersection(entry.model.known)
            _ = try entry.model.bootstrap(replacing: permitted)
        }
    }
    func runCoordinated(anchorNanoseconds: UInt64) throws {
        guard coordinated, Thread.isMainThread, prepared, state == .paused,
              anchorNanoseconds > DispatchTime.now().uptimeNanoseconds else { throw MidiFailure("coordinated MIDI missed its common start deadline") }
        try checkDestination()
        anchor = anchorNanoseconds; pendingRestore = true; state = .playing
        try schedule()
    }
    func start() {
        guard prepared, state == .prepared else { return }
        do {
            try checkDestination()
            for number in [SIGINT, SIGTERM, SIGHUP] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
                source.setEventHandler { [weak self] in self?.finish(reason: "signal") }
                source.resume(); signals.append(source)
            }
            anchor = DispatchTime.now().uptimeNanoseconds; state = .playing
            if timeline.source { publish() }
            tick(); publish()
        } catch { finish(reason: "start-failed", error: error) }
    }
    func publish() {
        guard !coordinated, state != .stopped else { return }
        do { try emit(snapshot(state == .playing ? "playing" : "paused")) }
        catch { finish(reason: "event-output-failed", error: error, publish: false) }
    }
    func snapshot(_ kind: String) -> [String: Any] {
        let elapsed = position()
        let current = loop ? elapsed.truncatingRemainder(dividingBy: timeline.duration) : min(elapsed, timeline.duration)
        var value: [String: Any] = ["kind": kind, "currentTime": current, "duration": timeline.duration,
                                  "loop": loop, "maximumLateness": maximumLateness]
        if let destination { value["device"] = destination.json }
        if timeline.arrangement { value["format"] = "midi-arrangement"; value["regions"] = timeline.regions.count }
        if timeline.arrangement { value["clock"] = ["kind": "mach-nanoseconds", "anchor": String(anchor), "position": offset] }
        if timeline.arrangement, loop, var clock = value["clock"] as? [String: Any] {
            clock["cycle"] = ["kind": "seconds", "duration": timeline.duration]; value["clock"] = clock
        }
        if timeline.source { value["bindings"] = timeline.bindings.compactMap { binding in
            sourceDestinations[binding.port].map { ["port": binding.port, "device": $0.json] as [String: Any] }
        } }
        return value
    }
    func receive(_ line: String) {
        guard state != .stopped else { return }
        do {
            let command = try JSONDecoder().decode(Command.self, from: Data(line.utf8))
            try checkDestination()
            switch command {
            case .pause:
                if state == .playing {
                    // Resolve a late loop boundary before pausing so a cycle
                    // cannot turn into a natural end or emit an expired phase.
                    if loop { tick(); guard state == .playing else { return } }
                    let elapsed = position()
                    if timeline.source && !loop {
                        try reconcile(at: min(elapsed, timeline.duration))
                        if elapsed >= timeline.duration { offset = timeline.duration; finish(reason: "finished"); return }
                    }
                    offset = loop ? elapsed.truncatingRemainder(dividingBy: timeline.duration) : min(elapsed, timeline.duration)
                    state = .paused
                    timer?.cancel(); timer = nil; try silence()
                }
            case .resume:
                if state == .paused {
                    anchor = DispatchTime.now().uptimeNanoseconds; state = .playing
                    try restore(at: offset); tick()
                }
            case .seek(let seconds):
                guard seconds.isFinite, seconds >= 0, seconds <= timeline.duration else { throw MidiFailure("seek must be within the MIDI timeline") }
                let wasPlaying = state == .playing
                let host = DispatchTime.now().uptimeNanoseconds
                timer?.cancel(); timer = nil; try silence()
                offset = seconds == timeline.duration && loop ? 0 : seconds
                if wasPlaying { anchor = host }
                if seconds == timeline.duration && !loop { finish(reason: "finished"); return }
                // Paused seek must remain silent; resume reconstructs held notes.
                if wasPlaying {
                    try restore(at: offset); tick()
                }
            case .status:
                if state == .playing { tick() }
                if state == .stopped { return }
            case .stop: finish(reason: "stop"); return
            case .recordingEpoch(let request):
                var event = snapshot(state == .playing ? "playing" : "paused")
                event["recordingRequest"] = request; try emit(event); return
            }
            publish()
        } catch { finish(reason: "command-failed", error: error) }
    }
    func finish(reason: String, error: Error? = nil, publish: Bool = true) {
        guard state != .stopped else { return }
        var stopped = snapshot("stopped"), failure = error
        state = .stopped; timer?.cancel(); timer = nil
        do { try silence() } catch { failure = failure ?? error }
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        signals.forEach { $0.cancel() }; signals.removeAll()
        stopped["reason"] = reason; stopped["success"] = failure == nil
        terminalFailure = failure
        if coordinated { onCoordinatedFailure?(reason, failure); return }
        if let failure { diagnostic(failure) }
        if publish {
            do {
                if let failure { try emit(["kind": "error", "message": String(describing: failure)]) }
                try emit(stopped)
            } catch { diagnostic(error); failure = error }
        }
        exit(failure == nil ? 0 : 1)
    }
}

#if !MIDI_LIBRARY
@main enum MidiCommandLine {
static func main() {
_ = signal(SIGPIPE, SIG_IGN)
do {
    var args = Array(CommandLine.arguments.dropFirst())
    if args == ["destinations"] {
        var client = MIDIClientRef()
        try checked(MIDIClientCreateWithBlock("MASC MIDI destinations" as CFString, &client, nil), "create MIDI client")
        defer { MIDIClientDispose(client) }
        try emit(["kind": "destinations", "destinations": try destinations().map(\.json)])
        exit(0)
    }
    guard args.first == "play" else { throw MidiFailure("usage: music-midi play --file TIMELINE_JSON --destination UID [--loop] | destinations") }
    args.removeFirst()
    var path: String?, uid: String?, loop = false
    while !args.isEmpty {
        switch args.removeFirst() {
        case "--file": guard path == nil, !args.isEmpty else { throw MidiFailure("--file requires one timeline path") }; path = args.removeFirst()
        case "--destination": guard uid == nil, !args.isEmpty else { throw MidiFailure("--destination requires one MIDI unique ID") }; uid = args.removeFirst()
        case "--loop": guard !loop else { throw MidiFailure("duplicate --loop") }; loop = true
        default: throw MidiFailure("unknown MIDI transport option")
        }
    }
    guard let path, let uid else { throw MidiFailure("--file and --destination are required") }
    let transport = try MidiTransport(path: path, uid: uid, loop: loop)
    try transport.prepare()
    transport.queue.async { transport.start() }
    DispatchQueue.global().async {
        while let line = readLine() { transport.queue.async { transport.receive(line) } }
        transport.queue.async { transport.finish(reason: "eof") }
    }
    withExtendedLifetime(transport) { RunLoop.main.run() }
} catch {
    diagnostic(error)
    do { try emit(["kind": "error", "message": String(describing: error)]) } catch { diagnostic(error) }
    exit(1)
}

}
}
#endif
