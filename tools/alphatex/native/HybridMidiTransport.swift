import Foundation

// This owner composes the two real protocol engines. It owns their joint
// admission, all-or-nothing lifecycle and one completion, not their wire data.
final class HybridMidiTransport: CoordinatedMidiTransport {
    let owners: [any CoordinatedMidiTransport]
    let stagingOrder: [Int]
    let duration: Double
    let cycle: MidiCycle?
    var anchor: UInt64 = 0
    var offset: Double = 0
    var terminalFailure: Error?
    var onCoordinatedFailure: ((String, Error?) -> Void)?
    var onCoordinatedEnd: (() -> Void)?
    enum State { case prepared, staged, playing, ended, stopped }
    var state = State.prepared
    var ended = Set<Int>()

    convenience init(midi: Timeline, ump: UmpArrangement, cycle: MidiCycle? = nil) throws {
        try midi.validate(cycle: cycle)
        guard midi.arrangement, midi.duration == ump.duration,
              let uid = midi.bindings.first?.destination else { throw MidiFailure("invalid hybrid MIDI arrangement clock") }
        let captured: any CoordinatedMidiTransport
        let capturedScopes: [Set<UmpChannel>]
        if let cycle {
            let owner = try UmpLoopTransport(timeline: ump, cycle: cycle)
            captured = owner; capturedScopes = owner.plan.clips.flatMap { $0.shapes.map(\.scope) }
        } else {
            let owner = try UmpRegionTransport(timeline: ump)
            captured = owner; capturedScopes = owner.clips.map(\.scope)
        }
        // Hybrid SMF sends MIDI1 UMP in explicit group zero. Compare complete
        // prefix state scopes, even for sequential clips: separate engines
        // cannot reconstruct each other's prior channel mutations.
        var channels = Set<UmpChannel>()
        for region in midi.regions {
            for address in try cycle?.window(region).scope ?? region.addresses {
                let port = address >> 8, channel = UInt32(address & 15) << 16
                guard let binding = midi.bindings.first(where: { $0.port == port }) else { throw MidiFailure("unbound hybrid SMF channel") }
                channels.insert(UmpChannel(source: binding.destination, channel: channel))
            }
        }
        guard capturedScopes.allSatisfy({ $0.isDisjoint(with: channels) }) else {
            throw MidiFailure("SMF and captured UMP share physical MIDI channel state; select independent channels, groups or outputs")
        }
        let source = try MidiTransport(timeline: midi, uid: uid, loop: cycle != nil, coordinated: true, groupZeroUMP: true, cycle: cycle)
        // The captured owner refuses an unsupported reconstruction before any
        // send, so it stages first; bindings keep their SMF-first order.
        self.init(owners: [source, captured], duration: cycle?.duration ?? midi.duration, cycle: cycle, stagingOrder: [1, 0])
    }
    init(owners: [any CoordinatedMidiTransport], duration: Double, cycle: MidiCycle? = nil, stagingOrder: [Int]? = nil) {
        let order = stagingOrder ?? Array(owners.indices)
        precondition(order.count == owners.count && Set(order) == Set(owners.indices), "hybrid staging order must name each owner once")
        self.owners = owners; self.stagingOrder = order; self.duration = duration; self.cycle = cycle
        for (index, owner) in owners.enumerated() {
            owner.onCoordinatedFailure = { [weak self] reason, error in self?.finish(reason: reason, error: error, publish: false) }
            owner.onCoordinatedEnd = { [weak self] in
                guard let self, self.state == .playing, self.cycle == nil else { return }
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
        var staged = 0
        do {
            for index in stagingOrder { try owners[index].stageCoordinated(at: seconds); staged += 1 }
            ended.removeAll(); offset = seconds; state = .staged
        } catch let refusal as UmpRefusal where staged == 0 {
            // No owner has staged or sent anything: the audio owner keeps playback.
            throw refusal
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
        if let cycle {
            do { return try cycle.phase(elapsed: host > anchor ? host - anchor : 0, offset: offset).seconds }
            catch { finish(reason: "hybrid-clock-failed", error: error, publish: false); return offset }
        }
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
