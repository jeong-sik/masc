import Foundation

struct UmpLoopInstance {
    let master: UInt128, copy: UInt64
    let entry: UInt128, end: UInt128, localEntry: UInt128, localEnd: UInt128
}
struct UmpLoopShape {
    let first: UInt64, last: UInt64
    let scope: Set<UmpChannel>
}
struct UmpLoopClip {
    let id: String, window: UmpLoopWindow, cut: UInt128
    let timed: [UmpTimedEvent], events: [UmpEvent]
    let first: UInt64?, last: UInt64?
    var shapes: [UmpLoopShape] = []

    init(id: String, window: UmpLoopWindow, cut: UInt128, timed: [UmpTimedEvent]) {
        self.id = id; self.window = window; self.cut = cut
        self.timed = timed; self.events = timed.map(\.event)
        let low = max(0, window.offset), high = min(Int128(window.sourceEnd), Int128(window.period) + window.offset)
        if high > low {
            first = UInt64(UInt128(low) / window.sourcePeriod)
            last = UInt64(UInt128(high - 1) / window.sourcePeriod)
        } else { first = nil; last = nil }
    }
    func instance(master: UInt128, copy: UInt64, initial: UInt128 = 0) -> UmpLoopInstance? {
        guard let first, let last, copy >= first, copy <= last else { return nil }
        let base = UInt128(copy) * window.sourcePeriod
        // Clamp in source coordinates before subtracting the placement. A
        // valid small visible suffix must not overflow at its unused far end.
        let lo = max(Int128(base), window.offset), hi = min(Int128(base + window.sourcePeriod), Int128(window.period) + window.offset)
        let entry = max(UInt128(lo - window.offset), master == 0 ? initial : 0)
        let end = UInt128(hi - window.offset)
        guard entry < end else { return nil }
        let local = UInt128(Int128(entry) + window.offset) - base
        return UmpLoopInstance(master: master, copy: copy, entry: entry, end: end,
                               localEntry: local, localEnd: UInt128(hi) - base)
    }
    func prefix(_ local: UInt128, inclusive: Bool = false) -> Int {
        var low = 0, high = timed.count
        while low < high {
            let middle = low + (high - low) / 2, tick = UInt128(timed[middle].ticks)
            let before: Bool
            if tick < cut { before = true }
            else {
                let delta = tick - cut
                // Compare first: packets beyond this finite trim need not
                // fit its scaled native phase at all.
                if delta >= window.sourcePeriod / window.tick { before = false }
                else {
                    let value = delta * window.tick
                    before = value < local || inclusive && value == local
                }
            }
            if before { low = middle + 1 } else { high = middle }
        }
        return low
    }
    func phase(_ ordinal: Int, in instance: UmpLoopInstance) throws -> UInt128 {
        let tick = UInt128(timed[ordinal].ticks)
        guard tick >= cut else { throw MidiFailure("historical UMP packet has no raw loop phase") }
        let delta = try umpMultiply(tick - cut, window.tick)
        guard let phase = try window.packetPhase(copy: instance.copy, delta: delta), phase >= instance.entry, phase < instance.end else {
            throw MidiFailure("UMP packet is outside its selected loop instance")
        }
        return phase
    }
    func scope(_ copy: UInt64) -> Set<UmpChannel> { shapes.first { copy >= $0.first && copy <= $0.last }?.scope ?? [] }
    func analysis(_ instance: UmpLoopInstance) throws -> UmpRestoration {
        try umpRestoration(events, prefixCount: prefix(instance.localEnd), replacing: UmpFootprint())
    }
    func entry(_ instance: UmpLoopInstance, host: UInt64, initial: UInt128, anchor: UInt64,
               replacing previous: UmpFootprint) throws -> UmpRestoration {
        let end = prefix(instance.localEnd), history = prefix(instance.localEntry)
        func due(_ index: Int) throws -> UInt64 {
            try window.deadline(phase: phase(index, in: instance), index: instance.master, initial: initial, anchor: anchor)
        }
        var before = history, through = history
        while before < end, try due(before) < host { before += 1 }
        through = before
        while through < end, try due(through) <= host { through += 1 }
        let notes = try analysis(instance)
        let entryHost = try window.deadline(phase: instance.entry, index: instance.master, initial: initial, anchor: anchor)
        let exactEntryEnd = prefix(instance.localEntry, inclusive: true)
        var expired = Set(notes.expiredNotes.filter { _, expiry in
            expiry < through && (expiry < exactEntryEnd || entryHost != host)
        }.map(\.key))
        // As for a late packet, a late entry acquires no voice when its
        // instance also closes by this host: a voice held to that end expires.
        if try entryHost != host && window.deadline(phase: instance.end, index: instance.master, initial: initial, anchor: anchor) <= host {
            for ordinal in 0..<before { if case .on = UmpMessage(events[ordinal]).action { expired.insert(ordinal) } }
        }
        return try umpRestoration(events, prefixCount: before, followingCount: through - before,
                                  preambleEndIndex: end, excludingNotes: expired, replacing: previous)
    }
}

