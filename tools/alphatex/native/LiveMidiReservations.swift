import Foundation

// Compile the same region/prefix ownership used by the actual MIDI transports.
// This probe opens no device and never substitutes source-name/track heuristics
// for physical destinations. The caller retains this private plan through play.
func liveMidiReservations(_ data: Data, format: String) throws -> [UmpLiveClaim] {
    struct Envelope: Decodable {
        let schemaVersion: Int
        let kind: String
        let duration: Double
        let midi: Timeline?
        let umpRegions: UmpArrangement?
    }
    var notes: Timeline?, captured: UmpArrangement?
    if format == "midi-arrangement" {
        notes = try JSONDecoder().decode(Timeline.self, from: data)
    } else {
        let plan = try JSONDecoder().decode(Envelope.self, from: data)
        let versions = ["wave-arrangement": 1, "mixed-arrangement": 2,
                        "capture-audio-arrangement": 4, "capture-arrangement": 5, "hybrid-arrangement": 6]
        guard versions[format] == plan.schemaVersion, plan.kind == format,
              plan.duration.isFinite, plan.duration > 0 else { throw MidiFailure("invalid backing ownership plan") }
        switch format {
        case "mixed-arrangement":
            guard let midi = plan.midi, plan.umpRegions == nil else { throw MidiFailure("missing backing MIDI timeline") }
            notes = midi
        case "capture-arrangement":
            guard let ump = plan.umpRegions, plan.midi == nil else { throw MidiFailure("missing backing UMP timeline") }
            captured = ump
        case "hybrid-arrangement":
            guard let midi = plan.midi, let ump = plan.umpRegions else { throw MidiFailure("missing hybrid backing timelines") }
            _ = try HybridMidiTransport(midi: midi, ump: ump)
            notes = midi; captured = ump
        default:
            guard plan.midi == nil, plan.umpRegions == nil else { throw MidiFailure("audio backing cannot hide MIDI ownership") }
        }
        guard notes == nil || notes!.duration == plan.duration,
              captured == nil || captured!.duration == plan.duration else { throw MidiFailure("backing MIDI clock differs from plan") }
    }
    var channels: [String: Set<UmpLiveChannel>] = [:]
    if let notes {
        try notes.validate()
        guard notes.arrangement else { throw MidiFailure("backing reservations require a MIDI region arrangement") }
        for region in notes.regions {
            for address in region.addresses {
                guard let binding = notes.bindings.first(where: { $0.port == address >> 8 }) else { throw MidiFailure("unbound backing MIDI channel") }
                channels[binding.destination, default: []].insert(UmpLiveChannel(group: 0, channel: UInt8(address & 15)))
            }
        }
    }
    if let captured {
        let owner = try UmpRegionTransport(timeline: captured)
        for clip in owner.clips {
            for address in clip.scope {
                channels[address.source, default: []].insert(UmpLiveChannel(group: UInt8((address.channel >> 24) & 15), channel: UInt8((address.channel >> 16) & 15)))
            }
        }
    }
    return channels.keys.sorted().map { UmpLiveClaim(destination: $0, scope: .channels(channels[$0]!)) }
}
