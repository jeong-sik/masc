import Foundation

// The authored beat window is shared by every source-rate stream. Resolve each
// absolute sample against its rational cycle, rather than accumulating rounded
// frame counts at successive wraps. Source clips and finite repeats stay intact.
struct WaveLoopClock: Decodable {
    let start: Int64, end: Int64, ppq: Int64
    let tempo: Double
    var duration: Double { Double(end - start) / Double(ppq) * 60 / tempo }
    func validate() throws {
        guard start >= 0, end > start, end <= 9_007_199_254_740_991, ppq == 960,
              tempo.isFinite, tempo > 0, duration.isFinite, duration > 0,
              duration * 1e9 < Double(UInt64.max) else { throw AudioFailure("invalid audio loop clock") }
    }
    func midiCycle() throws -> MidiCycle {
        let clock = try layout(rate: 1e9, projectTick: start, frameCount: 1, repetitions: 1)
        let reduction = loopGCD(UInt128(start), clock.divisor)
        let origin = try loopMultiply(UInt128(start) / reduction, clock.period / UInt128(end - start))
        return try MidiCycle(start: Double(start) / Double(ppq) * 60 / tempo,
                             end: Double(end) / Double(ppq) * 60 / tempo,
                             duration: duration, period: clock.period, divisor: clock.divisor,
                             exactStart: (origin, clock.divisor / reduction))
    }
    func layout(rate: Double, projectTick: Int64, frameCount: Int64, repetitions: Int64) throws -> WaveLoopLayout {
        try validate()
        guard projectTick >= 0, projectTick <= 9_007_199_254_740_991,
              rate.isFinite, rate > 0, rate.rounded(.down) == rate, rate <= Double(UInt32.max),
              frameCount > 0, repetitions > 0 else { throw AudioFailure("invalid audio loop source clock") }
        // Decode the actual binary64 tempo; no decimal approximation or new
        // user preference controls the clock.
        let bits = tempo.bitPattern, exponent = Int((bits >> 52) & 2047)
        var n = UInt128(bits & ((1 << 52) - 1)) + (exponent == 0 ? 0 : UInt128(1) << 52)
        var shift = exponent == 0 ? -1074 : exponent - 1075
        while n & 1 == 0 { n >>= 1; shift += 1 }
        guard shift > -128, shift < 128, shift <= 0 || n <= UInt128.max >> shift else { throw AudioFailure("audio loop exceeds the native rational clock range") }
        let d: UInt128
        if shift < 0 { d = UInt128(1) << -shift } else { n <<= shift; d = 1 }
        var top: [UInt128] = [60, UInt128(rate), d], bottom: [UInt128] = [UInt128(ppq), n]
        for i in top.indices { for j in bottom.indices {
            let g = loopGCD(top[i], bottom[j]); top[i] /= g; bottom[j] /= g
        } }
        let factor = try top.reduce(UInt128(1)) { try loopMultiply($0, $1) }
        let divisor = try bottom.reduce(UInt128(1)) { try loopMultiply($0, $1) }
        let period = try loopMultiply(UInt128(end - start), factor)
        let distance = try loopMultiply(UInt128(start >= projectTick ? start - projectTick : projectTick - start), factor)
        let frames = frameCount.multipliedReportingOverflow(by: repetitions)
        guard !frames.overflow, frames.partialValue > 0 else { throw AudioFailure("audio loop source exceeds the native frame range") }
        let sourceEnd = try loopMultiply(UInt128(frames.partialValue), divisor)
        let signedMax = UInt128(Int128.max)
        guard period >= divisor, period <= signedMax, distance <= signedMax, sourceEnd <= signedMax,
              start < projectTick || distance <= signedMax - period else { throw AudioFailure("audio loop is not representable at source sample precision") }
        return WaveLoopLayout(period: period, divisor: divisor,
            offset: start >= projectTick ? Int128(distance) : -Int128(distance), sourceEnd: sourceEnd,
            sourcePeriod: try loopMultiply(UInt128(frameCount), divisor), lead: 0, frameCount: frameCount)
    }
    func layout(rate: Double, start: ExactNanoseconds, startSeconds: Double, capture: CaptureAudioLayout) throws -> WaveLoopLayout {
        let master = try layout(rate: rate, projectTick: 0, frameCount: 1, repetitions: 1)
        let (startN, startD) = try start.rational(displaySeconds: startSeconds)
        var top = [startN, UInt128(rate)], bottom = [startD, UInt128(1_000_000_000)]
        for i in top.indices { for j in bottom.indices {
            let g = loopGCD(top[i], bottom[j]); top[i] /= g; bottom[j] /= g
        } }
        let placement = try top.reduce(UInt128(1)) { try loopMultiply($0, $1) }
        let placementDivisor = try bottom.reduce(UInt128(1)) { try loopMultiply($0, $1) }
        let masterGCD = loopGCD(loopGCD(master.period, UInt128(master.offset)), master.divisor)
        let sourceGCD = loopGCD(loopGCD(capture.period, capture.lead), capture.divisor)
        let masterDivisor = master.divisor / masterGCD, sourceDivisor = capture.divisor / sourceGCD
        let pair = try loopMultiply(masterDivisor / loopGCD(masterDivisor, sourceDivisor), sourceDivisor)
        let divisor = try loopMultiply(pair / loopGCD(pair, placementDivisor), placementDivisor)
        let masterScale = divisor / masterDivisor, sourceScale = divisor / sourceDivisor
        let period = try loopMultiply(master.period / masterGCD, masterScale)
        // Subtract whole positions before scaling: two large project origins
        // can have a small, exactly representable relative placement.
        let masterOffset = UInt128(master.offset) / masterGCD
        let masterWhole = masterOffset / masterDivisor, clipWhole = placement / placementDivisor
        let masterPart = try loopMultiply(masterOffset % masterDivisor, masterScale)
        let clipPart = try loopMultiply(placement % placementDivisor, divisor / placementDivisor)
        let positive = masterWhole > clipWhole || masterWhole == clipWhole && masterPart >= clipPart
        var whole = positive ? masterWhole - clipWhole : clipWhole - masterWhole
        let from = positive ? masterPart : clipPart, to = positive ? clipPart : masterPart
        let part: UInt128
        if from >= to { part = from - to }
        else { whole -= 1; part = divisor - (to - from) }
        let sum = try loopMultiply(whole, divisor).addingReportingOverflow(part)
        guard !sum.overflow else { throw AudioFailure("captured audio loop placement exceeds the native rational clock range") }
        let distance = sum.partialValue
        let sourcePeriod = try loopMultiply(capture.period / sourceGCD, sourceScale)
        let lead = try loopMultiply(capture.lead / sourceGCD, sourceScale)
        let sourceEnd = try loopMultiply(sourcePeriod, UInt128(capture.repetitions))
        let signedMax = UInt128(Int128.max)
        guard period >= divisor, period <= signedMax, distance <= signedMax, sourceEnd <= signedMax,
              !positive || distance <= signedMax - period else {
            throw AudioFailure("captured audio loop is not representable at source sample precision")
        }
        return WaveLoopLayout(period: period, divisor: divisor,
            offset: positive ? Int128(distance) : -Int128(distance), sourceEnd: sourceEnd,
            sourcePeriod: sourcePeriod, lead: lead, frameCount: capture.frameCount)
    }
}
private func loopGCD(_ a: UInt128, _ b: UInt128) -> UInt128 {
    var x = a, y = b
    while y > 0 { let r = x % y; x = y; y = r }
    return x
}
private func loopMultiply(_ a: UInt128, _ b: UInt128) throws -> UInt128 {
    let result = a.multipliedReportingOverflow(by: b)
    guard !result.overflow else { throw AudioFailure("audio loop exceeds the native rational clock range") }
    return result.partialValue
}
struct WaveLoopLayout {
    let period: UInt128, divisor: UInt128
    let offset: Int128
    let sourceEnd: UInt128
    let sourcePeriod: UInt128, lead: UInt128
    let frameCount: Int64
    func span(at frame: Int64, maximum: Int64) throws -> (source: Int64?, count: Int64) {
        guard frame >= 0, maximum > 0 else { throw AudioFailure("invalid audio loop stream position") }
        // The reduced operands keep the full-width quotient representable.
        // Large exact clock denominators must not shorten a valid stream.
        let product = (UInt128(frame) % period).multipliedFullWidth(by: divisor % period)
        let phase = period.dividingFullWidth(product).remainder
        func count(_ distance: UInt128) -> Int64 {
            let frames = distance / divisor + (distance % divisor == 0 ? 0 : 1)
            return Int64(min(UInt128(maximum), frames))
        }
        let untilWrap = count(period - phase), position = Int128(phase) + offset
        if position < 0 { return (nil, min(untilWrap, count(UInt128(-position)))) }
        if UInt128(position) >= sourceEnd { return (nil, untilWrap) }
        let local = UInt128(position) % sourcePeriod
        if local < lead { return (nil, min(untilWrap, count(lead - local))) }
        let source = (local - lead) / divisor
        if source >= UInt128(frameCount) { return (nil, min(untilWrap, count(sourcePeriod - local))) }
        return (Int64(source), min(untilWrap, frameCount - Int64(source)))
    }
}
