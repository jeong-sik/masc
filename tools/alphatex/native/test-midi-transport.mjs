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
