// Measurement harness for #45224. This file lives only on a measurement branch
// and is never merged. It counts UMP messages that reach a private CoreMIDI
// destination when the sending port/client is disposed, or its process exits,
// right after the final send, against controls that keep the sender alive.
// Only private virtual destinations owned by this process receive messages.
import Foundation
import CoreMIDI

let messagesPerTrial = 2
// Product note-off cleanup carries no sequence tag, so its (channel, note)
// slot identifies the trial. 16 channels x 128 notes bound the trial count.
let keySlots = 2048

enum MeasureCondition: String, CaseIterable {
    case disposeNow = "dispose_now"
    case portOnly = "port_only_dispose"
    case keepAlive = "keep_alive_until_receipt"
    case sharedClient = "shared_client"
    case productClose = "product_umpoutput_close"
    case packetDisposeNow = "midisend_dispose_now"
    case packetKeepAlive = "midisend_keep_alive"
    case sleep1ms = "compare_sleep_1ms_then_dispose"
    case sleep10ms = "compare_sleep_10ms_then_dispose"
    case childExit = "child_exit_without_dispose"
    case childDisposeExit = "child_dispose_then_exit"
    case childKeepAlive = "child_keep_alive_until_receipt"
}

enum Expect: Hashable {
    case seq(Int)       // MIDI 2.0 channel voice, sequence in word 1 high half
    case key2(UInt32)   // product cleanup note-off word 0 (word 1 is zero)
    case midi1(UInt32)  // MIDI 1.0 UMP word delivered to the 1.0 destination
    var words: Int { if case .midi1 = self { return 1 }; return 2 }
}

struct TrialRecord {
    let condition: MeasureCondition
    let trial: Int
    let expects: [Expect]
    let sendTimes: [UInt64?]
    let inWindow: [Bool]
    let failure: String?
    let disposeStatus: [Int32]
}

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func eventListWords(_ list: UnsafePointer<MIDIEventList>) -> [UInt32] {
    let raw = UnsafeRawPointer(list)
    let count = raw.loadUnaligned(fromByteOffset: MemoryLayout<MIDIEventList>.offset(of: \.numPackets)!, as: UInt32.self)
    var packet = raw.advanced(by: MemoryLayout<MIDIEventList>.offset(of: \.packet)!)
    var words: [UInt32] = []
    for _ in 0..<count {
        let size = Int(packet.loadUnaligned(fromByteOffset: MemoryLayout<MIDIEventPacket>.offset(of: \.wordCount)!, as: UInt32.self))
        let base = packet.advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \.words)!)
        for index in 0..<size { words.append(base.loadUnaligned(fromByteOffset: index * MemoryLayout<UInt32>.stride, as: UInt32.self)) }
        packet = UnsafeRawPointer(MIDIEventPacketNext(packet.assumingMemoryBound(to: MIDIEventPacket.self)))
    }
    return words
}

final class MeasureReceiver {
    let lock = NSCondition()
    var arrivals: [Expect: [UInt64]] = [:]
    var unparsedWords = 0
    var client = MIDIClientRef(), dest2 = MIDIEndpointRef(), dest1 = MIDIEndpointRef()
    var uid2: Int32 = 0, uid1: Int32 = 0
    func start() throws {
        var created = MIDIClientRef(), two = MIDIEndpointRef(), one = MIDIEndpointRef()
        try checked(MIDIClientCreate("MASC 45224 receiver" as CFString, nil, nil, &created), "create receiver client")
        try checked(MIDIDestinationCreateWithProtocol(created, "MASC 45224 m2 \(UUID().uuidString)" as CFString, ._2_0, &two) { [unowned self] list, _ in
            self.receive(list)
        }, "create private MIDI 2.0 destination")
        try checked(MIDIDestinationCreateWithProtocol(created, "MASC 45224 m1 \(UUID().uuidString)" as CFString, ._1_0, &one) { [unowned self] list, _ in
            self.receive(list)
        }, "create private MIDI 1.0 destination")
        client = created; dest2 = two; dest1 = one
        try checked(MIDIObjectGetIntegerProperty(dest2, kMIDIPropertyUniqueID, &uid2), "read MIDI 2.0 destination identity")
        try checked(MIDIObjectGetIntegerProperty(dest1, kMIDIPropertyUniqueID, &uid1), "read MIDI 1.0 destination identity")
    }
    func receive(_ list: UnsafePointer<MIDIEventList>) {
        let at = now(), words = eventListWords(list)
        lock.lock()
        var index = 0
        while index < words.count {
            let first = words[index], type = first >> 28
            if type == 4, index + 1 < words.count {
                let second = words[index + 1]
                arrivals[second == 0 ? .key2(first) : .seq(Int(second >> 16)), default: []].append(at); index += 2
            } else if type == 2 {
                arrivals[.midi1(first), default: []].append(at); index += 1
            } else { unparsedWords += 1; index += 1 }
        }
        lock.broadcast(); lock.unlock()
    }
    func wait(_ expects: [Expect], seconds: Double) -> [Bool] {
        lock.lock(); defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(seconds)
        while !expects.allSatisfy({ arrivals[$0] != nil }) {
            if !lock.wait(until: deadline) { break }
        }
        return expects.map { arrivals[$0] != nil }
    }
}

