import Foundation
import CoreMIDI

struct UmpLiveChannel: Decodable, Hashable {
    let group: UInt8
    let channel: UInt8
}
enum UmpLiveScope: Decodable {
    case endpoint, channels(Set<UmpLiveChannel>)
    enum Keys: String, CodingKey { case kind, channels }
    enum Kind: String, Decodable { case endpoint, channels }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .endpoint:
            guard !values.contains(.channels) else { throw MidiFailure("endpoint scope cannot specify channels") }
            self = .endpoint
        case .channels:
            let channels = try values.decode([UmpLiveChannel].self, forKey: .channels)
            guard !channels.isEmpty, Set(channels).count == channels.count,
                  channels.allSatisfy({ $0.group < 16 && $0.channel < 16 }) else { throw MidiFailure("invalid MIDI group/channel scope") }
            self = .channels(Set(channels))
        }
    }
    func overlaps(_ other: Self) -> Bool {
        switch (self, other) {
        case (.endpoint, _), (_, .endpoint): return true
        case (.channels(let a), .channels(let b)): return !a.isDisjoint(with: b)
        }
    }
    func includes(_ word: UInt32) -> Bool {
        switch self {
        case .endpoint: return true
        case .channels(let channels):
            guard word >> 28 == 2 || word >> 28 == 4 else { return false }
            return channels.contains(UmpLiveChannel(group: UInt8((word >> 24) & 15), channel: UInt8((word >> 16) & 15)))
        }
    }
    var json: [String: Any] {
        switch self {
        case .endpoint: return ["kind": "endpoint"]
        case .channels(let channels):
            return ["kind": "channels", "channels": channels.sorted {
                $0.group == $1.group ? $0.channel < $1.channel : $0.group < $1.group
            }.map { ["group": $0.group, "channel": $0.channel] }]
        }
    }
}
struct UmpLiveClaim: Decodable {
    let destination: String
    let scope: UmpLiveScope
    func conflicts(_ other: Self) -> Bool { destination == other.destination && scope.overlaps(other.scope) }
}
struct UmpLiveRoute: Decodable {
    let source: String
    let destination: String
    let scope: UmpLiveScope
    var claim: UmpLiveClaim { UmpLiveClaim(destination: destination, scope: scope) }
}
struct UmpLivePlan: Decodable {
    let schemaVersion: Int
    let routes: [UmpLiveRoute]
    // The caller declares backing ownership explicitly, including an empty set.
    let reserved: [UmpLiveClaim]
    func validate() throws {
        guard schemaVersion == 1, !routes.isEmpty else { throw MidiFailure("invalid live MIDI plan") }
        for uid in routes.map(\.source) + routes.map(\.destination) + reserved.map(\.destination) {
            guard let value = Int32(uid), String(value) == uid else { throw MidiFailure("live MIDI requires exact source/destination UIDs") }
        }
        for claim in routes.map(\.claim) + reserved {
            if case .channels(let channels) = claim.scope {
                guard !channels.isEmpty, channels.allSatisfy({ $0.group < 16 && $0.channel < 16 }) else { throw MidiFailure("invalid live MIDI channel lease") }
            }
        }
        for (index, route) in routes.enumerated() {
            guard !reserved.contains(where: route.claim.conflicts),
                  !routes.prefix(index).contains(where: { route.claim.conflicts($0.claim) }) else {
                throw MidiFailure("live MIDI shares physical destination/group/channel ownership")
            }
        }
    }
}

struct UmpLiveSource {
    let endpoint: MIDIEndpointRef
    let uid: Int32
    func check() throws {
        var identity: Int32 = 0
        try checked(MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &identity), "read live MIDI input identity")
        guard identity == uid else { throw MidiFailure("selected live MIDI input was removed or changed") }
        var offline: Int32 = 0
        let status = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
        if status != kMIDIUnknownProperty {
            try checked(status, "read live MIDI input state")
            guard offline == 0 else { throw MidiFailure("selected live MIDI input is offline") }
        }
    }
    static func selected(_ uid: String) throws -> Self {
        guard let value = Int32(uid), String(value) == uid else { throw MidiFailure("invalid live MIDI source UID") }
        var object = MIDIObjectRef(), type = MIDIObjectType.other
        try checked(MIDIObjectFindByUniqueID(value, &object, &type), "find selected live MIDI input")
        guard object != 0, type == .source else { throw MidiFailure("selected live MIDI object is not a source") }
        let result = Self(endpoint: object, uid: value)
        try result.check(); return result
    }
}

