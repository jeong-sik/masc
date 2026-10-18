import Foundation

// This owner composes the two real protocol engines. It owns their joint
// admission, all-or-nothing lifecycle and one completion, not their wire data.
final class HybridMidiTransport: CoordinatedMidiTransport {
    let owners: [any CoordinatedMidiTransport]
    let duration: Double
    var anchor: UInt64 = 0
    var offset: Double = 0
    var terminalFailure: Error?
    var onCoordinatedFailure: ((String, Error?) -> Void)?
    var onCoordinatedEnd: (() -> Void)?
    enum State { case prepared, staged, playing, ended, stopped }
    var state = State.prepared
    var ended = Set<Int>()

    convenience init(midi: Timeline, ump: UmpArrangement) throws {
        try midi.validate()
        guard midi.arrangement, midi.duration == ump.duration,
              let uid = midi.bindings.first?.destination else { throw MidiFailure("invalid hybrid MIDI arrangement clock") }
        let captured = try UmpRegionTransport(timeline: ump)
        // Hybrid SMF sends MIDI1 UMP in explicit group zero. Compare complete
        // prefix state scopes, even for sequential clips: separate engines
        // cannot reconstruct each other's prior channel mutations.
        var channels = Set<UmpChannel>()
        for region in midi.regions {
            for address in region.addresses {
                let port = address >> 8, channel = UInt32(address & 15) << 16
                guard let binding = midi.bindings.first(where: { $0.port == port }) else { throw MidiFailure("unbound hybrid SMF channel") }
                channels.insert(UmpChannel(source: binding.destination, channel: channel))
            }
        }
        guard captured.clips.allSatisfy({ $0.scope.isDisjoint(with: channels) }) else {
            throw MidiFailure("SMF and captured UMP share physical MIDI channel state; select independent channels, groups or outputs")
        }
        let source = try MidiTransport(timeline: midi, uid: uid, coordinated: true, groupZeroUMP: true)
        self.init(owners: [source, captured], duration: midi.duration)
    }
    init(owners: [any CoordinatedMidiTransport], duration: Double) {
        self.owners = owners; self.duration = duration
        for (index, owner) in owners.enumerated() {
            owner.onCoordinatedFailure = { [weak self] reason, error in self?.finish(reason: reason, error: error, publish: false) }
            owner.onCoordinatedEnd = { [weak self] in
                guard let self, self.state == .playing else { return }
                self.ended.insert(index)
                if self.ended.count == self.owners.count { self.state = .ended; self.onCoordinatedEnd?() }
            }
        }
    }
    func prepare() throws {
        do { for owner in owners { try owner.prepare() } }
        catch { finish(reason: "hybrid-prepare-failed", error: error, publish: false); throw error }
    }
    func stageCoordinated(at seconds: Double) throws {
        guard state != .stopped, seconds.isFinite, seconds >= 0, seconds < duration else { throw MidiFailure("invalid hybrid MIDI seek") }
        do {
            for owner in owners { try owner.stageCoordinated(at: seconds) }
            ended.removeAll(); offset = seconds; state = .staged
        } catch { finish(reason: "hybrid-stage-failed", error: error, publish: false); throw error }
    }
    func runCoordinated(anchorNanoseconds: UInt64) throws {
        guard state == .staged else { throw MidiFailure("hybrid MIDI is not staged") }
        do {
            for owner in owners { try owner.runCoordinated(anchorNanoseconds: anchorNanoseconds) }
            anchor = anchorNanoseconds; state = .playing
        } catch { finish(reason: "hybrid-start-failed", error: error, publish: false); throw error }
    }
    func position(at host: UInt64) -> Double {
        if state == .ended { return duration }
        guard state == .playing else { return offset }
        return min(duration, offset + Double(host > anchor ? host - anchor : 0) / 1e9)
    }
    func snapshot(_ kind: String) -> [String: Any] {
        var bindings: [[String: Any]] = []
        for owner in owners {
            for var binding in owner.snapshot(kind)["bindings"] as? [[String: Any]] ?? [] {
                binding["port"] = bindings.count; bindings.append(binding)
            }
        }
        return ["bindings": bindings]
    }
    func finish(reason: String, error: Error?, publish: Bool) {
        guard state != .stopped else { return }
        state = .stopped
        var failure = error
        for owner in owners {
            owner.finish(reason: reason, error: error, publish: false)
            failure = failure ?? owner.terminalFailure
        }
        terminalFailure = failure; onCoordinatedFailure?(reason, failure)
    }
}
