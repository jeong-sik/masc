import Foundation

func umpUnsigned(_ text: String) throws -> UInt128 {
    guard let value = UInt128(text), String(value) == text else { throw MidiFailure("invalid captured region integer") }
    return value
}
func umpMultiply(_ a: UInt128, _ b: UInt128) throws -> UInt128 {
    let value = a.multipliedReportingOverflow(by: b)
    guard !value.overflow else { throw MidiFailure("captured region exceeds the native rational clock range") }
    return value.partialValue
}
func umpAdd(_ a: UInt128, _ b: UInt128) throws -> UInt128 {
    let value = a.addingReportingOverflow(b)
    guard !value.overflow else { throw MidiFailure("captured region exceeds the native rational clock range") }
    return value.partialValue
}
func umpNanoseconds(_ seconds: Double) throws -> UInt64 {
    let value = (seconds * 1e9).rounded(.up)
    guard seconds.isFinite, seconds >= 0, value < Double(UInt64.max) else { throw MidiFailure("captured region exceeds the native host timeline") }
    return UInt64(value)
}
struct UmpRegionSource: Decodable {
    let id: String
    let extent: String
    let timeline: UmpTimeline
}
struct UmpRegion: Decodable {
    let id: String
    let source: String
    let startSeconds: Double
    let offset: String
    let extent: String
    let repeatCount: UInt64
}
struct UmpArrangement: Decodable {
    let schemaVersion: Int
    let duration: Double
    let sources: [UmpRegionSource]
    let regions: [UmpRegion]
}
struct UmpRegionClip {
    let id: String
    let start: UInt64
    let end: UInt64
    let repeatCount: UInt64
    let cut: UInt128
    let period: UInt128
    let numer: UInt128
    let denom: UInt128
    let timed: [UmpTimedEvent]
    let events: [UmpEvent]
    let endIndex: Int
    let scope: Set<UmpChannel>
    let releaseOwners: [Int: Int]
    let expiredNotes: [Int: Int]

    func prefix(at scaledTime: UInt128, inclusive: Bool = true) -> Int {
        var low = 0, high = endIndex
        while low < high {
            let middle = low + (high - low) / 2
            let tick = UInt128(timed[middle].ticks) * numer
            if tick < scaledTime || inclusive && tick == scaledTime { low = middle + 1 } else { high = middle }
        }
        return low
    }
    func restore(at time: UInt128, replacing previous: UmpFootprint) throws -> UmpRestoration {
        let before = prefix(at: time, inclusive: false), through = prefix(at: time)
        let expired = Set(expiredNotes.filter { $0.value < through }.map(\.key))
        return try umpRestoration(events, prefixCount: before, followingCount: through - before,
                                  excludingNotes: expired, replacing: previous)
    }
    func phase(at position: UInt64) -> (copy: UInt64, time: UInt128)? {
        guard position >= start, position < end else { return nil }
        let value = UInt128(position - start) * denom
        let copy = value / period
        guard copy < UInt128(repeatCount) else { return nil }
        return (UInt64(copy), cut + value % period)
    }
    func deadline(copy: UInt64, delta: UInt128) -> UInt64 {
        // Admission proves every repeated deadline fits in end <= UInt64max.
        let value = UInt128(copy) * period + delta
        return start + UInt64(value / denom + (value % denom == 0 ? 0 : 1))
    }
    func next(copy: UInt64, index: Int) -> UInt64 {
        if index < endIndex { return deadline(copy: copy, delta: UInt128(timed[index].ticks) * numer - cut) }
        return deadline(copy: copy, delta: period)
    }
}

// One effect owner uses physical destination IDs as state addresses. Logical
// asset/source strings remain in the immutable source timeline, while sequential
// assets on one channel share a real mutation footprint instead of pretending
// their device state is independent. Overlapping scopes are refused at admission.
final class UmpRegionTransport: CoordinatedMidiTransport {
    let timeline: UmpArrangement
    let clips: [UmpRegionClip]
    let output: UmpOutput
    let duration: UInt64
    var anchor: UInt64 = 0
    var terminalFailure: Error?
    var onCoordinatedFailure: ((String, Error?) -> Void)?
    var onCoordinatedEnd: (() -> Void)?
    enum State { case prepared, staged, playing, ended, stopped }
    var state = State.prepared
    var offset: UInt64 = 0
    var timer: DispatchSourceTimer?
    struct Cursor { var copy: UInt64; var index: Int; var acquired: Set<Int> }
    var cursors: [String: Cursor] = [:]