// All sends and acquired state run on the main lifecycle. The callback copies a
// bounded amount of raw input, never schedules future work in CoreMIDI, and never
// performs device discovery, JSON/file I/O or musical state changes.
final class UmpLiveInput {
    enum State { case idle, running, stopping, closed }
    struct Packet { let source: String; let host: UInt64; let ordinal: UInt64; let words: [UInt32] }
    let plan: UmpLivePlan
    let outputs: [UmpOutput]
    // 256 KiB of in-flight raw payload, including callback-to-main handoff and
    // future input timestamps. Exhaustion fails explicitly; input is never dropped.
    static let maximumPendingWords = 65_536
    let lock = NSLock(), callbacks = DispatchGroup()
    var accepting = false, pendingWords = 0
    var firstFailure: Error?
    var nextOrdinal: UInt64 = 0
    var state = State.idle
    var client = MIDIClientRef(), port = MIDIPortRef()
    var sources: [MIDIEndpointRef: UmpLiveSource] = [:]
    var pending: [Packet] = []
    var timer: DispatchSourceTimer?
    var forwarded: UInt64 = 0, filtered: UInt64 = 0
    var onEvent: (([String: Any]) throws -> Void)?
    var onClosed: ((Error?) -> Void)?
    var now: () -> UInt64 = { mach_absolute_time() }
    let timebase: mach_timebase_info_data_t
    init(plan: UmpLivePlan) throws {
        try plan.validate(); self.plan = plan
        outputs = plan.routes.map { UmpOutput(bindings: [UmpBinding(source: $0.source, destination: $0.destination)]) }
        var clock = mach_timebase_info_data_t(); mach_timebase_info(&clock); timebase = clock
        guard clock.numer > 0, clock.denom > 0 else { throw MidiFailure("live MIDI host clock is unavailable") }
    }
    func check() throws {
        for source in sources.values { try source.check() }
        for output in outputs { try output.checkDestinations() }
    }
    func start() throws {
        guard Thread.isMainThread, state == .idle else { throw MidiFailure("invalid live MIDI startup owner") }
        do { try startResources() }
        catch { stop(error: error); throw error }
    }
    private func startResources() throws {
        for uid in Set(plan.routes.map(\.source)) {
            let source = try UmpLiveSource.selected(uid); sources[source.endpoint] = source
        }
        try checked(MIDIClientCreateWithBlock("MASC live MIDI input" as CFString, &client, { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.state == .running else { return }
                do { try self.check() } catch { self.stop(error: error) }
            }
        }), "create live MIDI input client")
        for output in outputs {
            output.onFailure = { [weak self] error in self?.stop(error: error) }
            try output.prepare()
        }
        try checked(MIDIInputPortCreateWithProtocol(client, "MASC live MIDI input" as CFString, ._2_0, &port, { [weak self] list, context in
            self?.receive(list, context: context)
        }), "create live MIDI input port")
        for source in sources.values {
            try checked(MIDIPortConnectSource(port, source.endpoint, UnsafeMutableRawPointer(bitPattern: UInt(source.endpoint))), "connect selected live MIDI input")
        }
        try check()
        state = .running
        try onEvent?(snapshot("monitoring"))
        lock.lock(); accepting = true; lock.unlock()
    }
    func fail(_ error: Error) {
        lock.lock(); if firstFailure == nil { firstFailure = error }; accepting = false; lock.unlock()
        DispatchQueue.main.async { self.stop() }
    }
    func receive(_ list: UnsafePointer<MIDIEventList>, context: UnsafeMutableRawPointer?) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        callbacks.enter(); lock.unlock()
        defer { callbacks.leave() }
        guard list.pointee.protocol == ._2_0, let context,
              let source = sources[MIDIEndpointRef(UInt(bitPattern: context))] else {
            fail(MidiFailure("unbound live MIDI callback or protocol")); return
        }
        var packet = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIEventList>.offset(of: \.packet)!)
        for _ in 0..<list.pointee.numPackets {
            let host = packet.loadUnaligned(fromByteOffset: MemoryLayout<MIDIEventPacket>.offset(of: \.timeStamp)!, as: MIDITimeStamp.self)
            let count = Int(packet.loadUnaligned(fromByteOffset: MemoryLayout<MIDIEventPacket>.offset(of: \.wordCount)!, as: UInt32.self))
            let words = packet.advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \.words)!).assumingMemoryBound(to: UInt32.self)
            if count > 0 {
                lock.lock()
                guard accepting else { lock.unlock(); return }
                guard count <= Self.maximumPendingWords - pendingWords, nextOrdinal < UInt64.max else {
                    lock.unlock(); fail(MidiFailure("live MIDI input queue exhausted; forwarding stopped without hiding lost input")); return
                }
                pendingWords += count
                let copied = Packet(source: String(source.uid), host: host == 0 ? now() : host, ordinal: nextOrdinal,
                                    words: Array(UnsafeBufferPointer(start: words, count: count)))
                nextOrdinal += 1
                DispatchQueue.main.async { self.accept(copied) }
                lock.unlock()
            }
            packet = UnsafeRawPointer(words.advanced(by: count))
        }
    }
    func release(_ count: Int) { lock.lock(); pendingWords -= count; lock.unlock() }
    func accept(_ packet: Packet) {
        guard state == .running else { release(packet.words.count); return }
        pending.append(packet)
        pending.sort { $0.host == $1.host ? $0.ordinal < $1.ordinal : $0.host < $1.host }
        tick()
    }
    func tick() {
        guard state == .running else { return }
        timer?.cancel(); timer = nil
        do {
            try check()
            let host = now()
            while let packet = pending.first, packet.host <= host {
                pending.removeFirst()
                defer { release(packet.words.count) }
                let messages = try umpMessages(packet.words)
                for words in messages {
                    for (index, route) in plan.routes.enumerated() where route.source == packet.source {
                        if route.scope.includes(words[0]) {
                            try outputs[index].apply(UmpEvent(seconds: 0, source: packet.source, words: words)); forwarded += 1
                        } else { filtered += 1 }
                    }
                }
            }
            if let next = pending.first {
                let delta = UInt128(next.host - host) * UInt128(timebase.numer)
                let nanos = (delta + UInt128(timebase.denom) - 1) / UInt128(timebase.denom)
                guard nanos <= UInt128(UInt64.max) else { throw MidiFailure("live MIDI deadline exceeds host clock") }
                let deadline = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(UInt64(nanos))
                guard !deadline.overflow else { throw MidiFailure("live MIDI deadline exceeds uptime clock") }
                let timer = DispatchSource.makeTimerSource(queue: .main); self.timer = timer
                timer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline.partialValue), leeway: .nanoseconds(0))
                timer.setEventHandler { [weak self] in self?.tick() }; timer.resume()
            }
        } catch { stop(error: error) }
    }
    func snapshot(_ kind: String) -> [String: Any] {
        lock.lock(); let words = pendingWords; lock.unlock()
        let bindings = outputs.enumerated().compactMap { index, output -> [String: Any]? in
            guard var binding = output.snapshot().first else { return nil }
            binding["port"] = index; binding["source"] = plan.routes[index].source; binding["scope"] = plan.routes[index].scope.json
            return binding
        }
        return ["kind": kind, "deliveryProtocol": 2, "bindings": bindings,
                "forwardedMessages": String(forwarded), "filteredMessages": String(filtered), "pendingWords": words]
    }
    func stop(error: Error? = nil) {
        guard Thread.isMainThread else { fail(error ?? MidiFailure("live MIDI stop requires its lifecycle")); return }
        guard state != .stopping && state != .closed else { return }
        lock.lock(); accepting = false; if firstFailure == nil { firstFailure = error }; lock.unlock()
        state = .stopping; timer?.cancel(); timer = nil
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        callbacks.wait()
        for packet in pending { release(packet.words.count) }; pending.removeAll()
        // Every admitted callback has enqueued its handoff before this barrier.
        // Those queued blocks release their reservation without sending; only
        // then may cleanup and the final child acknowledgement complete.
        DispatchQueue.main.async {
            for output in self.outputs {
                do { try output.close() }
                catch { self.lock.lock(); if self.firstFailure == nil { self.firstFailure = error }; self.lock.unlock() }
            }
            self.state = .closed
            self.onClosed?(self.firstFailure)
        }
    }
}
