import Foundation

// State reconstruction uses the original message order, rather than emitting a
// bag of final controller values before every key. This preserves bank/program
// at Note On, pre-note pitch, and detach/reset expression on overlapping voices.
struct UmpAddress: Hashable {
    let source: String
    let prefix: UInt32
    var dialect: UInt32 { prefix >> 28 }
    var channel: UInt32 { prefix & 0x0f0f0000 }
}
struct UmpField: Hashable {
    enum Kind: Hashable {
        case controller(UInt32), program, bank, bend, pressure
        case poly(UInt32), noteBend(UInt32), noteRegistered(UInt32, UInt32), noteAssignable(UInt32, UInt32)
        case registered(UInt32, UInt32), assignable(UInt32, UInt32), noteReset(UInt32)
        var note: UInt32? {
            switch self {
            case .poly(let n), .noteBend(let n), .noteRegistered(let n, _), .noteAssignable(let n, _), .noteReset(let n): return n
            default: return nil
            }
        }
    }
    let address: UmpAddress
    let kind: Kind
    func covered(by known: Set<UmpField>) -> Bool {
        if known.contains(self) { return true }
        return address.dialect == 4 && kind.note.map { known.contains(UmpField(address: address, kind: .noteReset($0))) } == true
    }
    static let bankSelect: Set<UInt32> = [0, 32]
    static let registeredPitch: UInt32 = 3
    // A voice keeps what its Note On started with: its patch, Portamento Time
    // and On/Off glide, Tuning Program/Bank (MIDI Tuning Standard persists for
    // subsequent Note Ons, UMP v1.1.2 7.4.15), MPE Configuration, the Per-Note
    // Pitch Bend Sensitivity of "all Notes which follow" (7.4.13.1) and Pitch
    // 7.25, from which a receiver may select the sample. Assignable controllers
    // have vendor meanings and are kept as well. A per-note reset changed every
    // per-note value. Bend, pressure and other controllers are continuous.
    // The kept channel controllers and registered parameters are this table.
    static let keptByAttack: Set<Kind> = [.controller(5), .controller(37), .controller(65),
                                          .registered(0, 3), .registered(0, 4), .registered(0, 6), .registered(0, 7)]
    // Whether `message` fixes this field for later sound: a Note On keeps the
    // values above, a Program Change applies a MIDI 1.0 Bank Select, and a
    // Per-Note Management Detach keeps a sounding note's per-note values.
    func kept(by message: UmpMessage, sounding: Set<UInt32>) -> Bool {
        guard address == message.address else { return false }
        switch message.action {
        case .on(let number):
            switch kind {
            case .program, .bank, .assignable: return true
            case .controller, .registered: return UmpField.keptByAttack.contains(kind)
            case .noteRegistered(let note, let index): return note == number && index == UmpField.registeredPitch
            case .noteAssignable(let note, _), .noteReset(let note): return note == number
            case .bend, .pressure, .poly, .noteBend: return false
            }
        case .absolute(let kinds) where kinds.contains(.program):
            if case .controller(let index) = kind { return address.dialect == 2 && UmpField.bankSelect.contains(index) }
            return false
        case .management(let number, detach: true, _) where sounding.contains(number): return kind.note == number
        default: return false
        }
    }
}
enum UmpObstacle: String, Hashable {
    case opaque = "opaque system, SysEx or unknown messages"
    case mode = "device channel-mode changes"
    case compound = "MIDI 1.0 compound controllers or reserved MIDI 2.0 controllers"
    case hold = "Hold 2 pedal"
    case oneShot = "one-shot Portamento Control"
    case dialect = "mixed MIDI 1.0 and MIDI 2.0 state on one channel"
}
// Source state reconstruction cannot restore, raised before any message is
// sent, so a command owner can keep its current playback.
struct UmpRefusal: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
}
enum UmpAction {
    case on(UInt32), off(UInt32), absolute([UmpField.Kind]), relative(UmpField.Kind)
    case pedal(UInt32, Bool), kill, release, reset, management(UInt32, detach: Bool, reset: Bool), unsupported(UmpObstacle)
    case stateless
}
struct UmpMessage {
    // UMP v1.1.2 Appendix F.1: Utility NOOP, JR Clock and JR Timestamp, and
    // System Real Time Timing Clock and Active Sensing carry timing or link
    // liveness, not device state. Reconstruction neither restores nor replays them.
    static let statelessUtility: Set<UInt32> = [0x0, 0x1, 0x2]
    static let statelessSystem: Set<UInt32> = [0xf8, 0xfe]
    let address: UmpAddress
    let action: UmpAction
    init(_ event: UmpEvent) {
        let word = event.words[0], dialect = word >> 28, status = (word >> 20) & 15
        let number = (word >> 8) & 127, byte = word & 255
        address = UmpAddress(source: event.source, prefix: word & 0xff0f0000)
        guard dialect == 2 || dialect == 4 else {
            let stateless = dialect == 0 ? UmpMessage.statelessUtility.contains(status) : dialect == 1 && UmpMessage.statelessSystem.contains((word >> 16) & 255)
            action = stateless ? .stateless : .unsupported(.opaque); return
        }
        switch status {
        case 9 where dialect == 4 || byte > 0: action = .on(number)
        case 8, 9: action = .off(number)
        case 0 where dialect == 4: action = .absolute([.noteRegistered(number, byte)])
        case 1 where dialect == 4: action = .absolute([.noteAssignable(number, byte)])
        case 2...5 where dialect == 4:
            let field: UmpField.Kind = status == 2 || status == 4 ? .registered(number, byte) : .assignable(number, byte)
            action = status < 4 ? .absolute([field]) : .relative(field)
        case 6 where dialect == 4: action = .absolute([.noteBend(number)])
        case 10: action = .absolute([.poly(number)])
        case 11:
            switch number {
            case 64, 66: action = .pedal(number, dialect == 4 ? event.words[1] >= 0x80000000 : byte >= 64)
            case 120: action = .kill
            case 121: action = .reset
            case 123: action = .release
            case 122, 124...127: action = .unsupported(.mode)
            case 69: action = .unsupported(.hold)
            case 84: action = .unsupported(.oneShot)
            case 6, 38, 96...101: action = .unsupported(.compound)
            case 0 where dialect == 4: action = .unsupported(.compound)
            case 32 where dialect == 4: action = .unsupported(.compound)
            case 88 where dialect == 2: action = .unsupported(.compound)
            default: action = .absolute([.controller(number)])
            }
        case 12:
            action = .absolute(dialect == 4 && word & 1 != 0 ? [.program, .bank] : [.program])
        case 13: action = .absolute([.pressure])
        case 14: action = .absolute([.bend])
        case 15 where dialect == 4 && byte & ~3 == 0: action = .management(number, detach: byte & 2 != 0, reset: byte & 1 != 0)
        default: action = .unsupported(.opaque)
        }
    }
    var fields: [UmpField] {
        let kinds: [UmpField.Kind]
        switch action {
        case .absolute(let values): kinds = values
        case .relative(let value): kinds = [value]
        case .pedal(let number, _): kinds = [.controller(number)]
        case .management(let number, _, reset: true): kinds = [.noteReset(number)]
        case .reset:
            // Reset All Controllers retains bank/program, volume/pan and RPN
            // values. It does NOT reset MIDI2 PNCC or Per-Note Pitch Bend.
            kinds = [.bend, .pressure] + (0...127).map { .poly(UInt32($0)) }
                + [1,11,64,65,66,67].map { .controller(UInt32($0)) }
        default: kinds = []
        }
        return kinds.map { UmpField(address: address, kind: $0) }
    }
}

