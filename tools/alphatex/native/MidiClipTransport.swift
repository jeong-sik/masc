import Foundation
import CoreMIDI

struct MidiClipPlaybackPlan: Decodable {
    struct Source: Decodable { let originalSha256: String; let documentSha256: String; let ppq: UInt32 }
    enum Section: String, Decodable { case configuration, sequence }
    struct Event: Decodable {
        let id: String
        let section: Section
        let tick: String
        let words: [UInt32]
        let nanoseconds: ExactNanoseconds
    }
    let schemaVersion: Int
    let kind: String
    let source: Source
    let destination: String
    let setupNanoseconds: ExactNanoseconds
    let durationNanoseconds: ExactNanoseconds
    let events: [Event]

    func numerator(_ value: ExactNanoseconds) throws -> UInt128 {
        let (n, d) = try value.rational()
        guard d == UInt128(source.ppq) else { throw MidiFailure("Clip clock denominator disagrees with source PPQ") }
        return n
    }
    func rounded(_ value: ExactNanoseconds) throws -> UInt64 {
        let n = try numerator(value), d = UInt128(source.ppq)
        let time = n / d + (n % d == 0 ? 0 : 1)
        guard time < UInt128(UInt64.max) else { throw MidiFailure("Clip exceeds the native nanosecond clock") }
        return UInt64(time)
    }
    func validate() throws {
        func sha(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard schemaVersion == 1, kind == "midi-clip-playback", source.ppq > 0, source.ppq <= 65535,
              sha(source.originalSha256), sha(source.documentSha256),
              let uid = Int32(destination), String(uid) == destination else { throw MidiFailure("invalid native Clip playback identity") }
        let setup = try numerator(setupNanoseconds), duration = try numerator(durationNanoseconds)
        guard duration >= setup else { throw MidiFailure("Clip ends before configuration completes") }
        _ = try rounded(durationNanoseconds)
        var ids = Set<String>(), previous: UInt128 = 0, sequence = false
        for event in events {
            guard let identity = UInt128(event.id), String(identity) == event.id, identity >= 8, identity % 4 == 0,
                  ids.insert(event.id).inserted, let tick = UInt128(event.tick), String(tick) == event.tick,
                  let word = event.words.first, event.words.count == umpMessageWordCounts[Int(word >> 28)] else {
                throw MidiFailure("invalid native Clip source message")
            }
            let at = try numerator(event.nanoseconds)
            guard at >= previous, at <= duration else { throw MidiFailure("unordered or out-of-range Clip event") }
            switch event.section {
            case .configuration:
                guard !sequence, at <= setup else { throw MidiFailure("Clip configuration is outside its setup phase") }
            case .sequence:
                sequence = true
                guard at >= setup else { throw MidiFailure("Clip sequence precedes its setup phase") }
            }
            let type = word >> 28, utility = word >> 20 & 15
            guard !(type == 0 && [1,2,3,4].contains(utility)),
                  word != 0xf0200000, word != 0xf0210000 else { throw MidiFailure("Clip file or JR clock control cannot be sent as scheduled UMP") }
            _ = try rounded(event.nanoseconds); previous = at
        }
    }
}

enum MidiClipCommand: Decodable {
    case start, pause, resume, seek(UInt64), status, stop
    enum Keys: String, CodingKey { case kind, nanoseconds }
    enum Kind: String, Decodable { case start, pause, resume, seek, status, stop }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        if kind != .seek && values.contains(.nanoseconds) { throw MidiFailure("nanoseconds is only valid for Clip seek") }
        switch kind {
        case .start: self = .start
        case .pause: self = .pause
        case .resume: self = .resume
        case .status: self = .status
        case .stop: self = .stop
        case .seek:
            let value = try values.decode(String.self, forKey: .nanoseconds)
            guard let time = UInt64(value), String(time) == value else { throw MidiFailure("Clip seek requires exact UInt64 nanoseconds") }
            self = .seek(time)
        }
    }
}