// Immutable admission is also consumed by reservation/hybrid preflight. At
// most first-partial/full-middle/last-partial shapes describe finite copies;
// no repeated packet arrays or copy-count-sized state are constructed.
struct UmpLoopPlan {
    let cycle: MidiCycle, clips: [UmpLoopClip], bindings: [UmpBinding], compatibleEvents: [UmpEvent]
    init(timeline: UmpArrangement, cycle: MidiCycle) throws {
        guard timeline.schemaVersion == 1, timeline.duration.isFinite, timeline.duration > 0,
              !timeline.sources.isEmpty, !timeline.regions.isEmpty,
              Set(timeline.sources.map(\.id)).count == timeline.sources.count,
              Set(timeline.regions.map(\.id)).count == timeline.regions.count else { throw MidiFailure("invalid captured loop arrangement") }
        var sources: [String: (UmpRegionSource, [UmpTimedEvent])] = [:]
        for source in timeline.sources {
            guard !source.id.isEmpty else { throw MidiFailure("missing captured loop source identity") }
            let bound = try umpUnsigned(source.extent), parsed = try source.timeline.timedEvents(allowEmpty: true)
            guard bound > 0, parsed.allSatisfy({ UInt128($0.ticks) < bound }) else { throw MidiFailure("captured loop packet exceeds original source") }
            let timed = parsed.map { row in
                UmpTimedEvent(ticks: row.ticks, event: UmpEvent(seconds: row.event.seconds,
                    source: source.timeline.bindings.first { $0.source == row.event.source }!.destination, words: row.event.words))
            }
            sources[source.id] = (source, timed)
        }
        var clips: [UmpLoopClip] = [], potential = UmpFootprint(), wireEvents: [UmpEvent] = []
        for region in timeline.regions {
            guard !region.id.isEmpty, region.component != .audio, let (source, timed) = sources[region.source], region.repeatCount > 0 else {
                throw MidiFailure("invalid captured loop region")
            }
            let cut = try umpUnsigned(region.offset), extent = try umpUnsigned(region.extent)
            guard extent > 0, try umpAdd(cut, extent) <= umpUnsigned(source.extent) else { throw MidiFailure("captured loop trim exceeds original source") }
            let nanos = try umpNanoseconds(region.startSeconds)
            let start = try region.startNanoseconds?.rational(displaySeconds: region.startSeconds)
                ?? (UInt128(min(nanos, UInt64((region.startSeconds * 1e9).rounded(.down)))), 1)
            let window = try UmpLoopWindow(cycle: cycle, start: start, numer: source.timeline.clock.numer,
                denom: source.timeline.clock.denom, extent: extent, repetitions: region.repeatCount)
            var clip = UmpLoopClip(id: region.id, window: window, cut: cut, timed: timed)
            if let first = clip.first, let last = clip.last {
                var spans: [(UInt64, UInt64)] = [(first, first)]
                if last > first + 1 { spans.append((first + 1, last - 1)) }
                if last > first { spans.append((last, last)) }
                for (from, to) in spans {
                    let instance = clip.instance(master: 0, copy: from)!
                    let restored = try clip.entry(instance, host: window.deadline(phase: instance.entry, index: 0, initial: 0, anchor: 0),
                                                  initial: 0, anchor: 0, replacing: UmpFootprint())
                    let notes = try clip.analysis(instance)
                    var acquired = restored.heldNotes, effects = restored.events
                    for ordinal in clip.prefix(instance.localEntry)..<clip.prefix(instance.localEnd) {
                        let event = clip.events[ordinal]
                        switch UmpMessage(event).action {
                        case .on: acquired.insert(ordinal)
                        case .off:
                            guard let owner = notes.releaseOwners[ordinal], acquired.contains(owner) else { continue }
                            acquired.remove(owner)
                        case .kill, .release:
                            acquired = acquired.filter { UmpChannel(clip.events[$0]) != UmpChannel(event) }
                        default: break
                        }
                        effects.append(event)
                    }
                    let scope = Set(effects.compactMap(UmpChannel.init(voice:)))
                    for event in effects { potential.observe(UmpMessage(event)) }
                    wireEvents.append(contentsOf: effects)
                    clip.shapes.append(UmpLoopShape(first: from, last: to, scope: scope))
                }
            }
            clips.append(clip)
        }
        try potential.requireSupported()
        for (index, clip) in clips.enumerated() {
            for shape in clip.shapes {
                let instance = clip.instance(master: 0, copy: shape.first)!
                var previous = potential
                previous.touched = previous.touched.filter { field in shape.scope.contains { $0.contains(field.address) } }
                previous.addresses = previous.addresses.filter { address in shape.scope.contains { $0.contains(address) } }
                _ = try clip.entry(instance, host: clip.window.deadline(phase: instance.entry, index: 0, initial: 0, anchor: 0),
                                   initial: 0, anchor: 0, replacing: previous)
                let until = clip.instance(master: 0, copy: shape.last)!.end
                for other in clips.prefix(index) {
                    for peer in other.shapes where !shape.scope.isDisjoint(with: peer.scope) {
                        let first = other.instance(master: 0, copy: peer.first)!, last = other.instance(master: 0, copy: peer.last)!
                        guard !umpRationalLess(instance.entry, clip.window.divisor, last.end, other.window.divisor)
                            || !umpRationalLess(first.entry, other.window.divisor, until, clip.window.divisor) else {
                            throw MidiFailure("overlapping loop regions share physical MIDI channels")
                        }
                    }
                }
            }
        }
        let destinations = Set(clips.flatMap { $0.shapes.flatMap { $0.scope.map(\.source) } })
        self.cycle = cycle; self.clips = clips
        self.bindings = destinations.sorted().map { UmpBinding(source: $0, destination: $0) }
        self.compatibleEvents = wireEvents
    }
}

