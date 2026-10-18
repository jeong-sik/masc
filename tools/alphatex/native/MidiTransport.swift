import Foundation
import CoreMIDI

struct MidiFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
func checked(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw MidiFailure("\(operation): OSStatus \(status)") }
}
func emit(_ value: [String: Any]) throws {
    var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    bytes.append(10); try FileHandle.standardOutput.write(contentsOf: bytes)
}
func diagnostic(_ error: Error) {
    try? FileHandle.standardError.write(contentsOf: Data("\(error)\n".utf8))
}
struct Destination {
    let endpoint: MIDIEndpointRef
    let uid: Int32
    let name: String
    var json: [String: Any] { ["kind": "midi", "id": String(uid), "name": name, "protocol": 1] }
}
func destinations() throws -> [Destination] {
    try (0..<MIDIGetNumberOfDestinations()).map { index in
        let endpoint = MIDIGetDestination(index)
        var uid: Int32 = 0, name: Unmanaged<CFString>?
        try checked(MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid), "read MIDI destination identity")
        try checked(MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name), "read MIDI destination name")
        guard let name else { throw MidiFailure("MIDI destination name is unavailable") }
        return Destination(endpoint: endpoint, uid: uid, name: name.takeRetainedValue() as String)
    }
}
func selectedDestination(uid: String) throws -> Destination {
    guard let identity = Int32(uid), String(identity) == uid else { throw MidiFailure("MIDI destination requires its exact unique ID") }
    var object = MIDIObjectRef(), type = MIDIObjectType.other
    try checked(MIDIObjectFindByUniqueID(identity, &object, &type), "find selected MIDI destination")
    guard object != 0, type == .destination else { throw MidiFailure("selected MIDI object is not a destination") }
    var name: Unmanaged<CFString>?
    try checked(MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &name), "read selected MIDI destination name")
    guard let name else { throw MidiFailure("selected MIDI destination name is unavailable") }
    let selected = Destination(endpoint: object, uid: identity, name: name.takeRetainedValue() as String)
    try checkPinnedDestination(selected)
    return selected
}
func checkPinnedDestination(_ selected: Destination) throws {
    // A lookup/listing of unrelated endpoints may race their removal. Validate
    // only the selected reference, including reuse with a different identity.
    var identity: Int32 = 0
    try checked(MIDIObjectGetIntegerProperty(selected.endpoint, kMIDIPropertyUniqueID, &identity), "read selected MIDI destination identity")
    guard identity == selected.uid else { throw MidiFailure("selected MIDI destination was removed or changed") }
    var offline: Int32 = 0
    let status = MIDIObjectGetIntegerProperty(selected.endpoint, kMIDIPropertyOffline, &offline)
    if status != kMIDIUnknownProperty {
        try checked(status, "read selected MIDI destination state")
        guard offline == 0 else { throw MidiFailure("selected MIDI destination is offline") }
    }
}
struct Event: Decodable, Equatable {
    enum Kind: String, Decodable { case program, control, on, off }
    let kind: Kind
    let seconds: Double
    let channel: UInt8
    let program: UInt8?
    let controller: UInt8?
    let value: UInt8?
    let pitch: UInt8?
    let velocity: UInt8?
    func bytes() throws -> [UInt8] {
        guard seconds.isFinite, seconds >= 0, channel < 16 else { throw MidiFailure("invalid MIDI event position or channel") }
        switch kind {
        case .program:
            guard let program, program < 128 else { throw MidiFailure("invalid MIDI program") }
            return [0xc0 | channel, program]
        case .control:
            // These are the controls present in the editable project schema.
            // A richer MIDI source must extend that schema before projection.
            guard let controller, [7, 10].contains(controller), let value, value < 128 else {
                throw MidiFailure("unsupported project controller (volume/pan required)")
            }
            return [0xb0 | channel, controller, value]
        case .on:
            guard let pitch, pitch < 128, let velocity, velocity > 0, velocity < 128 else { throw MidiFailure("invalid MIDI note-on") }
            return [0x90 | channel, pitch, velocity]
        case .off:
            guard let pitch, pitch < 128 else { throw MidiFailure("invalid MIDI note-off") }
            return [0x80 | channel, pitch, 0]
        }
    }
    var key: UInt16 { UInt16(channel) << 8 | UInt16(pitch ?? controller ?? 0) }
}
// SMF F7 escapes can contain running status, real-time bytes or a partial
// message. CoreMIDI receives complete short messages with explicit status;
// SysEx fragments retain their source boundaries and timing.
struct WireState {
    var running: UInt8?, pending: [UInt8] = [], required = 0
    var exclusive = false
    mutating func feed(_ bytes: [UInt8]) throws -> [[UInt8]] {
        var messages: [[UInt8]] = [], sysex: [UInt8] = []
        for byte in bytes {
            if byte >= 0xf8 {
                if !sysex.isEmpty { messages.append(sysex); sysex = [] }
                messages.append([byte]); continue
            }
            if exclusive {
                if byte == 0xf7 { sysex.append(byte); exclusive = false; messages.append(sysex); sysex = [] }
                else if byte < 0x80 { sysex.append(byte) }
                else { throw MidiFailure("non-real-time status interrupts source SysEx") }
                continue
            }
            if byte >= 0x80 {
                guard pending.isEmpty else { throw MidiFailure("status interrupts an incomplete source MIDI message") }
                if byte == 0xf0 { running = nil; exclusive = true; sysex.append(byte); continue }
                if byte < 0xf0 {
                    running = byte; required = [0xc0, 0xd0].contains(byte & 0xf0) ? 2 : 3
                } else {
                    running = nil
                    switch byte {
                    case 0xf1, 0xf3: required = 2
                    case 0xf2: required = 3
                    case 0xf6: messages.append([byte]); continue
                    default: throw MidiFailure("undefined or unmatched source MIDI system status")
                    }
                }
                pending = [byte]
            } else {
                if pending.isEmpty {
                    guard let running else { throw MidiFailure("source MIDI data has no wire running status") }
                    pending = [running]; required = [0xc0, 0xd0].contains(running & 0xf0) ? 2 : 3
                }
                pending.append(byte)
                if pending.count == required { messages.append(pending); pending = [] }
            }
        }
        if !sysex.isEmpty { messages.append(sysex) }
        return messages
    }
    func complete() throws {
        guard !exclusive, pending.isEmpty else { throw MidiFailure("source ends inside a MIDI wire message") }
    }
}
struct WireEvent: Decodable {
    let seconds: Double
    let port: UInt8
    let bytes: [UInt8]
}
struct Binding: Decodable {
    let port: UInt8
    let destination: String
}
struct Timeline: Decodable {
    let schemaVersion: Int
    let duration: Double
    let events: [Event]
    let wireEvents: [WireEvent]
    let bindings: [Binding]
    var source: Bool { schemaVersion == 2 }
    enum Keys: String, CodingKey { case schemaVersion, duration, events, bindings }
    init(schemaVersion: Int, duration: Double, events: [Event]) {
        self.schemaVersion = schemaVersion; self.duration = duration; self.events = events
        wireEvents = []; bindings = []
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        duration = try values.decode(Double.self, forKey: .duration)
        switch schemaVersion {
        case 1:
            events = try values.decode([Event].self, forKey: .events); wireEvents = []; bindings = []
            guard !values.contains(.bindings) else { throw MidiFailure("phrase timeline cannot contain source bindings") }
        case 2:
            events = []; wireEvents = try values.decode([WireEvent].self, forKey: .events)
            bindings = try values.decode([Binding].self, forKey: .bindings)
        default: throw MidiFailure("unknown MIDI timeline schema")
        }
    }
    func validate() throws {
        guard duration.isFinite, source ? duration >= 0 : duration > 0,
              duration * 1e9 < Double(UInt64.max) else { throw MidiFailure("invalid MIDI timeline duration") }
        var previous = 0.0
        for event in events {
            _ = try event.bytes()
            guard event.seconds >= previous, event.seconds <= duration else { throw MidiFailure("MIDI events must be ordered inside the timeline") }
            previous = event.seconds
        }
        var decoders: [UInt8: WireState] = [:]
        var destinations = Set<String>()
        for binding in bindings {
            guard binding.port < 128, let uid = Int32(binding.destination), String(uid) == binding.destination,
                  decoders[binding.port] == nil, destinations.insert(binding.destination).inserted else {
                throw MidiFailure("source ports require unique explicit destination bindings")
            }
            decoders[binding.port] = WireState()
        }
        var used = Set<UInt8>()
        for event in wireEvents {
            guard event.seconds.isFinite, event.seconds >= previous, event.seconds <= duration,
                  !event.bytes.isEmpty, var decoder = decoders[event.port] else {
                throw MidiFailure("invalid or unbound source MIDI wire event")
            }
            _ = try decoder.feed(event.bytes); decoders[event.port] = decoder
            used.insert(event.port); previous = event.seconds
        }
        if source {
            guard !wireEvents.isEmpty, used == Set(bindings.map(\.port)) else { throw MidiFailure("source bindings must match used MIDI ports") }
            for decoder in decoders.values { try decoder.complete() }
        }
    }
}

