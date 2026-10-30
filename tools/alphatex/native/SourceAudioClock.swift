import Foundation

// Rendered PCM is a projection of the original MIDI performance. Its samples
// do not replace the exact source cut/copy period, including empty sample cuts.
struct SourceAudioClock: Decodable {
    let start: String, end: String, denominator: String
    func layout(rate: Double, offsetFrames: Int64, frameCount: Int64, repetitions: Int64) throws -> SourceAudioLayout {
        func integer(_ text: String) throws -> UInt128 {
            guard let value = UInt128(text), String(value) == text else { throw AudioFailure("invalid source audio fraction") }
            return value
        }
        let a = try integer(start), b = try integer(end), d = try integer(denominator)
        guard d > 0, b > a, offsetFrames >= 0, frameCount >= 0, repetitions > 0,
              rate.isFinite, rate > 0, rate.rounded(.down) == rate, rate <= Double(UInt32.max) else {
            throw AudioFailure("invalid source audio bounds")
        }
        let first = try sourceMultiply(a, UInt128(rate)), last = try sourceMultiply(b, UInt128(rate))
        let offset = sourceCeil(first, d), after = sourceCeil(last, d)
        guard offset == UInt128(offsetFrames), after - offset == UInt128(frameCount) else {
            throw AudioFailure("source audio sample cut differs from the original clock")
        }
        let period = last - first, residual = first % d
        let lead = residual == 0 ? 0 : d - residual
        let g = sourceGCD(sourceGCD(period, lead), d)
        let reducedPeriod = period / g, divisor = d / g
        let total = try sourceMultiply(reducedPeriod, UInt128(repetitions))
        let frames = sourceCeil(total, divisor)
        guard frames > 0, frames <= UInt128(Int64.max) else { throw AudioFailure("source audio exceeds the native frame timeline") }
        return SourceAudioLayout(period: reducedPeriod, lead: lead / g, divisor: divisor,
                                 repetitions: repetitions, frameCount: frameCount, totalFrames: Int64(frames))
    }
}
private func sourceGCD(_ a: UInt128, _ b: UInt128) -> UInt128 {
    var x = a, y = b
    while y > 0 { let r = x % y; x = y; y = r }
    return x
}
private func sourceMultiply(_ a: UInt128, _ b: UInt128) throws -> UInt128 {
    let result = a.multipliedReportingOverflow(by: b)
    guard !result.overflow else { throw AudioFailure("source audio exceeds the native rational clock range") }
    return result.partialValue
}
private func sourceCeil(_ n: UInt128, _ d: UInt128) -> UInt128 { n / d + (n % d == 0 ? 0 : 1) }

struct SourceAudioLayout {
    let period: UInt128, lead: UInt128, divisor: UInt128
    let repetitions: Int64, frameCount: Int64, totalFrames: Int64
    func span(at frame: Int64, maximum: Int64) -> (source: Int64?, count: Int64) {
        precondition(frame >= 0 && frame < totalFrames && maximum > 0)
        let available = min(maximum, totalFrames - frame)
        if frameCount == 0 { return (nil, available) }
        // Full-width modulo retains phase after a far seek without multiplying
        // a rounded period, or expanding the compressed finite copies.
        let phase = period.dividingFullWidth(UInt128(frame).multipliedFullWidth(by: divisor)).remainder
        let untilCopy = Int64(min(UInt128(available), sourceCeil(period - phase, divisor)))
        if phase < lead { return (nil, min(untilCopy, Int64(min(UInt128(available), sourceCeil(lead - phase, divisor))))) }
        let source = (phase - lead) / divisor
        if source >= UInt128(frameCount) { return (nil, untilCopy) }
        return (Int64(source), min(untilCopy, frameCount - Int64(source)))
    }
}