    init(timeline: UmpArrangement) throws {
        self.timeline = timeline; duration = try umpNanoseconds(timeline.duration)
        guard timeline.schemaVersion == 1, duration > 0, !timeline.sources.isEmpty, !timeline.regions.isEmpty,
              Set(timeline.sources.map(\.id)).count == timeline.sources.count,
              Set(timeline.regions.map(\.id)).count == timeline.regions.count else { throw MidiFailure("invalid captured region arrangement") }
        var sources: [String: (UmpRegionSource, [UmpTimedEvent])] = [:], destinations: [String] = []
        for source in timeline.sources {
            guard !source.id.isEmpty else { throw MidiFailure("missing captured source identity") }
            let bound = try umpUnsigned(source.extent)
            guard bound > 0 else { throw MidiFailure("empty captured source span") }
            let parsed = try source.timeline.timedEvents()
            guard parsed.allSatisfy({ UInt128($0.ticks) < bound }) else { throw MidiFailure("captured packet lies beyond its exclusive source end") }
            for binding in source.timeline.bindings where !destinations.contains(binding.destination) { destinations.append(binding.destination) }
            let timed = parsed.map { row -> UmpTimedEvent in
                let destination = source.timeline.bindings.first { $0.source == row.event.source }!.destination
                return UmpTimedEvent(ticks: row.ticks, event: UmpEvent(seconds: row.event.seconds, source: destination, words: row.event.words))
            }
            sources[source.id] = (source, timed)
        }
        var admitted: [UmpRegionClip] = [], potential = UmpFootprint()
        for region in timeline.regions {
            guard !region.id.isEmpty, let (source, timed) = sources[region.source], region.repeatCount > 0 else { throw MidiFailure("invalid captured region source or repetition") }
            let validStart = try umpNanoseconds(region.startSeconds)
            let start = min(validStart, UInt64((region.startSeconds * 1e9).rounded(.down))), cut = try umpUnsigned(region.offset), length = try umpUnsigned(region.extent)
            let after = try umpAdd(cut, length), bound = try umpUnsigned(source.extent)
            guard length > 0, after <= bound else { throw MidiFailure("captured region exceeds its source bounds") }
            let numer = UInt128(source.timeline.clock.numer), denom = UInt128(source.timeline.clock.denom)
            let period = try umpMultiply(length, numer), scaledCut = try umpMultiply(cut, numer)
            _ = try umpMultiply(after, numer)
            let total = try umpMultiply(period, UInt128(region.repeatCount))
            let span = total / denom + (total % denom == 0 ? 0 : 1)
            guard span > 0, span <= UInt128(duration), UInt128(start) + span <= UInt128(duration) else { throw MidiFailure("captured region exceeds arrangement duration") }
            let endIndex = timed.firstIndex { UInt128($0.ticks) >= after } ?? timed.count
            let events = timed.map(\.event), scope = Set(events.prefix(endIndex).map(UmpChannel.init))
            // Every replayed prefix is part of this physical scope, even when
            // its keys were originally acquired before the cut.
            for event in events.prefix(endIndex) { potential.observe(UmpMessage(event)) }
            let notes = try umpRestoration(events, prefixCount: endIndex, replacing: UmpFootprint())
            admitted.append(UmpRegionClip(id: region.id, start: start, end: start + UInt64(span), repeatCount: region.repeatCount,
                cut: scaledCut, period: period, numer: numer, denom: denom, timed: timed, events: events, endIndex: endIndex, scope: scope, releaseOwners: notes.releaseOwners, expiredNotes: notes.expiredNotes))
        }
        try potential.requireSupported()
        for (index, clip) in admitted.enumerated() {
            for other in admitted.prefix(index) where clip.start < other.end && other.start < clip.end {
                guard clip.scope.isDisjoint(with: other.scope) else { throw MidiFailure("overlapping captured regions share physical MIDI channels; select independent outputs") }
            }
            var previous = potential
            previous.touched = previous.touched.filter { field in clip.scope.contains { $0.contains(field.address) } }
            previous.addresses = previous.addresses.filter { address in clip.scope.contains { $0.contains(address) } }
            // Exact-entry events remain a due stream, including a zero-duration
            // attack/release pair. Their explicit baselines must precede each
            // entry Note On; they cannot repair a historical live voice's patch.
            _ = try clip.restore(at: clip.cut, replacing: previous)
        }
        clips = admitted
        output = UmpOutput(bindings: destinations.map { UmpBinding(source: $0, destination: $0) })
    }
    func prepare() throws {
        output.onFailure = { [weak self] error in self?.finish(reason: "destination-unavailable", error: error, publish: false) }
        try output.prepare()
    }
    func stageCoordinated(at seconds: Double) throws {
        guard Thread.isMainThread, state != .stopped else { throw MidiFailure("invalid captured region owner") }
        let position = try umpNanoseconds(seconds)
        guard position < duration else { throw MidiFailure("captured region seek exceeds duration") }
        for clip in clips {
            if let phase = clip.phase(at: position) {
                _ = try clip.restore(at: phase.time, replacing: output.prior(in: clip.scope))
            }
        }
        try output.checkDestinations(); timer?.cancel(); timer = nil
        try output.silence(); cursors.removeAll(); offset = position; state = .staged
    }
    func runCoordinated(anchorNanoseconds: UInt64) throws {
        guard state == .staged, anchorNanoseconds > DispatchTime.now().uptimeNanoseconds,
              duration - offset <= UInt64.max - anchorNanoseconds else { throw MidiFailure("captured regions missed the common host deadline") }
        anchor = anchorNanoseconds; state = .playing; schedule(at: offset)
    }
    func nanoseconds(at host: UInt64) -> UInt64 {
        guard state == .playing else { return state == .ended ? duration : offset }
        return offset + min(duration - offset, host > anchor ? host - anchor : 0)
    }
    func position(at host: UInt64) -> Double { Double(nanoseconds(at: host)) / 1e9 }
    func schedule(at position: UInt64) {
        timer?.cancel(); timer = nil
        guard state == .playing else { return }
        var next = duration
        for clip in clips {
            if position < clip.start { next = min(next, clip.start) }
            else if let phase = clip.phase(at: position) {
                if let cursor = cursors[clip.id], cursor.copy == phase.copy { next = min(next, clip.next(copy: cursor.copy, index: cursor.index)) }
                else { next = min(next, position) }
            }
        }
        let when = anchor + (max(offset, next) - offset)
        let timer = DispatchSource.makeTimerSource(queue: .main); self.timer = timer
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: when), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in self?.tick() }; timer.resume()
    }
    func tick() {
        guard state == .playing else { return }
        do {
            try output.checkDestinations()
            let host = DispatchTime.now().uptimeNanoseconds
            guard host >= anchor else { schedule(at: offset); return }
            let position = nanoseconds(at: host)
            // Release all outgoing scopes before acquiring a sequential region
            // on the same physical channel, regardless of source array order.
            for clip in clips {
                if let cursor = cursors[clip.id], clip.phase(at: position)?.copy != cursor.copy {
                    try output.drain(clip.events[cursor.index..<clip.endIndex])
                    try output.silence(in: clip.scope); cursors.removeValue(forKey: clip.id)
                }
            }
            for clip in clips {
                guard let phase = clip.phase(at: position) else { continue }
                if cursors[clip.id] == nil {
                    let restored = try clip.restore(at: phase.time, replacing: output.prior(in: clip.scope))
                    for event in restored.events { try output.apply(event) }
                    cursors[clip.id] = Cursor(copy: phase.copy, index: restored.nextIndex, acquired: restored.heldNotes)
                }
                var cursor = cursors[clip.id]!
                let due = clip.prefix(at: phase.time)
                while cursor.index < due {
                    let ordinal = cursor.index, event = clip.events[ordinal], message = UmpMessage(event)
                    switch message.action {
                    case .on:
                        let exact = UInt128(clip.timed[ordinal].ticks) * clip.numer == phase.time
                        if exact || (clip.expiredNotes[ordinal].map({ $0 >= due }) ?? true) {
                            try output.apply(event); cursor.acquired.insert(ordinal)
                        }
                    case .off:
                        if let owner = clip.releaseOwners[ordinal], cursor.acquired.contains(owner) {
                            try output.apply(event); cursor.acquired.remove(owner)
                        }
                    case .kill, .release:
                        try output.apply(event)
                        cursor.acquired = cursor.acquired.filter { UmpChannel(clip.events[$0]) != UmpChannel(event) }
                    default: try output.apply(event)
                    }
                    cursor.index += 1
                }
                cursors[clip.id] = cursor
            }
            if position >= duration {
                try output.silence(); timer?.cancel(); timer = nil; cursors.removeAll(); state = .ended; onCoordinatedEnd?(); return
            }
            schedule(at: position)
        } catch { finish(reason: "captured-region-playback-failed", error: error, publish: false) }
    }
    func snapshot(_ kind: String) -> [String: Any] { ["bindings": output.snapshot()] }
    func finish(reason: String, error: Error?, publish: Bool) {
        guard state != .stopped else { return }
        state = .stopped; timer?.cancel(); timer = nil; cursors.removeAll()
        var failure = error
        do { try output.close() } catch { failure = failure ?? error }
        terminalFailure = failure; onCoordinatedFailure?(reason, failure)
    }
}