// Include uncertain controller sends before the OS edge: their old value cannot
// be assumed to survive an error. The transport retains this footprint across
// pause/seek and releases its separately owned keys and pedals on cleanup.
struct UmpFootprint {
    var touched = Set<UmpField>()
    var addresses = Set<UmpAddress>()
    var obstacles = Set<UmpObstacle>()
    mutating func observe(_ message: UmpMessage) {
        touched.formUnion(message.fields)
        if message.address.dialect == 2 || message.address.dialect == 4 {
            if addresses.contains(where: { $0.source == message.address.source && $0.channel == message.address.channel && $0.dialect != message.address.dialect }) { obstacles.insert(.dialect) }
            addresses.insert(message.address)
        }
        if case .unsupported(let reason) = message.action { obstacles.insert(reason) }
    }
    func requireSupported() throws {
        guard obstacles.isEmpty else { throw UmpRefusal("captured UMP reconstruction cannot restore \(obstacles.map(\.rawValue).sorted().joined(separator: ", ")); full-source playback remains available") }
    }
}
// Fields the transport changed that `message` keeps (UmpField.kept) need a
// source baseline before it; other values sent later still reach the voice.
func umpKeptFields(_ message: UmpMessage, sounding: Set<UInt32>, changed previous: UmpFootprint) -> [UmpField] {
    previous.touched.filter { $0.kept(by: message, sounding: sounding) }
}
struct UmpVoice {
    let number: UInt32
    let on: Int
    var off: Int?
    var held = true
    var captured = false
}
struct UmpChannelState {
    var voices: [UmpVoice] = []
    var sustain = false, sostenuto = false
    mutating func prune() { voices.removeAll { !$0.held && !sustain && !(sostenuto && $0.captured) } }
}
struct UmpRestoration {
    let events: [UmpEvent]
    let nextIndex: Int
    let heldNotes: Set<Int>
    let releaseOwners: [Int: Int]
    let expiredNotes: [Int: Int]
}
func umpRestoration(_ events: [UmpEvent], before seconds: Double, replacing previous: UmpFootprint) throws -> UmpRestoration {
    let count = events.firstIndex(where: { $0.seconds >= seconds }) ?? events.count
    return try umpRestoration(events, prefixCount: count, replacing: previous)
}
func umpRestoration(_ events: [UmpEvent], prefixCount: Int, followingCount: Int = 0, preambleEndIndex: Int? = nil, excludingNotes: Set<Int> = [], replacing previous: UmpFootprint) throws -> UmpRestoration {
    guard prefixCount >= 0, prefixCount <= events.count, followingCount >= 0, followingCount <= events.count - prefixCount else { throw MidiFailure("invalid captured UMP prefix") }
    let admissionEnd = preambleEndIndex ?? (prefixCount + followingCount)
    guard admissionEnd >= prefixCount + followingCount, admissionEnd <= events.count else { throw MidiFailure("invalid captured UMP preamble boundary") }
    try previous.requireSupported()
    var footprint = UmpFootprint(), known = Set<UmpField>(), channels: [UmpAddress: UmpChannelState] = [:]
    var notes = Set<Int>(), next = 0
    var releaseOwners: [Int: Int] = [:], expiredNotes: [Int: Int] = [:]
    for (ordinal, event) in events.enumerated() {
        guard ordinal < prefixCount else { break }
        next = ordinal + 1
        let message = UmpMessage(event), address = message.address
        footprint.observe(message)
        if case .relative(let kind) = message.action, !UmpField(address: address, kind: kind).covered(by: known) {
            throw UmpRefusal("captured UMP relative parameter needs an absolute source baseline")
        }
        if case .relative = message.action {} else { known.formUnion(message.fields) }
        var channel = channels[address] ?? UmpChannelState()
        switch message.action {
        case .on(let number): channel.voices.append(UmpVoice(number: number, on: ordinal)); notes.insert(ordinal)
        case .off(let number):
            notes.insert(ordinal)
            if let index = channel.voices.firstIndex(where: { $0.number == number && $0.held }) {
                releaseOwners[ordinal] = channel.voices[index].on
                channel.voices[index].held = false; channel.voices[index].off = ordinal
            }
        case .pedal(let number, let on):
            if number == 64 { channel.sustain = on }
            else {
                if on && !channel.sostenuto { for index in channel.voices.indices where channel.voices[index].held { channel.voices[index].captured = true } }
                channel.sostenuto = on
                if !on { for index in channel.voices.indices { channel.voices[index].captured = false } }
            }
        case .release: for index in channel.voices.indices { channel.voices[index].held = false }
        case .kill:
            for voice in channel.voices { expiredNotes[voice.on] = ordinal }
            channel.voices.removeAll()
        case .reset:
            channel.sustain = false; channel.sostenuto = false
            for index in channel.voices.indices { channel.voices[index].captured = false }
        default: break
        }
        for voice in channel.voices where !voice.held && !channel.sustain && !(channel.sostenuto && voice.captured) { expiredNotes[voice.on] = ordinal }
        channel.prune(); channels[address] = channel
    }
    var live = Set<Int>(), entrySounding: [UmpAddress: Set<UInt32>] = [:]
    for (address, channel) in channels {
        for voice in channel.voices where !excludingNotes.contains(voice.on) {
            live.insert(voice.on); if let off = voice.off { live.insert(off) }
            entrySounding[address, default: []].insert(voice.number)
        }
    }
    // Region admission may inspect the retained due stream to prove that its
    // original preamble establishes each field before an attack/relative use.
    // This is validation only: future messages are never added to replay.
    // Historical live voices still require their own pre-attack baselines below.
    // Entry events in the restored batch are sent with the prefix, so they need
    // baselines only where a surviving or entering voice keeps a value. A later
    // preamble message plays at its own deadline: every voice still sounding
    // after the batch needs each changed field by then, and a later attack too.
    var entryKnown = known, batchChecked = false
    let batchEnd = prefixCount + followingCount
    func requireSoundingBaselines() throws {
        batchChecked = true
        let stale = previous.touched.filter { field in
            guard let numbers = entrySounding[field.address] else { return false }
            return field.kind.note.map(numbers.contains) ?? true
        }
        guard stale.allSatisfy({ $0.covered(by: entryKnown) }) else { throw UmpRefusal("captured UMP entry needs a source baseline for state of a note still sounding after its entry") }
    }
    for (ordinal, event) in zip(prefixCount..<admissionEnd, events[prefixCount..<admissionEnd]) {
        if ordinal == batchEnd { try requireSoundingBaselines() }
        let message = UmpMessage(event)
        footprint.observe(message)
        var required = umpKeptFields(message, sounding: entrySounding[message.address] ?? [], changed: previous)
        if case .on(let number) = message.action, ordinal >= batchEnd {
            required = previous.touched.filter { $0.address == message.address && ($0.kind.note == nil || $0.kind.note == number) }
        }
        guard required.allSatisfy({ $0.covered(by: entryKnown) }) else {
            throw UmpRefusal("captured UMP entry needs a source baseline for the patch, Pitch or per-note values a sounding note keeps")
        }
        if case .on(let number) = message.action { entrySounding[message.address, default: []].insert(number) }
        if case .relative(let kind) = message.action, !UmpField(address: message.address, kind: kind).covered(by: entryKnown) {
            throw UmpRefusal("captured UMP relative entry needs an absolute source baseline")
        }
        if case .relative = message.action {} else { entryKnown.formUnion(message.fields) }
    }
    if !batchChecked { try requireSoundingBaselines() }
    try footprint.requireSupported()
    guard previous.touched.allSatisfy({ $0.covered(by: entryKnown) }) else { throw UmpRefusal("captured UMP seek needs an explicit source baseline for previously changed state") }
    // Besides the cut, a changed field needs its baseline earlier in the replay
    // where a surviving voice keeps its value; the replay is sent at once, so any
    // other value it sets later still reaches that voice.
    known.removeAll()
    var replay: [UmpEvent] = [], sounding: [UmpAddress: Set<UInt32>] = [:]
    for ordinal in 0..<next {
        let event = events[ordinal], message = UmpMessage(event)
        if case .stateless = message.action { continue }
        if notes.contains(ordinal) && !live.contains(ordinal) { continue }
        guard umpKeptFields(message, sounding: sounding[message.address] ?? [], changed: previous).allSatisfy({ $0.covered(by: known) }) else {
            throw UmpRefusal("captured UMP seek needs a source baseline for a changed value that a Note On, Program Change or Detach keeps")
        }
        if case .on(let number) = message.action { sounding[message.address, default: []].insert(number) }
        if case .relative = message.action {} else { known.formUnion(message.fields) }
        replay.append(event)
    }
    return UmpRestoration(events: replay, nextIndex: next, heldNotes: Set(channels.values.flatMap { $0.voices.filter { $0.held && !excludingNotes.contains($0.on) }.map(\.on) }), releaseOwners: releaseOwners, expiredNotes: expiredNotes)
}