func taggedWords(seq: Int, index: Int) -> [UInt32] {
    // Note On / Note Off alternate; attribute type 3 keeps word 1 verbatim.
    let status: UInt32 = index % 2 == 0 ? 0x9 : 0x8
    return [0x40000003 | status << 20 | UInt32(index) << 8, UInt32(seq) << 16 | UInt32(index)]
}

// Same construction as UmpOutput.send: one complete message per MIDISendEventList.
func sendUmp(_ port: MIDIPortRef, _ destination: MIDIEndpointRef, _ words: [UInt32]) throws {
    let capacity = MemoryLayout<MIDIEventList>.size
    let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<MIDIEventList>.alignment)
    defer { storage.deallocate() }
    let list = storage.assumingMemoryBound(to: MIDIEventList.self), packet = MIDIEventListInit(list, ._2_0)
    try words.withUnsafeBufferPointer { buffer in
        let added = MIDIEventListAdd(list, capacity, packet, 0, buffer.count, buffer.baseAddress!)
        guard UInt(bitPattern: added) != 0 else { throw MidiFailure("event list cannot hold one message") }
        try checked(MIDISendEventList(port, destination, list), "send UMP")
    }
}

// Same construction as MidiTransport.sendWire's MIDISend path.
func sendPacket(_ port: MIDIPortRef, _ destination: MIDIEndpointRef, _ bytes: [UInt8]) throws {
    let capacity = 1024
    let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<MIDIPacketList>.alignment)
    defer { storage.deallocate() }
    let list = storage.assumingMemoryBound(to: MIDIPacketList.self), packet = MIDIPacketListInit(list)
    try bytes.withUnsafeBufferPointer { data in
        let added = MIDIPacketListAdd(list, capacity, packet, 0, data.count, data.baseAddress!)
        guard UInt(bitPattern: added) != 0 else { throw MidiFailure("packet list cannot hold one message") }
        try checked(MIDISend(port, destination, list), "send MIDI packet list")
    }
}

func createSender(_ name: String) throws -> (MIDIClientRef, MIDIPortRef) {
    var client = MIDIClientRef(), port = MIDIPortRef()
    try checked(MIDIClientCreateWithBlock(name as CFString, &client, { _ in }), "create sender client")
    do { try checked(MIDIOutputPortCreate(client, name as CFString, &port), "create sender port") }
    catch { MIDIClientDispose(client); throw error }
    return (client, port)
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

func logChoose(_ n: Int, _ k: Int) -> Double { lgamma(Double(n + 1)) - lgamma(Double(k + 1)) - lgamma(Double(n - k + 1)) }
// Two-sided Fisher exact test of [[a, b], [c, d]].
func fisherTwoSided(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Double {
    let r1 = a + b, r2 = c + d, c1 = a + c, n = r1 + r2
    func p(_ x: Int) -> Double { exp(logChoose(r1, x) + logChoose(r2, c1 - x) - logChoose(n, c1)) }
    let observed = p(a)
    var total = 0.0
    for x in max(0, c1 - r2)...min(r1, c1) { let px = p(x); if px <= observed * (1 + 1e-7) { total += px } }
    return min(1, total)
}
func wilson(_ k: Int, _ n: Int) -> [Double] {
    guard n > 0 else { return [0, 1] }
    let z = 1.959964, p = Double(k) / Double(n), m = Double(n)
    let denominator = 1 + z * z / m
    let center = (p + z * z / (2 * m)) / denominator
    let half = z * (p * (1 - p) / m + z * z / (4 * m * m)).squareRoot() / denominator
    return [max(0, center - half), min(1, center + half)]
}
func jsonValue(_ value: UInt64?) -> Any { value.map { $0 as Any } ?? NSNull() }
func percentile(_ sorted: [UInt64], _ q: Double) -> UInt64? {
    guard !sorted.isEmpty else { return nil }
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
}
func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: bytes)
}

