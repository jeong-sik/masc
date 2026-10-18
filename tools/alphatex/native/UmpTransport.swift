import Foundation
import CoreMIDI

// Both native MIDI owners run on the audio owner's main lifecycle. Their
// protocols and state models remain distinct; no UMP is translated to bytes.
protocol CoordinatedMidiTransport: AnyObject {
    var anchor: UInt64 { get }
    var terminalFailure: Error? { get }
    var onCoordinatedFailure: ((String, Error?) -> Void)? { get set }
    var onCoordinatedEnd: (() -> Void)? { get set }
    func prepare() throws
    func stageCoordinated(at seconds: Double) throws
    func runCoordinated(anchorNanoseconds: UInt64) throws
    func position(at host: UInt64) -> Double
    func snapshot(_ kind: String) -> [String: Any]
    func finish(reason: String, error: Error?, publish: Bool)
}
extension MidiTransport: CoordinatedMidiTransport {}

struct UmpClock: Decodable {
    let origin: String
    let numer: UInt32
    let denom: UInt32
    func ticks(_ host: String) throws -> UInt64 {
        guard let start = UInt64(origin), String(start) == origin,
              let time = UInt64(host), String(time) == host, time >= start, numer > 0, denom > 0 else { throw MidiFailure("invalid captured UMP clock") }
        return time - start
    }
    func seconds(_ host: String) throws -> Double {
        let delta = try ticks(host), divisor = UInt64(denom)
        return (Double(delta / divisor) * Double(numer) + Double(delta % divisor) * Double(numer) / Double(denom)) / 1e9
    }
}
struct UmpBinding: Decodable { let source: String; let destination: String }
struct UmpPacket: Decodable {
    let kind: String
    let protocolID: Int
    let hostTime: String
    let source: String
    let timestampOrigin: String
    let words: [UInt32]
    enum CodingKeys: String, CodingKey { case kind, hostTime, source, timestampOrigin, words; case protocolID = "protocol" }
}
struct UmpEvent {
    let seconds: Double
    let source: String
    let words: [UInt32]
}
struct UmpTimedEvent { let ticks: UInt64; let event: UmpEvent }
struct UmpTimeline: Decodable {
    let schemaVersion: Int
    let duration: Double
    let clock: UmpClock
    let bindings: [UmpBinding]
    let packets: [UmpPacket]
    func events() throws -> [UmpEvent] {
        guard duration * 1e9 < Double(UInt64.max) else { throw MidiFailure("captured UMP exceeds the native timeline") }
        return try timedEvents().map(\.event)
    }
    func timedEvents() throws -> [UmpTimedEvent] {
        guard schemaVersion == 4, duration.isFinite, duration > 0,
              !packets.isEmpty, !bindings.isEmpty, Set(bindings.map(\.source)).count == bindings.count else { throw MidiFailure("invalid captured UMP timeline") }
        _ = try clock.seconds(clock.origin)
        var endpointSources: [String: Set<String>] = [:], groupSources: [String: Set<String>] = [:]
        var exclusiveGroups = Set<String>(), exclusiveEndpoints = Set<String>()
        var used = Set<String>(), owners: [String: String] = [:], result: [(Int, UmpTimedEvent)] = []
        for binding in bindings {
            guard !binding.source.isEmpty, let uid = Int32(binding.destination), String(uid) == binding.destination else { throw MidiFailure("invalid UMP source destination") }
        }
        let sizes = [1,1,1,2,2,4,1,1,2,2,2,3,3,4,4,4]
        for packet in packets {
            guard packet.kind == "midi", packet.protocolID == 2, ["packet", "received"].contains(packet.timestampOrigin),
                  let binding = bindings.first(where: { $0.source == packet.source }), !packet.words.isEmpty else { throw MidiFailure("invalid or unbound captured UMP packet") }
            let seconds = try clock.seconds(packet.hostTime)
            guard seconds.isFinite, seconds <= duration else { throw MidiFailure("UMP packet lies outside capture duration") }
            used.insert(packet.source)
            var offset = 0
            while offset < packet.words.count {
                let word = packet.words[offset], type = Int(word >> 28), count = sizes[type]
                guard offset + count <= packet.words.count else { throw MidiFailure("truncated captured UMP message") }
                endpointSources[binding.destination, default: []].insert(packet.source)
                let group = "\(binding.destination)/\((word >> 24) & 15)"
                if [1,2,3,4,5,13].contains(type) { groupSources[group, default: []].insert(packet.source) }
                if [1,3,5,13].contains(type) { exclusiveGroups.insert(group) }
                else if type != 2 && type != 4 { exclusiveEndpoints.insert(binding.destination) }
                if type == 2 || type == 4 {
                    let address = "\(binding.destination)/\((word >> 24) & 15)/\((word >> 16) & 15)"
                    guard owners[address] == nil || owners[address] == packet.source else { throw MidiFailure("captured sources share a destination/group/channel; select independent source outputs") }
                    owners[address] = packet.source
                }
                result.append((result.count, UmpTimedEvent(ticks: try clock.ticks(packet.hostTime), event: UmpEvent(seconds: seconds, source: packet.source, words: Array(packet.words[offset..<(offset + count)])))))
                offset += count
            }
        }
        guard exclusiveGroups.allSatisfy({ (groupSources[$0]?.count ?? 0) == 1 }),
              exclusiveEndpoints.allSatisfy({ (endpointSources[$0]?.count ?? 0) == 1 }) else {
            throw MidiFailure("captured system/SysEx/group state requires independent source outputs")
        }
        guard used == Set(bindings.map(\.source)) else { throw MidiFailure("UMP bindings must match captured sources") }
        return result.sorted { $0.1.ticks == $1.1.ticks ? $0.0 < $1.0 : $0.1.ticks < $1.1.ticks }.map { $0.1 }
    }
}

