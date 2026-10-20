import Synchronization

struct PcmFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

// Single control-thread producer / single audio-thread consumer. Samples are
// published after copying and retired after reading, using release/acquire.
// The render path neither allocates, locks, logs nor calls the producer.
@available(macOS 15.0, *)
final class PcmRing {
    let capacity: Int
    let samples: UnsafeMutablePointer<Float>
    let written = Atomic<UInt64>(0)
    let read = Atomic<UInt64>(0)
    let fault = Atomic<Int32>(0) // 1: underrun, 2: callback format
    let faultFrames = Atomic<UInt64>(0)
    let missing = Atomic<UInt64>(0)
    let stopped = Atomic<Bool>(false)

    init(capacity: Int) throws {
        guard capacity > 0, capacity <= Int.max / 2 else { throw PcmFailure("invalid PCM queue capacity") }
        self.capacity = capacity
        samples = .allocate(capacity: capacity * 2)
        samples.initialize(repeating: 0, count: capacity * 2)
    }
    deinit { samples.deallocate() }
    var available: UInt64 { written.load(ordering: .acquiring) - read.load(ordering: .acquiring) }
    // Only the single audio callback writes these fields. Preserve its first
    // fault; later invalid callbacks cannot relabel an existing underrun.
    func rejectFormat(frames: Int) {
        guard fault.load(ordering: .relaxed) == 0 else { return }
        faultFrames.store(UInt64(frames), ordering: .relaxed)
        fault.store(2, ordering: .releasing)
    }
    func append(_ values: [Float]) throws {
        guard !stopped.load(ordering: .acquiring), fault.load(ordering: .acquiring) == 0 else { throw PcmFailure("PCM output is retired") }
        guard !values.isEmpty, values.count % 2 == 0, values.allSatisfy(\.isFinite) else { throw PcmFailure("invalid finite stereo PCM") }
        let count = values.count / 2, start = written.load(ordering: .relaxed)
        let (end, overflow) = start.addingReportingOverflow(UInt64(count))
        guard !overflow, UInt64(count) <= UInt64(capacity) - available else { throw PcmFailure("PCM producer exceeded output capacity") }
        for index in 0..<count {
            let slot = Int((start + UInt64(index)) % UInt64(capacity)) * 2
            samples[slot] = values[index * 2]; samples[slot + 1] = values[index * 2 + 1]
        }
        written.store(end, ordering: .releasing)
    }
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        if stopped.load(ordering: .acquiring) || fault.load(ordering: .relaxed) != 0 {
            left.update(repeating: 0, count: frames); right.update(repeating: 0, count: frames)
            return
        }
        let start = read.load(ordering: .relaxed)
        let count = min(frames, Int(written.load(ordering: .acquiring) - start))
        for index in 0..<count {
            let slot = Int((start + UInt64(index)) % UInt64(capacity)) * 2
            left[index] = samples[slot]; right[index] = samples[slot + 1]
        }
        if count < frames {
            left.advanced(by: count).update(repeating: 0, count: frames - count)
            right.advanced(by: count).update(repeating: 0, count: frames - count)
            missing.store(UInt64(frames - count), ordering: .releasing)
            faultFrames.store(UInt64(frames), ordering: .relaxed)
            fault.store(1, ordering: .releasing)
        }
        read.store(start + UInt64(count), ordering: .releasing)
    }
}