enum Command: Decodable {
    case pause, resume, seek(Double), status, stop
    enum Keys: String, CodingKey { case kind, seconds }
    enum Kind: String, Decodable { case pause, resume, seek, status, stop }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        if kind != .seek && values.contains(.seconds) { throw MidiFailure("seconds is only valid for seek") }
        switch kind {
        case .pause: self = .pause
        case .resume: self = .resume
        case .seek: self = .seek(try values.decode(Double.self, forKey: .seconds))
        case .status: self = .status
        case .stop: self = .stop
        }
    }
}
final class MidiTransport {
    enum State { case prepared, playing, paused, stopped }
    let timeline: Timeline
    let selectedUID: String
    let loop: Bool
    let queue = DispatchQueue(label: "masc.music.midi.transport", qos: .userInteractive)
    var destination: Destination?
    var prepared = false // admission and resources belong to queue
    var client = MIDIClientRef(), port = MIDIPortRef()
    var state = State.prepared
    var timer: DispatchSourceTimer?
    var signals: [DispatchSourceSignal] = []
    var anchor: UInt64 = 0, offset = 0.0, index = 0
    var held: [UInt16: Event] = [:]
    var maximumLateness = 0.0
    var sourceDestinations: [UInt8: Destination] = [:], wireStates: [UInt8: WireState] = [:]
    var sourceExclusive = Set<UInt8>()
    var sourceHeld: [UInt8: [UInt16: Int]] = [:], sourcePedals: [UInt8: Set<UInt16>] = [:]

