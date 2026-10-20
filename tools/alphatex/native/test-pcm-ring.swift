import Foundation
import Synchronization

@main struct RingTests {
    static func main() throws {
        if #available(macOS 15.0, *) {
            let ring = try PcmRing(capacity: 4)
            try ring.append([1, -1, 2, -2, 3, -3])
            var left = [Float](repeating: 9, count: 3), right = left
            left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
                ring.render(frames: 2, left: l.baseAddress!, right: r.baseAddress!)
            } }
            precondition(Array(left.prefix(2)) == [1, 2] && Array(right.prefix(2)) == [-1, -2])
            try ring.append([4, -4, 5, -5, 6, -6]) // wraps without replacing unread3
            do { try ring.append([7, -7]); preconditionFailure("overflow accepted") } catch {}
            do { try ring.append([7, -7, .nan, 0]); preconditionFailure("nonfinite accepted") } catch {}
            precondition(ring.written.load(ordering: .acquiring) == 6)
            left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
                ring.render(frames: 3, left: l.baseAddress!, right: r.baseAddress!)
            } }
            precondition(left == [3, 4, 5] && right == [-3, -4, -5])
            left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
                ring.render(frames: 3, left: l.baseAddress!, right: r.baseAddress!)
            } }
            precondition(left == [6, 0, 0] && right == [-6, 0, 0])
            precondition(ring.missing.load(ordering: .acquiring) == 2 && ring.available == 0)
            precondition(ring.faultFrames.load(ordering: .acquiring) == 3)
            ring.rejectFormat(frames: 99)
            precondition(ring.fault.load(ordering: .acquiring) == 1 && ring.faultFrames.load(ordering: .acquiring) == 3)
            do { try ring.append([7, -7]); preconditionFailure("retired queue accepted PCM") } catch {}
            print("PCM_RING_WRAP_OVERFLOW_UNDERRUN_PASS")

            let invalidFormat = try PcmRing(capacity: 4)
            invalidFormat.rejectFormat(frames: 3)
            invalidFormat.rejectFormat(frames: 4)
            precondition(invalidFormat.fault.load(ordering: .acquiring) == 2)
            precondition(invalidFormat.faultFrames.load(ordering: .acquiring) == 3 && invalidFormat.missing.load(ordering: .acquiring) == 0)
            print("PCM_RING_FIRST_FORMAT_FAULT_PASS")

            let parallel = try PcmRing(capacity: 128)
            let total = 20_000
            DispatchQueue.concurrentPerform(iterations: 2) { lane in
                if lane == 0 {
                    for n in 1...total {
                        while parallel.available == UInt64(parallel.capacity) {}
                        try! parallel.append([Float(n), -Float(n)])
                    }
                } else {
                    let l = UnsafeMutablePointer<Float>.allocate(capacity: 1), r = UnsafeMutablePointer<Float>.allocate(capacity: 1)
                    defer { l.deallocate(); r.deallocate() }
                    for n in 1...total {
                        // The consumer owns read; written can only grow here.
                        while parallel.written.load(ordering: .acquiring) == parallel.read.load(ordering: .relaxed) {}
                        parallel.render(frames: 1, left: l, right: r)
                        precondition(l.pointee == Float(n) && r.pointee == -Float(n))
                    }
                }
            }
            precondition(parallel.available == 0 && parallel.fault.load(ordering: .acquiring) == 0)
            parallel.stopped.store(true, ordering: .releasing)
            left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
                parallel.render(frames: 3, left: l.baseAddress!, right: r.baseAddress!)
            } }
            precondition(left == [0, 0, 0] && right == [0, 0, 0])
            precondition(parallel.read.load(ordering: .acquiring) == UInt64(total))
            print("PCM_RING_CONCURRENT_STEREO_RETIRE_PASS")
        }
    }
}
