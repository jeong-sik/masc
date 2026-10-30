import Foundation

extension PracticePlan {
    func validate(loop backing: WaveLoopClock) throws {
        try backing.validate()
        guard let loop, duration == backing.duration, countInSeconds.isFinite, countInSeconds >= 0 else {
            throw AudioFailure("practice loop differs from its backing clock")
        }
        let (n, d) = try loop.lead()
        guard countInSeconds == Double(n) / Double(d) / 1e9,
              loop.metronome || n > 0 else { throw AudioFailure("invalid loop count-in duration") }
        _ = try PulseLoopLayout(loop: backing, pulse: PulseAudioClock(period: loop.period,
            beatsPerBar: loop.beatsPerBar, duration: backing.duration), unit: loop.unit, rate: 48000, frameCount: 576)
    }
}

// Sample the original song's notated beat grid inside an authored loop. A
// partial bar is still a partial bar on every pass; neither beat rounding nor
// source-buffer boundaries restart the meter or accumulate a new period.
struct PulseLoopLayout {
    let period: UInt128, divisor: UInt128
    let beat: UInt128, origin: UInt128, firstBeat: UInt128
    let beatsPerBar: UInt128, frameCount: Int64

    init(loop: WaveLoopClock, pulse: PulseAudioClock, unit: Int64,
         rate: Double, frameCount: Int64) throws {
        func gcd(_ a: UInt128, _ b: UInt128) -> UInt128 {
            var x = a, y = b
            while y > 0 { let r = x % y; x = y; y = r }
            return x
        }
        func multiply(_ a: UInt128, _ b: UInt128) throws -> UInt128 {
            let value = a.multipliedReportingOverflow(by: b)
            guard !value.overflow else { throw AudioFailure("loop pulse exceeds the native rational range") }
            return value.partialValue
        }
        func ratio(_ top: [UInt128], _ bottom: [UInt128]) throws -> (UInt128, UInt128) {
            var top = top, bottom = bottom
            for i in top.indices { for j in bottom.indices {
                let g = gcd(top[i], bottom[j]); top[i] /= g; bottom[j] /= g
            } }
            return (try top.reduce(1, multiply), try bottom.reduce(1, multiply))
        }
        // Validate before deriving duration: an untrusted end-start can itself
        // overflow even though the eventual layout would reject that clock.
        try loop.validate()
        guard unit > 0, unit & (unit - 1) == 0, pulse.duration == loop.duration else {
            throw AudioFailure("loop pulse disagrees with the authored meter or duration")
        }
        // Use the loop's own start as the source origin. Unused large absolute
        // song positions must not be multiplied by the exact tempo factor.
        let master = try loop.layout(rate: rate, projectTick: loop.start, frameCount: 1, repetitions: 1)
        let source = try pulse.layout(rate: rate, frameCount: frameCount)
        let beat = source.clock.period, beatDivisor = source.clock.divisor
        let factor = master.period / UInt128(loop.end - loop.start)
        let ticks = UInt128(loop.ppq) * 4
        let expected = try ratio([factor, ticks], [master.divisor, UInt128(unit)])
        guard !umpRationalLess(beat, beatDivisor, expected.0, expected.1),
              !umpRationalLess(expected.0, expected.1, beat, beatDivisor) else {
            throw AudioFailure("loop pulse tempo differs from the backing clock")
        }
        // Resolve the bar index in musical ticks before scaling to frames.
        // Keep only the proper beat fraction in the common native clock.
        let position = UInt128(loop.start) * UInt128(unit)
        let origin = try ratio([beat, position % ticks], [beatDivisor, ticks])
        let reduction = gcd(master.period, master.divisor)
        let masterPeriod = master.period / reduction, masterDivisor = master.divisor / reduction
        let pair = try multiply(masterDivisor / gcd(masterDivisor, beatDivisor), beatDivisor)
        let divisor = try multiply(pair / gcd(pair, origin.1), origin.1)
        self.period = try multiply(masterPeriod, divisor / masterDivisor)
        self.beat = try multiply(beat, divisor / beatDivisor)
        self.origin = try multiply(origin.0, divisor / origin.1)
        self.divisor = divisor; firstBeat = position / ticks
        beatsPerBar = UInt128(pulse.beatsPerBar); self.frameCount = source.clock.frameCount
    }

    func span(at frame: Int64, maximum: Int64) throws -> (source: Int64?, count: Int64, gain: Float) {
        guard frame >= 0, maximum > 0 else { throw AudioFailure("invalid loop pulse position") }
        // Compute the modular product at full width, without a narrower
        // frame*divisor intermediate or a cumulative rounded beat count.
        let product = (UInt128(frame) % period).multipliedFullWidth(by: divisor % period)
        let phase = period.dividingFullWidth(product).remainder
        var copy = phase / beat, local = phase % beat
        if local >= beat - origin { local -= beat - origin; copy += 1 }
        else { local += origin }
        func count(_ distance: UInt128) -> Int64 {
            let samples = distance / divisor + (distance % divisor == 0 ? 0 : 1)
            return Int64(min(UInt128(maximum), samples))
        }
        let untilBoundary = min(count(period - phase), count(beat - local))
        let sample = local / divisor
        let source = sample < UInt128(frameCount) ? Int64(sample) : nil
        let length = source.map { min(untilBoundary, frameCount - $0) } ?? untilBoundary
        let accent = (firstBeat % beatsPerBar + copy % beatsPerBar) % beatsPerBar == 0
        return (source, length, accent ? 1 : 0.5)
    }
}