// This owner schedules a Clip directly; no captured-session clock or audio asset
// is invented. Integer absolute deadlines preserve source order through rounding.
final class MidiClipTransport {
    enum State { case prepared, playing, paused, stopped }
    let plan: MidiClipPlaybackPlan
    let times: [UInt64]
    let events: [UmpEvent]
    let duration: UInt64
    let setup: UInt64
    let output: UmpOutput
    var state = State.prepared
    var index = 0
    var offset: UInt64 = 0
    var anchor: UInt64 = 0
    var pendingRestore = false
    var timer: DispatchSourceTimer?
    var terminalFailure: Error?
    var onState: (([String: Any]) throws -> Void)?
    var onStop: ((Error?) -> Void)?
    var now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }

    init(plan: MidiClipPlaybackPlan) throws {
        try plan.validate(); self.plan = plan
        times = try plan.events.map { try plan.rounded($0.nanoseconds) }
        duration = try plan.rounded(plan.durationNanoseconds); setup = try plan.rounded(plan.setupNanoseconds)
        events = plan.events.map { UmpEvent(seconds: 0, source: plan.source.documentSha256, words: $0.words) }
        // No implicit MIDI1 compatibility route: Clip playback owns native UMP.
        output = UmpOutput(bindings: [UmpBinding(source: plan.source.documentSha256, destination: plan.destination)], metadata: .tempoAndMeter)
    }
    func prepare() throws {
        guard Thread.isMainThread, state == .prepared, output.client == 0, !output.closed else { throw MidiFailure("Clip preparation requires one main owner") }
        guard try umpNativeProtocol(plan.destination) == .midi2 else { throw MidiFailure("native MIDI2 Clip audition requires a MIDI 2.0 destination") }
        output.onFailure = { [weak self] error in self?.finish(reason: "destination-unavailable", error: error) }
        try output.prepare()
    }
    func start() throws {
        guard state == .prepared, !output.selected.isEmpty else { throw MidiFailure("Clip output is not prepared") }
        anchor = now(); state = .playing
        try publish(); tick()
    }
    func position(at host: UInt64) -> UInt64 {
        guard state == .playing else { return offset }
        let elapsed = host > anchor ? host - anchor : 0
        return offset + min(elapsed, duration - offset)
    }
    func reconstruction(at time: UInt64) throws -> UmpRestoration {
        let count = times.firstIndex(where: { $0 >= time }) ?? times.count
        let end = times[count...].firstIndex(where: { $0 > time }) ?? times.count
        let restored = try umpRestoration(events, prefixCount: count, followingCount: end - count,
            preambleEndIndex: events.count, dueAdmission: .original, metadata: .tempoAndMeter, replacing: output.footprint)
        // Future channel baselines may precede future attacks; group timing
        // cannot be credited as already restored by an event after this cut.
        let clocks = output.footprint.touched.filter { field in
            switch field.kind { case .tempo, .meter: return true; default: return false }
        }
        var known = Set<UmpField>()
        for event in restored.events + Array(events[count..<end]) {
            known.formUnion(UmpMessage(event, metadata: .tempoAndMeter).fields)
        }
        guard clocks.allSatisfy({ $0.covered(by: known) }) else {
            throw UmpRefusal("Clip reconstruction cannot restore group tempo/meter from a future source event")
        }
        return restored
    }
    func schedule() throws {
        timer?.cancel(); timer = nil
        guard state == .playing else { return }
        let target = pendingRestore ? offset : index < times.count ? times[index] : duration
        let delay = target > offset ? target - offset : 0
        let deadline = anchor.addingReportingOverflow(delay)
        guard !deadline.overflow, deadline.partialValue < UInt64.max else { throw MidiFailure("Clip deadline exceeds the host clock") }
        let source = DispatchSource.makeTimerSource(queue: .main); timer = source
        source.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline.partialValue), leeway: .nanoseconds(0))
        source.setEventHandler { [weak self] in self?.tick() }; source.resume()
    }
    func tick() {
        guard state == .playing else { return }
        do {
            try output.checkDestinations()
            let time = position(at: now())
            if pendingRestore {
                if time >= duration { offset = duration; finish(reason: "finished"); return }
                let restored = try reconstruction(at: time)
                pendingRestore = false; index = restored.nextIndex
                for event in restored.events { try output.apply(event) }
            }
            while index < events.count && times[index] <= time { try output.apply(events[index]); index += 1 }
            if index == events.count && time >= duration { offset = duration; finish(reason: "finished"); return }
            try schedule()
        } catch { finish(reason: "clip-playback-failed", error: error) }
    }
    func snapshot(_ kind: String, refusal: String? = nil) -> [String: Any] {
        let current = position(at: now()), device = output.selected[plan.source.documentSha256]
        var value: [String: Any] = ["kind": kind, "format": "midi-clip", "loop": false,
            "currentTime": Double(current) / 1e9, "duration": Double(duration) / 1e9,
            "currentNanoseconds": String(current), "durationNanoseconds": String(duration), "setupNanoseconds": String(setup),
            "clock": ["kind": "monotonic-nanoseconds"],
            "source": ["originalSha256": plan.source.originalSha256, "documentSha256": plan.source.documentSha256, "ppq": plan.source.ppq],
            "device": ["kind": "midi", "protocol": 2, "nativeProtocol": 2, "id": plan.destination, "name": device?.name ?? ""],
            "bindings": output.snapshot()]
        if let refusal { value["refusal"] = refusal }
        return value
    }
    func publish(refusal: String? = nil) throws {
        try onState?(snapshot(state == .playing ? "playing" : "paused", refusal: refusal))
    }
    func receive(_ line: String) {
        guard state != .stopped else { return }
        do {
            let command = try JSONDecoder().decode(MidiClipCommand.self, from: Data(line.utf8))
            try output.checkDestinations()
            if state == .prepared {
                switch command {
                case .start, .stop: break
                case .status: try onState?(snapshot("ready")); return
                default: throw MidiFailure("Clip start must be admitted before transport commands")
                }
            }
            switch command {
            case .start: try start(); return
            case .stop: finish(reason: "stop"); return
            case .pause:
                if state == .playing {
                    tick(); guard state == .playing else { return }
                    let time = position(at: now()); _ = try reconstruction(at: time)
                    timer?.cancel(); timer = nil; try output.silence()
                    offset = time; state = .paused; pendingRestore = true
                }
            case .resume:
                if state == .paused {
                    _ = try reconstruction(at: offset)
                    anchor = now(); state = .playing; pendingRestore = true; tick()
                    guard state != .stopped else { return }
                }
            case .seek(let time):
                guard time <= duration else { throw MidiFailure("Clip seek is outside the admitted timeline") }
                if time < duration { _ = try reconstruction(at: time) }
                let playing = state == .playing
                timer?.cancel(); timer = nil; try output.silence(); offset = time
                if time == duration { finish(reason: "finished"); return }
                pendingRestore = true
                if playing { anchor = now(); tick(); guard state != .stopped else { return } }
            case .status:
                if state == .playing { tick(); guard state != .stopped else { return } }
            }
            try publish()
        } catch let refusal as UmpRefusal {
            do { try publish(refusal: refusal.description) } catch { finish(reason: "status-failed", error: error) }
        } catch { finish(reason: "command-failed", error: error) }
    }
    func finish(reason: String, error: Error? = nil) {
        guard state != .stopped else { return }
        offset = position(at: now()); state = .stopped; timer?.cancel(); timer = nil
        var failure = error
        do { try output.close() } catch { failure = failure ?? error }
        terminalFailure = failure
        do {
            if let failure { try onState?(["kind": "error", "message": String(describing: failure)]) }
            var event = snapshot("stopped"); event["reason"] = reason; event["success"] = failure == nil
            try onState?(event)
        } catch { failure = failure ?? error; terminalFailure = failure }
        onStop?(failure)
    }
}