// A complete source audition delivers every original UMP, including opaque
// system/expression data. Reconstruction additionally requires known source
// state; staging is silent and its restoration shares the audio start epoch.
final class UmpTransport: CoordinatedMidiTransport {
    let timeline: UmpTimeline
    let events: [UmpEvent]
    var anchor: UInt64 = 0
    var terminalFailure: Error?
    var onCoordinatedFailure: ((String, Error?) -> Void)?
    var onCoordinatedEnd: (() -> Void)?
    var timer: DispatchSourceTimer?
    enum State { case prepared, staged, playing, ended, stopped }
    var state = State.prepared
    var index = 0
    var offset: Double = 0
    var pendingRestore = false
    let output: UmpOutput
    init(timeline: UmpTimeline) throws {
        self.timeline = timeline; events = try timeline.events(); output = UmpOutput(bindings: timeline.bindings)
    }
    func prepare() throws {
        output.onFailure = { [weak self] error in self?.finish(reason: "destination-unavailable", error: error, publish: false) }
        try output.prepare()
    }
    func stageCoordinated(at seconds: Double) throws {
        guard Thread.isMainThread, state != .stopped, seconds.isFinite, seconds >= 0, seconds < timeline.duration else { throw MidiFailure("invalid captured UMP position or owner") }
        let original = state == .prepared && seconds == 0
        if !original { _ = try umpRestoration(events, before: seconds, replacing: output.footprint) }
        try output.checkDestinations()
        timer?.cancel(); timer = nil
        try output.silence()
        offset = seconds; pendingRestore = !original; state = .staged
    }
    func runCoordinated(anchorNanoseconds: UInt64) throws {
        guard state == .staged, anchorNanoseconds > DispatchTime.now().uptimeNanoseconds else { throw MidiFailure("captured UMP missed the common start deadline") }
        anchor = anchorNanoseconds; state = .playing; schedule()
    }
    func position(at host: UInt64) -> Double {
        if state == .ended { return timeline.duration }
        guard state == .playing else { return offset }
        return min(timeline.duration, offset + (host > anchor ? Double(host - anchor) / 1e9 : 0))
    }
    func schedule() {
        timer?.cancel(); timer = nil
        guard state == .playing else { return }
        let seconds = pendingRestore ? offset : index < events.count ? events[index].seconds : timeline.duration
        let when = anchor.addingReportingOverflow(UInt64(max(0, seconds - offset) * 1e9))
        guard !when.overflow else { finish(reason: "clock-overflow", error: MidiFailure("UMP deadline exceeds host clock"), publish: false); return }
        let source = DispatchSource.makeTimerSource(queue: .main); timer = source
        source.schedule(deadline: DispatchTime(uptimeNanoseconds: when.partialValue), leeway: .nanoseconds(0))
        source.setEventHandler { [weak self] in self?.tick() }; source.resume()
    }
    func tick() {
        guard state == .playing else { return }
        do {
            try output.checkDestinations()
            let host = DispatchTime.now().uptimeNanoseconds
            guard host >= anchor else { schedule(); return }
            let seconds = position(at: host)
            if pendingRestore {
                if seconds >= timeline.duration {
                    // The reconstructed interval has already ended. This is
                    // distinct from an original full-source audition, whose
                    // delayed callback still delivers the original stream.
                    pendingRestore = false; index = events.count
                    timer?.cancel(); timer = nil; try output.silence()
                    state = .ended; onCoordinatedEnd?(); return
                }
                // Reconstruct the current phase if the callback was delayed:
                // notes that ended between staging and this epoch stay silent.
                let restored = try umpRestoration(events, before: seconds, replacing: output.footprint)
                pendingRestore = false; index = restored.nextIndex
                for event in restored.events { try output.apply(event) }
            }
            while index < events.count && events[index].seconds <= seconds { try output.apply(events[index]); index += 1 }
            if index == events.count && seconds >= timeline.duration {
                timer?.cancel(); timer = nil; try output.silence(); state = .ended; onCoordinatedEnd?(); return
            }
            schedule()
        } catch { finish(reason: "ump-playback-failed", error: error, publish: false) }
    }
    func snapshot(_ kind: String) -> [String: Any] { ["bindings": output.snapshot()] }
    func finish(reason: String, error: Error?, publish: Bool) {
        guard state != .stopped else { return }
        state = .stopped; timer?.cancel(); timer = nil
        var failure = error
        do { try output.close() } catch { failure = failure ?? error }
        terminalFailure = failure; onCoordinatedFailure?(reason, failure)
    }
}