final class UmpLoopTransport: CoordinatedMidiTransport {
    let plan: UmpLoopPlan, output: UmpOutput
    var anchor: UInt64 = 0, terminalFailure: Error?
    var onCoordinatedFailure: ((String, Error?) -> Void)?, onCoordinatedEnd: (() -> Void)?
    enum State { case prepared, staged, playing, stopped }
    var state = State.prepared
    var offset: Double = 0, initial: [UInt128] = []
    var timer: DispatchSourceTimer?, generation: UInt64 = 0, batchHost: UInt64?, watermark: UInt64?
    struct Cursor { let instance: UmpLoopInstance, notes: UmpRestoration; var index: Int; var acquired: Set<Int> }
    var cursors: [Int: Cursor] = [:], completed: [Int: UmpLoopInstance] = [:]
    struct Action {
        enum Kind: Int { case close, enter, packet }
        let clip: Int, instance: UmpLoopInstance, phase: UInt128, kind: Kind
    }
    init(timeline: UmpArrangement, cycle: MidiCycle) throws {
        plan = try UmpLoopPlan(timeline: timeline, cycle: cycle); output = UmpOutput(bindings: plan.bindings, compatibleEvents: plan.compatibleEvents)
    }
    func prepare() throws {
        output.onFailure = { [weak self] error in self?.finish(reason: "destination-unavailable", error: error, publish: false) }
        try output.prepare()
    }
    func stageCoordinated(at seconds: Double) throws {
        guard Thread.isMainThread, state != .stopped, seconds.isFinite, seconds >= 0, seconds < plan.cycle.duration else {
            throw MidiFailure("invalid captured loop seek")
        }
        let phase = try plan.cycle.phaseParts(elapsed: 0, offset: seconds).remainder
        let initial = try plan.clips.map { try umpMultiply(phase, $0.window.masterScale) }
        for (index, clip) in plan.clips.enumerated() {
            if let source = try clip.window.sourcePhase(at: initial[index]),
               let instance = clip.instance(master: 0, copy: source.copy, initial: initial[index]) {
                _ = try clip.entry(instance, host: 0, initial: initial[index], anchor: 0, replacing: output.prior(in: clip.scope(source.copy)))
            }
        }
        try output.checkDestinations(); try output.silence()
        generation += 1; timer?.cancel(); timer = nil; cursors.removeAll(); completed.removeAll()
        watermark = nil; batchHost = nil; self.initial = initial; offset = seconds; state = .staged
    }
    func runCoordinated(anchorNanoseconds: UInt64) throws {
        guard state == .staged, anchorNanoseconds > DispatchTime.now().uptimeNanoseconds else { throw MidiFailure("captured loop missed the common epoch") }
        anchor = anchorNanoseconds; state = .playing; arm(anchorNanoseconds)
    }
    func position(at host: UInt64) -> Double {
        guard state == .playing else { return offset }
        do { return try plan.cycle.phase(elapsed: host > anchor ? host - anchor : 0, offset: offset).seconds }
        catch { finish(reason: "captured-loop-clock-failed", error: error, publish: false); return offset }
    }
    // Arithmetic lookup is bounded by the current native batch's at-most-two
    // master cycles, independent of missed cycles and finite source repeats.
    func candidate(_ index: Int, lower: (index: UInt128, remainder: UInt128),
                   upper: (index: UInt128, remainder: UInt128)) throws -> UmpLoopInstance? {
        let clip = plan.clips[index], window = clip.window
        guard let first = clip.first, let last = clip.last,
              clip.shapes.contains(where: { !$0.scope.isEmpty }) else { return nil }
        var master = lower.index
        if let done = completed[index] { master = max(master, done.master) }
        while master <= upper.index {
            let low = master == lower.index ? lower.remainder : 0, high = master == upper.index ? upper.remainder : window.period
            if let range = try window.copies(lower: low, upper: high) {
                var copy = max(first, range.lowerBound)
                if let done = completed[index], done.master == master { copy = max(copy, done.copy + 1) }
                if copy <= min(last, range.upperBound), let instance = clip.instance(master: master, copy: copy, initial: initial[index]),
                   instance.entry <= high, instance.end > low { return instance }
            }
            if master == upper.index { break }; master += 1
        }
        return nil
    }
    func nextAction(_ index: Int, host: UInt64) throws -> Action? {
        let clip = plan.clips[index]
        if let cursor = cursors[index] {
            if cursor.index < clip.prefix(cursor.instance.localEnd) {
                return try Action(clip: index, instance: cursor.instance, phase: clip.phase(cursor.index, in: cursor.instance), kind: .packet)
            }
            return Action(clip: index, instance: cursor.instance, phase: cursor.instance.end, kind: .close)
        }
        let batch = try clip.window.dueBatch(elapsed: host - anchor, initial: initial[index])
        guard let instance = try candidate(index, lower: batch.lower, upper: batch.upper) else { return nil }
        return Action(clip: index, instance: instance, phase: instance.entry, kind: .enter)
    }
    func deadline(_ action: Action) throws -> UInt64 {
        try plan.clips[action.clip].window.deadline(phase: action.phase, index: action.instance.master, initial: initial[action.clip], anchor: anchor)
    }
    func precedes(_ a: Action, _ b: Action) -> Bool {
        let aw = plan.clips[a.clip].window, bw = plan.clips[b.clip].window
        let am = a.instance.master + (a.phase == aw.period ? 1 : 0), bm = b.instance.master + (b.phase == bw.period ? 1 : 0)
        let ap = a.phase == aw.period ? 0 : a.phase, bp = b.phase == bw.period ? 0 : b.phase
        if am != bm { return am < bm }
        if umpRationalLess(ap, aw.divisor, bp, bw.divisor) { return true }
        if umpRationalLess(bp, bw.divisor, ap, aw.divisor) { return false }
        if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
        return a.clip < b.clip
    }
    // One original packet/boundary per continuation keeps stop/seek and device
    // notifications serviceable without imposing a message/time budget.
    func advanceBatch() throws -> Bool {
        guard state == .playing, let host = batchHost else { return false }
        var selected: Action?
        for index in plan.clips.indices {
            if let action = try nextAction(index, host: host), try deadline(action) <= host,
               selected == nil || precedes(action, selected!) { selected = action }
        }
        guard let action = selected else { watermark = host; batchHost = nil; try schedule(after: host); return false }
        let index = action.clip, clip = plan.clips[index], instance = action.instance
        switch action.kind {
        case .enter:
            let restore = try clip.entry(instance, host: host, initial: initial[index], anchor: anchor,
                                         replacing: output.prior(in: clip.scope(instance.copy)))
            cursors[index] = Cursor(instance: instance, notes: try clip.analysis(instance), index: restore.nextIndex, acquired: restore.heldNotes)
            for event in restore.events { try output.apply(event) }
        case .close:
            try output.silence(in: clip.scope(instance.copy)); cursors.removeValue(forKey: index); completed[index] = instance
        case .packet:
            var cursor = cursors[index]!, ordinal = cursor.index
            let event = clip.events[ordinal], message = UmpMessage(event)
            switch message.action {
            case .on:
                let exact = try deadline(action) == host
                let end = try clip.window.deadline(phase: instance.end, index: instance.master, initial: initial[index], anchor: anchor)
                let expired = try cursor.notes.expiredNotes[ordinal].map { expiry in
                    try clip.window.deadline(phase: clip.phase(expiry, in: instance), index: instance.master, initial: initial[index], anchor: anchor) <= host
                } ?? false
                if exact || end > host && !expired { cursor.acquired.insert(ordinal); cursors[index] = cursor; try output.apply(event) }
            case .off:
                if let owner = cursor.notes.releaseOwners[ordinal], cursor.acquired.contains(owner) {
                    try output.apply(event); cursor.acquired.remove(owner)
                }
            case .kill, .release:
                try output.apply(event); cursor.acquired = cursor.acquired.filter { UmpChannel(clip.events[$0]) != UmpChannel(event) }
            default: try output.apply(event)
            }
            cursor.index += 1; cursors[index] = cursor
        }
        return true
    }
    func arm(_ when: UInt64) {
        timer?.cancel(); let timer = DispatchSource.makeTimerSource(queue: .main); self.timer = timer
        let token = generation
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: when), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in guard let self, self.generation == token else { return }; self.tick() }; timer.resume()
    }
    func schedule(after host: UInt64) throws {
        guard state == .playing else { return }
        let first = plan.clips[0].window, phase = try first.phase(elapsed: host - anchor, initial: initial[0])
        var when = try first.deadline(phase: first.period, index: phase.index, initial: initial[0], anchor: anchor)
        for index in plan.clips.indices {
            let clip = plan.clips[index]
            if let cursor = cursors[index] {
                let end = clip.prefix(cursor.instance.localEnd)
                let phase = try cursor.index < end ? clip.phase(cursor.index, in: cursor.instance) : cursor.instance.end
                when = min(when, try clip.window.deadline(phase: phase, index: cursor.instance.master, initial: initial[index], anchor: anchor))
            } else {
                let p = try clip.window.phase(elapsed: host - anchor, initial: initial[index])
                if let next = try candidate(index, lower: p, upper: (p.index + 1, clip.window.period)) {
                    when = min(when, try clip.window.deadline(phase: next.entry, index: next.master, initial: initial[index], anchor: anchor))
                }
            }
        }
        guard when > host else { throw MidiFailure("captured loop did not advance its native deadline") }; arm(when)
    }
    func continueBatch(_ token: UInt64) {
        guard generation == token, state == .playing else { return }
        do { if try advanceBatch() { DispatchQueue.main.async { [weak self] in self?.continueBatch(token) } } }
        catch { finish(reason: "captured-loop-playback-failed", error: error, publish: false) }
    }
    func beginBatch(at host: UInt64) throws -> Bool {
        guard state == .playing, batchHost == nil else { return false }
        try output.checkDestinations()
        guard host >= anchor else { arm(anchor); return false }
        if watermark == host { try schedule(after: host); return false }
        batchHost = host; return true
    }
    func tick() {
        do { if try beginBatch(at: DispatchTime.now().uptimeNanoseconds) { continueBatch(generation) } }
        catch { finish(reason: "captured-loop-clock-failed", error: error, publish: false) }
    }
    func snapshot(_ kind: String) -> [String: Any] { ["bindings": output.snapshot()] }
    func finish(reason: String, error: Error?, publish: Bool) {
        guard state != .stopped else { return }
        state = .stopped; generation += 1; timer?.cancel(); timer = nil; batchHost = nil
        var failure = error
        do { try output.close() } catch { failure = failure ?? error }
        cursors.removeAll(); completed.removeAll(); terminalFailure = failure; onCoordinatedFailure?(reason, failure)
    }
}