final class Measurement {
    let receiver = MeasureReceiver()
    var nextSequence = 1
    var shared: (MIDIClientRef, MIDIPortRef) = (0, 0)
    let window: Double
    init(window: Double) { self.window = window }
    func sequence() throws -> Int {
        guard nextSequence < 1 << 16 else { throw MidiFailure("sequence space exhausted") }
        defer { nextSequence += 1 }
        return nextSequence
    }
    func dispose(_ port: MIDIPortRef, _ client: MIDIClientRef) -> [Int32] { [MIDIPortDispose(port), MIDIClientDispose(client)] }

    func run(_ condition: MeasureCondition, trial: Int) -> TrialRecord {
        let slot = UInt32(trial % keySlots), channel = slot % 16, note = (slot / 16) % 128
        var expects: [Expect] = [], sendTimes: [UInt64?] = [], statuses: [Int32] = []
        var failure: String?
        var after: [() -> Void] = []
        do {
            switch condition {
            case .productClose:
                // The real owner: prepare, one acquired Note On, close() -> silence() -> dispose.
                let seq = try sequence()
                let on: [UInt32] = [0x40900003 | channel << 16 | note << 8, UInt32(seq) << 16]
                expects = [.seq(seq), .key2(0x40800000 | channel << 16 | note << 8)]
                let output = UmpOutput(bindings: [UmpBinding(source: "A", destination: String(receiver.uid2))])
                try output.prepare()
                sendTimes.append(now()); try output.apply(UmpEvent(seconds: 0, source: "A", words: on))
                sendTimes.append(now()); try output.close()
            case .packetDisposeNow, .packetKeepAlive:
                let (client, port) = try createSender("MASC 45224 packet sender")
                for index in 0..<messagesPerTrial {
                    let status = (index % 2 == 0 ? 0x90 : 0x80) | UInt8(channel)
                    let velocity = UInt8(index + 1 + (condition == .packetKeepAlive ? 64 : 0))
                    expects.append(.midi1(0x20000000 | UInt32(status) << 16 | note << 8 | UInt32(velocity)))
                    sendTimes.append(now()); try sendPacket(port, receiver.dest1, [status, UInt8(note), velocity])
                }
                if condition == .packetDisposeNow { statuses = dispose(port, client) }
                else { after.append { [unowned self] in statuses = self.dispose(port, client) } }
            case .disposeNow, .portOnly, .keepAlive, .sharedClient, .sleep1ms, .sleep10ms:
                let (client, port) = try condition == .sharedClient ? shared : createSender("MASC 45224 sender")
                for index in 0..<messagesPerTrial {
                    let seq = try sequence(); expects.append(.seq(seq))
                    sendTimes.append(now()); try sendUmp(port, receiver.dest2, taggedWords(seq: seq, index: index))
                }
                switch condition {
                case .disposeNow: statuses = dispose(port, client)
                case .portOnly:
                    statuses = [MIDIPortDispose(port)]
                    after.append { statuses.append(MIDIClientDispose(client)) }
                case .sleep1ms: usleep(1_000); statuses = dispose(port, client)
                case .sleep10ms: usleep(10_000); statuses = dispose(port, client)
                case .keepAlive: after.append { [unowned self] in statuses = self.dispose(port, client) }
                default: break
                }
            case .childExit, .childDisposeExit, .childKeepAlive:
                var seqs: [Int] = []
                for _ in 0..<messagesPerTrial { seqs.append(try sequence()) }
                expects = seqs.map { .seq($0) }; sendTimes = seqs.map { _ in nil }
                let mode = condition == .childExit ? "exit" : condition == .childDisposeExit ? "dispose-exit" : "keep-alive"
                let process = Process()
                process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                process.arguments = ["child", mode, String(receiver.uid2)] + seqs.map(String.init)
                let input = Pipe(), output = Pipe()
                process.standardInput = input; process.standardOutput = output
                try process.run()
                if condition == .childKeepAlive {
                    let line = output.fileHandleForReading.readData(ofLength: 5)
                    guard line == Data("sent\n".utf8) else { throw MidiFailure("keep-alive child did not report its sends") }
                    after.append { try? input.fileHandleForWriting.close(); process.waitUntilExit() }
                } else {
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw MidiFailure("child exited with \(process.terminationStatus)") }
                }
            }
        } catch { failure = String(describing: error) }
        let observed = failure == nil ? receiver.wait(expects, seconds: window) : expects.map { _ in false }
        for action in after { action() }
        return TrialRecord(condition: condition, trial: trial, expects: expects, sendTimes: sendTimes,
                           inWindow: observed, failure: failure, disposeStatus: statuses)
    }
}