    init(path: String, uid: String, loop: Bool) throws {
        timeline = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try timeline.validate()
        if timeline.source {
            guard !loop else { throw MidiFailure("source audition plays once; loop state reconstruction is not connected") }
            guard timeline.bindings.first?.destination == uid else { throw MidiFailure("primary source destination differs from explicit bindings") }
        }
        guard let value = Int32(uid), String(value) == uid else { throw MidiFailure("MIDI destination requires its exact unique ID") }
        selectedUID = uid; self.loop = loop
    }
    // CoreMIDI's client is created on the main run loop. Transfer its ownership
    // before admitting notifications; resource selection and mutation use queue.
    func prepare() throws {
        guard Thread.isMainThread else { throw MidiFailure("MIDI preparation requires the main run loop") }
        var createdClient = MIDIClientRef()
        try checked(MIDIClientCreateWithBlock("MASC phrase output" as CFString, &createdClient, { [weak self] _ in
            self?.queue.async { [weak self] in self?.destinationChanged() }
        }), "create MIDI client")
        try queue.sync {
            client = createdClient
            do {
                destination = try selectedDestination(uid: selectedUID)
                for binding in timeline.bindings {
                    sourceDestinations[binding.port] = try selectedDestination(uid: binding.destination)
                    wireStates[binding.port] = WireState()
                }
                try checked(MIDIOutputPortCreate(client, "MASC phrase output" as CFString, &port), "create MIDI output port")
                try checkDestination()
                prepared = true
            } catch {
                if port != 0 { MIDIPortDispose(port); port = 0 }
                if client != 0 { MIDIClientDispose(client); client = 0 }
                destination = nil
                throw error
            }
        }
    }
    func destinationChanged() {
        guard prepared, state != .stopped else { return }
        do { try checkDestination() }
        catch { finish(reason: "destination-unavailable", error: error) }
    }
    func checkDestination() throws {
        guard let destination else { throw MidiFailure("MIDI destination has not been selected") }
        for selected in timeline.source ? Array(sourceDestinations.values) : [destination] {
            try checkPinnedDestination(selected)
        }
    }
    func send(_ bytes: [UInt8]) throws {
        guard let destination else { throw MidiFailure("MIDI destination has not been selected") }
        try sendWire(bytes, to: destination)
    }
    func sendWire(_ bytes: [UInt8], to destination: Destination) throws {
        // Apple limits each MIDIPacketList to 65536 bytes. Include actual ABI
        // header offsets, check every Add result, split only long SysEx data.
        let capacity = 65536
        let overhead = MemoryLayout<MIDIPacketList>.offset(of: \.packet)! + MemoryLayout<MIDIPacket>.offset(of: \.data)!
        let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: MIDIPacketList.self)
        var offset = 0
        while offset < bytes.count {
            let count = min(capacity - overhead, bytes.count - offset)
            let packet = MIDIPacketListInit(list)
            try bytes.withUnsafeBufferPointer { data in
                let added = MIDIPacketListAdd(list, capacity, packet, 0, count, data.baseAddress!.advanced(by: offset))
                guard UInt(bitPattern: added) != 0 else {
                    throw MidiFailure("MIDI packet list could not hold source bytes")
                }
                // Due messages only: no future shared-port work survives stop.
                try checked(MIDISend(port, destination.endpoint, list), "send MIDI event")
            }
            offset += count
        }
    }
    func sourceApply(_ event: WireEvent) throws {
        guard var decoder = wireStates[event.port], let destination = sourceDestinations[event.port] else {
            throw MidiFailure("source MIDI port is not prepared")
        }
        let messages = try decoder.feed(event.bytes)
        // Keep decoder progress even if the endpoint fails mid-fragment, so
        // cleanup closes an exclusive stream before sending channel note-offs.
        wireStates[event.port] = decoder
        for bytes in messages {
            // Acquire ownership before sending: a failed OSStatus cannot prove
            // that the endpoint did not receive a note or pedal-on. Release it
            // only after success, so failure cleanup retries uncertain releases.
            if let status = bytes.first {
                let channel = UInt16(status & 15), type = status & 0xf0
                if bytes.count == 3 && type == 0x90 && bytes[2] > 0 {
                    let key = channel << 8 | UInt16(bytes[1]), count = sourceHeld[event.port]?[key] ?? 0
                    sourceHeld[event.port, default: [:]][key] = count + 1
                } else if bytes.count == 3 && type == 0xb0 && [64, 66, 69].contains(bytes[1]) && bytes[2] >= 64 {
                    sourcePedals[event.port, default: []].insert(channel << 8 | UInt16(bytes[1]))
                }
            }
            if bytes.first == 0xf0 { sourceExclusive.insert(event.port) }
            try sendWire(bytes, to: destination)
            if let status = bytes.first {
                let channel = UInt16(status & 15), type = status & 0xf0
                if status == 0xff { sourceHeld[event.port] = [:]; sourcePedals[event.port] = [] }
                else if bytes.count == 3 && (type == 0x80 || type == 0x90 && bytes[2] == 0) {
                    let key = channel << 8 | UInt16(bytes[1]), count = sourceHeld[event.port]?[key] ?? 0
                    sourceHeld[event.port, default: [:]][key] = max(0, count - 1)
                } else if bytes.count == 3 && type == 0xb0 {
                    let controller = bytes[1], key = channel << 8 | UInt16(controller)
                    if [64, 66, 69].contains(controller) && bytes[2] < 64 { sourcePedals[event.port]?.remove(key) }
                    if controller == 121 { sourcePedals[event.port] = (sourcePedals[event.port] ?? []).filter { $0 >> 8 != channel } }
                    if [120, 123, 124, 125, 126, 127].contains(controller) {
                        sourceHeld[event.port] = (sourceHeld[event.port] ?? [:]).filter { $0.key >> 8 != channel }
                    }
                }
            }
            if bytes.contains(0xf7) { sourceExclusive.remove(event.port) }
        }
    }
    func sourceSilence() throws {
        var failure: Error?
        for binding in timeline.bindings {
            guard let destination = sourceDestinations[binding.port] else { continue }
            var messages: [[UInt8]] = []
            if sourceExclusive.contains(binding.port) { messages.append([0xf7]) }
            for (key, count) in (sourceHeld[binding.port] ?? [:]).sorted(by: { $0.key < $1.key }) {
                for _ in 0..<count { messages.append([0x80 | UInt8(key >> 8), UInt8(key & 127), 0]) }
            }
            for key in (sourcePedals[binding.port] ?? []).sorted() {
                messages.append([0xb0 | UInt8(key >> 8), UInt8(key & 127), 0])
            }
            for bytes in messages { do { try sendWire(bytes, to: destination) } catch { failure = failure ?? error } }
        }
        sourceHeld.removeAll(); sourcePedals.removeAll(); sourceExclusive.removeAll()
        if let failure { throw failure }
    }
    func apply(_ event: Event) throws {
        // A failed send cannot prove the destination missed the Note On, so the
        // key is owned before sending. It is released only after a sent Note Off.
        if event.kind == .on { held[event.key] = event }
        try send(event.bytes())
        if event.kind == .off { held.removeValue(forKey: event.key) }
    }
    func silence() throws {
        if timeline.source { try sourceSilence(); return }
        var failure: Error?
        for event in held.values.sorted(by: { $0.key < $1.key }) {
            do {
                try send([0x80 | event.channel, event.pitch!, 0])
                held.removeValue(forKey: event.key)
            } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }
    func restore(at seconds: Double) throws {
        try reconcile(at: seconds, reconstruct: true)
    }
    func reconcile(at seconds: Double, reconstruct: Bool = false) throws {
        if timeline.source {
            guard !reconstruct else { throw MidiFailure("source seek/resume requires expression-state reconstruction") }
            // Expression, zero-length notes, note-off velocity and SysEx are an
            // ordered stream. Never reduce late source events to held-key state.
            while index < timeline.wireEvents.count && timeline.wireEvents[index].seconds <= seconds {
                try sourceApply(timeline.wireEvents[index]); index += 1
            }
            return
        }
        var programs: [UInt8: Event] = [:], controls: [UInt16: Event] = [:]
        var notes = reconstruct ? [:] : held
        if reconstruct { index = 0 }
        // Consume the complete target boundary before emitting. A fully expired
        // note interval must not be replayed when the deadline queue wakes late.
        while index < timeline.events.count && timeline.events[index].seconds <= seconds {
            let event = timeline.events[index]
            switch event.kind {
            case .program: programs[event.channel] = event
            case .control: controls[event.key] = event
            case .on: notes[event.key] = event
            case .off: notes.removeValue(forKey: event.key)
            }
            index += 1
        }
        for event in programs.values.sorted(by: { $0.channel < $1.channel }) { try apply(event) }
        for event in controls.values.sorted(by: { $0.key < $1.key }) { try apply(event) }
        for event in held.values.sorted(by: { $0.key < $1.key }) where notes[event.key] != event {
            try send([0x80 | event.channel, event.pitch!, 0])
            held.removeValue(forKey: event.key)
        }
        for event in notes.values.sorted(by: { $0.key < $1.key }) where held[event.key] != event { try apply(event) }
    }
    func position(at host: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Double {
        guard state == .playing else { return offset }
        return offset + Double(host - anchor) / 1e9
    }
    func schedule() throws {
        timer?.cancel(); timer = nil
        guard state == .playing else { return }
        let next = timeline.source ? (index < timeline.wireEvents.count ? timeline.wireEvents[index].seconds : timeline.duration)
            : (index < timeline.events.count ? timeline.events[index].seconds : timeline.duration)
        let delay = max(0, next - offset) * 1e9
        guard delay < Double(UInt64.max) else { throw MidiFailure("MIDI event exceeds the host clock range") }
        let (deadline, overflow) = anchor.addingReportingOverflow(UInt64(delay))
        guard !overflow, deadline < UInt64.max else { throw MidiFailure("MIDI event exceeds the host clock range") }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline), leeway: .nanoseconds(0))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume(); timer = source
    }
    func tick() {
        guard state == .playing else { return }
        do {
            let host = DispatchTime.now().uptimeNanoseconds
            let now = position(at: host)
            let next = timeline.source ? (index < timeline.wireEvents.count ? timeline.wireEvents[index].seconds : now)
                : (index < timeline.events.count ? timeline.events[index].seconds : now)
            maximumLateness = max(maximumLateness, now - next)
            if timeline.source { try reconcile(at: min(now, timeline.duration)) }
            if now >= timeline.duration {
                if !loop { offset = timeline.duration; finish(reason: "finished"); return }
                // Resolve phase before replaying any pending events. Keep the
                // same host sample so cleanup/restoration time remains elapsed.
                offset = now.truncatingRemainder(dividingBy: timeline.duration)
                anchor = host
                try silence()
                try restore(at: offset)
            } else { try reconcile(at: now) }
            try schedule()
        } catch { finish(reason: "playback-failed", error: error) }
    }
    func start() {
        guard prepared, state == .prepared else { return }
        do {
            try checkDestination()
            for number in [SIGINT, SIGTERM, SIGHUP] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
                source.setEventHandler { [weak self] in self?.finish(reason: "signal") }
                source.resume(); signals.append(source)
            }
            anchor = DispatchTime.now().uptimeNanoseconds; state = .playing
            if timeline.source { publish() }
            tick(); publish()
        } catch { finish(reason: "start-failed", error: error) }
    }
    func publish() {
        guard state != .stopped else { return }
        do { try emit(snapshot(state == .playing ? "playing" : "paused")) }
        catch { finish(reason: "event-output-failed", error: error, publish: false) }
    }
    func snapshot(_ kind: String) -> [String: Any] {
        let elapsed = position()
        let current = loop ? elapsed.truncatingRemainder(dividingBy: timeline.duration) : min(elapsed, timeline.duration)
        var value: [String: Any] = ["kind": kind, "currentTime": current, "duration": timeline.duration,
                                  "loop": loop, "maximumLateness": maximumLateness]
        if let destination { value["device"] = destination.json }
        if timeline.source { value["bindings"] = timeline.bindings.compactMap { binding in
            sourceDestinations[binding.port].map { ["port": binding.port, "device": $0.json] as [String: Any] }
        } }
        return value
    }
    func receive(_ line: String) {
        guard state != .stopped else { return }
        do {
            let command = try JSONDecoder().decode(Command.self, from: Data(line.utf8))
            try checkDestination()
            if timeline.source {
                switch command {
                case .pause, .resume, .seek: throw MidiFailure("source audition supports play/stop from the beginning; expression-state chase is not connected")
                case .status, .stop: break
                }
            }
            switch command {
            case .pause:
                if state == .playing {
                    let elapsed = position()
                    offset = loop ? elapsed.truncatingRemainder(dividingBy: timeline.duration) : min(elapsed, timeline.duration)
                    state = .paused
                    timer?.cancel(); timer = nil; try silence()
                }
            case .resume:
                if state == .paused {
                    anchor = DispatchTime.now().uptimeNanoseconds; state = .playing
                    try restore(at: offset); tick()
                }
            case .seek(let seconds):
                guard seconds.isFinite, seconds >= 0, seconds <= timeline.duration else { throw MidiFailure("seek must be within the MIDI timeline") }
                let wasPlaying = state == .playing
                let host = DispatchTime.now().uptimeNanoseconds
                timer?.cancel(); timer = nil; try silence()
                offset = seconds == timeline.duration && loop ? 0 : seconds
                if wasPlaying { anchor = host }
                if seconds == timeline.duration && !loop { finish(reason: "finished"); return }
                // Paused seek must remain silent; resume reconstructs held notes.
                if wasPlaying {
                    try restore(at: offset); tick()
                }
            case .status:
                if state == .playing { tick() }
                if state == .stopped { return }
            case .stop: finish(reason: "stop"); return
            }
            publish()
        } catch { finish(reason: "command-failed", error: error) }
    }
    func finish(reason: String, error: Error? = nil, publish: Bool = true) {
        guard state != .stopped else { return }
        var stopped = snapshot("stopped"), failure = error
        state = .stopped; timer?.cancel(); timer = nil
        do { try silence() } catch { failure = failure ?? error }
        if port != 0 { MIDIPortDispose(port); port = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
        signals.forEach { $0.cancel() }; signals.removeAll()
        stopped["reason"] = reason; stopped["success"] = failure == nil
        if let failure { diagnostic(failure) }
        if publish {
            do {
                if let failure { try emit(["kind": "error", "message": String(describing: failure)]) }
                try emit(stopped)
            } catch { diagnostic(error); failure = error }
        }
        exit(failure == nil ? 0 : 1)
    }
}

