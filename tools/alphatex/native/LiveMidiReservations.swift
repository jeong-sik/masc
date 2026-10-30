import Foundation

// Compile the same region/prefix ownership used by the actual MIDI transports.
// This probe opens no ports and never substitutes source-name/track heuristics
// for physical destinations. The caller retains this private plan through play.
func liveMidiReservations(_ data: Data, format: String, nativeProtocol: (String) throws -> UmpNativeProtocol = umpNativeProtocol) throws -> [UmpLiveClaim] {
    struct Envelope: Decodable {
        let schemaVersion: Int
        let kind: String
        let duration: Double
        let midi: Timeline?
        let umpRegions: UmpArrangement?
        let loop: WaveLoopClock?
        let practice: PracticePlan?
    }
    var notes: Timeline?, captured: UmpArrangement?, cycle: MidiCycle?
    if format == "midi-arrangement" {
        notes = try JSONDecoder().decode(Timeline.self, from: data)
    } else {
        let plan = try JSONDecoder().decode(Envelope.self, from: data)
        let versions = ["wave-arrangement": 1, "mixed-arrangement": 2,
                        "capture-audio-arrangement": 4, "capture-arrangement": 5, "hybrid-arrangement": 6]
        guard versions[format] == plan.schemaVersion, plan.kind == format,
              plan.duration.isFinite, plan.duration > 0 else { throw MidiFailure("invalid backing ownership plan") }
        if let loop = plan.loop {
            try loop.validate()
            if let practice = plan.practice {
                try practice.validate(loop: loop)
                guard abs(practice.countInSeconds + practice.duration - plan.duration) <= plan.duration.ulp else { throw MidiFailure("invalid backing count-in duration") }
            } else { guard plan.duration == loop.duration else { throw MidiFailure("backing loop differs from its authored clock") } }
            cycle = try loop.midiCycle()
        }
        switch format {
        case "mixed-arrangement":
            guard let midi = plan.midi, plan.umpRegions == nil else { throw MidiFailure("missing backing MIDI timeline") }
            notes = midi
        case "capture-arrangement":
            guard let ump = plan.umpRegions, plan.midi == nil else { throw MidiFailure("missing backing UMP timeline") }
            captured = ump
        case "hybrid-arrangement":
            guard let midi = plan.midi, let ump = plan.umpRegions else { throw MidiFailure("missing hybrid backing timelines") }
            _ = try HybridMidiTransport(midi: midi, ump: ump, cycle: cycle)
            notes = midi; captured = ump
        default:
            guard plan.midi == nil, plan.umpRegions == nil else { throw MidiFailure("audio backing cannot hide MIDI ownership") }
        }
        guard cycle != nil || (notes == nil || notes!.duration == plan.duration)
              && (captured == nil || captured!.duration == plan.duration) else { throw MidiFailure("backing MIDI clock differs from plan") }
    }
    var channels: [String: Set<UmpLiveChannel>] = [:]
    var nativeProtocols: [String: UmpNativeProtocol] = [:]
    if let notes {
        try notes.validate(cycle: cycle)
        guard notes.arrangement else { throw MidiFailure("backing reservations require a MIDI region arrangement") }
        for region in notes.regions {
            for address in try cycle?.window(region).scope ?? region.addresses {
                guard let binding = notes.bindings.first(where: { $0.port == address >> 8 }) else { throw MidiFailure("unbound backing MIDI channel") }
                channels[binding.destination, default: []].insert(UmpLiveChannel(group: 0, channel: UInt8(address & 15)))
            }
        }
    }
    if let captured {
        let scopes: [Set<UmpChannel>]
        if let cycle { scopes = try UmpLoopPlan(timeline: captured, cycle: cycle).clips.flatMap { $0.shapes.map(\.scope) } }
        else { scopes = try UmpRegionTransport(timeline: captured).clips.map(\.scope) }
        for scope in scopes {
            for address in scope {
                if nativeProtocols[address.source] == nil { nativeProtocols[address.source] = try nativeProtocol(address.source) }
                let wire = nativeProtocols[address.source]!
                channels[address.source, default: []].insert(UmpLiveChannel(group: wire == .midi1 ? 0 : UInt8((address.channel >> 24) & 15), channel: UInt8((address.channel >> 16) & 15)))
            }
        }
    }
    return channels.keys.sorted().map { UmpLiveClaim(destination: $0, scope: .channels(channels[$0]!), nativeProtocol: nativeProtocols[$0]?.rawValue) }
}
