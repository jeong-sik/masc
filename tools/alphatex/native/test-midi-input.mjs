// Actual owned CoreMIDI source -> production input helper -> production JS consumer.
// No physical devices, audio streams, output routes, playback, or TUI snapshots.
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawn, spawnSync } from 'node:child_process'
import { createInterface } from 'node:readline'
import { openMidiInput } from '../midi-input.mjs'
import { openStepInput } from '../step-input.mjs'
import { newEditor, editorCommand } from '../sequencer-editor.mjs'
import { saveProject, loadProject, projectMidi } from '../sequencer-files.mjs'
import { importMidiSource, midiSourcePattern } from '../midi-source.mjs'
if (process.platform !== 'darwin') { console.log('MIDI_INPUT_NATIVE_SKIP: CoreMIDI requires macOS'); process.exit(0) }
const directory = await mkdtemp(join(tmpdir(), 'masc-midi-input-native-'))
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done }); return { promise, resolve } }
const helper = join(directory, 'input'), fixture = join(directory, 'source')
const sourceCode = `import Foundation
import CoreMIDI
func checked(_ status:OSStatus)throws { if status != noErr {throw NSError(domain:"fixture",code:Int(status))} }
func emit(_ value:[String:Any]) { let data=try! JSONSerialization.data(withJSONObject:value);FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data([10])) }
@main enum Source {
 static func main() throws {
  var client=MIDIClientRef(),selected=MIDIEndpointRef(),other=MIDIEndpointRef(),destination=MIDIEndpointRef()
  let protocolID:MIDIProtocolID = CommandLine.arguments.dropFirst().first == "1" ? ._1_0 : ._2_0
  try checked(MIDIClientCreateWithBlock("MASC input fixture" as CFString,&client,{_ in}))
  try checked(MIDISourceCreateWithProtocol(client,UUID().uuidString as CFString,protocolID,&selected))
  try checked(MIDISourceCreateWithProtocol(client,UUID().uuidString as CFString,protocolID,&other))
  try checked(MIDIDestinationCreateWithProtocol(client,UUID().uuidString as CFString,._2_0,&destination,{_,_ in}))
  func uid(_ endpoint:MIDIEndpointRef)throws->String{var value:Int32=0;try checked(MIDIObjectGetIntegerProperty(endpoint,kMIDIPropertyUniqueID,&value));return String(value)}
  emit(["kind":"ready","source":try uid(selected),"other":try uid(other),"destination":try uid(destination)])
  DispatchQueue.global().async {
   while let line=readLine(){DispatchQueue.main.async {
    do {
     let command=try JSONSerialization.jsonObject(with:Data(line.utf8)) as! [String:Any]
     let id=command["id"] as! Int
     switch command["kind"] as! String {
     case "emit":
      let packets=command["packets"] as! [[UInt32]],host=mach_absolute_time()
      let size=MemoryLayout<MIDIEventList>.size+packets.reduce(0){$0+$1.count*4+32}
      let raw=UnsafeMutableRawPointer.allocate(byteCount:size,alignment:MemoryLayout<MIDIEventList>.alignment);defer{raw.deallocate()}
      let list=raw.assumingMemoryBound(to:MIDIEventList.self);var last=MIDIEventListInit(list,protocolID)
      for(index,words)in packets.enumerated(){last=words.withUnsafeBufferPointer{buffer in MIDIEventListAdd(list,size,last,host+UInt64(index),buffer.count,buffer.baseAddress!)}}
      try checked(MIDIReceivedEventList(command["other"] as? Bool == true ? other:selected,UnsafePointer(list)))
      emit(["kind":"sent","id":id,"hostTimes":packets.indices.map{String(host+UInt64($0))}])
     case "remove":try checked(MIDIEndpointDispose(selected));selected=0;emit(["kind":"removed","id":id])
     case "stop":
      if selected != 0{try checked(MIDIEndpointDispose(selected))};try checked(MIDIEndpointDispose(other));try checked(MIDIEndpointDispose(destination));try checked(MIDIClientDispose(client));emit(["kind":"closed","id":id]);exit(0)
     default:throw NSError(domain:"fixture-command",code:1)
     }
    }catch{emit(["kind":"error","message":String(describing:error)]);exit(1)}
   }}
   DispatchQueue.main.async{exit(2)}
  }
  RunLoop.main.run()
 }
}
`
const decisionCode = `import Foundation
import CoreMIDI
func inputList(_ owner:MidiInput,_ packets:[[UInt32]],protocolID:MIDIProtocolID = ._2_0) {
 let size=MemoryLayout<MIDIEventList>.size+packets.reduce(0){$0+$1.count*4+32}
 let raw=UnsafeMutableRawPointer.allocate(byteCount:size,alignment:MemoryLayout<MIDIEventList>.alignment);defer{raw.deallocate()}
 let list=raw.assumingMemoryBound(to:MIDIEventList.self);var last=MIDIEventListInit(list,protocolID)
 for(index,words)in packets.enumerated(){last=words.withUnsafeBufferPointer{MIDIEventListAdd(list,size,last,UInt64(index),$0.count,$0.baseAddress!)}}
 owner.receive(UnsafePointer(list),context:UnsafeMutableRawPointer(bitPattern:UInt(owner.endpoint)))
}
func input(_ owner:MidiInput,_ words:[UInt32],protocolID:MIDIProtocolID = ._2_0) {inputList(owner,[words],protocolID:protocolID)}
// A test watchdog bounds a failed owned-lifecycle observation, not product life.
func pump(_ done:()->Bool) {
 let end=Date().addingTimeInterval(5)
 while !done(){precondition(Date()<end,"input owner did not settle");RunLoop.main.run(until:Date().addingTimeInterval(0.001))}
}
@main enum Decisions {
 static func main() throws {
  var client=MIDIClientRef(),source=MIDIEndpointRef(),uid:Int32=0
  try inputChecked(MIDIClientCreateWithBlock("MASC input bounds fixture" as CFString,&client,{_ in}),"fixture client")
  try inputChecked(MIDISourceCreateWithProtocol(client,UUID().uuidString as CFString,._2_0,&source),"fixture source")
  try inputChecked(MIDIObjectGetIntegerProperty(source,kMIDIPropertyUniqueID,&uid),"fixture identity")
  defer{MIDIEndpointDispose(source);MIDIClientDispose(client)}
  let words=Array(repeating:UInt32(0),count:8192)
  do {
   let owner=try MidiInput(source:String(uid));var done=false,events:[[String:Any]]=[]
   owner.onEvent={events.append($0)};owner.onClosed={error in precondition(error != nil);done=true}
   try owner.start()
   for _ in 0..<8{input(owner,words)}
   precondition(owner.pendingWords==MidiInput.maximumPendingWords)
   input(owner,[0x43953c00,0x90000000]);precondition(!owner.accepting && owner.failure != nil)
   pump{done};precondition(owner.pendingWords==0 && owner.pending.isEmpty && owner.inFlight==nil)
   let final=events.last!;precondition(final["kind"] as? String == "stopped" && final["success"] as? Bool == false)
   precondition(final["admittedPackets"] as? String == "8" && final["discardedPackets"] as? String == "8")
   precondition(!events.contains{$0["kind"] as? String == "midi"})
  }
  do {
   let owner=try MidiInput(source:String(uid));var done=false,packets=0
   owner.onEvent={ [weak owner] event in if event["kind"] as? String == "midi" {packets+=1;try owner!.acknowledge(event["ordinal"] as! String)} }
   owner.onClosed={error in precondition(error==nil);done=true};try owner.start()
   for index in 0..<9{input(owner,words);pump{packets==index+1};precondition(owner.pendingWords==0)}
   owner.stop();pump{done};precondition(packets==9 && owner.acknowledged==9)
  }
  do {
   let owner=try MidiInput(source:String(uid));var done=false,ordinals:[String]=[]
   owner.onEvent={event in if event["kind"] as? String == "midi" {let ordinal=event["ordinal"] as! String;ordinals.append(ordinal);DispatchQueue.main.async{try! owner.acknowledge(ordinal)}}}
   owner.onClosed={error in precondition(error==nil);done=true};try owner.start()
   for _ in 0..<3{input(owner,[0x43953c00,0x90000000])};owner.stop();precondition(owner.pendingWords==6)
   pump{done};precondition(ordinals==["0","1","2"] && owner.pendingWords==0 && owner.acknowledged==3)
   owner.stop();precondition(owner.phase == .closed)
  }
  do {
   let owner=try MidiInput(source:String(uid));var done=false
   owner.onEvent={_ in};owner.onClosed={error in precondition(error != nil);done=true};try owner.start()
   input(owner,[0x20903c7f],protocolID:._1_0);pump{done};precondition(owner.pendingWords==0)
  }
  do {
   let owner=try MidiInput(source:String(uid));var done=false,received:[UInt32]=[]
   owner.onEvent={event in if event["kind"] as? String == "midi" {let words=event["words"] as! [UInt32],ordinal=event["ordinal"] as! String;received.append(words[0]);DispatchQueue.main.async{try! owner.acknowledge(ordinal)}}}
   owner.onClosed={error in precondition(error==nil);done=true};try owner.start()
   let first:[UInt32]=[0x43953c00,0x44953d00],second:[UInt32]=[0x43853c00,0x44853d00]
   DispatchQueue.concurrentPerform(iterations:2){index in
    inputList(owner,[Array(repeating:[first[index],0x90000000],count:2048).flatMap{$0},Array(repeating:[second[index],0x10000000],count:2048).flatMap{$0}])
   }
   owner.stop();pump{done}
   precondition(received==[first[0],second[0],first[1],second[1]] || received==[first[1],second[1],first[0],second[0]])
  }
  print("MIDI_INPUT_NATIVE_BOUNDS_PASS: explicit callback/handoff overflow, reusable capacity, queued-input drain, protocol failure, concurrent callback list ordering")
 }
}
`
async function source(protocol = '2') {
  const child = spawn(fixture, [protocol], { stdio: ['pipe', 'pipe', 'pipe'] }), ready = deferred(), pending = new Map()
  let id = 0, failure = '', resolveClosed
  const closed = new Promise(resolve => { resolveClosed = resolve })
  const lines = createInterface({ input: child.stdout })
  lines.on('line', line => { const event = JSON.parse(line); if (event.kind === 'ready') ready.resolve(event); else if (event.kind === 'error') failure = event.message; else pending.get(event.id)?.resolve(event) })
  child.stderr.setEncoding('utf8').on('data', text => { failure += text })
  child.once('close', (code, signal) => { lines.close(); resolveClosed({ code, signal }); if (code !== 0) ready.resolve({ error: failure || `fixture closed ${code ?? signal}` }) })
  const identity = await ready.promise; assert.equal(identity.error, undefined, identity.error)
  const request = async value => { const ticket = deferred(); const requestId = id++; pending.set(requestId, ticket); child.stdin.write(JSON.stringify({ ...value, id: requestId }) + '\n'); const event = await ticket.promise; pending.delete(requestId); return event }
  return { ...identity, request, async close() { await request({ kind: 'stop' }); assert.deepEqual(await closed, { code: 0, signal: null }, failure) } }
}
const active = new Set()
const open = (selected, options = {}) => { const controller = new AbortController(); const input = openMidiInput({ source: selected.source, executable: helper, onPacket() {}, signal: controller.signal, ...options }); const owner = { ...input, abort: () => controller.abort(new Error('test cleanup')) }; active.add(owner); input.completion.finally(() => active.delete(owner)).catch(() => {}); return owner }
try {
  await writeFile(join(directory, 'Source.swift'), sourceCode)
  await writeFile(join(directory, 'Decisions.swift'), decisionCode)
  for (const [files, output] of [[[new URL('./MidiInput.swift', import.meta.url).pathname], helper], [[join(directory, 'Source.swift')], fixture]]) {
    const built = spawnSync('xcrun', ['swiftc', '-parse-as-library', '-O', ...files, '-o', output, '-framework', 'CoreMIDI'], { encoding: 'utf8' }); assert.equal(built.status, 0, built.stderr)
  }
  const decisionBinary = join(directory, 'decisions')
  const builtDecisions = spawnSync('xcrun', ['swiftc', '-parse-as-library', '-D', 'MIDI_INPUT_LIBRARY', '-O', new URL('./MidiInput.swift', import.meta.url).pathname, join(directory, 'Decisions.swift'), '-o', decisionBinary, '-framework', 'CoreMIDI'], { encoding: 'utf8' })
  assert.equal(builtDecisions.status, 0, builtDecisions.stderr)
  const decisions = spawnSync(decisionBinary, [], { encoding: 'utf8' }); assert.equal(decisions.status, 0, decisions.stderr + decisions.stdout); console.log(decisions.stdout.trim())
  let selected = await source()
  try {
    const wrong = open({ source: selected.destination }); await assert.rejects(wrong.ready, /not a source/); await assert.rejects(wrong.completion)
    const received = [], all = deferred(), packets = [[0], [0x43953c03, 0x90012345], [0x33020102, 0], Array.from({ length: 160 }, () => [0x43853c00, 0x12340000, 0x43953c03, 0x90012345]).flat()]
    const expectedWords = packets.flat().length
    let receivedWords = 0
    const input = open(selected, { onPacket(event) { received.push(event); receivedWords += event.words.length; if (receivedWords >= expectedWords) all.resolve() } })
    assert.equal((await input.ready).source.id, selected.source)
    await selected.request({ kind: 'emit', packets: [[0x44913d00, 0x81230000]], other: true })
    const sent = await selected.request({ kind: 'emit', packets }); await all.promise; input.stop()
    const final = await input.completion
    // CoreMIDI may split a source event packet for IPC. Compare every word
    // and its original host timestamp, not an invented packetization promise.
    assert.deepEqual(received.flatMap(event => event.words.map(word => [word, event.hostTime])),
      packets.flatMap((words, index) => words.map(word => [word, sent.hostTimes[index]])))
    assert.deepEqual(received.map(event => event.ordinal), received.map((_, index) => String(index)))
    assert.ok(received.every(event => event.source === selected.source && event.timestampOrigin === 'packet' && event.protocol === 2))
    assert.equal(final.admittedPackets, String(received.length)); assert.equal(final.acknowledgedPackets, String(received.length)); assert.equal(final.pendingWords, 0)
    console.log('MIDI_INPUT_NATIVE_FIDELITY_PASS: selected source pinning, wrong object refusal, variable-sized/multiple packets, exact host timestamps and UMP words, acknowledged drain')
  } finally { await selected.close() }
  selected = await source('1')
  try {
    const words = [], all = deferred(), packets = [[0x20953c7f], [0x20b5407f], [0x20e50040], [0x20853c00]]
    const input = open(selected, { onPacket(event) { words.push(...event.words); if (words.length >= 8) all.resolve() } })
    assert.equal((await input.ready).protocol, 2)
    await selected.request({ kind: 'emit', packets }); await all.promise; input.stop(); await input.completion
    assert.deepEqual(words, [0x40953c00, 0xffff0000, 0x40b54000, 0xffffffff, 0x40e50000, 0x80000000, 0x40853c00, 0])
    console.log('MIDI_INPUT_NATIVE_MIDI1_PASS: actual MIDI1 source converts note/hold/bend/release into protocol2 delivery through the same consumer')
  } finally { await selected.close() }
  selected = await source('1')
  try {
    let editor = editorCommand(newEditor(), 'note C2 0 4').editor
    editor = editorCommand(editor, 'track-add Keyboard').editor
    const original = editor.project, held = deferred(), inserted = deferred()
    let task = Promise.resolve()
    const input = openStepInput({ source: selected.source, getEditor: () => editor,
      adoptEditor(next) { editor = next; inserted.resolve() },
      enqueue(action) { const decision = task.then(action); task = decision.catch(() => {}); return decision },
      onState(state) { if (state.held === 3) held.resolve() },
      openInput: options => open(selected, options) })
    await input.ready
    await selected.request({ kind: 'emit', other: true, packets: [[0x2095307f]] })
    await selected.request({ kind: 'emit', packets: [[0x20953c60, 0x20954070, 0x2095437f]] })
    await held.promise; assert.equal(editor.project, original)
    await selected.request({ kind: 'emit', packets: [[0x20853c40, 0x20854020, 0x20854310]] })
    await inserted.promise; input.stop(); await input.completion
    assert.deepEqual(editor.project.tracks[0], original.tracks[0])
    assert.deepEqual(editor.project.tracks[1].notes.map(note => [note.start, note.duration, note.pitch, note.velocity]), [[0,960,60,96],[0,960,64,112],[0,960,67,127]])
    assert.deepEqual(editorCommand(editor, 'undo').editor.project, original)
    const path = join(directory, 'keyboard.json'); await saveProject(path, editor.project)
    const reopened = (await loadProject(path)).project
    assert.deepEqual(reopened, editor.project)
    const notes = midiSourcePattern(importMidiSource(projectMidi(reopened))).notes.filter(note => note.track === 2)
    assert.deepEqual(notes.map(note => [note.start, note.duration, note.pitch, note.velocity]), [[0,960,60,96],[0,960,64,112],[0,960,67,127]])
    console.log('MIDI_STEP_NATIVE_EDIT_PASS: selected actual MIDI1 source -> protocol2 owner -> serialized chord editor -> one undo, other track retained, save/reopen/MIDI export')
  } finally { await selected.close() }
  selected = await source()
  try {
    const entered = deferred(), decision = deferred()
    const input = open(selected, { async onPacket() { entered.resolve(); await decision.promise } }); await input.ready
    await selected.request({ kind: 'emit', packets: [[0x43953c03, 0x90012345]] }); await entered.promise; input.stop()
    let settled = false; input.completion.then(() => { settled = true }, () => { settled = true }); await Promise.resolve(); assert.equal(settled, false)
    decision.resolve(); const final = await input.completion; assert.equal(final.acknowledgedPackets, '1'); assert.equal(final.discardedPackets, '0')
    console.log('MIDI_INPUT_NATIVE_DRAIN_PASS: normal stop retains the admitted consumer before acknowledgement and finalization')
  } finally { await selected.close() }
  selected = await source()
  try {
    const entered = deferred(), decision = deferred(), cancelled = deferred()
    const input = open(selected, { async onPacket(event, { signal }) { signal.addEventListener('abort', () => cancelled.resolve(), { once: true }); entered.resolve(); await decision.promise } }); await input.ready
    await selected.request({ kind: 'emit', packets: [[0x43953c03, 0x90012345]] }); await entered.promise
    await selected.request({ kind: 'remove' }); await cancelled.promise
    let settled = false; input.completion.catch(() => { settled = true }); await Promise.resolve(); assert.equal(settled, false)
    decision.resolve(); await assert.rejects(input.completion)
    console.log('MIDI_INPUT_NATIVE_REMOVAL_PASS: removing the selected source cancels and joins an admitted consumer')
  } finally { await selected.close() }
} finally {
  for (const input of active) input.abort()
  await Promise.allSettled([...active].map(input => input.completion))
  await rm(directory, { recursive: true, force: true })
}
