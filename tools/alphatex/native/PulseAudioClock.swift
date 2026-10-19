import Foundation

struct PracticePlan: Decodable {
    let countInSeconds: Double
    let duration: Double
}
struct PulseAudioClock: Decodable {
    struct Period: Decodable { let numerator: String; let denominator: String }
    let period: Period
    let beatsPerBar: Int64
    let duration: Double
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
        let total = Int64(frames), bound = try multiply(UInt128(total), divisor)
        let copies = bound / period + (bound % period == 0 ? 0 : 1)
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
