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
var reviewClock: UInt64 = 0, reviewSendCost: UInt64 = 0
var reviewSent: [[UInt8]] = [], reviewExit: Int32?
final class MidiTransport {`)
  const replaceEffect = (start, end, body) => {
    const first = source.indexOf(start), last = source.indexOf(end, first)
    assert.ok(first >= 0 && last > first)
    source = source.slice(0, first) + body + source.slice(last)
  }
  replaceEffect('    func send(', '    func apply(', `    func send(_ bytes: [UInt8]) throws {
        reviewSent.append(bytes); reviewClock += reviewSendCost
    }
`)
  replaceEffect('    func schedule()', '    func tick()', '    func schedule() throws {}\n')
  replaceEffect('    func checkDestination()', '    func send(', `    func checkDestination() throws {
        guard destination != nil else { throw MidiFailure("synthetic unavailable destination") }
    }
`)
  source = source.replace('exit(failure == nil ? 0 : 1)', 'reviewExit = failure == nil ? 0 : 1')
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
    reviewClock = host; reviewSendCost = cost; reviewSent = []; reviewExit = nil
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
reset(0)
let pending = try transport(events); pending.destination = nil; pending.state = .prepared
pending.destinationChanged(); pending.start()
precondition(pending.state == .prepared && reviewExit == nil && reviewSent.isEmpty)
precondition(pending.snapshot("prepared")["device"] == nil)
pending.prepared = true; pending.destinationChanged()
precondition(pending.state == .stopped && reviewExit == 1)
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
