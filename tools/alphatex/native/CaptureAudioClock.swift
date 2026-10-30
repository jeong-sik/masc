import Foundation

struct AudioFailure: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
}

// A captured clip repeats in its original host-clock domain, including silent
// pre-roll and tails. Sample boundaries are rounded once from each absolute
// cycle position; rounding one period and accumulating it would drift.
struct CaptureAudioClock: Decodable {
    let origin: String
    let offset: String
    let extent: String
    let numer: UInt32
    let denom: UInt32
    let firstAudioHostTime: String

    func layout(rate: Double, offsetFrames: Int64, frameCount: Int64, repetitions: Int64) throws -> CaptureAudioLayout {
        func integer(_ text: String, host: Bool = false) throws -> UInt128 {
            guard let value = UInt128(text), String(value) == text, !host || value <= UInt128(UInt64.max) else {
                throw AudioFailure("invalid captured audio clock integer")
            }
            return value
        }
        func multiply(_ a: UInt128, _ b: UInt128) throws -> UInt128 {
            let value = a.multipliedReportingOverflow(by: b)
            guard !value.overflow else { throw AudioFailure("captured audio exceeds the native rational clock range") }
            return value.partialValue
        }
        func add(_ a: UInt128, _ b: UInt128) throws -> UInt128 {
            let value = a.addingReportingOverflow(b)
            guard !value.overflow else { throw AudioFailure("captured audio exceeds the native rational clock range") }
            return value.partialValue
        }
        let start = try integer(origin, host: true), audio = try integer(firstAudioHostTime, host: true)
        let cut = try integer(offset), length = try integer(extent)
        guard numer > 0, denom > 0, length > 0, audio >= start,
              rate.isFinite, rate > 0, rate.rounded(.down) == rate, rate <= Double(UInt32.max),
              offsetFrames >= 0, frameCount > 0, repetitions > 0 else { throw AudioFailure("invalid captured audio clock bounds") }
        let divisor = UInt128(denom) * 1_000_000_000
        let factor = UInt128(numer) * UInt128(rate)
        let period = try multiply(length, factor)
        let source = try add(multiply(audio - start, factor), multiply(UInt128(offsetFrames), divisor))
        let trim = try multiply(cut, factor)
        guard source >= trim else { throw AudioFailure("captured audio begins before the region cut") }
        let lead = source - trim
        guard try add(lead, multiply(UInt128(frameCount), divisor)) <= period else {
            throw AudioFailure("captured audio frames extend beyond their clock interval")
        }
        let total = try multiply(period, UInt128(repetitions))
        // AVAudioFramePosition is signed 64-bit. The rational multiplication is
        // checked before division and never traps on an untrusted plan.
        let totalFrames = total / divisor + (total % divisor == 0 ? 0 : 1)
        guard totalFrames > 0, totalFrames <= UInt128(Int64.max) else { throw AudioFailure("captured audio exceeds the native frame timeline") }
        return CaptureAudioLayout(period: period, lead: lead, divisor: divisor, repetitions: repetitions,
                                  frameCount: frameCount, totalFrames: Int64(totalFrames))
    }
}

struct CaptureAudioLayout {
    let period: UInt128
    let lead: UInt128
    let divisor: UInt128
    let repetitions: Int64
    let frameCount: Int64
    let totalFrames: Int64

    func start(_ copy: Int64) -> Int64 {
        let value = period * UInt128(copy) + lead
        return Int64(value / divisor + (value % divisor == 0 ? 0 : 1))
    }
    // Locate a copy arithmetically, including after a far seek. Storage and
    // admission cost do not depend on the number of repeated copies.
    func span(at frame: Int64, maximum: Int64) -> (source: Int64?, count: Int64) {
        precondition(frame >= 0 && frame < totalFrames && maximum > 0)
        var low: Int64 = 0, high = repetitions
        while low < high {
            let middle = low + (high - low) / 2
            if start(middle) <= frame { low = middle + 1 } else { high = middle }
        }
        if low > 0 {
            let local = frame - start(low - 1)
            if local < frameCount { return (local, min(maximum, frameCount - local)) }
        }
        let after = low < repetitions ? start(low) : totalFrames
        return (nil, min(maximum, after - frame))
    }
}
