import Foundation
import CryptoKit
import Darwin

// Offline render inputs have source ports, not physical MIDI destinations.
// Each region/port receives an independent plug-in instance. The source clock,
// prefix chase and exact finite-copy edges reuse the live transport's types.
struct MidiRenderSource: Decodable {
    let id: String
    let duration: Double
    let events: [WireEvent]

    func messages() throws -> [WireEvent] {
        guard !id.isEmpty, duration.isFinite, duration > 0 else {
            throw MidiFailure("invalid VST render source")
        }
        var previous = 0.0, states: [Int: WireState] = [:], result: [WireEvent] = []
        for event in events {
            guard event.seconds.isFinite, event.seconds >= previous, event.seconds <= duration,
                  event.port >= 0, event.port < 128, !event.bytes.isEmpty else {
                throw MidiFailure("invalid or unordered VST source wire event")
            }
            var state = states[event.port] ?? WireState()
            let messages = try state.feed(event.bytes)
            // The VST host consumes complete messages. Fragment timing must not
            // be silently collapsed into the timestamp of a later terminator.
            try state.complete()
            for message in messages {
                var completeMessage = WireState()
                _ = try completeMessage.feed(message)
                try completeMessage.complete()
            }
            result.append(contentsOf: messages.map { WireEvent(seconds: event.seconds, port: event.port, bytes: $0) })
            states[event.port] = state; previous = event.seconds
        }
        guard !result.isEmpty else { throw MidiFailure("VST source has no MIDI wire messages") }
        return result
    }
}

struct MidiRenderPlan: Decodable {
    let schemaVersion: Int
    let kind: String
    let duration: Double
    let sources: [MidiRenderSource]
    let regions: [MidiRegionSpec]

    func compile() throws -> [MidiRegion] {
        guard schemaVersion == 1, kind == "vst-arrangement", duration.isFinite, duration > 0,
              duration * 1e9 < Double(UInt64.max), !regions.isEmpty,
              Set(sources.map(\.id)).count == sources.count,
              Set(regions.map(\.id)).count == regions.count else {
            throw MidiFailure("invalid VST arrangement render plan")
        }
        var messages: [String: [WireEvent]] = [:], lengths: [String: Double] = [:]
        for source in sources {
            messages[source.id] = try source.messages(); lengths[source.id] = source.duration
        }
        return try regions.map { spec in
            guard !spec.id.isEmpty, let events = messages[spec.source], let length = lengths[spec.source] else {
                throw MidiFailure("missing VST region source")
            }
            let region = try MidiRegion(spec: spec, sourceDuration: length, events: events)
            guard region.end <= duration else { throw MidiFailure("VST region exceeds the render clock") }
            return region
        }
    }
}

struct MidiRenderPart {
    let region: MidiRegion
    let port: Int