_ = signal(SIGPIPE, SIG_IGN)
do {
    var args = Array(CommandLine.arguments.dropFirst())
    if args == ["destinations"] {
        var client = MIDIClientRef()
        try checked(MIDIClientCreateWithBlock("MASC MIDI destinations" as CFString, &client, nil), "create MIDI client")
        defer { MIDIClientDispose(client) }
        try emit(["kind": "destinations", "destinations": try destinations().map(\.json)])
        exit(0)
    }
    guard args.first == "play" else { throw MidiFailure("usage: music-midi play --file TIMELINE_JSON --destination UID [--loop] | destinations") }
    args.removeFirst()
    var path: String?, uid: String?, loop = false
    while !args.isEmpty {
        switch args.removeFirst() {
        case "--file": guard path == nil, !args.isEmpty else { throw MidiFailure("--file requires one timeline path") }; path = args.removeFirst()
        case "--destination": guard uid == nil, !args.isEmpty else { throw MidiFailure("--destination requires one MIDI unique ID") }; uid = args.removeFirst()
        case "--loop": guard !loop else { throw MidiFailure("duplicate --loop") }; loop = true
        default: throw MidiFailure("unknown MIDI transport option")
        }
    }
    guard let path, let uid else { throw MidiFailure("--file and --destination are required") }
    let transport = try MidiTransport(path: path, uid: uid, loop: loop)
    try transport.prepare()
    transport.queue.async { transport.start() }
    DispatchQueue.global().async {
        while let line = readLine() { transport.queue.async { transport.receive(line) } }
        transport.queue.async { transport.finish(reason: "eof") }
    }
    withExtendedLifetime(transport) { RunLoop.main.run() }
} catch {
    diagnostic(error)
    do { try emit(["kind": "error", "message": String(describing: error)]) } catch { diagnostic(error) }
    exit(1)
}
