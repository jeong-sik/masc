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
// Continued-fraction comparison avoids cross products: ordinary fractional
// tempos can have exact binary denominators large enough to overflow UInt128.
func umpRationalLess(_ a: UInt128, _ b: UInt128, _ c: UInt128, _ d: UInt128) -> Bool {
    var a = a, b = b, c = c, d = d, reversed = false
    while true {
        let left = a / b, right = c / d
        if left != right { return reversed ? left > right : left < right }
        let ar = a % b, cr = c % d
        if ar == 0 || cr == 0 { return reversed ? ar > cr : ar < cr }
        a = b; b = ar; c = d; d = cr; reversed.toggle()
    }
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
struct CaptureStartNanoseconds: Decodable {
    let numerator: String
    let denominator: String
    func rational(displaySeconds: Double) throws -> (UInt128, UInt128) {
        let n = try umpUnsigned(numerator), d = try umpUnsigned(denominator)
        guard d > 0 else { throw MidiFailure("invalid captured placement denominator") }
        let secondsDenom = try umpMultiply(d, 1_000_000_000)
        let displayed = Double(n / secondsDenom) + Double(n % secondsDenom) / Double(secondsDenom)
        guard displayed == displaySeconds else { throw MidiFailure("captured placement display disagrees with exact start") }
        return (n, d)
    }
}
enum CaptureRegionComponent: String, Decodable { case audio, midi }
struct UmpRegion: Decodable {
    let id: String
    let source: String
    let startSeconds: Double
    let offset: String
    let extent: String
    let repeatCount: UInt64
    var component: CaptureRegionComponent? = nil
    var startNanoseconds: CaptureStartNanoseconds? = nil
}
struct UmpArrangement: Decodable {
    let schemaVersion: Int
    let duration: Double
    let sources: [UmpRegionSource]
    let regions: [UmpRegion]
}

// A source packet keeps its original host ticks. This window places those
// ticks on the authored master period without rounding either clock first.
struct UmpLoopWindow {
    let cycle: MidiCycle
    let period: UInt128, divisor: UInt128, masterScale: UInt128
    let sourcePeriod: UInt128, sourceEnd: UInt128, tick: UInt128
    let offset: Int128
    let repetitions: UInt64

    init(cycle: MidiCycle, start: (numerator: UInt128, divisor: UInt128),
         numer: UInt32, denom: UInt32, extent: UInt128, repetitions: UInt64) throws {
        guard let authoredOrigin = cycle.exactStart, start.divisor > 0, numer > 0, denom > 0,
              extent > 0, repetitions > 0 else { throw MidiFailure("captured looping requires exact original clocks") }
        func gcd(_ a: UInt128, _ b: UInt128) -> UInt128 {
            var a = a, b = b
            while b > 0 { let remainder = a % b; a = b; b = remainder }
            return a
        }
        func lcm(_ a: UInt128, _ b: UInt128) throws -> UInt128 { try umpMultiply(a / gcd(a, b), b) }
        func reduced(_ value: (numerator: UInt128, divisor: UInt128)) -> (numerator: UInt128, divisor: UInt128) {
            let factor = gcd(value.numerator, value.divisor)
            return (value.numerator / factor, value.divisor / factor)
        }
        let origin = reduced(authoredOrigin), start = reduced(start)
        let reduction = gcd(UInt128(numer), UInt128(denom))
        let sourceD = UInt128(denom) / reduction
        let first = try lcm(cycle.divisor, origin.divisor)
        let second = try lcm(first, start.divisor)
        let divisor = try lcm(second, sourceD)
        let masterScale = divisor / cycle.divisor
        let period = try umpMultiply(cycle.period, masterScale)
        let tick = try umpMultiply(UInt128(numer) / reduction, divisor / sourceD)
        let sourcePeriod = try umpMultiply(extent, tick)
        let sourceEnd = try umpMultiply(sourcePeriod, UInt128(repetitions))
        let a = origin.numerator / origin.divisor, b = start.numerator / start.divisor
        let ar = try umpMultiply(origin.numerator % origin.divisor, divisor / origin.divisor)
        let br = try umpMultiply(start.numerator % start.divisor, divisor / start.divisor)
        let positive = a > b || a == b && ar >= br
        var whole = positive ? a - b : b - a
        let from = positive ? ar : br, to = positive ? br : ar
        let part: UInt128
        if from >= to { part = from - to }
        else { whole -= 1; part = divisor - (to - from) }
        let distance = try umpAdd(umpMultiply(whole, divisor), part), bound = UInt128(Int128.max)
        guard period <= bound, sourceEnd <= bound, distance <= bound,
              !positive || distance <= bound - period else { throw MidiFailure("captured loop exceeds the native rational clock range") }
        self.cycle = cycle; self.period = period; self.divisor = divisor; self.masterScale = masterScale
        self.sourcePeriod = sourcePeriod; self.sourceEnd = sourceEnd; self.tick = tick
        self.offset = positive ? Int128(distance) : -Int128(distance); self.repetitions = repetitions
    }
    // Return original finite source-copy phase at an exact master remainder.
    func phase(remainder: UInt128) throws -> (copy: UInt64, local: UInt128)? {
        guard remainder < cycle.period else { throw MidiFailure("invalid captured master phase") }
        let phase = try umpMultiply(remainder, masterScale)
        return try sourcePhase(at: phase)
    }
    func sourcePhase(at phase: UInt128) throws -> (copy: UInt64, local: UInt128)? {
        guard phase < period else { throw MidiFailure("invalid captured master phase") }
        let position = Int128(phase) + offset
        guard position >= 0, UInt128(position) < sourceEnd else { return nil }
        return (UInt64(UInt128(position) / sourcePeriod), UInt128(position) % sourcePeriod)
    }
    func phase(elapsed: UInt64, initial: UInt128) throws -> (index: UInt128, remainder: UInt128) {
        guard initial < period else { throw MidiFailure("invalid captured epoch phase") }
        let product = UInt128(elapsed).multipliedFullWidth(by: divisor)
        let low = product.low.addingReportingOverflow(initial)
        let high = product.high.addingReportingOverflow(low.overflow ? 1 : 0)
        guard !high.overflow, high.partialValue < period else { throw MidiFailure("captured phase exceeds the host clock range") }
        let result = period.dividingFullWidth((high: high.partialValue, low: low.partialValue))
        return (result.quotient, result.remainder)
    }
    // ceil(t)==host is the whole exact interval (host-1,host], which may
    // cross a master boundary and many compressed original-copy boundaries.
    func dueBatch(elapsed: UInt64, initial: UInt128) throws ->
        (lower: (index: UInt128, remainder: UInt128), upper: (index: UInt128, remainder: UInt128), includesLower: Bool) {
        let upper = try phase(elapsed: elapsed, initial: initial)
        let lower = elapsed == 0 ? upper : try phase(elapsed: elapsed - 1, initial: initial)
        return (lower, upper, elapsed == 0)
    }
    func copies(lower: UInt128, upper: UInt128) throws -> ClosedRange<UInt64>? {
        guard lower <= upper, upper <= period else { throw MidiFailure("invalid captured batch interval") }
        let from = Int128(lower) + offset, to = Int128(upper) + offset
        guard to >= 0, from < Int128(sourceEnd) else { return nil }
        let first = from <= 0 ? 0 : UInt128(from) / sourcePeriod
        let last = min(UInt128(to), sourceEnd - 1) / sourcePeriod
        guard first <= last else { return nil }
        return UInt64(first)...UInt64(last)
    }
    // Exact half-open master membership is separate from its integer deadline.
    func packetPhase(copy: UInt64, delta: UInt128) throws -> UInt128? {
        guard copy < repetitions, delta < sourcePeriod else { throw MidiFailure("invalid captured packet source phase") }
        let source = try umpAdd(umpMultiply(UInt128(copy), sourcePeriod), delta)
        if offset >= 0 {
            let start = UInt128(offset)
            guard source >= start, source - start < period else { return nil }
            return source - start
        }
        let start = UInt128(-offset)
        guard start < period, source < period - start else { return nil }
        return source + start
    }
    // Difference first, then one ceil. A large valid common denominator may
    // make the absolute intermediate wider than UInt128 even for host UInt64.
    func deadline(phase: UInt128, index: UInt128, initial: UInt128, anchor: UInt64) throws -> UInt64 {
        guard phase <= period, initial < period else { throw MidiFailure("invalid captured loop deadline phase") }
        var wide = index.multipliedFullWidth(by: period)
        let sum = wide.low.addingReportingOverflow(phase)
        let high = wide.high.addingReportingOverflow(sum.overflow ? 1 : 0)
        guard !high.overflow, high.partialValue != 0 || sum.partialValue >= initial else {
            throw MidiFailure("captured packet precedes the common epoch")
        }
        let low = sum.partialValue.subtractingReportingOverflow(initial)
        wide = (high.partialValue - (low.overflow ? 1 : 0), low.partialValue)
        guard wide.high < divisor else { throw MidiFailure("captured deadline exceeds the host clock range") }
        let divided = divisor.dividingFullWidth(wide)
        let delay = try umpAdd(divided.quotient, divided.remainder == 0 ? 0 : 1)
        guard delay <= UInt128(UInt64.max - anchor) else { throw MidiFailure("captured deadline exceeds the host clock range") }
        return anchor + UInt64(delay)
    }
}
struct UmpRegionClip {
    let id: String
    let start: UInt64
    let origin: UInt64
    let phaseOffset: UInt128
    let lowerBound: UInt128
    let upperBound: UInt128
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
    let footprint: UmpFootprint
    var entryPrior = UmpFootprint()

    // A first copy follows only earlier regions on its channels; each repeat
    // also follows the copy before it.
    func prior(repeating: Bool) -> UmpFootprint {
        guard repeating else { return entryPrior }
        var value = entryPrior; value.formUnion(footprint); return value
    }
    func prefix(at scaledTime: UInt128, inclusive: Bool = true) -> Int {
        var low = 0, high = endIndex
        while low < high {
            let middle = low + (high - low) / 2
            let tick = UInt128(timed[middle].ticks) * numer
            if tick < scaledTime || inclusive && tick == scaledTime { low = middle + 1 } else { high = middle }
        }
        return low
    }
    func restore(at time: UInt128, deadline: (position: UInt64, copy: UInt64)? = nil, replacing previous: UmpFootprint) throws -> UmpRestoration {
        var before = prefix(at: time, inclusive: false)
        let through = prefix(at: time)
        if let deadline {
            // Source events in the current integer due batch are not history,
            // even when their exact rational timestamps lie between two ns.
            var low = 0, high = through
            while low < high {
                let middle = low + (high - low) / 2
                let tick = UInt128(timed[middle].ticks) * numer
                if tick < cut || next(copy: deadline.copy, index: middle) < deadline.position { low = middle + 1 }
                else { high = middle }
            }
            before = low
        }
        let expired = Set(expiredNotes.filter { _, ordinal in
            guard ordinal < through else { return false }
            guard let deadline else { return true }
            // A historical voice that overlaps the entry is audible in this
            // native batch even if its original release shares the deadline.
            // An expiry at the exact cut has zero overlap; a deadline before
            // this callback is genuinely expired history.
            return UInt128(timed[ordinal].ticks) * numer <= cut
                || self.deadline(copy: deadline.copy, delta: 0) != deadline.position
        }.map(\.key))
        return try umpRestoration(events, prefixCount: before, followingCount: through - before,
                                  preambleEndIndex: endIndex, excludingNotes: expired, replacing: previous)
    }
    func phase(at position: UInt64) -> (copy: UInt64, time: UInt128)? {
        guard position >= start, position < end else { return nil }
        let value = UInt128(position - origin) * denom - phaseOffset
        let copy = value / period
        guard copy < UInt128(repeatCount) else { return nil }
        return (UInt64(copy), cut + value % period)
    }
    func deadline(copy: UInt64, delta: UInt128) -> UInt64 {
        // Admission proves every repeated deadline fits in end <= UInt64max.
        let value = phaseOffset + UInt128(copy) * period + delta
        return origin + UInt64(value / denom + (value % denom == 0 ? 0 : 1))
    }
    func next(copy: UInt64, index: Int) -> UInt64 {
        if index < endIndex { return deadline(copy: copy, delta: UInt128(timed[index].ticks) * numer - cut) }
        return deadline(copy: copy, delta: period)
    }
}

extension UmpFootprint {
    func scoped(to scope: Set<UmpChannel>) -> UmpFootprint {
        var value = self
        value.touched = touched.filter { field in scope.contains { $0.contains(field.address) } }
        value.addresses = addresses.filter { address in scope.contains { $0.contains(address) } }
        return value
    }
    mutating func formUnion(_ other: UmpFootprint) {
        touched.formUnion(other.touched); addresses.formUnion(other.addresses); obstacles.formUnion(other.obstacles)
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
            let parsed = try source.timeline.timedEvents(allowEmpty: true)
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
            guard !region.id.isEmpty, region.component != .audio, let (source, timed) = sources[region.source], region.repeatCount > 0 else { throw MidiFailure("invalid captured region source or repetition") }
            let validStart = try umpNanoseconds(region.startSeconds)
            let startFraction = try region.startNanoseconds?.rational(displaySeconds: region.startSeconds)
                ?? (UInt128(min(validStart, UInt64((region.startSeconds * 1e9).rounded(.down)))), 1)
            let (startN, startD) = startFraction
            guard startN / startD <= UInt128(UInt64.max) else { throw MidiFailure("captured placement exceeds native host timeline") }
            let origin = UInt64(startN / startD), cut = try umpUnsigned(region.offset), length = try umpUnsigned(region.extent)
            let after = try umpAdd(cut, length), bound = try umpUnsigned(source.extent)
            guard length > 0, after <= bound else { throw MidiFailure("captured region exceeds its source bounds") }
            let numer = try umpMultiply(UInt128(source.timeline.clock.numer), startD)
            let denom = try umpMultiply(UInt128(source.timeline.clock.denom), startD)
            let phaseOffset = try umpMultiply(startN % startD, UInt128(source.timeline.clock.denom))
            let lowerBound = try umpAdd(umpMultiply(UInt128(origin), denom), phaseOffset)
            let startWide = UInt128(origin) + (phaseOffset == 0 ? 0 : 1)
            guard startWide <= UInt128(UInt64.max) else { throw MidiFailure("captured placement exceeds native host timeline") }
            let start = UInt64(startWide)
            let period = try umpMultiply(length, numer), scaledCut = try umpMultiply(cut, numer)
            _ = try umpMultiply(after, numer)
            let total = try umpMultiply(period, UInt128(region.repeatCount))
            let upperBound = try umpAdd(lowerBound, total)
            let end = upperBound / denom + (upperBound % denom == 0 ? 0 : 1)
            guard end > UInt128(start), end <= UInt128(duration) else { throw MidiFailure("captured region exceeds arrangement duration") }
            let endIndex = timed.firstIndex { UInt128($0.ticks) >= after } ?? timed.count
            let events = timed.map(\.event), scope = Set(events.prefix(endIndex).compactMap(UmpChannel.init(voice:)))
            // Every replayed prefix is part of this physical scope, even when
            // its keys were originally acquired before the cut.
            var own = UmpFootprint()
            for event in events.prefix(endIndex) { own.observe(UmpMessage(event)); potential.observe(UmpMessage(event)) }
            let notes = try umpRestoration(events, prefixCount: endIndex, replacing: UmpFootprint())
            admitted.append(UmpRegionClip(id: region.id, start: start, origin: origin, phaseOffset: phaseOffset,
                lowerBound: lowerBound, upperBound: upperBound, end: UInt64(end), repeatCount: region.repeatCount,
                cut: scaledCut, period: period, numer: numer, denom: denom, timed: timed, events: events, endIndex: endIndex, scope: scope, releaseOwners: notes.releaseOwners, expiredNotes: notes.expiredNotes, footprint: own))
        }
        try potential.requireSupported()
        for index in admitted.indices {
            var clip = admitted[index]
            for other in admitted.prefix(index) where !clip.scope.isDisjoint(with: other.scope) {
                let entersBeforeEnd = umpRationalLess(clip.lowerBound, clip.denom, other.upperBound, other.denom)
                let otherEntersBeforeEnd = umpRationalLess(other.lowerBound, other.denom, clip.upperBound, clip.denom)
                guard !entersBeforeEnd || !otherEntersBeforeEnd else { throw MidiFailure("overlapping captured regions share physical MIDI channels; select independent outputs") }
            }
            for other in admitted where umpRationalLess(other.lowerBound, other.denom, clip.lowerBound, clip.denom) {
                clip.entryPrior.formUnion(other.footprint.scoped(to: clip.scope))
            }
            // Entry events and silent preambles remain an original due stream.
            // Explicit baselines must precede each attack/relative use; they
            // cannot repair a historical live voice's patch or escape the cut.
            _ = try clip.restore(at: clip.cut, replacing: clip.prior(repeating: clip.repeatCount > 1))
            admitted[index] = clip
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
            let prior = output.prior(in: clip.scope), phase = clip.phase(at: position)
            if let phase { _ = try clip.restore(at: phase.time, replacing: prior) }
            // Admission proved each entry ahead after earlier regions and copies
            // only. After a seek back this owner may have changed more of its
            // state: refuse the seek rather than stop playback at that entry.
            if position < clip.start || phase.map({ $0.copy + 1 < clip.repeatCount }) == true {
                var ahead = clip.prior(repeating: phase != nil || clip.repeatCount > 1)
                ahead.formUnion(prior)
                _ = try clip.restore(at: clip.cut, replacing: ahead)
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
                    let restored = try clip.restore(at: phase.time, deadline: (position, phase.copy), replacing: output.prior(in: clip.scope))
                    for event in restored.events { try output.apply(event) }
                    cursors[clip.id] = Cursor(copy: phase.copy, index: restored.nextIndex, acquired: restored.heldNotes)
                }
                var cursor = cursors[clip.id]!
                let due = clip.prefix(at: phase.time)
                while cursor.index < due {
                    let ordinal = cursor.index, event = clip.events[ordinal], message = UmpMessage(event)
                    switch message.action {
                    case .on:
                        let exact = clip.next(copy: phase.copy, index: ordinal) == position
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
