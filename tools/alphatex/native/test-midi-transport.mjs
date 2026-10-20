// Native scheduling decisions with a controlled clock/send boundary. This does
// not register a CoreMIDI client, enumerate devices or send to any endpoint.
import assert from 'node:assert/strict'
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'

const directory = await mkdtemp(join(tmpdir(), 'masc-midi-decisions-'))
try {
  let source = await readFile(new URL('./MidiTransport.swift', import.meta.url), 'utf8')
  source = source.slice(0, source.indexOf('\n#if !MIDI_LIBRARY'))
    .replaceAll('DispatchTime.now().uptimeNanoseconds', 'reviewClock')
    .replace('final class MidiTransport {', `
var reviewPhraseFailure: UInt8?
var reviewClock: UInt64 = 0, reviewSendCost: UInt64 = 0
var reviewSent: [[UInt8]] = [], reviewWire: [(Int32, [UInt8])] = [], reviewWireFail = false, reviewExit: Int32?
// Supply distinct property keys together with the synthetic property APIs;
// this harness never initializes a CoreMIDI client or its resources.
let reviewUniqueIDProperty = "review-uid" as CFString, reviewOfflineProperty = "review-offline" as CFString
struct ReviewDestination {
    let uid: Int32
    var type = MIDIObjectType.destination
    var offline: Int32? = 0
}
var reviewObjects: [MIDIObjectRef: ReviewDestination] = [:], reviewFound: MIDIObjectRef?
var reviewPropertyReads: [MIDIObjectRef] = []
func reviewFindByUniqueID(_ uid: MIDIUniqueID, _ object: UnsafeMutablePointer<MIDIObjectRef>?, _ type: UnsafeMutablePointer<MIDIObjectType>?) -> OSStatus {
    guard let endpoint = reviewFound ?? reviewObjects.first(where: { $0.value.uid == uid })?.key,
          let value = reviewObjects[endpoint] else { return kMIDIObjectNotFound }
    object?.pointee = endpoint; type?.pointee = value.type; return noErr
}
func reviewIntegerProperty(_ object: MIDIObjectRef, _ property: CFString, _ value: UnsafeMutablePointer<Int32>) -> OSStatus {
    reviewPropertyReads.append(object)
    guard let found = reviewObjects[object] else { return -50 }
    if property as String == kMIDIPropertyUniqueID as String { value.pointee = found.uid; return noErr }
    if property as String == kMIDIPropertyOffline as String {
        guard let offline = found.offline else { return kMIDIUnknownProperty }
        value.pointee = offline; return noErr
    }
    return kMIDIUnknownProperty
}
func reviewStringProperty(_ object: MIDIObjectRef, _ property: CFString, _ value: UnsafeMutablePointer<Unmanaged<CFString>?>) -> OSStatus {
    reviewPropertyReads.append(object)
    guard reviewObjects[object] != nil else { return -50 }
    value.pointee = Unmanaged.passRetained("synthetic selected destination" as CFString); return noErr
}
final class MidiTransport {`)
    .replaceAll('MIDIObjectFindByUniqueID(', 'reviewFindByUniqueID(')
    .replaceAll('MIDIObjectGetIntegerProperty(', 'reviewIntegerProperty(')
    .replaceAll('MIDIObjectGetStringProperty(', 'reviewStringProperty(')
    .replaceAll('kMIDIPropertyUniqueID', 'reviewUniqueIDProperty')
    .replaceAll('kMIDIPropertyOffline', 'reviewOfflineProperty')
  const replaceEffect = (start, end, body) => {
    const first = source.indexOf(start), last = source.indexOf(end, first)
    assert.ok(first >= 0 && last > first)
    source = source.slice(0, first) + body + source.slice(last)
  }
  // The real selection/identity code remains intact. Unrelated discovery always
  // fails in this harness; selected lookup/check must never depend on it.
  replaceEffect('func destinations()', 'func selectedDestination(', `func destinations() throws -> [Destination] {
    throw MidiFailure("synthetic unselected enumeration failure")
}
`)
  replaceEffect('    func send(', '    func sendWire(', `    func send(_ bytes: [UInt8]) throws {
        reviewSent.append(bytes); reviewClock += reviewSendCost
        if bytes.first.map({ $0 & 0xf0 }) == reviewPhraseFailure {
            reviewPhraseFailure = nil; throw MidiFailure("synthetic phrase send failure")
        }
    }
`)
  replaceEffect('    func sendWire(', '    func sourceApply(', `    func sendWire(_ bytes: [UInt8], to destination: Destination) throws {
        reviewWire.append((destination.uid, bytes))
        if reviewWireFail { reviewWireFail = false; throw MidiFailure("synthetic send failure") }
    }
`)
  replaceEffect('    func schedule()', '    func tick()', '    func schedule() throws {}\n')
  const pinnedCheckStart = source.indexOf('    func checkDestination()')
  const pinnedCheckEnd = source.indexOf('    func send(', pinnedCheckStart)
  const pinnedCheck = source.slice(pinnedCheckStart, pinnedCheckEnd).replace('func checkDestination()', 'func reviewCheckDestination()')
  replaceEffect('    func checkDestination()', '    func send(', `    func checkDestination() throws {
        guard destination != nil else { throw MidiFailure("synthetic unavailable destination") }
    }
`)
  source = source.replace('exit(failure == nil ? 0 : 1)', 'reviewExit = failure == nil ? 0 : 1')
  source += `\nextension MidiTransport {\n${pinnedCheck}}\n`
  // Exact edges for a fractional project tempo and for denominators whose
  // copy products need 256 bits. JS writes and checks the same edges natively.
  const { fraction, projectNanoseconds, regionEdgeSeconds } = await import('../exact-time.mjs')
  const fractionalStart = fraction(...projectNanoseconds({ tempo: 120.1, ppq: 960 }, 3 * 960 + 17))
  const fractionalPeriod = { numerator: '4166675', denominator: '8' }, probeCopy = 1_234_567, copies = 2_000_000
  const wideDivisor = (1n << 97n) - 1n, wideStart = { numerator: String(3n * wideDivisor + 12345n), denominator: String(wideDivisor) }
  const widePeriod = fraction(520_834_375n * (1n << 90n) + 7n, 1000n * (1n << 90n))
  assert.ok(BigInt(fractionalStart.denominator) > 1n << 50n && BigInt(widePeriod.numerator) * BigInt(copies) > 1n << 128n)
  const edges = (start, period) => [0, probeCopy, copies].map(copy => regionEdgeSeconds(start, period, copy))
  const fractionalEdges = edges(fractionalStart, fractionalPeriod), wideEdges = edges(wideStart, widePeriod)
  source += String.raw`
func transport(_ events: [[String: Any]], loop: Bool = true) throws -> MidiTransport {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "duration": 1, "events": events]).write(to: path)
    defer { try? FileManager.default.removeItem(at: path) }
    let value = try MidiTransport(path: path.path, uid: "1", loop: loop)
    value.destination = Destination(endpoint: 0, uid: 1, name: "synthetic, never registered")
    value.state = .playing
    return value
}
func reset(_ host: UInt64, cost: UInt64 = 0) {
    reviewClock = host; reviewSendCost = cost; reviewSent = []; reviewExit = nil; reviewPhraseFailure = nil
}
func ons() -> [[UInt8]] { reviewSent.filter { $0[0] & 0xf0 == 0x90 } }
func near(_ first: Double, _ second: Double) { precondition(abs(first - second) < 1e-8) }
let events: [[String: Any]] = [
    ["kind":"program", "seconds":0.0, "channel":0, "program":0],
    ["kind":"on", "seconds":0.4, "channel":0, "pitch":60, "velocity":100],
    ["kind":"off", "seconds":0.6, "channel":0, "pitch":60],
    ["kind":"on", "seconds":0.9, "channel":0, "pitch":62, "velocity":100],
    ["kind":"off", "seconds":1.0, "channel":0, "pitch":62]
]
reset(1_250_000_000)
let late = try transport(events); late.index = 1; late.tick()
precondition(ons().isEmpty); near(late.position(), 0.25)
reset(800_000_000)
let within = try transport(events); within.index = 1; within.tick()
precondition(reviewSent.isEmpty && within.index == 3)
reset(500_000_000)
let live = try transport(events); live.index = 1; live.tick()
precondition(ons() == [[0x90, 60, 100]])
reviewClock = 600_000_000; live.tick()
precondition(reviewSent == [[0x90,60,100], [0x80,60,0]])
let heldEvents: [[String: Any]] = [
    ["kind":"program", "seconds":0.0, "channel":0, "program":0],
    ["kind":"on", "seconds":0.0, "channel":0, "pitch":65, "velocity":100],
    ["kind":"off", "seconds":1.0, "channel":0, "pitch":65]
]
reset(1_000_000_000, cost: 100_000_000)
let drift = try transport(heldEvents); drift.index = 2; drift.held[65] = drift.timeline.events[1]; drift.tick()
precondition(drift.anchor == 1_000_000_000)
near(drift.position(), Double(reviewClock % 1_000_000_000) / 1e9)
reset(600_000_000)
let boundary = try transport(events); boundary.offset = 0.6; boundary.anchor = reviewClock
try boundary.restore(at: 0.6); boundary.tick()
precondition(ons().isEmpty && boundary.index == 3)
let adjacent: [[String: Any]] = [
    ["kind":"on", "seconds":0.0, "channel":0, "pitch":60, "velocity":100],
    ["kind":"off", "seconds":0.6, "channel":0, "pitch":60],
    ["kind":"on", "seconds":0.6, "channel":0, "pitch":60, "velocity":80],
    ["kind":"off", "seconds":1.0, "channel":0, "pitch":60]
]
reset(600_000_000)
let retrigger = try transport(adjacent); retrigger.offset = 0.6; retrigger.anchor = reviewClock
try retrigger.restore(at: 0.6); retrigger.tick()
precondition(ons() == [[0x90,60,80]])
reset(1_250_000_000)
let ended = try transport(events, loop: false); ended.index = 1; ended.tick()
precondition(ons().isEmpty && ended.state == .stopped && reviewExit == 0)
reset(2_250_000_000)
let paused = try transport(heldEvents); paused.index = 2; paused.held[65] = paused.timeline.events[1]
paused.receive("{\"kind\":\"pause\"}")
precondition(paused.state == .paused); near(paused.offset, 0.25)
reviewClock = 2_300_000_000; paused.receive("{\"kind\":\"resume\"}")
near(paused.position(), 0.25)
reset(1_250_000_000)
let status = try transport(events); status.index = 1; status.receive("{\"kind\":\"status\"}")
precondition(ons().isEmpty); near(status.snapshot("playing")["currentTime"] as! Double, 0.25)
// The OS may deliver a Note On and still return failure. The failed tick's
// finish must release it; pause/seek retry only the releases that failed.
reset(0)
let failedPhraseOn = try transport(heldEvents, loop: false)
reviewPhraseFailure = 0x90; failedPhraseOn.tick()
precondition(reviewSent == [[0xc0,0],[0x90,65,100],[0x80,65,0]])
precondition(failedPhraseOn.held.isEmpty && failedPhraseOn.state == .stopped && reviewExit == 1)
let twoHeldEvents = Array(heldEvents.prefix(2)) + [
    ["kind":"on", "seconds":0.0, "channel":0, "pitch":67, "velocity":90],
    ["kind":"off", "seconds":1.0, "channel":0, "pitch":65],
    ["kind":"off", "seconds":1.0, "channel":0, "pitch":67]
]
for command in ["{\"kind\":\"pause\"}", "{\"kind\":\"seek\",\"seconds\":0.5}"] {
    reset(0)
    let owner = try transport(twoHeldEvents, loop: false); owner.tick()
    precondition(owner.held.count == 2)
    reviewSent = []; reviewPhraseFailure = 0x80
    owner.receive(command)
    precondition(reviewSent == [[0x80,65,0],[0x80,67,0],[0x80,65,0]])
    precondition(owner.held.isEmpty && owner.state == .stopped && reviewExit == 1)
}
reset(0)
let releasedOwner = try transport(twoHeldEvents, loop: false); releasedOwner.tick()
reviewSent = []; releasedOwner.receive("{\"kind\":\"pause\"}")
precondition(reviewSent == [[0x80,65,0],[0x80,67,0]] && releasedOwner.held.isEmpty && releasedOwner.state == .paused)
print("PHRASE_FAILED_SEND_PASS: uncertain Note On cleanup and pause/seek failed release retry without repeating successful releases")
reset(0)
let pending = try transport(events); pending.destination = nil; pending.state = .prepared
pending.destinationChanged(); pending.start()
precondition(pending.state == .prepared && reviewExit == nil && reviewSent.isEmpty)
precondition(pending.snapshot("prepared")["device"] == nil)
pending.prepared = true; pending.destinationChanged()
precondition(pending.state == .stopped && reviewExit == 1)
// Full source wire decisions use the same native parser/scheduler/cleanup, with
// only OS send, endpoint lookup, deadline and exit effects replaced above.
func wire(_ events: [[String: Any]], duration: Double = 1, bindings: [[String: Any]] = [["port":0,"destination":"1"]]) throws -> MidiTransport {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    try JSONSerialization.data(withJSONObject: ["schemaVersion":2,"duration":duration,"bindings":bindings,"events":events]).write(to:path)
    defer { try? FileManager.default.removeItem(at:path) }
    let value = try MidiTransport(path:path.path,uid:bindings[0]["destination"] as! String,loop:false)
    value.destination = Destination(endpoint:0,uid:1,name:"synthetic")
    for binding in value.timeline.bindings {
        value.sourceDestinations[binding.port] = Destination(endpoint:0,uid:Int32(binding.destination)!,name:"synthetic source")
        value.wireStates[binding.port] = WireState()
    }
    value.state = .playing
    return value
}
var decoder = WireState()
let decoded1 = try decoder.feed([0xf0,0x7d,1,0xf8,2]); precondition(decoded1 == [[0xf0,0x7d,1],[0xf8],[2]])
let decoded2 = try decoder.feed([3,0xf7,0x90,60]); precondition(decoded2 == [[3,0xf7]])
let decoded3 = try decoder.feed([100,61,90,0xf8,62,0]); precondition(decoded3 == [[0x90,60,100],[0x90,61,90],[0xf8],[0x90,62,0]])
try decoder.complete()
let expression: [[String: Any]] = [
    ["seconds":0,"port":0,"bytes":[0xb0,64,127,0xb0,66,127,0xb0,69,127,0x90,60,100,60,90]],
    ["seconds":0.5,"port":0,"bytes":[0x80,60,77,0xe0,1,65,0xa0,60,80,0xd0,40]],
    ["seconds":1,"port":0,"bytes":[0x80,60,45]]
]
reset(500_000_000);reviewWire=[]
let stream = try wire(expression);stream.tick()
precondition(reviewWire.map(\.1) == [[0xb0,64,127],[0xb0,66,127],[0xb0,69,127],[0x90,60,100],[0x90,60,90],[0x80,60,77],[0xe0,1,65],[0xa0,60,80],[0xd0,40]])
try stream.silence()
precondition(Array(reviewWire.suffix(4)).map(\.1) == [[0x80,60,0],[0xb0,64,0],[0xb0,66,0],[0xb0,69,0]])
precondition(!reviewWire.contains { $0.1.count == 3 && $0.1[0] & 0xf0 == 0xb0 && [120,123].contains($0.1[1]) })
reset(0);reviewWire=[]
let zeroSource = try wire([["seconds":0,"port":0,"bytes":[0x90,60,100,0x80,60,77]]],duration:0)
zeroSource.tick()
precondition(reviewWire.map(\.1) == [[0x90,60,100],[0x80,60,77]] && reviewExit == 0)
reset(0);reviewWire=[]
let routed = try wire([["seconds":0,"port":2,"bytes":[0x90,60,100]], ["seconds":0,"port":7,"bytes":[0x91,64,90]]],bindings:[["port":2,"destination":"1"],["port":7,"destination":"2"]])
routed.tick();precondition(reviewWire.map(\.0) == [1,2]);try routed.silence()
precondition(Array(reviewWire.suffix(2)).map(\.0) == [1,2])
reset(0);reviewWire=[]
let failedExclusive = try wire([["seconds":0,"port":0,"bytes":[0xf0,0x7d,1,0xf7]]])
reviewWireFail=true;failedExclusive.tick()
precondition(reviewWire.map(\.1) == [[0xf0,0x7d,1,0xf7],[0xf7]] && reviewExit == 1)
// A release that fails may still have reached the device, but must not erase
// cleanup ownership. Successful releases must not add redundant cleanup offs.
func releaseDecision(_ setup: [UInt8], _ release: [UInt8], expected: [[UInt8]], fail: Bool = true) throws {
    reset(0); reviewWire = []; reviewWireFail = false
    let value = try wire([["seconds":0,"port":0,"bytes":setup], ["seconds":0.5,"port":0,"bytes":release]])
    value.tick()
    reviewClock = 500_000_000; reviewWire = []; reviewWireFail = fail
    value.tick()
    if fail { precondition(value.state == .stopped && reviewExit == 1) }
    else { try value.silence() }
    precondition(reviewWire.map(\.1) == expected, "unexpected release cleanup: \(reviewWire.map(\.1))")
}
for release: [UInt8] in [[0x80,60,77], [0x90,60,0]] {
    try releaseDecision([0x90,60,100], release, expected:[release,[0x80,60,0]])
    try releaseDecision([0x90,60,100], release, expected:[release], fail:false)
}
for pedal: UInt8 in [64,66,69] {
    let off: [UInt8] = [0xb0,pedal,0]
    try releaseDecision([0xb0,pedal,127], off, expected:[off,off])
    try releaseDecision([0xb0,pedal,127], off, expected:[off], fail:false)
}
let owned: [UInt8] = [0x90,60,100,0xb0,64,127]
try releaseDecision(owned, [0xff], expected:[[0xff],[0x80,60,0],[0xb0,64,0]])
try releaseDecision(owned, [0xff], expected:[[0xff]], fail:false)
try releaseDecision(owned, [0xb0,121,0], expected:[[0xb0,121,0],[0x80,60,0],[0xb0,64,0]])
try releaseDecision(owned, [0xb0,121,0], expected:[[0xb0,121,0],[0x80,60,0]], fail:false)
for mode: UInt8 in [120,123,124,125,126,127] {
    let release: [UInt8] = [0xb0,mode,0]
    try releaseDecision(owned, release, expected:[release,[0x80,60,0],[0xb0,64,0]])
    try releaseDecision(owned, release, expected:[release,[0xb0,64,0]], fail:false)
}
try releaseDecision([0x90,60,100,0x90,60,90], [0x80,60,77],
    expected:[[0x80,60,77],[0x80,60,0],[0x80,60,0]])
try releaseDecision([0x90,60,100,0x90,60,90], [0x80,60,77],
    expected:[[0x80,60,77],[0x80,60,0]], fail:false)
reset(0); reviewWire = []
let failedOn = try wire([["seconds":0,"port":0,"bytes":[0x90,60,100]]])
reviewWireFail = true; failedOn.tick()
precondition(reviewWire.map(\.1) == [[0x90,60,100],[0x80,60,0]] && reviewExit == 1)
reset(0); reviewWire = []
let failedPedalOn = try wire([["seconds":0,"port":0,"bytes":[0xb0,64,127]]])
reviewWireFail = true; failedPedalOn.tick()
precondition(reviewWire.map(\.1) == [[0xb0,64,127],[0xb0,64,0]] && reviewExit == 1)
// Cleanup keeps a failed release owned, so the next cleanup retries only that
// message. Each held count, pedal and open SysEx is released exactly once.
func cleanupDecision(_ setup: [UInt8], _ ending: [UInt8], expected: [[UInt8]], fail: Bool = true) throws {
    reset(0); reviewWire = []; reviewWireFail = false
    let value = try wire([["seconds":0,"port":0,"bytes":setup], ["seconds":1,"port":0,"bytes":ending]])
    value.tick()
    reviewWire = []; reviewWireFail = fail
    do { try value.silence(); precondition(!fail) } catch { precondition(fail) }
    if fail { try value.silence() }
    precondition(reviewWire.map(\.1) == expected, "unexpected cleanup: \(reviewWire.map(\.1))")
    reviewWire = []; try value.silence()
    precondition(reviewWire.isEmpty, "released ownership was retried: \(reviewWire.map(\.1))")
}
let pressed: [UInt8] = [0x90,60,100,0x90,60,90,0x90,62,100,0xb0,64,127]
let lifted: [UInt8] = [0x80,60,0,0x80,60,0,0x80,62,0,0xb0,64,0]
try cleanupDecision(pressed, lifted, expected:[[0x80,60,0],[0x80,60,0],[0x80,62,0],[0xb0,64,0],[0x80,60,0]])
try cleanupDecision(pressed, lifted, expected:[[0x80,60,0],[0x80,60,0],[0x80,62,0],[0xb0,64,0]], fail:false)
try cleanupDecision([0xb0,64,127,0xb0,66,127], [0xb0,64,0,0xb0,66,0], expected:[[0xb0,64,0],[0xb0,66,0],[0xb0,64,0]])
try cleanupDecision([0xf0,0x7d,1], [2,0xf7], expected:[[0xf7],[0xf7]])
try cleanupDecision([0xf0,0x7d,1], [2,0xf7], expected:[[0xf7]], fail:false)
print("SOURCE_CLEANUP_RETRY_PASS: failed note/pedal/SysEx terminator cleanup stays owned and is retried once; successful releases are not repeated")
reset(0); reviewWire = []
let expressiveState: [[String: Any]] = [
    ["seconds":0,"port":0,"bytes":[0xb0,0,4,0xb0,32,2,0xc0,33,0xb0,101,0,0xb0,100,0,0xb0,6,12,0xb0,38,0,0xb0,1,80,0xe0,1,65,0xd0,40,0x90,60,100]],
    ["seconds":0.1,"port":0,"bytes":[0xb0,66,100]],
    ["seconds":0.2,"port":0,"bytes":[0x90,64,90,0xb0,64,90,0x80,60,77,0x80,64,45,0xa0,60,70]],
    ["seconds":0.8,"port":0,"bytes":[0xb0,64,0,0xb0,66,0]]
]
let chase = try wire(expressiveState)
chase.tick(); reviewClock = 300_000_000; chase.tick()
chase.receive("{\"kind\":\"pause\"}")
precondition(chase.state == .paused)
reviewWire = []
chase.receive("{\"kind\":\"resume\"}")
precondition(chase.state == .playing && reviewExit == nil)
let restored = reviewWire.map(\.1)
let prefix: [[UInt8]] = [[0xb0,0,4],[0xb0,32,2],[0xc0,33],[0xb0,101,0],[0xb0,100,0],[0xb0,6,12],[0xb0,38,0],[0xb0,1,80],[0xe0,1,65]]
precondition(Array(restored.prefix(prefix.count)) == prefix)
precondition(Array(restored.suffix(8)) == [[0x90,60,100],[0xb0,66,100],[0xb0,64,90],[0x90,64,90],[0x80,60,77],[0x80,64,45],[0xd0,40],[0xa0,60,70]])
chase.receive("{\"kind\":\"pause\"}"); reviewWire = []
chase.receive("{\"kind\":\"seek\",\"seconds\":0.25}")
precondition(chase.state == .paused && reviewWire.isEmpty)
chase.receive("{\"kind\":\"resume\"}")
precondition(chase.state == .playing && reviewWire.map(\.1) == restored)
// A held note keeps the patch of its attack. Exercise actual pause/resume, not
// only the model's refusal predicate: nothing may be replayed before the error.
let changedPrograms: [[[UInt8]]] = [
    [[0xc0,1],[0x90,60,100],[0xc0,2]],
    [[0x90,60,100],[0xc0,1]],
    [[0xb0,0,4],[0xc0,1],[0x90,60,100],[0xb0,0,5],[0xc0,1],[0xb0,0,4]],
    [[0xc0,1],[0xb0,64,127],[0x90,60,100],[0x80,60,42],[0xc0,2]],
    [[0xc0,1],[0x90,60,100],[0xb0,66,127],[0x80,60,42],[0xc0,2]]
]
for messages in changedPrograms {
    reset(0); reviewWire = []
    let owner = try wire([["seconds":0,"port":0,"bytes":messages.flatMap { $0 }]])
    owner.tick(); reviewClock = 300_000_000
    owner.receive("{\"kind\":\"pause\"}"); precondition(owner.state == .paused)
    reviewWire = []; owner.receive("{\"kind\":\"resume\"}")
    precondition(owner.state == .stopped && reviewExit == 1 && reviewWire.isEmpty)
}
for messages: [[UInt8]] in [
    [[0xc0,1],[0x90,60,100],[0xc0,2],[0xc0,1]],
    [[0xc0,1],[0x90,60,100],[0xb0,0,5]],
    [[0xc0,1],[0x90,60,100],[0xc1,2]],
    [[0xc0,1],[0x90,60,100],[0xc0,2],[0x80,60,42]],
    [[0xc0,1],[0xb0,64,127],[0x90,60,100],[0x80,60,42],[0xc0,2],[0xb0,64,0]]
] {
    var model = SourceChase()
    for bytes in messages { model.observe(bytes, port: 0) }
    _ = try model.bootstrap(replacing: model)
}
reset(0); reviewWire = []
let sameProgram = try wire([["seconds":0,"port":0,"bytes":[0xc0,1,0x90,60,100,0xc0,2,0xc0,1]]])
sameProgram.tick(); reviewClock = 300_000_000
sameProgram.receive("{\"kind\":\"pause\"}"); reviewWire = []
sameProgram.receive("{\"kind\":\"resume\"}")
precondition(sameProgram.state == .playing && reviewWire.map(\.1) == [[0xc0,1],[0xc0,2],[0xc0,1],[0x90,60,100]])
print("SOURCE_PROGRAM_RECONSTRUCTION_PASS: explicit refusal before replay for unknown/changed patches and pedal-held notes; bank latches, restored patches and released notes retained")
var parameter = SourceChase()
for bytes: [UInt8] in [[0xb0,101,0],[0xb0,100,0],[0xb0,6,12],[0xb0,38,0],[0xb0,96,0],[0xb0,97,0]] { parameter.observe(bytes, port: 0) }
let parameters = try parameter.bootstrap(replacing: parameter)
precondition(parameters.map(\.1) == parameter.history.map(\.1))
var unknown = SourceChase(); unknown.observe([0xb0,101,0],port:0);unknown.observe([0xb0,100,0],port:0);unknown.observe([0xb0,96,0],port:0)
do { _ = try unknown.bootstrap(replacing: unknown);preconditionFailure("relative value guessed") } catch {}
reset(0); reviewWire = []
let missingBaseline = try wire([["seconds":0,"port":0,"bytes":[0x90,60,100]],["seconds":0.2,"port":0,"bytes":[0xb0,7,80]]])
missingBaseline.tick();reviewClock=300_000_000;missingBaseline.tick()
missingBaseline.receive("{\"kind\":\"seek\",\"seconds\":0}")
precondition(missingBaseline.state == .stopped && reviewExit == 1)
precondition(reviewWire.last!.1 == [0x80,60,0])
for opaque: [UInt8] in [[0xf0,0x7d,1,0xf7],[0xb0,99,1,0xb0,98,2,0xb0,6,3],[0xb0,69,127],[0xb0,88,42],[0xb0,126,1]] {
    reset(0);reviewWire=[]
    let value=try wire([["seconds":0,"port":0,"bytes":opaque]])
    value.tick();precondition(value.state == .playing)
    value.receive("{\"kind\":\"pause\"}");value.receive("{\"kind\":\"resume\"}")
    precondition(value.state == .stopped && reviewExit == 1)
}
reset(0);reviewWire=[]
let split=try wire([["seconds":0,"port":0,"bytes":[0x90,60]],["seconds":0.5,"port":0,"bytes":[100]]])
split.tick();split.receive("{\"kind\":\"pause\"}");split.receive("{\"kind\":\"resume\"}")
reviewClock=600_000_000;split.tick()
precondition(reviewWire.map(\.1) == [[0x90,60,100]])
reset(0);reviewWire=[]
let pauseDue=try wire([["seconds":0.2,"port":0,"bytes":[0x90,72,80,0x80,72,56]]])
reviewClock=300_000_000;pauseDue.receive("{\"kind\":\"pause\"}")
precondition(reviewWire.map(\.1) == [[0x90,72,80],[0x80,72,56]])
reset(1_000_000_000);reviewWire=[]
let endpointPause=try wire([["seconds":1,"port":0,"bytes":[0x90,72,80,0x80,72,56]]])
endpointPause.receive("{\"kind\":\"pause\"}")
precondition(endpointPause.state == .stopped && reviewExit == 0)


var resetPressure = SourceChase()
for bytes: [UInt8] in [[0x90,60,100],[0xa0,60,100],[0xb0,121,0]] { resetPressure.observe(bytes,port:0) }
let resetMessages = try resetPressure.bootstrap(replacing:resetPressure).map(\.1)
precondition(!resetMessages.contains([0xa0,60,100]))
var laterPressure = resetPressure;laterPressure.observe([0xe0,1,70],port:0);laterPressure.observe([0xa0,61,99],port:0)
_ = try resetPressure.bootstrap(replacing:laterPressure)
var mixedPedals = SourceChase()
for bytes: [UInt8] in [[0xb0,64,0],[0xb0,66,0],[0xb0,64,127],[0x90,60,100],[0x80,60,42],[0xb0,66,127],[0xb0,64,0]] { mixedPedals.observe(bytes,port:0) }
let mixedMessages = try mixedPedals.bootstrap(replacing:mixedPedals).map(\.1)
precondition(!mixedMessages.contains { $0[0] & 0xf0 == 0x90 })
for release: [UInt8] in [[0x90,60,0],[0x80,60,0],[0x80,60,77]] {
    var value = SourceChase()
    for bytes: [UInt8] in [[0xb0,64,127],[0x90,60,100],release,[0xb0,123,0]] { value.observe(bytes,port:0) }
    let result = try value.bootstrap(replacing:value).map(\.1)
    precondition(result.last == release)
}
var coarseParameter = SourceChase()
for bytes: [UInt8] in [[0xb0,101,0],[0xb0,100,0],[0xb0,6,12]] { coarseParameter.observe(bytes,port:0) }
_ = try coarseParameter.bootstrap(replacing:coarseParameter)
var laterFine = coarseParameter;laterFine.observe([0xb0,38,1],port:0)
do { _ = try coarseParameter.bootstrap(replacing:laterFine);preconditionFailure("unknown fine parameter restored") } catch {}
// A cut entry replays with notes:false, but the pedal position is physical
// state and must be re-established anyway, after the events it replaces.
var cutPedals = SourceChase()
for bytes: [UInt8] in [[0xb0,64,127],[0x90,60,100],[0xb0,66,127],[0xd0,77]] { cutPedals.observe(bytes,port:0) }
let cutMessages = try cutPedals.bootstrap(replacing:cutPedals,notes:false).map(\.1)
precondition(Array(cutMessages.suffix(3)) == [[0xb0,66,127],[0xb0,64,127],[0xd0,77]],"cut entry did not re-establish the pedal and pressure state")
precondition(!cutMessages.contains { $0[0] & 0xf0 == 0x90 },"cut entry replayed note events")
print("SOURCE_CHASE_DECISIONS_PASS: ordered expression, pedal membership, release wire forms, reset coverage, parameter components, paused seek, decoder continuation, due and endpoint pause")

// Exercise production UID lookup, object-type/name validation and the complete
// selected-reference check against synthetic CoreMIDI property boundaries.
func mustReject(_ operation: () throws -> Void) {
    do { try operation(); preconditionFailure("selected destination failure was ignored") }
    catch {}
}
reviewObjects = [10: ReviewDestination(uid: 1), 20: ReviewDestination(uid: 2)]
reviewPropertyReads = []
let selected = try selectedDestination(uid: "1")
precondition(selected.endpoint == 10 && selected.uid == 1)
let pinned = try wire([["seconds":0,"port":2,"bytes":[0xf8]],["seconds":0,"port":7,"bytes":[0xf8]]],
    bindings:[["port":2,"destination":"1"],["port":7,"destination":"2"]])
pinned.destination = selected
pinned.sourceDestinations = [2:selected, 7:try selectedDestination(uid:"2")]
// Unselected objects can appear and disappear without affecting either binding.
reviewObjects[99] = ReviewDestination(uid:99)
try pinned.reviewCheckDestination()
reviewObjects.removeValue(forKey:99)
try pinned.reviewCheckDestination()
precondition(Set(reviewPropertyReads) == [10,20])
reviewObjects[10]?.offline = nil; try pinned.reviewCheckDestination()
reviewObjects[10]?.offline = 1; mustReject { try pinned.reviewCheckDestination() }
reviewObjects[10]?.offline = 0
reviewObjects.removeValue(forKey:20); mustReject { try pinned.reviewCheckDestination() }
reviewObjects[20] = ReviewDestination(uid:3); mustReject { try pinned.reviewCheckDestination() }
mustReject { _ = try selectedDestination(uid:"2") }
reviewObjects[20] = ReviewDestination(uid:2,type:.source)
mustReject { _ = try selectedDestination(uid:"2") }
reviewObjects[20] = ReviewDestination(uid:2)
reviewFound = 20; mustReject { _ = try selectedDestination(uid:"1") }; reviewFound = nil
mustReject { _ = try selectedDestination(uid:"01") }
func arrangement(_ sources: [[String: Any]], _ regions: [[String: Any]], duration: Double = 3) throws -> MidiTransport {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    try JSONSerialization.data(withJSONObject: ["schemaVersion":3,"duration":duration,"sources":sources,"regions":regions]).write(to:path)
    defer { try? FileManager.default.removeItem(at:path) }
    let value = try MidiTransport(path:path.path,uid:"1",loop:false)
    for binding in value.timeline.bindings { value.sourceDestinations[binding.port] = Destination(endpoint:0,uid:Int32(binding.destination)!,name:"synthetic region") }
    value.destination = value.sourceDestinations[0]; value.state = .playing
    return value
}
func asset(_ id: String, _ events: [[String: Any]], destination: String = "1") -> [String: Any] {
    ["id":id,"timeline":["schemaVersion":2,"duration":1.0,"bindings":[["port":2,"destination":destination]],"events":events]]
}
// Plans carry exact region starts and periods. Unless a test names the exact
// fraction, it is the whole nanosecond nearest its binary64 value, and
// startSeconds is the native display of that exact start.
func nanoseconds(_ seconds: Double) -> (String, String) { (String(UInt64((seconds * 1e9).rounded())), "1") }
func display(_ value: (String, String)) -> Double {
    let n = UInt128(value.0)!, d = UInt128(value.1)! * 1_000_000_000
    return Double(n / d) + Double(n % d) / Double(d)
}
func clip(_ id: String, _ source: String, start: Double = 0, from: Double = 0.1, to: Double = 0.6, repeatCount: Int = 2,
          startNanoseconds: (String, String)? = nil, periodNanoseconds: (String, String)? = nil) -> [String: Any] {
    let exactStart = startNanoseconds ?? nanoseconds(start), period = periodNanoseconds ?? nanoseconds(to - from)
    return ["id":id,"source":source,"startSeconds":display(exactStart),"sourceStart":from,"sourceEnd":to,"repeatCount":repeatCount,
            "startNanoseconds":["numerator":exactStart.0,"denominator":exactStart.1],"periodNanoseconds":["numerator":period.0,"denominator":period.1]]
}
let regionSource = asset("a", [
    ["seconds":0,"port":2,"bytes":[0xc0,33,0xb0,64,0,0xb0,66,0,0xb0,1,0]],
    ["seconds":0.05,"port":2,"bytes":[0x90,60,100]],
    ["seconds":0.1,"port":2,"bytes":[0x90,64,90,0x80,64,77]],
    ["seconds":0.2,"port":2,"bytes":[0xb0,1,70]],
    ["seconds":0.4,"port":2,"bytes":[0x80,60,45]],
    ["seconds":1,"port":2,"bytes":[0x90,70,88,0x80,70,99]]])
reset(0);reviewWire=[]
let arranged = try arrangement([regionSource],[clip("r","a")]); try arranged.reconcile(at:0)
precondition(reviewWire.map(\.1).contains([0x90,60,100]))
precondition(Array(reviewWire.suffix(2)).map(\.1) == [[0x90,64,90],[0x80,64,77]])
reviewWire=[];try arranged.reconcile(at:0.5)
precondition(reviewWire.map(\.1).contains([0x80,60,45]))
precondition(Array(reviewWire.suffix(2)).map(\.1) == [[0x90,64,90],[0x80,64,77]])
precondition(arranged.regionCursors[0].copy==1 && arranged.regionCursors[0].active)
try arranged.reconcile(at:1);precondition(arranged.regionCursors[0].copy==2)
// A trimmed endpoint is exclusive; original full-source endpoint messages survive.
reset(0);reviewWire=[]
let whole = try arrangement([regionSource],[clip("whole","a",from:0,to:1,repeatCount:1)])
try whole.reconcile(at:0);try whole.reconcile(at:1)
precondition(reviewWire.map(\.1).contains([0x90,70,88]) && reviewWire.map(\.1).contains([0x80,70,99]))
let exclusive = try arrangement([regionSource],[clip("trim","a",from:0.05,to:0.4,repeatCount:1)])
reviewWire=[];try exclusive.reconcile(at:0);try exclusive.reconcile(at:1)
precondition(!reviewWire.map(\.1).contains([0x80,60,45]) && reviewWire.map(\.1).contains([0x80,60,0]))
// Same physical channel cannot overlap, including two assets/ports.
mustReject { _ = try arrangement([regionSource],[clip("x","a"),clip("y","a",start:0.2)]) }
let otherSame = asset("b",[["seconds":0,"port":2,"bytes":[0xc0,2,0x90,67,90]]])
mustReject { _ = try arrangement([regionSource,otherSame],[clip("x","a"),clip("y","b",start:0.2)]) }
let distinct = asset("b",[["seconds":0,"port":2,"bytes":[0xc1,2,0x91,67,90]]])
let together = try arrangement([regionSource,distinct],[clip("x","a"),clip("y","b",start:0.2,repeatCount:1)])
try together.reconcile(at:0.2);reviewWire=[];try together.reconcile(at:0.7)
precondition(!reviewWire.map(\.1).contains([0x80,60,0])) // first owner's live repeat survives second owner cleanup
precondition(reviewWire.map(\.1).contains([0x81,67,0]))
// Adjacent owners must establish every previously mutated field.
mustReject { _ = try arrangement([regionSource,otherSame],[clip("x","a",repeatCount:1),clip("y","b",start:0.5,repeatCount:1)]) }
let regionMissingBaseline = asset("u",[["seconds":0,"port":2,"bytes":[0x90,60,100]],["seconds":0.5,"port":2,"bytes":[0xb0,1,80]]])
mustReject { _ = try arrangement([regionMissingBaseline],[clip("u","u",from:0.1,to:0.7)]) }
// Seeking through millions of copies uses arithmetic and one cursor.
let huge = try arrangement([regionSource],[clip("huge","a",repeatCount:2_000_000)],duration:1_000_000)
reviewWire=[];try huge.reconcile(at:999_999.75,reconstruct:true)
precondition(huge.regionCursors.count==1 && huge.regionCursors[0].copy==1_999_999 && reviewWire.count<30)
reset(250_000_000);let pausedRegion = try arrangement([regionSource],[clip("p","a")]);try pausedRegion.reconcile(at:0.25)
pausedRegion.receive("{\"kind\":\"pause\"}");reviewWire=[]
pausedRegion.receive("{\"kind\":\"seek\",\"seconds\":0.75}")
precondition(reviewWire.isEmpty);pausedRegion.receive("{\"kind\":\"resume\"}")
precondition(reviewExit == nil && reviewWire.map(\.1).contains([0x90,60,100]))
let initialBoundary = asset("initial",[["seconds":0,"port":2,"bytes":[0x90,60,100,0xc0,20]]])
mustReject { _ = try arrangement([asset("prior",[["seconds":0,"port":2,"bytes":[0xc0,10]]]),initialBoundary], [clip("prior","prior",from:0,to:1,repeatCount:1),clip("initial","initial",start:1,from:0,to:1,repeatCount:1)]) }
let lateCopies = try arrangement([regionSource],[clip("late","a")])
reviewWire=[];try lateCopies.reconcile(at:2)
precondition(reviewWire.isEmpty && lateCopies.regionCursors[0].copy==2)
let livePhase = try arrangement([regionSource],[clip("live","a",repeatCount:2_000_000)],duration:1_000_000)
reviewWire=[];try livePhase.reconcile(at:999_999.75)
precondition(livePhase.regionCursors[0].copy==1_999_999 && reviewWire.count<30)
// A late first common-epoch tick skips never-started expired copies. It
// must preserve the boundary stream for other region copies still alive.
func sharedClock(_ template: MidiTransport, at offset: Double = 0) throws -> MidiTransport {
    reset(0); reviewWire=[]
    let t=try MidiTransport(timeline:template.timeline,uid:"1",coordinated:true)
    t.prepared=true;t.sourceDestinations=template.sourceDestinations
    t.destination=template.sourceDestinations.values.first
    try t.stageCoordinated(at:offset);try t.runCoordinated(anchorNanoseconds:1_000_000_000)
    return t
}
let heldSource=asset("held",[["seconds":0,"port":2,"bytes":[0x90,60,100]],["seconds":0.8,"port":2,"bytes":[0x80,60,42]]])
let heldTemplate=try arrangement([heldSource],[clip("held","held",from:0,to:1,repeatCount:3)])
let expiredInitial=try sharedClock(heldTemplate)
reviewClock=5_000_000_000;expiredInitial.tick()
precondition(reviewWire.isEmpty && expiredInitial.state == .paused && !expiredInitial.pendingRestore)
let liveInitial=try sharedClock(heldTemplate)
reviewClock=2_250_000_000;liveInitial.tick()
precondition(reviewWire.map(\.1)==[[0x90,60,100]])
let exactInitial=try sharedClock(heldTemplate)
reviewClock=2_000_000_000;exactInitial.tick()
precondition(reviewWire.map(\.1)==[[0x90,60,100]])
let longer:[String:Any]=["id":"long","timeline":["schemaVersion":2,"duration":2,"bindings":[["port":2,"destination":"1"]],"events":[
    ["seconds":0,"port":2,"bytes":[0xc1,1]],
    ["seconds":0.5,"port":2,"bytes":[0x91,62,100]],
    ["seconds":0.5,"port":2,"bytes":[0x81,62,42]],
    ["seconds":0.5,"port":2,"bytes":[0xc1,20]]]]]
let shortSource=asset("short",[["seconds":0.4,"port":2,"bytes":[0x90,60,100]],["seconds":0.8,"port":2,"bytes":[0x80,60,42]]])
let partialTemplate=try arrangement([shortSource,longer],[clip("short","short",from:0,to:1,repeatCount:3),clip("long","long",from:0,to:2,repeatCount:1)])
let partialInitial=try sharedClock(partialTemplate,at:0.5)
reviewClock=1_800_000_000;partialInitial.tick()
precondition(reviewWire.map(\.1)==[[0xc1,1],[0x91,62,100],[0x81,62,42],[0xc1,20]])
let coordinatedBase = try arrangement([regionSource],[clip("clock","a",repeatCount:1)])
let shared = try MidiTransport(timeline:coordinatedBase.timeline,uid:"1",coordinated:true)
shared.destination=coordinatedBase.destination;shared.sourceDestinations=coordinatedBase.sourceDestinations;shared.prepared=true
reset(1_000_000_000);reviewWire=[]
try shared.stageCoordinated(at:0.2);precondition(reviewWire.isEmpty && shared.state == .paused)
mustReject { try shared.runCoordinated(anchorNanoseconds:1_000_000_000) }
precondition(reviewWire.isEmpty)
try shared.runCoordinated(anchorNanoseconds:2_000_000_000)
precondition(reviewWire.isEmpty && shared.pendingRestore && shared.position()==0.2)
shared.tick();precondition(reviewWire.isEmpty && shared.pendingRestore)
reviewClock=2_000_000_000;shared.tick();precondition(!reviewWire.isEmpty && !shared.pendingRestore)
try shared.stageCoordinated(at:0.25);precondition(shared.state == .paused && shared.offset==0.25)
var sharedEnded=0;shared.onCoordinatedEnd={sharedEnded+=1}
try shared.runCoordinated(anchorNanoseconds:3_000_000_000)
reviewClock=6_000_000_000;shared.tick()
precondition(sharedEnded==1 && shared.state == .paused && shared.prepared)
var sharedFinished=0;shared.onCoordinatedFailure={_,_ in sharedFinished+=1}
shared.finish(reason:"stop",publish:false);precondition(sharedFinished==1 && shared.state == .stopped && reviewExit==nil)
shared.finish(reason:"stop",publish:false);precondition(sharedFinished==1)
print("COORDINATED_MIDI_DECISIONS_PASS: staged silence, late-epoch refusal, common-epoch restoration, no early sends, shared pause position, logical end and owned shutdown callback")
// Exact copy edges. JS writes A = 100 BPM source ticks 1920..3840, whose
// binary64 keys are 2.3999999999999995..4.800000000000001, and its duplicate
// B at beat 4. Both edges are exactly 2.4e9 ns: B owns the channel from A's end.
let adjacentSource = ["id":"adjacent","timeline":["schemaVersion":2,"duration":5.0,"bindings":[["port":2,"destination":"1"]],"events":[
    ["seconds":2.3999999999999995,"port":2,"bytes":[0x90,60,100]],["seconds":3.0,"port":2,"bytes":[0x80,60,0]],
    ["seconds":4.5,"port":2,"bytes":[0x90,62,90]],["seconds":4.9,"port":2,"bytes":[0x80,62,0]]]]] as [String: Any]
let adjacentOwners = try arrangement([adjacentSource],[
    clip("A","adjacent",from:2.3999999999999995,to:4.800000000000001,repeatCount:1,periodNanoseconds:("2400000000","1")),
    clip("B","adjacent",start:2.4,from:2.3999999999999995,to:4.800000000000001,repeatCount:1,periodNanoseconds:("2400000000","1"))],duration:4.8)
precondition(adjacentOwners.timeline.regions[0].end == adjacentOwners.timeline.regions[1].start, "adjacent exact edges differ")
reset(0);reviewWire=[];try adjacentOwners.reconcile(at:2.3);reviewWire=[];try adjacentOwners.reconcile(at:2.4)
precondition(reviewWire.map(\.1) == [[0x80,62,0],[0x90,60,100]], "adjacent hand-over order")
// The last copy ends on the validated edge: 6.4 + 2 * 3.2 s at 75 BPM. B's
// attack at that edge survives A's cleanup.
func longAsset(_ id: String, _ events: [[String: Any]]) -> [String: Any] {
    ["id":id,"timeline":["schemaVersion":2,"duration":7.0,"bindings":[["port":2,"destination":"1"]],"events":events]]
}
let lastCopy = longAsset("lastCopy",[["seconds":0,"port":2,"bytes":[0x90,60,100]],["seconds":0.1,"port":2,"bytes":[0x80,60,0]],
    ["seconds":3.0000000000000004,"port":2,"bytes":[0x90,64,90]],["seconds":3.3,"port":2,"bytes":[0x80,64,0]]])
let handover = try arrangement([lastCopy],[
    clip("A","lastCopy",start:6.4,from:0,to:3.2000000000000006,repeatCount:2,periodNanoseconds:("3200000000","1")),
    clip("B","lastCopy",start:12.8,from:0,to:3.2000000000000006,repeatCount:1,periodNanoseconds:("3200000000","1"))],duration:16.1)
precondition(handover.timeline.regions[0].end == 12.8)
reset(0);reviewWire=[];try handover.reconcile(at:12.7);reviewWire=[];try handover.reconcile(at:12.8);try handover.reconcile(at:12.81)
precondition(reviewWire.map(\.1) == [[0x80,64,0],[0x90,60,100]] && handover.sourceModel.channels[0]?.notes.map(\.pitch) == [60], "last copy cut the next owner")
// An attack inside the last copy whose binary64 time lands on the closing edge
// is sent and released before the next owner begins at that instant.
let edgeEvents = longAsset("edgeAttack",[["seconds":0,"port":2,"bytes":[0x90,60,100]],["seconds":0.1,"port":2,"bytes":[0x80,60,0]],
    ["seconds":3.2,"port":2,"bytes":[0x90,64,90]]])
let edgeAttack = try arrangement([edgeEvents],[
    clip("A","edgeAttack",start:6.4,from:0,to:3.2000000000000006,repeatCount:2,periodNanoseconds:("3200000000","1")),
    clip("B","edgeAttack",start:12.8,from:0,to:3.2000000000000006,repeatCount:1,periodNanoseconds:("3200000000","1"))],duration:16.1)
reset(0);reviewWire=[];try edgeAttack.reconcile(at:12.7);reviewWire=[];try edgeAttack.reconcile(at:12.8);try edgeAttack.reconcile(at:12.81)
precondition(reviewWire.map(\.1) == [[0x90,64,90],[0x80,64,0],[0x90,60,100]] && edgeAttack.sourceModel.channels[0]?.notes.map(\.pitch) == [60], "edge attack ordered after the next owner")
// Seeking exactly onto a copy edge starts that copy; the previous copy's end
// (note 62 from source 0.3) is not re-attacked.
let tailSource = asset("tail",[["seconds":0,"port":2,"bytes":[0x90,60,100]],["seconds":0.3,"port":2,"bytes":[0x90,62,90]],["seconds":0.9,"port":2,"bytes":[0x80,62,0,0x80,60,0]]])
let seekEdge = try arrangement([tailSource],[clip("tail","tail",start:0.3,from:0,to:0.4,repeatCount:2)],duration:1.1)
reset(0);reviewWire=[];try seekEdge.reconcile(at:0.7,reconstruct:true)
precondition(seekEdge.regionCursors[0].copy == 1 && reviewWire.map(\.1) == [[0x90,60,100]], "seek onto a copy edge re-attacked the previous copy")
// A fractional tempo start and 256-bit copy products keep exact edges for two
// million copies; copy(at:) agrees with those edges.
for (name, start, period, expected) in [("fractional", ("${fractionalStart.numerator}","${fractionalStart.denominator}"), ("${fractionalPeriod.numerator}","${fractionalPeriod.denominator}"), [${fractionalEdges.join(',')}]),
                                        ("wide", ("${wideStart.numerator}","${wideStart.denominator}"), ("${widePeriod.numerator}","${widePeriod.denominator}"), [${wideEdges.join(',')}])] {
    let edges = try arrangement([regionSource],[clip(name,"a",from:0.1,to:0.1005,repeatCount:${copies},startNanoseconds:start,periodNanoseconds:period)],duration:expected[2])
    let region = edges.timeline.regions[0]
    precondition(region.start == expected[0] && region.boundary(${probeCopy}) == expected[1] && region.end == expected[2], "\(name) exact edges")
    precondition(region.copy(at:expected[1]) == ${probeCopy} && region.copy(at:expected[1].nextDown) == ${probeCopy - 1} && region.copy(at:expected[2]) == ${copies - 1})
}
// Edges past the 64-bit host clock, sub-nanosecond copies, a display that names
// another start and plans without the exact fields are refused.
func refusal(_ regions: [[String: Any]]) -> String {
    do { _ = try arrangement([regionSource],regions,duration:1); preconditionFailure("invalid exact region admitted") }
    catch { return String(describing: error) }
}
precondition(refusal([clip("overflow","a",repeatCount:3,periodNanoseconds:("9223372036854775807","1"))]) == "MIDI region exceeds the native nanosecond timeline")
precondition(refusal([clip("short","a",periodNanoseconds:("1","2"))]) == "MIDI region copies must last at least one nanosecond")
var misdisplayed = clip("display","a"); misdisplayed["startSeconds"] = 1e-10
precondition(refusal([misdisplayed]) == "exact start disagrees with its display seconds")
var missing = clip("missing","a"); missing.removeValue(forKey:"periodNanoseconds"); mustReject { _ = try arrangement([regionSource],[missing]) }
print("MIDI_REGION_EDGE_PASS: exact adjacent hand-over, last-copy edge, closing-edge attack order, seek onto a copy edge, fractional and 256-bit edges, host-clock/sub-nanosecond/display/missing-field refusals")
print("MIDI_ARRANGEMENT_DECISIONS_PASS: original boundary events, trims/full endpoints, finite repeats, overlapping physical ownership admission, distinct-channel cleanup, prior-state baselines, compressed seek, silent paused seek/resume")

func loopArrangement(_ source: [String: Any]) throws -> MidiTransport {
    let template = try arrangement([source],[clip("loop",source["id"] as! String,from:0,to:1,repeatCount:1)],duration:1)
    let value = try MidiTransport(timeline:template.timeline,uid:"1",loop:true)
    value.destination=template.destination;value.sourceDestinations=template.sourceDestinations;value.state = .playing
    return value
}
let loopEvents = asset("loop-events",[
    ["seconds":0,"port":2,"bytes":[0xb0,1,0]],
    ["seconds":0.1,"port":2,"bytes":[0x90,60,100]],
    ["seconds":0.2,"port":2,"bytes":[0x80,60,77]],
    ["seconds":1,"port":2,"bytes":[0x90,70,88,0x80,70,99]]])
reset(0);reviewWire=[]
let missedLoop=try loopArrangement(loopEvents);missedLoop.tick()
reviewWire=[];reviewClock=1_250_000_000;missedLoop.tick()
precondition(!reviewWire.contains { $0.1[0] & 0xf0 == 0x90 })
precondition(!reviewWire.contains { $0.1[0] & 0xf0 == 0x80 })
near(missedLoop.offset,0.25)
// Exactly due full-source endpoint pairs survive, including on a loop.
reset(0);reviewWire=[]
let onTimeLoop=try loopArrangement(loopEvents);onTimeLoop.tick()
reviewWire=[];reviewClock=1_000_000_000;onTimeLoop.tick()
precondition(reviewWire.map(\.1).contains([0x90,70,88]) && reviewWire.map(\.1).contains([0x80,70,99]))
// All acquired keys precede missed attacks of that pitch in the source FIFO.
let fifoEvents=asset("fifo",[
    ["seconds":0,"port":2,"bytes":[0xb0,64,0,0x90,60,100]],
    ["seconds":0.1,"port":2,"bytes":[0xb0,64,127,0x90,60,90]],
    ["seconds":0.2,"port":2,"bytes":[0x80,60,77]],
    ["seconds":0.3,"port":2,"bytes":[0x80,60,45]],
    ["seconds":0.4,"port":2,"bytes":[0xb0,64,0]]])
reset(0);reviewWire=[]
let fifoLoop=try loopArrangement(fifoEvents);fifoLoop.tick()
reviewWire=[];try fifoLoop.reconcile(at:1,observedAt:1.25)
precondition(reviewWire.map(\.1) == [[0xb0,64,127],[0x80,60,77],[0xb0,64,0]])
let failureEvents=asset("failure",[
    ["seconds":0,"port":2,"bytes":[0x90,60,100]],
    ["seconds":0.2,"port":2,"bytes":[0x80,60,77]]])
reset(0);reviewWire=[]
let failingLoop=try loopArrangement(failureEvents);failingLoop.tick()
reviewWire=[];reviewWireFail=true
mustReject { try failingLoop.reconcile(at:1,observedAt:1.25) }
precondition(failingLoop.sourceHeld[0]?[60] == 1)
try failingLoop.silence()
precondition(failingLoop.sourceHeld[0]?[60] == 0 && reviewWire.map(\.1) == [[0x80,60,77],[0x80,60,0]])
print("MIDI_LOOP_DECISIONS_PASS: late wrap skips expired unacquired attacks, exact endpoints survive, FIFO releases retain velocity, pedals and uncertain release cleanup remain owned")

// Shared audio/MIDI cycles retain original project/source regions, and their
// fractional host deadlines derive from the original epoch even after a stall.
let commonSource=asset("common",[
    ["seconds":0,"port":2,"bytes":[0xc0,0]],
    ["seconds":0.05,"port":2,"bytes":[0x90,60,100]],
    ["seconds":0.1,"port":2,"bytes":[0x80,60,71]],
    ["seconds":0.3,"port":2,"bytes":[0x90,62,90]],
    ["seconds":0.35,"port":2,"bytes":[0x80,62,73]],
    ["seconds":0.6,"port":2,"bytes":[0x90,65,110]],
    ["seconds":0.8,"port":2,"bytes":[0x80,65,74]]])
let commonBase=try arrangement([commonSource],[clip("common","common",from:0,to:1,repeatCount:1)],duration:1)
let commonClock=try MidiCycle(start:0.2,end:0.6,duration:0.4,period:400_000_000,divisor:1)
reset(0);reviewWire=[]
let common=try MidiTransport(timeline:commonBase.timeline,uid:"1",loop:true,coordinated:true,cycle:commonClock)
common.prepared=true;common.destination=commonBase.destination;common.sourceDestinations=commonBase.sourceDestinations
try common.stageCoordinated(at:0);try common.runCoordinated(anchorNanoseconds:1_000_000_000)
reviewClock=1_000_000_000;common.tick()
precondition(!reviewWire.map(\.1).contains { $0[0]&0xf0==0x90 })
reviewClock=1_100_000_000;common.tick();precondition(reviewWire.map(\.1).contains([0x90,62,90]))
reviewClock=1_150_000_000;common.tick();precondition(reviewWire.map(\.1).contains([0x80,62,73]))
reviewWire=[];reviewClock=1_400_000_000;common.tick()
precondition(common.cycleIndex==1 && common.state == .playing && common.anchor==1_000_000_000)
precondition(!reviewWire.map(\.1).contains { $0[0]&0xf0==0x90 })
reviewWire=[];reviewClock=4_001_100_000_000;common.tick()
precondition(common.cycleIndex==10_000 && common.anchor==1_000_000_000)
precondition(reviewWire.map(\.1).contains([0x90,62,90]) && !reviewWire.map(\.1).contains([0x90,65,110]))
try common.stageCoordinated(at:0.15);precondition(common.state == .paused && abs(common.offset-0.35)<1e-12)
let beforeResume=reviewWire.count;try common.runCoordinated(anchorNanoseconds:reviewClock+1_000_000_000)
precondition(reviewWire.count==beforeResume)
mustReject { try common.stageCoordinated(at:0.4) }
try common.silence()
let lateCommon=try MidiTransport(timeline:commonBase.timeline,uid:"1",loop:true,coordinated:true,cycle:commonClock)
lateCommon.prepared=true;lateCommon.destination=commonBase.destination;lateCommon.sourceDestinations=commonBase.sourceDestinations
reset(0);reviewWire=[];try lateCommon.stageCoordinated(at:0);try lateCommon.runCoordinated(anchorNanoseconds:1_000_000_000)
reviewClock=1_250_000_000;lateCommon.tick()
precondition(!reviewWire.map(\.1).contains { $0[0]&0xf0==0x90 },"expired first-callback interval replayed")
let exactCommon=try MidiTransport(timeline:commonBase.timeline,uid:"1",loop:true,coordinated:true,cycle:commonClock)
exactCommon.prepared=true;exactCommon.destination=commonBase.destination;exactCommon.sourceDestinations=commonBase.sourceDestinations
reset(0);reviewWire=[];try exactCommon.stageCoordinated(at:0.1);try exactCommon.runCoordinated(anchorNanoseconds:1_000_000_000)
reviewClock=1_000_000_000;exactCommon.tick()
precondition(reviewWire.map(\.1).contains([0x90,62,90]),"exactly due entry attack lost")
reviewClock=1_050_000_000;exactCommon.tick()
precondition(reviewWire.map(\.1).contains([0x80,62,73]),"owned entry release velocity lost")
let outsideOpaque=asset("outsideOpaque",[
    ["seconds":0.3,"port":2,"bytes":[0x90,60,100]],
    ["seconds":0.4,"port":2,"bytes":[0x80,60,45]],
    ["seconds":0.8,"port":2,"bytes":[0xf0,0x7d,1,0xf7]]])
let opaquePath=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
try JSONSerialization.data(withJSONObject:["schemaVersion":3,"duration":1,"sources":[outsideOpaque],"regions":[clip("outsideOpaque","outsideOpaque",from:0,to:1,repeatCount:1)]]).write(to:opaquePath)
let opaqueTimeline=try JSONDecoder().decode(Timeline.self,from:Data(contentsOf:opaquePath));try FileManager.default.removeItem(at:opaquePath)
_ = try MidiTransport(timeline:opaqueTimeline,uid:"1",loop:true,coordinated:true,cycle:commonClock)
mustReject { try opaqueTimeline.validate() }
let includesOpaque=try MidiCycle(start:0.2,end:0.9,duration:0.7,period:700_000_000,divisor:1)
mustReject { _ = try MidiTransport(timeline:opaqueTimeline,uid:"1",loop:true,coordinated:true,cycle:includesOpaque) }
print("COMMON_MIDI_REPAIR_PASS: unreachable after-cut opaque retained, reachable opaque refused; late entry chases current phase, due attack and owned original release preserved")
let endpointSource=asset("endpoint",[
    ["seconds":0,"port":2,"bytes":[0xc0,0]],
    ["seconds":1,"port":2,"bytes":[0x90,72,80,0x80,72,77]]])
let endpointBase=try arrangement([endpointSource],[clip("endpoint","endpoint",from:0,to:1,repeatCount:1)],duration:1)
let endpointCycle=try MidiCycle(start:0,end:1,duration:1,period:1_000_000_000,divisor:1)
for missed in [false,true] {
    let owner=try MidiTransport(timeline:endpointBase.timeline,uid:"1",loop:true,coordinated:true,cycle:endpointCycle)
    owner.prepared=true;owner.destination=endpointBase.destination;owner.sourceDestinations=endpointBase.sourceDestinations
    reset(0);reviewWire=[];try owner.stageCoordinated(at:0);try owner.runCoordinated(anchorNanoseconds:1_000_000_000)
    reviewClock=1_000_000_000;owner.tick();reviewWire=[]
    reviewClock=missed ? 3_000_000_000:2_000_000_000;owner.tick()
    precondition(reviewWire.map(\.1).contains([0x90,72,80]) == !missed,"past source endpoint acquired after missed whole cycles")
    precondition(reviewWire.map(\.1).contains([0x80,72,77]) == !missed)
}
print("COMMON_MIDI_MULTICYCLE_PASS: exact next endpoint batch retained, stale endpoint attack skipped after multiple missed cycles")
// A callback may cross the virtual wrap while outgoing packets still share
// its exact native host deadline. Preserve that complete original wire batch.
for tiny in [false,true] {
    let on:Double=tiny ? 1.4e-9:0.4995836801, off:Double=tiny ? 1.45e-9:0.4995836802
    let duration:Double=tiny ? 25.0/16/1e9:60/120.1
    let period:UInt128=tiny ? 25:UInt128("703687441776640000000000")!
    let divisor:UInt128=tiny ? 16:UInt128("1408547695956241")!
    let base=try arrangement([asset("wrapBatch",[
        ["seconds":0,"port":2,"bytes":[0xc0,0]],
        ["seconds":on,"port":2,"bytes":[0x90,78,100]],
        ["seconds":off,"port":2,"bytes":[0x80,78,75]]])],
        [clip("wrapBatch","wrapBatch",from:0,to:1,repeatCount:1)],duration:1)
    let clock=try MidiCycle(start:0,end:duration,duration:duration,period:period,divisor:divisor)
    for initial in [false,true] { for late in [false,true] {
        let owner=try MidiTransport(timeline:base.timeline,uid:"1",loop:true,coordinated:true,cycle:clock)
        owner.prepared=true;owner.destination=base.destination;owner.sourceDestinations=base.sourceDestinations
        reset(0);reviewWire=[];try owner.stageCoordinated(at:0);try owner.runCoordinated(anchorNanoseconds:1_000_000_000)
        if !initial { reviewClock=1_000_000_000;owner.tick();reviewWire=[] }
        let due=try clock.deadline(position:on,index:0,offset:0,anchor:1_000_000_000)
        reviewClock=due+(late ? 1:0);owner.tick()
        let notes=reviewWire.map(\.1).filter { $0[0]&0xe0==0x80 }
        precondition(notes == (late ? []:[[0x90,78,100],[0x80,78,75]]),"wrap lost exactly-due original pair or replayed expired history")
        precondition(owner.state == .playing && owner.anchor==1_000_000_000)
    }}
}
print("COMMON_MIDI_OUTGOING_BATCH_PASS: ordinary fractional tempo and short cycles retain due outgoing pairs on initial/active callbacks and skip genuinely expired pairs")
let lateOutside=asset("lateOutside",[
 ["seconds":0,"port":2,"bytes":[0xc0,0]],
 ["seconds":0.3,"port":2,"bytes":[0x90,80,100]],
 ["seconds":0.4,"port":2,"bytes":[0x80,80,73]],
 ["seconds":0.8,"port":2,"bytes":[0xf0,0x7d,1,0xf7]]])
let lateOutsidePath=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
try JSONSerialization.data(withJSONObject:["schemaVersion":3,"duration":1,"sources":[lateOutside],"regions":[clip("lateOutside","lateOutside",from:0,to:1,repeatCount:1)]]).write(to:lateOutsidePath)
let lateOutsideTimeline=try JSONDecoder().decode(Timeline.self,from:Data(contentsOf:lateOutsidePath))
try FileManager.default.removeItem(at:lateOutsidePath)
let lateOutsideBase=commonBase
let lateOutsideCycle=try MidiCycle(start:0.2,end:0.6,duration:0.4,period:400_000_000,divisor:1)
let lateOutsideOwner=try MidiTransport(timeline:lateOutsideTimeline,uid:"1",loop:true,coordinated:true,cycle:lateOutsideCycle)
lateOutsideOwner.prepared=true;lateOutsideOwner.destination=lateOutsideBase.destination;lateOutsideOwner.sourceDestinations=lateOutsideBase.sourceDestinations
reset(0);reviewWire=[];try lateOutsideOwner.stageCoordinated(at:0);try lateOutsideOwner.runCoordinated(anchorNanoseconds:1_000_000_000)
reviewClock=1_450_000_001;lateOutsideOwner.tick()
print("LATE_FIRST_WRAP_OUTSIDE_OPAQUE",lateOutsideOwner.state,"FAILURE",String(describing:lateOutsideOwner.terminalFailure),"WIRE",reviewWire.map(\.1))
precondition(lateOutsideOwner.state == .playing && lateOutsideOwner.terminalFailure==nil && !reviewWire.map(\.1).contains { $0[0]==0xf0 },"late wrap included unreachable opaque suffix")


let missedSource=asset("missedSource",[
 ["seconds":0,"port":2,"bytes":[0xc0,0]],
 ["seconds":0.1249999991,"port":2,"bytes":[0x90,81,100]],
 ["seconds":0.1249999992,"port":2,"bytes":[0x80,81,79]]])
let missedBase=try arrangement([missedSource],[clip("missedSource","missedSource",from:0,to:0.125,repeatCount:8)],duration:1)
let missedCycle=try MidiCycle(start:0,end:0.625,duration:0.625,period:625_000_000,divisor:1)
for initial in [false,true] { for late in [false,true] {
 let owner=try MidiTransport(timeline:missedBase.timeline,uid:"1",loop:true,coordinated:true,cycle:missedCycle)
 owner.prepared=true;owner.destination=missedBase.destination;owner.sourceDestinations=missedBase.sourceDestinations
 reset(0);reviewWire=[];try owner.stageCoordinated(at:0);try owner.runCoordinated(anchorNanoseconds:1_000_000_000)
 if !initial {reviewClock=1_000_000_000;owner.tick();reviewWire=[]}
 reviewClock=1_625_000_000+(late ? 1:0);owner.tick()
 let deadline=try missedCycle.deadline(position:0.5+0.1249999991,index:0,offset:0,anchor:1_000_000_000)
 print("COMPRESSED_OLD_DUE_COPY_INITIAL",initial,"DEADLINE",deadline,"HOST",reviewClock,"WIRE",reviewWire.map(\.1))
 precondition(deadline==1_625_000_000)
 let notes=reviewWire.map(\.1).filter { $0[0]&0xe0==0x80 }
 precondition(notes == (late ? []:[[0x90,81,100],[0x80,81,79]]),"compressed skip lost exactly-due old copy or replayed late history")
 }
}

print("COMMON_MIDI_COMPRESSED_BATCH_PASS: arithmetic missed-copy lookup retains earliest native batch copy; late first wrap ignores unreachable opaque suffix")
// A late wrap begins a copy only for its due native batch. A key that copy
// attacked before this callback is held across the cut, yet stays silent.
let heldCutBase=try arrangement([asset("heldCut",[
 ["seconds":0,"port":2,"bytes":[0xc0,0]],
 ["seconds":0.1,"port":2,"bytes":[0x90,83,100]],
 ["seconds":0.124,"port":2,"bytes":[0x80,83,70]]])],[clip("heldCut","heldCut",from:0,to:0.125,repeatCount:8)],duration:1)
let heldCutCycle=try MidiCycle(start:0,end:0.6125,duration:0.6125,period:612_500_000,divisor:1)
for (staged,active) in [(0.0,true),(0.0,false),(0.45,false)] { for late:UInt64 in [0,1,2_000_000] {
 let owner=try MidiTransport(timeline:heldCutBase.timeline,uid:"1",loop:true,coordinated:true,cycle:heldCutCycle)
 owner.prepared=true;owner.destination=heldCutBase.destination;owner.sourceDestinations=heldCutBase.sourceDestinations
 reset(0);reviewWire=[];try owner.stageCoordinated(at:staged);try owner.runCoordinated(anchorNanoseconds:1_000_000_000)
 if active { reviewClock=1_000_000_000;owner.tick();reviewClock=1_490_000_000;owner.tick();reviewWire=[] }
 let wrap=try heldCutCycle.deadline(position:heldCutCycle.end,index:0,offset:staged,anchor:1_000_000_000)
 reviewClock=wrap+late;owner.tick()
 print("WRAP_EXPIRED_ATTACK_STAGED",staged,"ACTIVE",active,"LATE",late,"WIRE",reviewWire.map(\.1))
 let notes=reviewWire.map(\.1).filter { $0[0]&0xe0==0x80 }
 precondition(notes == (active ? [[0x80,83,70]]:[]),"late wrap re-attacked a key whose attack expired before the cut")
 precondition(owner.state == .playing && owner.cycleIndex==1 && owner.sourceHeld[0]?[83] ?? 0==0)
}}
print("COMMON_MIDI_WRAP_EXPIRED_ATTACK_PASS: active, first and seeked callbacks at or after the wrap keep keys a cut copy attacked earlier silent; the drained copy's acquired release survives")
// A cut entry acquires no key it did not send, so a same-batch original
// release stays silent, and a key held across a later program change does
// not make the notes-free entry refuse playback.
let cutReleaseBase=try arrangement([asset("cutRelease",[
 ["seconds":0,"port":2,"bytes":[0xc0,0]],
 ["seconds":0.1,"port":2,"bytes":[0x90,83,100]],
 ["seconds":0.1124999995,"port":2,"bytes":[0x80,83,70]]])],[clip("cutRelease","cutRelease",from:0,to:0.125,repeatCount:8)],duration:1)
let cutProgramBase=try arrangement([asset("cutProgram",[
 ["seconds":0,"port":2,"bytes":[0xc0,0]],
 ["seconds":0.1,"port":2,"bytes":[0x90,83,100]],
 ["seconds":0.11,"port":2,"bytes":[0xc0,1]],
 ["seconds":0.124,"port":2,"bytes":[0x80,83,70]]])],[clip("cutProgram","cutProgram",from:0,to:0.125,repeatCount:8)],duration:1)
for base in [cutReleaseBase,cutProgramBase] {
 let owner=try MidiTransport(timeline:base.timeline,uid:"1",loop:true,coordinated:true,cycle:heldCutCycle)
 owner.prepared=true;owner.destination=base.destination;owner.sourceDestinations=base.sourceDestinations
 reset(0);reviewWire=[];try owner.stageCoordinated(at:0);try owner.runCoordinated(anchorNanoseconds:1_000_000_000)
 reviewClock=try heldCutCycle.deadline(position:heldCutCycle.end,index:0,offset:0,anchor:1_000_000_000);owner.tick()
 print("WRAP_CUT_ENTRY",owner.state,"FAILURE",String(describing:owner.terminalFailure),"WIRE",reviewWire.map(\.1))
 precondition(owner.state == .playing && owner.terminalFailure==nil,"notes-free cut entry refused a key held across a program change")
 let notes=reviewWire.map(\.1).filter { $0[0]&0xe0==0x80 }
 precondition(notes.isEmpty,"cut entry sounded or released a key it never sent")
}
print("COMMON_MIDI_WRAP_CUT_ENTRY_OWNERSHIP_PASS: a notes-free cut entry acquires nothing, so its same-batch original release stays silent, and it does not refuse a key held across a program change")
let zeroBase=try arrangement([asset("zero",[
    ["seconds":0,"port":2,"bytes":[0xc0,0]],
    ["seconds":0.3,"port":2,"bytes":[0x90,74,80,0x80,74,77]]])],[clip("zero","zero",from:0,to:1,repeatCount:1)],duration:1)
for initial in [true,false] {
    let owner=try MidiTransport(timeline:zeroBase.timeline,uid:"1",loop:true,coordinated:true,cycle:commonClock)
    owner.prepared=true;owner.destination=zeroBase.destination;owner.sourceDestinations=zeroBase.sourceDestinations
    reset(0);reviewWire=[];try owner.stageCoordinated(at:0);try owner.runCoordinated(anchorNanoseconds:1_000_000_000)
    if !initial { reviewClock=1_000_000_000;owner.tick();reviewWire=[] }
    reviewClock=try commonClock.deadline(position:0.3,index:initial ? 0:1,offset:0,anchor:1_000_000_000)
    owner.tick()
    precondition(reviewWire.map(\.1).contains([0x90,74,80]) && reviewWire.map(\.1).contains([0x80,74,77]),"native exactly-due zero pair consumed as floating history")
}
print("COMMON_MIDI_HOST_BOUNDARY_PASS: original zero pair retained at exact native deadlines for first entry and after a wrap without epsilon")
let activeLate=try MidiTransport(timeline:commonBase.timeline,uid:"1",loop:true,coordinated:true,cycle:commonClock)
activeLate.prepared=true;activeLate.destination=commonBase.destination;activeLate.sourceDestinations=commonBase.sourceDestinations
reset(0);reviewWire=[];try activeLate.stageCoordinated(at:0);try activeLate.runCoordinated(anchorNanoseconds:1_000_000_000)
reviewClock=1_000_000_000;activeLate.tick();reviewWire=[]
reviewClock=1_250_000_000;activeLate.tick()
precondition(!reviewWire.map(\.1).contains { $0[0]&0xf0==0x90 },"active late callback replayed expired interval")
let liveLate=try MidiTransport(timeline:commonBase.timeline,uid:"1",loop:true,coordinated:true,cycle:commonClock)
liveLate.prepared=true;liveLate.destination=commonBase.destination;liveLate.sourceDestinations=commonBase.sourceDestinations
reset(0);reviewWire=[];try liveLate.stageCoordinated(at:0);try liveLate.runCoordinated(anchorNanoseconds:1_000_000_000)
reviewClock=1_000_000_000;liveLate.tick();reviewWire=[]
reviewClock=1_125_000_000;liveLate.tick();precondition(reviewWire.map(\.1).contains([0x90,62,90]),"still-live late note lost")
reviewClock=1_150_000_000;liveLate.tick();precondition(reviewWire.map(\.1).contains([0x80,62,73]),"owned late note original release lost")
print("COMMON_MIDI_ACTIVE_LATE_PASS: expired unacquired interval skipped, still-live attack and its original release retained")
let seekZero=try MidiTransport(timeline:zeroBase.timeline,uid:"1",loop:true,coordinated:true,cycle:commonClock)
seekZero.prepared=true;seekZero.destination=zeroBase.destination;seekZero.sourceDestinations=zeroBase.sourceDestinations
reset(0);reviewWire=[];try seekZero.stageCoordinated(at:0.1);try seekZero.runCoordinated(anchorNanoseconds:1_000_000_000)
reviewClock=1_000_000_000;seekZero.tick()
precondition(reviewWire.map(\.1).contains([0x90,74,80]) && reviewWire.map(\.1).contains([0x80,74,77]),"seek boundary swallowed exactly-due zero pair")
let fifoSource=asset("fifoCommon",[
    ["seconds":0,"port":2,"bytes":[0xc0,0]],
    ["seconds":0.1,"port":2,"bytes":[0x90,60,100]],
    ["seconds":0.2,"port":2,"bytes":[0x90,60,90]],
    ["seconds":0.3,"port":2,"bytes":[0x80,60,45]],
    ["seconds":0.8,"port":2,"bytes":[0x80,60,77]]])
let fifoBase=try arrangement([fifoSource],[clip("fifoCommon","fifoCommon",from:0,to:1,repeatCount:1)],duration:1)
for fail in [false,true] {
    let owner=try MidiTransport(timeline:fifoBase.timeline,uid:"1",loop:true,coordinated:true,cycle:endpointCycle)
    owner.prepared=true;owner.destination=fifoBase.destination;owner.sourceDestinations=fifoBase.sourceDestinations
    reset(0);reviewWire=[];try owner.stageCoordinated(at:0);try owner.runCoordinated(anchorNanoseconds:1_000_000_000)
    reviewClock=1_000_000_000;owner.tick();reviewWire=[]
    reviewClock=1_400_000_000;owner.tick()
    precondition(reviewWire.map(\.1)==[[0x90,60,90]] && owner.sourceHeld[0]?[60]==1,"expired A release stole live B")
    reviewClock=1_800_000_000;reviewWireFail=fail;owner.tick()
    if fail {
        precondition(owner.state == .stopped && owner.terminalFailure != nil)
        precondition(Array(reviewWire.suffix(2)).map(\.1)==[[0x80,60,77],[0x80,60,0]] && owner.sourceHeld[0]?[60]==0,"uncertain B release lost cleanup ownership")
    } else { precondition(reviewWire.map(\.1)==[[0x90,60,90],[0x80,60,77]] && owner.sourceHeld[0]?[60]==0) }
}
let scopeA=asset("scopeA",[
    ["seconds":0.3,"port":2,"bytes":[0x90,60,100]], ["seconds":0.5,"port":2,"bytes":[0x80,60,45]],
    ["seconds":0.8,"port":2,"bytes":[0x91,62,90]], ["seconds":0.9,"port":2,"bytes":[0x81,62,77]]])
let scopeB=asset("scopeB",[["seconds":0.3,"port":2,"bytes":[0x91,64,90]],["seconds":0.5,"port":2,"bytes":[0x81,64,77]]])
let scopePath=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
try JSONSerialization.data(withJSONObject:["schemaVersion":3,"duration":1,"sources":[scopeA,scopeB],"regions":[clip("scopeA","scopeA",from:0,to:1,repeatCount:1),clip("scopeB","scopeB",from:0,to:1,repeatCount:1)]]).write(to:scopePath)
let scopeTimeline=try JSONDecoder().decode(Timeline.self,from:Data(contentsOf:scopePath));try FileManager.default.removeItem(at:scopePath)
mustReject { try scopeTimeline.validate() }
let scoped=try MidiTransport(timeline:scopeTimeline,uid:"1",loop:true,coordinated:true,cycle:commonClock)
precondition(scoped.regionScopes==[Set([0]),Set([1])])
scoped.prepared=true;scoped.destination=fifoBase.destination;scoped.sourceDestinations=fifoBase.sourceDestinations
reset(0);reviewWire=[];try scoped.stageCoordinated(at:0);try scoped.runCoordinated(anchorNanoseconds:1_000_000_000)
reviewClock=1_100_000_000;scoped.tick()
precondition(scoped.sourceHeld[0]?[60]==1 && scoped.sourceHeld[0]?[UInt16(1<<8|64)]==1)
reviewWire=[];try scoped.sourceSilence(addresses:scoped.regionScopes[0])
precondition(reviewWire.map(\.1)==[[0x80,60,0]] && scoped.sourceHeld[0]?[UInt16(1<<8|64)]==1,"one window scope silenced a disjoint owner")
// An ended prefix key has no restoration effect and must not reserve its
// channel or erase the state of another, genuinely audible region owner.
let deadPrefix=asset("deadPrefix",[
    ["seconds":0.01,"port":2,"bytes":[0x91,62,90]], ["seconds":0.1,"port":2,"bytes":[0x81,62,45]],
    ["seconds":0.25,"port":2,"bytes":[0x90,60,100]], ["seconds":0.35,"port":2,"bytes":[0x80,60,77]]])
let deadPath=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
let delayedClip=clip("deadPrefix","deadPrefix",start:0.3,from:0.2,to:1,repeatCount:1)
let otherPrefix=asset("otherPrefix",[["seconds":0.25,"port":2,"bytes":[0x91,64,90]],["seconds":0.5,"port":2,"bytes":[0x81,64,77]]])
try JSONSerialization.data(withJSONObject:["schemaVersion":3,"duration":1.1,"sources":[deadPrefix,otherPrefix],"regions":[delayedClip,clip("otherPrefix","otherPrefix",from:0,to:1,repeatCount:1)]]).write(to:deadPath)
let deadTimeline=try JSONDecoder().decode(Timeline.self,from:Data(contentsOf:deadPath));try FileManager.default.removeItem(at:deadPath)
let deadOwner=try MidiTransport(timeline:deadTimeline,uid:"1",loop:true,coordinated:true,cycle:commonClock)
precondition(deadOwner.regionScopes==[Set([0]),Set([1])])
deadOwner.prepared=true;deadOwner.destination=fifoBase.destination;deadOwner.sourceDestinations=fifoBase.sourceDestinations
reset(0);reviewWire=[];try deadOwner.stageCoordinated(at:0);try deadOwner.runCoordinated(anchorNanoseconds:1_000_000_000)
reviewClock=1_060_000_000;deadOwner.tick();precondition(deadOwner.sourceModel.channels[1]?.notes.first?.pitch==64)
reviewClock=1_150_000_000;deadOwner.tick()
precondition(deadOwner.sourceModel.channels[1]?.notes.first?.pitch==64 && deadOwner.sourceHeld[0]?[UInt16(1<<8|64)]==1,"dead prefix replacement erased another region's state")
// A range can span only the suffix and prefix of adjacent copies. Its absent
// middle channel is not audible merely because the region repeats.
let partialCopies=try arrangement([asset("partialCopies",[
    ["seconds":0.05,"port":2,"bytes":[0x90,60,90]],["seconds":0.1,"port":2,"bytes":[0x80,60,77]],
    ["seconds":0.4,"port":2,"bytes":[0x91,62,90]],["seconds":0.5,"port":2,"bytes":[0x81,62,77]],
    ["seconds":0.85,"port":2,"bytes":[0x90,60,90]],["seconds":0.9,"port":2,"bytes":[0x80,60,77]]])],
    [clip("partialCopies","partialCopies",from:0,to:1,repeatCount:2)],duration:2)
let partialClock=try MidiCycle(start:0.8,end:1.2,duration:0.4,period:400_000_000,divisor:1)
let partialWindow=try partialClock.window(partialCopies.timeline.regions[0])
precondition(partialWindow.scope==Set([0]),"unreachable repeated-copy middle reserved a channel")
// Original project mapping owns due membership; inverse source arithmetic
// rounds .02 upward here and would wrongly discard the zero pair's channel.
let boundarySource=asset("boundarySource",[
    ["seconds":0.02,"port":2,"bytes":[0x91,64,90,0x81,64,77]],
    ["seconds":0.04,"port":2,"bytes":[0x90,60,90,0x80,60,77]]])
let boundaryClip=clip("boundarySource","boundarySource",start:0.03,from:0.01,to:0.2,repeatCount:1)
let boundaryBase=try arrangement([boundarySource],[boundaryClip],duration:1)
let boundaryCycle=try MidiCycle(start:0.04,end:0.1,duration:0.06,period:60_000_000,divisor:1)
let boundaryWindow=try boundaryCycle.window(boundaryBase.timeline.regions[0])
precondition(boundaryWindow.scope==Set([0,1]),"native-due channel disappeared through inverse source phase")
let conflictSource=asset("conflict",[["seconds":0.04,"port":2,"bytes":[0x91,64,100]],["seconds":0.08,"port":2,"bytes":[0x81,64,77]]])
let conflictPath=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
try JSONSerialization.data(withJSONObject:["schemaVersion":3,"duration":1,"sources":[boundarySource,conflictSource],"regions":[boundaryClip,clip("conflict","conflict",from:0,to:1,repeatCount:1)]]).write(to:conflictPath)
let conflictTimeline=try JSONDecoder().decode(Timeline.self,from:Data(contentsOf:conflictPath));try FileManager.default.removeItem(at:conflictPath)
mustReject { _ = try MidiTransport(timeline:conflictTimeline,uid:"1",loop:true,coordinated:true,cycle:boundaryCycle) }
let earlyBase=try arrangement([asset("early",[["seconds":0,"port":2,"bytes":[0xc0,0]],["seconds":0.2+0.1,"port":2,"bytes":[0x90,74,80,0x80,74,77]]])],[clip("early","early",from:0,to:1,repeatCount:1)],duration:1)
let early=try MidiTransport(timeline:earlyBase.timeline,uid:"1",loop:true,coordinated:true,cycle:commonClock)
early.prepared=true;early.destination=earlyBase.destination;early.sourceDestinations=earlyBase.sourceDestinations
reset(0);reviewWire=[];try early.stageCoordinated(at:0);try early.runCoordinated(anchorNanoseconds:1_000_000_000)
reviewClock=1_000_000_000;early.tick();reviewWire=[]
let exact=try commonClock.deadline(position:0.2+0.1,index:0,offset:0,anchor:1_000_000_000)
reviewClock=exact-1;early.tick();precondition(reviewWire.isEmpty,"floating phase overrode future native deadline")
reviewClock=exact;early.tick();precondition(reviewWire.map(\.1)==[[0x90,74,80],[0x80,74,77]])
print("COMMON_MIDI_OWNERSHIP_PASS: skipped A/live B keeps FIFO source-origin release and uncertain cleanup; effective window scopes drive admission and silence; native deadline is sole due authority")
let fractional=try MidiCycle(start:0,end:48.0/247,duration:48.0/247,period:48_000_000_000,divisor:247)
for index in UInt128(0)..<10_000 {
    let expected=(index+1)*48_000_000_000/247+(((index+1)*48_000_000_000)%247==0 ? 0:1)
    let deadline=try fractional.deadline(position:fractional.end,index:index,offset:0,anchor:0)
    precondition(UInt128(deadline)==expected)
    let earlier=try fractional.phase(elapsed:deadline-1,offset:0),due=try fractional.phase(elapsed:deadline,offset:0)
    precondition(earlier.index==index && due.index==index+1)
}
// A controller outside the cut must not invent a cross-cycle baseline need.
let outsideBase=try arrangement([asset("outside",[
    ["seconds":0.3,"port":2,"bytes":[0x90,60,100]],
    ["seconds":0.4,"port":2,"bytes":[0x80,60,45]],
    ["seconds":0.8,"port":2,"bytes":[0xb0,1,70]]])],[clip("outside","outside",from:0,to:1,repeatCount:1)],duration:1)
_ = try MidiTransport(timeline:outsideBase.timeline,uid:"1",loop:true,coordinated:true,cycle:commonClock)
let badCommon=try arrangement([asset("unknown",[
    ["seconds":0.3,"port":2,"bytes":[0x90,60,100]],
    ["seconds":0.4,"port":2,"bytes":[0x80,60,45]],
    ["seconds":0.5,"port":2,"bytes":[0xb0,1,70]]])],[clip("unknown","unknown",from:0,to:1,repeatCount:1)],duration:1)
mustReject { _ = try MidiTransport(timeline:badCommon.timeline,uid:"1",loop:true,coordinated:true,cycle:commonClock) }
mustReject { _ = try MidiTransport(timeline:commonBase.timeline,uid:"1",loop:true,coordinated:true) }
print("COMMON_MIDI_CYCLE_PASS: original absolute regions, half-open cuts, source phase, 10000 fractional deadlines without epoch drift, missed cycles, staged controls and audible-window baseline admission")

print("SELECTED_MIDI_DESTINATION_PASS: unrelated enumeration failure/churn isolated; selected removal, UID reuse, source type, offline and noncanonical ID rejected")
print("SOURCE_MIDI_DECISIONS_PASS: F7 running status/partial messages, realtime/SysEx order, expression/release velocity, overlapping held-key cleanup, pedals, zero duration, explicit ports, partial-send cleanup, failed note/pedal/reset/channel-mode release retry, successful release ownership")
print("MIDI_DECISIONS_PASS: late cycles, expired intervals, live notes, send-time epoch, inclusive seek, retrigger, one-shot end, pause/status phase, startup admission")
`
  const swift = join(directory, 'Review.swift'), binary = join(directory, 'review')
  await writeFile(swift, source)
  const compile = spawnSync('xcrun', ['swiftc', swift, '-module-cache-path', join(directory, 'modules'), '-o', binary, '-framework', 'CoreMIDI'], { encoding: 'utf8' })
  assert.equal(compile.status, 0, compile.stderr)
  const run = spawnSync(binary, [], { encoding: 'utf8' })
  assert.equal(run.status, 0, run.stderr)
  assert.ok(run.stdout.includes('MIDI_DECISIONS_PASS'))
  console.log(run.stdout.trim())
} finally { await rm(directory, { recursive: true, force: true }) }