    // One file streams every finite copy. Repeated periods are always measured
    // from the original rational edge, never by adding rounded durations.
    func write(_ emit: (Double, [UInt8]) throws -> Void) throws {
        let events = region.events.filter { $0.port == port }
        let entry = midiRegionEntry(events, at: region.spec.sourceStart)
        var previous = SourceChase()
        var held: [UInt16: Int] = [:], pedals = Set<UInt16>()
        func send(_ at: Double, _ bytes: [UInt8]) throws {
            let status = bytes[0], channel = UInt16(status & 15), type = status & 0xf0
            try emit(at, bytes)
            if status == 0xff { held.removeAll(); pedals.removeAll() }
            else if bytes.count == 3 {
                let key = channel << 8 | UInt16(bytes[1])
                if type == 0x90 && bytes[2] > 0 { held[key, default: 0] += 1 }
                if type == 0x80 || type == 0x90 && bytes[2] == 0 { held[key] = max(0, (held[key] ?? 0) - 1) }
                if type == 0xb0 {
                    if [64, 66, 69].contains(bytes[1]) {
                        if bytes[2] >= 64 { pedals.insert(key) } else { pedals.remove(key) }
                    }
                    if bytes[1] == 121 { pedals = pedals.filter { $0 >> 8 != channel } }
                    if [120, 123, 124, 125, 126, 127].contains(bytes[1]) { held = held.filter { $0.key >> 8 != channel } }
                }
            }
        }
        for copy in 0..<region.spec.repeatCount {
            let at = region.boundary(copy) - region.start
            guard previous.touched.isSubset(of: entry.safeKnown) else {
                throw MidiFailure("VST region repeat needs a source baseline before sounding previously changed channels")
            }
            var permitted = previous
            permitted.touched.formIntersection(entry.model.known)
            for (_, bytes) in try entry.model.bootstrap(replacing: permitted) { try send(at, bytes) }
            var model = entry.model, next = entry.next
            while next < events.count && region.includes(events[next].seconds) {
                let event = events[next]
                try send(region.eventTime(event.seconds, copy: copy) - region.start, event.bytes)
                model.observe(event.bytes, port: port); next += 1
            }
            let end = region.boundary(copy + 1) - region.start
            // Cleanup follows messages actually emitted, including source reset,
            // channel-mode release and Hold 2. Released pedal-held voices need
            // only their pedal release, not another synthesized Note Off.
            for (key, count) in held.sorted(by: { $0.key < $1.key }) {
                for _ in 0..<count { try send(end, [0x80 | UInt8(key >> 8), UInt8(key & 127), 0]) }
            }
            for key in pedals.sorted() { try send(end, [0xb0 | UInt8(key >> 8), UInt8(key & 127), 0]) }
            previous = model
            for key in previous.channels.keys { previous.channels[key]?.notes.removeAll() }
        }
    }
}

// Publishes only within a newly owned directory. The caller owns cancellation
// and removes its preparation tree after the native child actually closes.
func exportMidiRenderPlan(path: String, directory: String) throws -> [String: Any] {
    let plan = try JSONDecoder().decode(MidiRenderPlan.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let regions = try plan.compile(), root = URL(fileURLWithPath: directory, isDirectory: true)
    guard mkdir(root.path, 0o700) == 0 else {
        throw MidiFailure("cannot acquire VST MIDI render directory: errno \(errno)")
    }
    var complete = false
    defer { if !complete { try? FileManager.default.removeItem(at: root) } }
    var parts: [[String: Any]] = []
    for region in regions {
        let ports = Set(region.events.filter { region.includes($0.seconds) }.map(\.port)).sorted()
        for port in ports {
            let file = root.appendingPathComponent("part-\(parts.count).jsonl")
            let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw MidiFailure("cannot create VST MIDI render part: errno \(errno)") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var hash = SHA256(), count = 0
            let duration = region.end - region.start
            func row(_ value: [String: Any]) throws {
                var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); bytes.append(10)
                try handle.write(contentsOf: bytes); hash.update(data: bytes)
            }
            do {
                try row(["schemaVersion": 1, "kind": "vst-midi-part", "duration": duration])
                try MidiRenderPart(region: region, port: port).write { seconds, bytes in
                    try row(["seconds": seconds, "bytes": bytes]); count += 1
                }
                try handle.close()
            } catch { try? handle.close(); throw error }
            parts.append(["id": parts.count, "region": region.spec.id, "source": region.spec.source, "port": port,
                          "path": file.path, "startSeconds": region.start, "duration": duration,
                          "eventCount": count, "sha256": hash.finalize().map { String(format: "%02x", $0) }.joined()])
        }
    }
    guard !parts.isEmpty else { throw MidiFailure("VST arrangement contains no render parts") }
    let result: [String: Any] = ["schemaVersion": 1, "kind": "vst-render-parts", "duration": plan.duration, "parts": parts]
    try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: root.appendingPathComponent("manifest.json"), options: [.withoutOverwriting])
    complete = true
    return result
}
