import Foundation

struct PracticePlan: Decodable {
    let countInSeconds: Double
    let duration: Double
    var loop: LoopPracticePlan? = nil
}
// Authored beat count is separate from the backing phase. Its exact period is
// projected once onto the selected native host clock, never once per loop.
struct LoopPracticePlan: Decodable {
    let period: PulseAudioClock.Period
    let countInBeats: String
    let beatsPerBar: Int64
    let unit: Int64
    let metronome: Bool
    func lead() throws -> (UInt128, UInt128) {
        guard let beats = UInt128(countInBeats), String(beats) == countInBeats,
              let n = UInt128(period.numerator), n > 0, String(n) == period.numerator,
              let d = UInt128(period.denominator), d > 0, String(d) == period.denominator,
              beatsPerBar > 0, beats % UInt128(beatsPerBar) == 0 else { throw AudioFailure("invalid loop count-in clock") }
        var x = beats, y = d
        while y > 0 { let r = x % y; x = y; y = r }
        let product = n.multipliedReportingOverflow(by: beats / x)
        guard !product.overflow else { throw AudioFailure("count-in exceeds the native rational clock range") }
        return (product.partialValue, d / x)
    }
    func hostTicks(numer: UInt32, denom: UInt32) throws -> UInt64 {
        guard numer > 0, denom > 0 else { throw AudioFailure("invalid native host timebase") }
        let (n, d) = try lead()
        var top = [n, UInt128(denom)], bottom = [d, UInt128(numer)]
        for i in top.indices { for j in bottom.indices {
            var a = top[i], b = bottom[j]
            while b > 0 { let r = a % b; a = b; b = r }
            top[i] /= a; bottom[j] /= a
        } }
        func product(_ a: UInt128, _ b: UInt128) throws -> UInt128 {
            let result = a.multipliedReportingOverflow(by: b)
            guard !result.overflow else { throw AudioFailure("count-in exceeds the native host clock range") }
            return result.partialValue
        }
        let numerator = try top.reduce(1, product), denominator = try bottom.reduce(1, product)
        let ticks = numerator / denominator + (numerator % denominator == 0 ? 0 : 1)
        guard ticks <= UInt64.max else { throw AudioFailure("count-in exceeds the native host timeline") }
        return UInt64(ticks)
    }
}
struct PulseAudioClock: Decodable {
    struct Period: Decodable { let numerator: String; let denominator: String }
    let period: Period
    let beatsPerBar: Int64
    let duration: Double
    var beatCount: String? = nil
    func layout(rate: Double, frameCount: Int64) throws -> PulseAudioLayout {
        func integer(_ text: String) throws -> UInt128 {
            guard let value = UInt128(text), value > 0, String(value) == text else { throw AudioFailure("invalid practice clock fraction") }
            return value
        }
        func multiply(_ a: UInt128, _ b: UInt128) throws -> UInt128 {
            let result = a.multipliedReportingOverflow(by: b)
            guard !result.overflow else { throw AudioFailure("practice exceeds the native rational clock range") }
            return result.partialValue
        }
        func gcd(_ a: UInt128, _ b: UInt128) -> UInt128 {
            var x = a, y = b
            while y > 0 { let remainder = x % y; x = y; y = remainder }
            return x
        }
        let n = try integer(period.numerator), d = try integer(period.denominator)
        guard gcd(n, d) == 1, beatsPerBar > 0, duration.isFinite, duration > 0,
              rate.isFinite, rate > 0, rate.rounded(.down) == rate, rate <= Double(UInt32.max), frameCount > 0 else { throw AudioFailure("invalid practice clock bounds") }
        // Cancel factors before multiplying. The rational is nanoseconds/beat;
        // this layout is source frames/beat, independently of render quanta.
        let a = gcd(n, 1_000_000_000), b = gcd(UInt128(rate), d)
        let period = try multiply(n / a, UInt128(rate) / b)
        let divisor = try multiply(d / b, 1_000_000_000 / a)
        guard period >= divisor else { throw AudioFailure("practice beat is shorter than one source sample") }
        let frames = (duration * rate).rounded(.up)
        guard frames.isFinite, frames > 0, frames < Double(Int64.max) else { throw AudioFailure("practice exceeds the native frame timeline") }
        let total: Int64, copies: UInt128
        if let beatCount {
            copies = try integer(beatCount)
            let g = gcd(copies, divisor)
            let extent = try multiply(period, copies / g), denominator = divisor / g
            let exact = extent / denominator + (extent % denominator == 0 ? 0 : 1)
            guard exact > 0, exact <= UInt128(Int64.max) else { throw AudioFailure("count-in exceeds the native frame timeline") }
            total = Int64(exact)
        } else {
            total = Int64(frames)
            let bound = try multiply(UInt128(total), divisor)
            copies = bound / period + (bound % period == 0 ? 0 : 1)
        }
        guard copies > 0, copies <= UInt128(Int64.max) else { throw AudioFailure("practice exceeds the native repeat range") }
        _ = try multiply(period, copies)
        let length = Int64(min(UInt128(frameCount), period / divisor))
        return PulseAudioLayout(clock: CaptureAudioLayout(period: period, lead: 0, divisor: divisor,
            repetitions: Int64(copies), frameCount: length, totalFrames: total), beatsPerBar: beatsPerBar)
    }
}
struct PulseAudioLayout {
    let clock: CaptureAudioLayout
    let beatsPerBar: Int64
    var totalFrames: Int64 { clock.totalFrames }
    func span(at frame: Int64, maximum: Int64) -> (source: Int64?, count: Int64, gain: Float) {
        let span = clock.span(at: frame, maximum: min(maximum, totalFrames - frame))
        let copy = UInt128(frame) * clock.divisor / clock.period
        return (span.source, span.count, copy % UInt128(beatsPerBar) == 0 ? 1 : 0.5)
    }
}
