// Actual edited capture -> Worker snapshot -> unchanged native transport ->
// private CoreMIDI destinations. This does not open any existing device/output.
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { spawnSync } from 'node:child_process'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import JZZ from 'jzz'
import { capturedMidiFixture, packet } from '../test/helpers/captured-midi-fixture.mjs'
import { newUmpEditor, umpEditorCommand } from '../ump-editor.mjs'
import { prepareCapturedPlayback } from '../capture-playback.mjs'

const directory = await mkdtemp(join(tmpdir(), 'masc-edited-ump-wire-'))
try {
  const main = String.raw`import Foundation
import CoreMIDI

@main enum Probe {
 static func require(_ value:Bool,_ message:String)throws {if !value {throw MidiFailure(message)}}
 static func main() throws {
  struct Input:Decodable {let timeline:UmpTimeline;let expected:[String:[UInt32]]}
  let path=CommandLine.arguments[1]
  let original=try JSONDecoder().decode(Input.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
  var client=MIDIClientRef(),endpoints:[MIDIEndpointRef]=[]
  try checked(MIDIClientCreate("MASC edited UMP wire probe" as CFString,nil,nil,&client),"create private probe client")
  defer {for endpoint in endpoints {MIDIEndpointDispose(endpoint)};MIDIClientDispose(client)}
  let lock=NSLock();var received:[String:[UInt32]]=[:]
  func observed(_ source:String)->[UInt32] {lock.lock();defer{lock.unlock()};return received[source,default:[]]}
  func endpoint(_ source:String)throws->String {
   var result=MIDIEndpointRef()
   try checked(MIDIDestinationCreateWithProtocol(client,"MASC edited \(UUID().uuidString)" as CFString,._2_0,&result,{list,_ in
    let raw=UnsafeRawPointer(list)
    let count=raw.loadUnaligned(fromByteOffset:MemoryLayout<MIDIEventList>.offset(of:\.numPackets)!,as:UInt32.self)
    var pointer=raw.advanced(by:MemoryLayout<MIDIEventList>.offset(of:\.packet)!)
    var words:[UInt32]=[]
    for _ in 0..<count {
     let size=Int(pointer.loadUnaligned(fromByteOffset:MemoryLayout<MIDIEventPacket>.offset(of:\.wordCount)!,as:UInt32.self))
     let data=pointer.advanced(by:MemoryLayout<MIDIEventPacket>.offset(of:\.words)!)
     words += (0..<size).map {data.loadUnaligned(fromByteOffset:$0*MemoryLayout<UInt32>.stride,as:UInt32.self)}
     pointer=UnsafeRawPointer(MIDIEventPacketNext(pointer.assumingMemoryBound(to:MIDIEventPacket.self)))
    }
    lock.lock();received[source,default:[]] += words;lock.unlock()
   }),"create owned native2 destination")
   endpoints.append(result);var uid:Int32=0
   try checked(MIDIObjectGetIntegerProperty(result,kMIDIPropertyUniqueID,&uid),"read owned destination identity")
   return String(uid)
  }
  func spin(_ label:String,_ complete:()->Bool)throws {
   let deadline=Date().addingTimeInterval(5)
   while !complete() {
    try require(Date()<deadline,"observation timed out: \(label)")
    _ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))
   }
  }
  func transport(_ tag:String)throws->UmpTransport {
   var bindings:[UmpBinding]=[]
   for source in original.timeline.bindings.map(\.source) {bindings.append(UmpBinding(source:source,destination:try endpoint(tag+source)))}
   return try UmpTransport(timeline:UmpTimeline(schemaVersion:original.timeline.schemaVersion,duration:original.timeline.duration,
    clock:original.timeline.clock,bindings:bindings,packets:original.timeline.packets))
  }
  let full=try transport("full/")
  defer {full.finish(reason:"probe-cleanup",error:nil,publish:false)}
  try full.prepare();try full.stageCoordinated(at:0)
  try full.runCoordinated(anchorNanoseconds:DispatchTime.now().uptimeNanoseconds+100_000_000)
  try spin("natural transport completion") {full.state == .ended || full.state == .stopped}
  try require(full.state == .ended && full.terminalFailure == nil,"native source transport failed")
  for (source,words) in original.expected {
   try spin("full \(source) receipt") {observed("full/"+source).count >= words.count}
   try require(observed("full/"+source)==words,"native2 word/order mismatch for \(source): \(observed("full/"+source))")
  }
  try require(full.output.held.isEmpty && full.output.pedals.isEmpty,"original release messages did not settle owned state")
  full.finish(reason:"completed",error:nil,publish:false)
  try require(full.timer == nil && full.output.closed && full.output.port == 0 && full.output.client == 0,"native resources did not retire")
  print("EDITED_UMP_NATIVE_WIRE_PASS: exact Attribute3 fractional pitch, velocity0/full16, Note Index, PN32 and original releases on two actual private native2 destinations")

  let cancelled=try transport("cancel/")
  defer {cancelled.finish(reason:"probe-cleanup",error:nil,publish:false)}
  try cancelled.prepare();try cancelled.stageCoordinated(at:0)
  try cancelled.runCoordinated(anchorNanoseconds:DispatchTime.now().uptimeNanoseconds+100_000_000)
  // The first source packet contains PN state, pedal-down and four attacks
  // (12 words). Cancel after their receive acknowledgement, not a fixed sleep.
  try spin("admitted edited attacks") {observed("cancel/A").count >= 12 || cancelled.state == .stopped}
  try require(cancelled.state == .playing && cancelled.terminalFailure == nil,"cancel owner did not acquire edited attacks")
  let sent=Array(cancelled.events.prefix(cancelled.index))
  var held:[UmpOutput.Key:Int]=[:]
  for note:UInt32 in [60,64,67,71] {held[UmpOutput.Key(source:"A",prefix:0x43050000,number:note)]=1}
  // Main-thread delay may also admit B. Its single fixture note's state is
  // derived from the independently checked source prefix, never DUT held state.
  let b=sent.filter {$0.source == "B"}.map {$0.words[0]}
  if b.contains(0x49921103) && !b.contains(0x49821100) {held[UmpOutput.Key(source:"B",prefix:0x49020000,number:17)]=1}
  let pedals:Set<UmpOutput.Key>=[UmpOutput.Key(source:"A",prefix:0x43050000,number:64)]
  try require(cancelled.output.held == held && cancelled.output.pedals == pedals,"fixture attacks (including velocity0) or pedal ownership missing")
  cancelled.finish(reason:"cancelled",error:nil,publish:false)
  for source in original.expected.keys {
   let prefix=sent.filter {$0.source == source}.flatMap(\.words)
   try require(prefix==Array(original.expected[source]!.prefix(prefix.count)),"cancel admitted prefix differs from the independent word oracle")
   let keys=held.filter {$0.key.source == source}
   let controls=pedals.filter {$0.source == source}
   let expectedCount=prefix.count+2*(keys.values.reduce(0,+)+controls.count)
   try spin("cancel \(source) cleanup receipt") {observed("cancel/"+source).count >= expectedCount}
   let actual=observed("cancel/"+source)
   try require(Array(actual.prefix(prefix.count))==prefix && actual.count==expectedCount,"cancel changed admitted stream or missed cleanup")
   var cleanup:[[UInt32]]=[]
   for (key,count) in keys {
    try require((source == "A" && [60,64,67,71].contains(key.number)) || source == "B" && key.number == 17,"cleanup retargeted an edited Note Index")
    for _ in 0..<count {cleanup.append([source == "A" ? 0x43850000 | key.number << 8 : 0x49820000 | key.number << 8,0])}
   }
   for key in controls {
    try require(source == "A" && key.number == 64,"unexpected owned controller")
    cleanup.append([0x43b54000,0])
   }
   let tail=Array(actual.dropFirst(prefix.count))
   let messages=stride(from:0,to:tail.count,by:2).map {Array(tail[$0..<($0+2)])}
   let sorted:([[UInt32]])->[[UInt32]] = {$0.sorted {$0.lexicographicallyPrecedes($1)}}
   try require(sorted(messages)==sorted(cleanup),"cancel cleanup changed note indices or shared-channel state")
  }
  try require(cancelled.timer == nil && cancelled.output.held.isEmpty && cancelled.output.pedals.isEmpty
    && cancelled.output.closed && cancelled.output.port == 0 && cancelled.output.client == 0,"cancel left an owned timer/key/port/client")
  print("EDITED_UMP_NATIVE_CANCEL_PASS: real acquired-note/pedal releases observed; source timer, held state, output port and client retired")
  try emit(["kind":"edited-ump-native-proof","protocol":2,"scope":"private CoreMIDI destinations",
   "clock":["origin":original.timeline.clock.origin,"numer":original.timeline.clock.numer,"denom":original.timeline.clock.denom],
   "receivedFull":Dictionary(uniqueKeysWithValues:original.expected.keys.map {($0,observed("full/"+$0))}),
   "receivedCancel":Dictionary(uniqueKeysWithValues:original.expected.keys.map {($0,observed("cancel/"+$0))}),
   "ownersRetired":true])
 }
}`
  await writeFile(join(directory, 'Probe.swift'), main)
  const built = spawnSync('xcrun', ['swiftc', '-parse-as-library', '-D', 'MIDI_LIBRARY',
    ...['MidiTransport', 'UmpTransport', 'UmpOutput', 'UmpState'].map(name => new URL(`${name}.swift`, import.meta.url).pathname),
    join(directory, 'Probe.swift'), '-o', join(directory, 'probe'), '-framework', 'CoreMIDI'], { encoding: 'utf8' })
  assert.equal(built.status, 0, built.stderr)
  const rows = [
    packet(0n, 'A', [JZZ.UMP.umpPnRPN(3, 5, 60, 3, 0x7b123456), JZZ.UMP.umpControl(3, 5, 64, 0xffffffff),
      ...[60, 64, 67, 71].map(key => JZZ.UMP.umpNoteOn(3, 5, key, 0x9001))]),
    packet(2400000n, 'B', [JZZ.UMP.umpNoteOn(9, 2, 17, 0x1234)]),
    packet(4800000n, 'A', [JZZ.UMP.umpPnPitchBend(3, 5, 60, 0x87654321), JZZ.UMP.umpAftertouch(3, 5, 60, 0xabcdef01)]),
    packet(9600000n, 'B', [JZZ.UMP.umpNoteOff(9, 2, 17, 0xfedc)]),
    packet(12000000n, 'A', [...[60, 64, 67, 71].map(key => JZZ.UMP.umpNoteOff(3, 5, key, 0x1234)), JZZ.UMP.umpControl(3, 5, 64, 0)]),
  ]
  await capturedMidiFixture(async ({ root, path, imported }) => {
    const worker = new Worker(new URL('../arrangement-worker.mjs', import.meta.url)); let id = 0
    const scratch = join(root, 'scratch'); await mkdir(scratch)
    const request = async job => {
      const response = once(worker, 'message'); worker.postMessage({ ...job, id: ++id })
      const [message] = await response; assert.equal(message.ok, true, message.error); return message.result
    }
    try {
      const options = { sourceRoot: dirname(path), directory: scratch }
      const source = await request({ kind: 'prepare-ump', project: imported.project, asset: imported.asset, ...options })
      let editor = newUmpEditor(source.asset, source.packets)
      for (const line of ['revoice Cmaj7 drop2', 'velocity 0', 'scope B 10 3', 'pitch-absolute 64.25', 'velocity 65535']) editor = umpEditorCommand(editor, line).editor
      const variant = await request({ kind: 'import-ump', project: imported.project, asset: imported.asset, ump: editor.asset.ump, ...options })
      const snapshot = await request({ kind: 'prepare-take', project: variant.project, asset: variant.asset, ...options })
      const playback = await prepareCapturedPlayback(snapshot.directory, { directory: scratch, sourceBindings: [{ source: 'A', destination: '1' }, { source: 'B', destination: '2' }] })
      const timeline = JSON.parse(await readFile(playback.path)).ump
      const expected = {
        A: [0x43053c03, 0x7b123456, 0x43b54000, 0xffffffff,
          0x43953c03, 55 * 512, 0x43954003, 0x90010000 + 60 * 512, 0x43954303, 0x90010000 + 64 * 512, 0x43954703, 0x90010000 + 71 * 512,
          0x43653c00, 0x87654321, 0x43a53c00, 0xabcdef01,
          0x43853c00, 0x12340000, 0x43854000, 0x12340000, 0x43854300, 0x12340000, 0x43854700, 0x12340000, 0x43b54000, 0],
        B: [0x49921103, 0xffff8080, 0x49821100, 0xfedc0000],
      }
      for (const [source, words] of Object.entries(expected)) assert.deepEqual(timeline.packets.filter(packet => packet.source === source).flatMap(packet => packet.words), words)
      const input = join(directory, 'timeline.json'); await writeFile(input, JSON.stringify({ timeline, expected }))
      const result = spawnSync(join(directory, 'probe'), [input], { encoding: 'utf8' })
      assert.equal(result.status, 0, result.stdout + result.stderr)
      process.stdout.write(result.stdout)
    } finally { await worker.terminate() }
  }, rows)
} finally { await rm(directory, { recursive: true, force: true }) }
