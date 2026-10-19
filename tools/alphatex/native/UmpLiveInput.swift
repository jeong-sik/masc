import Foundation
import CoreMIDI

struct UmpLiveChannel: Decodable, Hashable {
    let group: UInt8
    let channel: UInt8
}
enum UmpLiveScope: Decodable, Equatable {
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
    // Stable identity of the route inside one live owner. `live-set` selects
    // active routes by key, so a key must survive across reconfigure commands.
    let key: String
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
        guard schemaVersion == 1 else { throw MidiFailure("invalid live MIDI plan") }
        try Self.validate(routes: routes, reserved: reserved)
    }
    // The same contract governs the startup plan and every `live-set` target
    // subset, so the active set is always a legal standalone plan.
    static func validate(routes: [UmpLiveRoute], reserved: [UmpLiveClaim]) throws {
        guard !routes.isEmpty else { throw MidiFailure("live MIDI requires at least one active route") }
        var keys = Set<String>()
        for route in routes {
            guard !route.key.isEmpty, keys.insert(route.key).inserted else { throw MidiFailure("live MIDI route keys must be unique and non-empty") }
        }
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
    var plan: UmpLivePlan
    // The physical ownership declaration is re-derived by the monitor on every
    // `set`, so a stale snapshot never gates a live route change.
    var reserved: [UmpLiveClaim]
    // `activeRoutes` and `outputs` stay index-aligned: routing and snapshots
    // address an output by the position of its active route. `live-set` swaps
    // both arrays together and never closes a route that stays active.
    var activeRoutes: [UmpLiveRoute]
    var outputs: [UmpOutput]
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
        try plan.validate(); self.plan = plan; reserved = plan.reserved
        activeRoutes = plan.routes
        outputs = plan.routes.map { UmpOutput(bindings: [UmpBinding(source: $0.source, destination: $0.destination)]) }
        var clock = mach_timebase_info_data_t(); mach_timebase_info(&clock); timebase = clock
        guard clock.numer > 0, clock.denom > 0 else { throw MidiFailure("live MIDI host clock is unavailable") }
    }
    func checkFailure() throws {
        lock.lock(); let failure = firstFailure; lock.unlock()
        if let failure { throw failure }
    }
    func check() throws {
        try checkFailure()
        for source in sources.values { try source.check() }
        for output in outputs { try output.checkDestinations() }
    }
    func start() throws {
        guard Thread.isMainThread, state == .idle else { throw MidiFailure("invalid live MIDI startup owner") }
        do { try startResources() }
        catch { stop(error: error); throw error }
    }
    private func startResources() throws {
        for uid in Set(activeRoutes.map(\.source)) {
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
        lock.lock(); accepting = true; lock.unlock()
        // Handoffs queue on this lifecycle: opening admission before the ACK
        // preserves its first input without permitting a send ahead of the ACK.
        try onEvent?(snapshot("monitoring"))
    }
    // `live-set`: reconcile the running owner to a new catalog and active key
    // set. Routes that stay active keep their CoreMIDI connections; only added
    // routes are opened and only removed routes are closed. A route that cannot
    // open is reported in `rejected` instead of stopping the owner, and the ACK
    // admits exactly the live set so the caller can judge a target match.
    func set(routes: [UmpLiveRoute], active: [String], reserved: [UmpLiveClaim]?) throws {
        guard Thread.isMainThread, state == .running else { throw MidiFailure("live MIDI set requires its running lifecycle") }
        if let reserved { self.reserved = reserved }
        var catalog: [String: UmpLiveRoute] = [:]
        for route in routes {
            guard !route.key.isEmpty, catalog.updateValue(route, forKey: route.key) == nil else {
                throw MidiFailure("live MIDI route keys must be unique and non-empty")
            }
        }
        var activeKeys = Set<String>()
        for key in active {
            guard catalog[key] != nil else {
                // An active key the catalog does not define is a protocol error:
                // keep the current set and name the refusal instead of opening a
                // route from a bare key.
                try onEvent?(["kind": "ack", "admitted": activeRoutes.map(\.key), "rejected": [], "error": "unknown-key"])
                return
            }
            activeKeys.insert(key)
        }
        // The active subset, in catalog order, is itself a legal plan.
        let desired = routes.filter { activeKeys.contains($0.key) }
        if !desired.isEmpty { try UmpLivePlan.validate(routes: desired, reserved: self.reserved) }
        let kept = Dictionary(zip(activeRoutes, outputs).filter { activeKeys.contains($0.0.key) }.map { ($0.0.key, $0) },
                              uniquingKeysWith: { first, _ in first })
        var nextRoutes: [UmpLiveRoute] = [], nextOutputs: [UmpOutput] = [], rejected: [String] = []
        for route in desired {
            if let (old, output) = kept[route.key],
               old.source == route.source, old.destination == route.destination, old.scope == route.scope {
                nextRoutes.append(route); nextOutputs.append(output)
                continue
            }
            let output = UmpOutput(bindings: [UmpBinding(source: route.source, destination: route.destination)])
            output.onFailure = { [weak self] error in self?.stop(error: error) }
            do {
                try ensureSource(route.source)
                try output.prepare()
                nextRoutes.append(route); nextOutputs.append(output)
            } catch {
                try? output.close(); rejected.append(route.key)
            }
        }
        let nextKeys = Set(nextRoutes.map(\.key))
        for (route, output) in zip(activeRoutes, outputs) where !nextKeys.contains(route.key) { try? output.close() }
        activeRoutes = nextRoutes; outputs = nextOutputs
        syncSources(Set(nextRoutes.map(\.source)))
        try onEvent?(["kind": "ack", "admitted": nextRoutes.map(\.key), "rejected": rejected])
    }
    // Open a source the first time a route needs it and drop it once the last
    // route releases it. A route that already has its port stays untouched, so
    // an unrelated `live-set` never breaks an open connection.
    private func ensureSource(_ uid: String) throws {
        lock.lock(); let known = sources.values.contains { String($0.uid) == uid }; lock.unlock()
        guard !known else { return }
        let source = try UmpLiveSource.selected(uid)
        try checked(MIDIPortConnectSource(port, source.endpoint, UnsafeMutableRawPointer(bitPattern: UInt(source.endpoint))), "connect selected live MIDI input")
        lock.lock(); sources[source.endpoint] = source; lock.unlock()
    }
    private func syncSources(_ needed: Set<String>) {
        lock.lock()
        let stale = sources.filter { !needed.contains(String($0.value.uid)) }
        for endpoint in stale.keys { sources.removeValue(forKey: endpoint) }
        lock.unlock()
        for endpoint in stale.keys { MIDIPortDisconnectSource(port, endpoint) }
    }
    func fail(_ error: Error) {
        lock.lock(); if firstFailure == nil { firstFailure = error }; accepting = false; lock.unlock()
        DispatchQueue.main.async { self.stop() }
    }
    func receive(_ list: UnsafePointer<MIDIEventList>, context: UnsafeMutableRawPointer?) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        let source = context.flatMap { sources[MIDIEndpointRef(UInt(bitPattern: $0))] }
        callbacks.enter(); lock.unlock()
        defer { callbacks.leave() }
        guard list.pointee.protocol == ._2_0, let source else {
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
                    for (index, route) in activeRoutes.enumerated() where route.source == packet.source {
                        if route.scope.includes(words[0]) {
                            try checkFailure()
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
            binding["port"] = index; binding["key"] = activeRoutes[index].key
            binding["source"] = activeRoutes[index].source; binding["scope"] = activeRoutes[index].scope.json
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