func childMain(_ arguments: [String]) throws -> Never {
    guard arguments.count == 2 + messagesPerTrial, let uid = Int32(arguments[1]) else { throw MidiFailure("child arguments") }
    let seqs = try arguments.dropFirst(2).map { value -> Int in
        guard let seq = Int(value) else { throw MidiFailure("child sequence") }
        return seq
    }
    let (client, port) = try createSender("MASC 45224 child sender")
    var object = MIDIObjectRef(), type = MIDIObjectType.other
    try checked(MIDIObjectFindByUniqueID(uid, &object, &type), "child find destination")
    guard type == .destination else { throw MidiFailure("child target is not a destination") }
    for (index, seq) in seqs.enumerated() { try sendUmp(port, object, taggedWords(seq: seq, index: index)) }
    switch arguments[0] {
    case "exit": exit(0)
    case "dispose-exit": MIDIPortDispose(port); MIDIClientDispose(client); exit(0)
    case "keep-alive":
        FileHandle.standardOutput.write(Data("sent\n".utf8))
        _ = FileHandle.standardInput.readDataToEndOfFile()
        exit(0)
    default: throw MidiFailure("child mode")
    }
}

@main enum MidiCloseMeasure {
    static func main() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "child" { try childMain(Array(arguments.dropFirst())) }
        var trials = 400, windowMs = 500.0, graceMs = 3000.0, seed: UInt64 = 45224, json: String?
        var conditions = MeasureCondition.allCases
        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            guard let value = arguments.first else { throw MidiFailure("missing value for \(flag)") }
            arguments.removeFirst()
            switch flag {
            case "--trials": trials = Int(value) ?? -1
            case "--window-ms": windowMs = Double(value) ?? -1
            case "--grace-ms": graceMs = Double(value) ?? -1
            case "--seed": seed = UInt64(value) ?? 0
            case "--json": json = value
            case "--conditions":
                conditions = try value.split(separator: ",").map { name in
                    guard let condition = MeasureCondition(rawValue: String(name)) else { throw MidiFailure("unknown condition \(name)") }
                    return condition
                }
            default: throw MidiFailure("unknown flag \(flag)")
            }
        }
        guard trials > 0, trials <= keySlots, windowMs > 0, graceMs >= 0 else { throw MidiFailure("invalid trials/window/grace") }

        let measurement = Measurement(window: windowMs / 1000)
        try measurement.receiver.start()
        measurement.shared = try createSender("MASC 45224 shared sender")
        // A harness that cannot deliver to its own destination measures nothing.
        let probe = try measurement.sequence()
        try sendUmp(measurement.shared.1, measurement.receiver.dest2, taggedWords(seq: probe, index: 0))
        guard measurement.receiver.wait([.seq(probe)], seconds: 5) == [true] else { throw MidiFailure("warm-up message never arrived") }

        let started = Date()
        var rng = SplitMix64(state: seed)
        var records: [TrialRecord] = []
        for trial in 0..<trials {
            for condition in conditions.shuffled(using: &rng) { records.append(measurement.run(condition, trial: trial)) }
            if (trial + 1) % 50 == 0 { FileHandle.standardError.write(Data("round \(trial + 1)/\(trials) \(Int(Date().timeIntervalSince(started)))s\n".utf8)) }
        }
        Thread.sleep(forTimeInterval: graceMs / 1000)

        let receiver = measurement.receiver
        receiver.lock.lock()
        let arrivals = receiver.arrivals, unparsed = receiver.unparsedWords
        receiver.lock.unlock()
        let expected = Set(records.flatMap(\.expects) + [.seq(probe)])
        let unexpected = arrivals.keys.filter { !expected.contains($0) }.count
        let duplicates = arrivals.values.filter { $0.count > 1 }.count

        func lostTrials(_ condition: MeasureCondition) -> (lost: Int, valid: Int) {
            let valid = records.filter { $0.condition == condition && $0.failure == nil }
            return (valid.filter { $0.expects.contains { arrivals[$0] == nil } }.count, valid.count)
        }
        var rows: [[String: Any]] = []
        print(String(repeating: "-", count: 132))
        print("condition".padding(toLength: 34, withPad: " ", startingAt: 0), "trials msgs  words  recvWin recvAll lostMsg lostTrial  rate     95% CI          p(vs keep) p50us  p99us")
        for condition in conditions {
            let all = records.filter { $0.condition == condition }
            let valid = all.filter { $0.failure == nil }
            let messages = valid.reduce(0) { $0 + $1.expects.count }
            let words = valid.reduce(0) { $0 + $1.expects.reduce(0) { $0 + $1.words } }
            let inWindow = valid.reduce(0) { $0 + $1.inWindow.filter { $0 }.count }
            let total = valid.reduce(0) { $0 + $1.expects.filter { arrivals[$0] != nil }.count }
            let wordsReceived = valid.reduce(0) { $0 + $1.expects.filter { arrivals[$0] != nil }.reduce(0) { $0 + $1.words } }
            let (lost, count) = lostTrials(condition)
            let lostByIndex = (0..<messagesPerTrial).map { index in valid.filter { index < $0.expects.count && arrivals[$0.expects[index]] == nil }.count }
            var latencies: [UInt64] = []
            for record in valid {
                for (index, expect) in record.expects.enumerated() {
                    if let sent = record.sendTimes[index], let first = arrivals[expect]?.first, first >= sent { latencies.append((first - sent) / 1000) }
                }
            }
            latencies.sort()
            let keep = lostTrials(.keepAlive), dispose = lostTrials(.disposeNow)
            let pKeep = conditions.contains(.keepAlive) ? fisherTwoSided(lost, count - lost, keep.lost, keep.valid - keep.lost) : Double.nan
            let pDispose = conditions.contains(.disposeNow) ? fisherTwoSided(lost, count - lost, dispose.lost, dispose.valid - dispose.lost) : Double.nan
            let ci = wilson(lost, count)
            let failures = all.compactMap(\.failure)
            let badDispose = valid.flatMap(\.disposeStatus).filter { $0 != 0 }.count
            rows.append(["condition": condition.rawValue, "trials": all.count, "failedTrials": failures.count,
                         "firstFailure": failures.first.map { $0 as Any } ?? NSNull(),
                         "messagesSent": messages, "wordsSent": words,
                         "messagesReceivedInWindow": inWindow, "messagesReceivedTotal": total,
                         "wordsReceivedTotal": wordsReceived, "wordsLost": words - wordsReceived,
                         "lateMessages": total - inWindow, "lostMessages": messages - total,
                         "lostByMessageIndex": lostByIndex,
                         "trialsWithLoss": lost, "trialLossRate": count > 0 ? Double(lost) / Double(count) as Any : NSNull(),
                         "trialLossWilson95": ci, "fisherPvsKeepAlive": pKeep.isNaN ? NSNull() : pKeep as Any,
                         "fisherPvsDisposeNow": pDispose.isNaN ? NSNull() : pDispose as Any,
                         "nonZeroDisposeStatus": badDispose,
                         "latencyMicros": ["n": latencies.count, "p50": jsonValue(percentile(latencies, 0.5)),
                                           "p99": jsonValue(percentile(latencies, 0.99)), "max": jsonValue(latencies.last)]])
            func f(_ value: Double) -> String { String(format: "%.4f", value) }
            print(condition.rawValue.padding(toLength: 34, withPad: " ", startingAt: 0),
                  String(format: "%6ld %5ld %6ld %7ld %7ld %7ld %9ld", all.count, messages, words, inWindow, total, messages - total, lost),
                  f(count > 0 ? Double(lost) / Double(count) : 0), "[\(f(ci[0])),\(f(ci[1]))]",
                  pKeep.isNaN ? "   n/a   " : String(format: "%9.2e", pKeep),
                  percentile(latencies, 0.5).map { String($0) } ?? "-", percentile(latencies, 0.99).map { String($0) } ?? "-",
                  failures.isEmpty ? "" : "failed=\(failures.count) first=\(failures[0])")
        }
        print(String(repeating: "-", count: 132))
        print("unexpected arrival keys=\(unexpected) duplicate keys=\(duplicates) unparsed words=\(unparsed) elapsed=\(Int(Date().timeIntervalSince(started)))s")
        let environment: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
                                          "hwModel": sysctlString("hw.model"), "cpu": sysctlString("machdep.cpu.brand_string"),
                                          "cores": ProcessInfo.processInfo.activeProcessorCount]
        let document: [String: Any] = ["issue": 45224, "trialsPerCondition": trials, "messagesPerTrial": messagesPerTrial,
                                       "windowMs": windowMs, "graceMs": graceMs, "seed": String(seed),
                                       "conditionOrder": "every round shuffles all conditions (SplitMix64 seed)",
                                       "unexpectedArrivalKeys": unexpected, "duplicateArrivalKeys": duplicates, "unparsedWords": unparsed,
                                       "elapsedSeconds": Date().timeIntervalSince(started), "environment": environment, "conditions": rows]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        if let json { try data.write(to: URL(fileURLWithPath: json)) }
    }
}