#if !MIDI_CLIP_LIBRARY
@main enum MidiClipCommandLine {
    static func main() {
        _ = signal(SIGPIPE, SIG_IGN)
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            if args == ["destinations"] {
                var client = MIDIClientRef()
                try checked(MIDIClientCreateWithBlock("MASC native Clip destinations" as CFString, &client, nil), "create Clip discovery client")
                defer { MIDIClientDispose(client) }
                let catalog: [[String: Any]] = try destinations().map { destination in
                    ["kind": "midi", "protocol": 2, "nativeProtocol": try umpNativeProtocol(String(destination.uid)).rawValue,
                     "id": String(destination.uid), "name": destination.name]
                }
                try emit(["kind": "destinations", "destinations": catalog]); return
            }
            guard args.first == "play" else { throw MidiFailure("usage: music-midi-clip play --file PLAN --destination UID") }
            args.removeFirst(); var path: String?, destination: String?
            while !args.isEmpty {
                switch args.removeFirst() {
                case "--file": guard path == nil, !args.isEmpty else { throw MidiFailure("--file requires one Clip plan") }; path = args.removeFirst()
                case "--destination": guard destination == nil, !args.isEmpty else { throw MidiFailure("--destination requires one MIDI2 ID") }; destination = args.removeFirst()
                default: throw MidiFailure("unknown native Clip option")
                }
            }
            guard let path, let destination else { throw MidiFailure("Clip plan and destination are required") }
            let plan = try JSONDecoder().decode(MidiClipPlaybackPlan.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard plan.destination == destination else { throw MidiFailure("Clip destination differs from the admitted plan") }
            let transport = try MidiClipTransport(plan: plan)
            var signals: [DispatchSourceSignal] = []
            transport.onState = emit
            transport.onStop = { error in signals.forEach { $0.cancel() }; exit(error == nil ? 0 : 1) }
            for number in [SIGTERM, SIGINT, SIGHUP] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { transport.finish(reason: "signal") }; source.resume(); signals.append(source)
            }
            // Acquiring an endpoint does not admit Note On. The parent verifies
            // this identity before sending start, so pre-ready cancellation is
            // owned without sounding the first source packet.
            try transport.prepare(); try emit(transport.snapshot("ready"))
            DispatchQueue.global().async {
                while let line = readLine() { DispatchQueue.main.async { transport.receive(line) } }
                DispatchQueue.main.async { transport.finish(reason: "eof") }
            }
            withExtendedLifetime(transport) { RunLoop.main.run() }
        } catch {
            diagnostic(error); do { try emit(["kind": "error", "message": String(describing: error)]) } catch { diagnostic(error) }
            exit(1)
        }
    }
}
#endif
