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
        // Only fields that select the attack must survive a seek baseline; the
        // rest may be defaulted without changing which sample sounds.
        var determinesAttack: Bool {
            switch self {
            case .program, .bank, .noteRegistered, .noteAssignable, .noteReset: return true
            default: return false
            }
        }
    }
    let address: UmpAddress
    let kind: Kind
    func covered(by known: Set<UmpField>) -> Bool {
        if known.contains(self) { return true }
        return address.dialect == 4 && kind.note.map { known.contains(UmpField(address: address, kind: .noteReset($0))) } == true
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
enum UmpAction {
    case on(UInt32), off(UInt32), absolute([UmpField.Kind]), relative(UmpField.Kind)
    case pedal(UInt32, Bool), kill, release, reset, management(UInt32, Bool), unsupported(UmpObstacle)
    // System real-time (MT1 F8/FE) and utility (MT0 NOOP/JR clock/timestamp)
    // messages carry no channel state and must not refuse reconstruction.
    case ignored
}
struct UmpMessage {
    let address: UmpAddress
    let action: UmpAction
    init(_ event: UmpEvent) {
        let word = event.words[0], dialect = word >> 28, status = (word >> 20) & 15
        let number = (word >> 8) & 127, byte = word & 255, detail = (word >> 16) & 15
        address = UmpAddress(source: event.source, prefix: word & 0xff0f0000)
        guard dialect == 2 || dialect == 4 else {
            // Utility (MT0) NOOP, JR Clock and JR Timestamp carry no channel
            // state; only genuinely opaque messages remain obstacles.
            action = dialect == 0 && (status == 0 || status == 1 || status == 2) ? .ignored : .unsupported(.opaque)
            return
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
        case 15 where dialect == 4 && byte & ~3 == 0: action = .management(number, byte & 1 != 0)
        case 15 where dialect == 2 && (detail == 8 || detail == 14): action = .ignored
        default: action = .unsupported(.opaque)
        }
    }
    var fields: [UmpField] {
        let kinds: [UmpField.Kind]
        switch action {
        case .absolute(let values): kinds = values
        case .relative(let value): kinds = [value]
        case .pedal(let number, _): kinds = [.controller(number)]
        case .management(let number, true): kinds = [.noteReset(number)]
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
        guard obstacles.isEmpty else { throw MidiFailure("captured UMP reconstruction cannot restore \(obstacles.map(\.rawValue).sorted().joined(separator: ", ")); full-source playback remains available") }
    }
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
}
func umpRestoration(_ events: [UmpEvent], before seconds: Double, replacing previous: UmpFootprint) throws -> UmpRestoration {
    try previous.requireSupported()
    var footprint = UmpFootprint(), known = Set<UmpField>(), channels: [UmpAddress: UmpChannelState] = [:]
    var notes = Set<Int>(), next = 0
    for (ordinal, event) in events.enumerated() {
        guard event.seconds < seconds else { break }
        next = ordinal + 1
        let message = UmpMessage(event), address = message.address
        footprint.observe(message)
        if case .relative(let kind) = message.action, !UmpField(address: address, kind: kind).covered(by: known) {
            throw MidiFailure("captured UMP relative parameter needs an absolute source baseline")
        }
        if case .relative = message.action {} else { known.formUnion(message.fields) }
        var channel = channels[address] ?? UmpChannelState()
        switch message.action {
        case .on(let number): channel.voices.append(UmpVoice(number: number, on: ordinal)); notes.insert(ordinal)
        case .off(let number):
            notes.insert(ordinal)
            if let index = channel.voices.firstIndex(where: { $0.number == number && $0.held }) {
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
        case .kill: channel.voices.removeAll()
        case .reset:
            channel.sustain = false; channel.sostenuto = false
            for index in channel.voices.indices { channel.voices[index].captured = false }
        default: break
        }
        channel.prune(); channels[address] = channel
    }
    try footprint.requireSupported()
    guard previous.touched.filter({ $0.kind.determinesAttack }).allSatisfy({ $0.covered(by: known) }) else { throw MidiFailure("captured UMP seek needs an explicit source baseline for previously changed state") }
    var live = Set<Int>()
    for channel in channels.values {
        for voice in channel.voices { live.insert(voice.on); if let off = voice.off { live.insert(off) } }
    }
    // Establish prior mutations before each surviving Note On, not merely by
    // the cut. For example a later program message cannot establish the patch
    // that a voice used when its original Note On selected a sample.
    known.removeAll()
    var replay: [UmpEvent] = []
    for ordinal in 0..<next {
        let event = events[ordinal], message = UmpMessage(event)
        if case .on(let number) = message.action, live.contains(ordinal) {
            let required = previous.touched.filter { $0.kind.determinesAttack && $0.address == message.address && ($0.kind.note == nil || $0.kind.note == number) }
            guard required.allSatisfy({ $0.covered(by: known) }) else { throw MidiFailure("captured UMP seek needs a source baseline before a surviving Note On") }
        }
        if case .relative = message.action {} else { known.formUnion(message.fields) }
        if !notes.contains(ordinal) || live.contains(ordinal) { replay.append(event) }
    }
    return UmpRestoration(events: replay, nextIndex: next)
}
