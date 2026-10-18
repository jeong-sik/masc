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
struct Event: Decodable {
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
struct Timeline: Decodable {
    let schemaVersion: Int
    let duration: Double
    let events: [Event]
    func validate() throws {
        guard schemaVersion == 1, duration.isFinite, duration > 0,
              duration * 1e9 < Double(UInt64.max) else { throw MidiFailure("invalid MIDI timeline duration") }
        var previous = 0.0
        for event in events {
            _ = try event.bytes()
            guard event.seconds >= previous, event.seconds <= duration else { throw MidiFailure("MIDI events must be ordered inside the timeline") }
            previous = event.seconds
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
    var client = MIDIClientRef(), port = MIDIPortRef()
    var state = State.prepared
    var timer: DispatchSourceTimer?
    var signals: [DispatchSourceSignal] = []
    var anchor: UInt64 = 0, offset = 0.0, index = 0
    var held: [UInt16: Event] = [:]
    var maximumLateness = 0.0

    init(path: String, uid: String, loop: Bool) throws {
        timeline = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try timeline.validate()
        guard let value = Int32(uid), String(value) == uid else { throw MidiFailure("MIDI destination requires its exact unique ID") }
        selectedUID = uid; self.loop = loop
    }
    // Create the client on the main run loop; all subsequent state and sends
    // belong to one serial queue, independent of terminal rendering.
    func prepare() throws {
        try checked(MIDIClientCreateWithBlock("MASC phrase output" as CFString, &client, { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.state != .stopped else { return }
                do { try self.checkDestination() }
                catch { self.finish(reason: "destination-unavailable", error: error) }
            }
        }), "create MIDI client")
        guard let found = try destinations().first(where: { String($0.uid) == selectedUID }) else {
            throw MidiFailure("selected MIDI destination is unavailable: \(selectedUID)")
        }
        destination = found
        try checked(MIDIOutputPortCreate(client, "MASC phrase output" as CFString, &port), "create MIDI output port")
        try checkDestination()
    }
    func checkDestination() throws {
        guard let destination, try destinations().contains(where: {
            $0.endpoint == destination.endpoint && String($0.uid) == selectedUID
        }) else { throw MidiFailure("selected MIDI destination was removed or changed") }
        var offline: Int32 = 0
        let status = MIDIObjectGetIntegerProperty(destination.endpoint, kMIDIPropertyOffline, &offline)
        if status != kMIDIUnknownProperty {
            try checked(status, "read selected MIDI destination state")
            guard offline == 0 else { throw MidiFailure("selected MIDI destination is offline") }
        }
    }
    func send(_ bytes: [UInt8]) throws {
        guard let destination else { throw MidiFailure("MIDI destination has not been selected") }
        var list = MIDIPacketList()
        let result: OSStatus = withUnsafeMutablePointer(to: &list) { pointer in
            let packet = MIDIPacketListInit(pointer)
            return bytes.withUnsafeBufferPointer { data in
                // Structured project messages have at most three data bytes.
                _ = MIDIPacketListAdd(pointer, MemoryLayout<MIDIPacketList>.size, packet, 0, data.count, data.baseAddress!)
                // Only already-due messages enter CoreMIDI. Pause/seek/stop
                // cannot leave this transport's future events in a shared port.
                return MIDISend(port, destination.endpoint, pointer)
            }
        }
        try checked(result, "send MIDI event")
    }
    func apply(_ event: Event) throws {
        try send(event.bytes())
        if event.kind == .on { held[event.key] = event }
        if event.kind == .off { held.removeValue(forKey: event.key) }
    }
    func silence() throws {
        var failure: Error?
        for event in held.values.sorted(by: { $0.key < $1.key }) {
            do { try send([0x80 | event.channel, event.pitch!, 0]) } catch { failure = failure ?? error }
        }
        held.removeAll()
        if let failure { throw failure }
    }
    func restore(at seconds: Double) throws {
        var programs: [UInt8: Event] = [:], controls: [UInt16: Event] = [:], notes: [UInt16: Event] = [:]
        index = 0
        while index < timeline.events.count && timeline.events[index].seconds < seconds {
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
        for event in notes.values.sorted(by: { $0.key < $1.key }) { try apply(event) }
    }
    func position() -> Double {
        guard state == .playing else { return offset }
        return offset + Double(DispatchTime.now().uptimeNanoseconds - anchor) / 1e9
    }
    func schedule() throws {
        timer?.cancel(); timer = nil
        guard state == .playing else { return }
        let next = index < timeline.events.count ? timeline.events[index].seconds : timeline.duration
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
            let now = position()
            while index < timeline.events.count && timeline.events[index].seconds <= min(now, timeline.duration) {
                let event = timeline.events[index]
                maximumLateness = max(maximumLateness, now - event.seconds)
                try apply(event); index += 1
            }
            if now >= timeline.duration {
                if !loop { offset = timeline.duration; finish(reason: "finished"); return }
                try silence()
                // Skip completed cycles after suspension instead of emitting
                // stale iterations as a burst. Restore the current musical phase.
                offset = now.truncatingRemainder(dividingBy: timeline.duration)
                anchor = DispatchTime.now().uptimeNanoseconds
                try restore(at: offset)
            }
            try schedule()
        } catch { finish(reason: "playback-failed", error: error) }
    }
    func start() {
        do {
            try checkDestination()
            for number in [SIGINT, SIGTERM, SIGHUP] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
                source.setEventHandler { [weak self] in self?.finish(reason: "signal") }
                source.resume(); signals.append(source)
            }
            anchor = DispatchTime.now().uptimeNanoseconds; state = .playing
            tick(); publish()
        } catch { finish(reason: "start-failed", error: error) }
    }
    func publish() {
        guard state != .stopped else { return }
        do { try emit(snapshot(state == .playing ? "playing" : "paused")) }
        catch { finish(reason: "event-output-failed", error: error, publish: false) }
    }
    func snapshot(_ kind: String) -> [String: Any] {
        let current = min(position(), timeline.duration)
        return ["kind": kind, "currentTime": current, "duration": timeline.duration,
                "device": destination!.json, "loop": loop, "maximumLateness": maximumLateness]
    }
    func receive(_ line: String) {
        guard state != .stopped else { return }
        do {
            let command = try JSONDecoder().decode(Command.self, from: Data(line.utf8))
            try checkDestination()
            switch command {
            case .pause:
                if state == .playing {
                    offset = min(position(), timeline.duration); state = .paused
                    timer?.cancel(); timer = nil; try silence()
                }
            case .resume:
                if state == .paused {
                    try restore(at: offset); anchor = DispatchTime.now().uptimeNanoseconds; state = .playing; tick()
                }
            case .seek(let seconds):
                guard seconds.isFinite, seconds >= 0, seconds <= timeline.duration else { throw MidiFailure("seek must be within the MIDI timeline") }
                let wasPlaying = state == .playing
                timer?.cancel(); timer = nil; try silence()
                offset = seconds == timeline.duration && loop ? 0 : seconds
                if seconds == timeline.duration && !loop { finish(reason: "finished"); return }
                // Paused seek must remain silent; resume reconstructs held notes.
                if wasPlaying {
                    try restore(at: offset); anchor = DispatchTime.now().uptimeNanoseconds; tick()
                }
            case .status: break
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
