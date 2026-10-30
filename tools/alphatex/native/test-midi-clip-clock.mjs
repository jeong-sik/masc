// Production native owner with a controlled monotonic clock and owned endpoint:
// exact deadlines beyond binary64 precision, protocol admission and retirement.
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
const directory = await mkdtemp(join(tmpdir(), 'masc-clip-clock-'))
try {
  await writeFile(join(directory, 'Probe.swift'), String.raw`
import Foundation
import CoreMIDI
@main enum Probe {
 static func requireFailure(_ action:()throws->Void){do{try action();preconditionFailure("invalid admission")}catch{}}
 static func main() throws {
  var client=MIDIClientRef(),endpoint=MIDIEndpointRef()
  try checked(MIDIClientCreateWithBlock("MASC Clip clock QA" as CFString,&client,nil),"create private clock client")
  try checked(MIDIDestinationCreateWithProtocol(client,"MASC Clip clock \(UUID().uuidString)" as CFString,._2_0,&endpoint,{_,_ in}),"create private clock endpoint")
  defer {MIDIEndpointDispose(endpoint);MIDIClientDispose(client)}
  var uid:Int32=0;try checked(MIDIObjectGetIntegerProperty(endpoint,kMIDIPropertyUniqueID,&uid),"read clock endpoint")
  func exact(_ n:UInt64)->ExactNanoseconds {ExactNanoseconds(numerator:String(n),denominator:"1")}
  let source=MidiClipPlaybackPlan.Source(originalSha256:String(repeating:"a",count:64),documentSha256:String(repeating:"b",count:64),ppq:1)
  let first:UInt64=9007199254740993,last=first+1
  let messages=[MidiClipPlaybackPlan.Event(id:"8",section:.sequence,tick:"0",words:[0x43941103,0x7900],nanoseconds:exact(first)),
    MidiClipPlaybackPlan.Event(id:"16",section:.sequence,tick:"1",words:[0x43841100,0xffff0000],nanoseconds:exact(last))]
  func plan(_ duration:UInt64,_ events:[MidiClipPlaybackPlan.Event])->MidiClipPlaybackPlan {
   MidiClipPlaybackPlan(schemaVersion:1,kind:"midi-clip-playback",source:source,destination:String(uid),setupNanoseconds:exact(0),durationNanoseconds:exact(duration),events:events)
  }
  var clock:UInt64=0
  let owner=try MidiClipTransport(plan:plan(last+10,messages));owner.now={clock}
  try owner.prepare();try owner.start();precondition(owner.index==0)
  clock=first-1;owner.tick();precondition(owner.index==0 && owner.output.held.isEmpty,"never send one nanosecond early")
  clock=first;owner.tick();precondition(owner.index==1 && owner.output.held.values.reduce(0,+)==1,"retain exact first native deadline")
  clock=last;owner.tick();precondition(owner.index==2 && owner.output.held.isEmpty,"adjacent native deadlines cannot collapse in Double")
  owner.finish(reason:"probe-stop");precondition(owner.output.client==0 && owner.output.port==0 && owner.timer==nil)

  clock=0
  let pending=try MidiClipTransport(plan:plan(100,[MidiClipPlaybackPlan.Event(id:"8",section:.sequence,tick:"0",words:[0x43941100,0xffff0000],nanoseconds:exact(0))]))
  pending.now={clock};try pending.prepare();pending.receive("{\"kind\":\"stop\"}")
  precondition(pending.state == .stopped && pending.index==0 && pending.output.held.isEmpty,"cancellation before start cannot acquire a note")

  let empty=try MidiClipTransport(plan:plan(0,[]));empty.now={0};try empty.prepare()
  var states:[String]=[];empty.onState={states.append($0["kind"] as! String)}
  try empty.start();precondition(states==["playing","stopped"] && empty.output.client==0 && empty.terminalFailure==nil)

  clock=UInt64.max-1
  let overflow=try MidiClipTransport(plan:plan(last+10,messages));overflow.now={clock};try overflow.prepare();try overflow.start()
  precondition(overflow.state == .stopped && overflow.terminalFailure != nil && overflow.output.client==0,"host deadline overflow must retire resources")

  requireFailure {_ = try MidiClipTransport(plan:plan(last+10,Array(messages.reversed())))}
  let duplicate=[messages[0],messages[0]];requireFailure {_ = try MidiClipTransport(plan:plan(last+10,duplicate))}
  let tempo=UmpEvent(seconds:0,source:"clip",words:[0xd0100000,50000000,0,0])
  if case .unsupported = UmpMessage(tempo).action {} else {preconditionFailure("capture metadata default changed")}
  if case .absolute = UmpMessage(tempo,metadata:.tempoAndMeter).action {} else {preconditionFailure("Clip metadata not reconstructible")}
  // A future declaration cannot restore the device's unknown initial tempo.
  // Metadata at the cut remains a valid due baseline; another group cannot
  // provide it because UmpField identity includes source and group.
  let changedTempo:[UInt32]=[0xd0100000,60000000,0,0]
  func metadataPlan(_ sameGroup:Bool)->MidiClipPlaybackPlan {
   plan(1200000000,[
    MidiClipPlaybackPlan.Event(id:"8",section:.sequence,tick:"0",words:[sameGroup ? 0x40903c00 : 0x41903c00,0xffff0000],nanoseconds:exact(0)),
    MidiClipPlaybackPlan.Event(id:"16",section:.sequence,tick:"1",words:changedTempo,nanoseconds:exact(500000000)),
    MidiClipPlaybackPlan.Event(id:"32",section:.sequence,tick:"2",words:[sameGroup ? 0x40803c00 : 0x41803c00,0xffff0000],nanoseconds:exact(1100000000))])
  }
  for sameGroup in [true,false] {
   clock=0;let metadataOwner=try MidiClipTransport(plan:metadataPlan(sameGroup));metadataOwner.now={clock}
   try metadataOwner.prepare();try metadataOwner.start();clock=750000000;metadataOwner.tick()
   requireFailure {_ = try metadataOwner.reconstruction(at:0)}
   _ = try metadataOwner.reconstruction(at:500000000)
   _ = try metadataOwner.reconstruction(at:750000000)
   let held=metadataOwner.output.held
   metadataOwner.receive("{\"kind\":\"seek\",\"nanoseconds\":\"0\"}")
   precondition(metadataOwner.state == .playing && metadataOwner.index==2 && metadataOwner.output.held==held && metadataOwner.terminalFailure==nil,"refused backward seek must retain original owner and held state")
   metadataOwner.finish(reason:"metadata-probe")
  }
  print("MIDI_CLIP_CLOCK_PASS: adjacent UInt64 deadlines beyond binary64, no early send, pre-start cancel, empty Clip, overflow cleanup, metadata context isolation and malformed plan refusal")
 }
}`)
  const sources = ['MidiTransport', 'UmpTransport', 'UmpOutput', 'UmpState', 'MidiClipTransport']
    .map(name => fileURLToPath(new URL(`${name}.swift`, import.meta.url)))
  const built = spawnSync('xcrun', ['swiftc', '-parse-as-library', '-D', 'MIDI_LIBRARY', '-D', 'MIDI_CLIP_LIBRARY',
    ...sources, join(directory, 'Probe.swift'), '-o', join(directory, 'probe'), '-framework', 'CoreMIDI'], { encoding: 'utf8' })
  assert.equal(built.status, 0, built.stderr)
  const result = spawnSync(join(directory, 'probe'), [], { encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  process.stdout.write(result.stdout)
} finally { await rm(directory, { recursive: true, force: true }) }
