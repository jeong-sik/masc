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
  source = source.slice(0, source.lastIndexOf('\n_ = signal(SIGPIPE,'))
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
func clip(_ id: String, _ source: String, start: Double = 0, from: Double = 0.1, to: Double = 0.6, repeatCount: Int = 2) -> [String: Any] {
    ["id":id,"source":source,"startSeconds":start,"sourceStart":from,"sourceEnd":to,"repeatCount":repeatCount]
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
print("MIDI_ARRANGEMENT_DECISIONS_PASS: original boundary events, trims/full endpoints, finite repeats, overlapping physical ownership admission, distinct-channel cleanup, prior-state baselines, compressed seek, silent paused seek/resume")

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
