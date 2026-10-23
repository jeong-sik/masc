// Real production helper and owned CoreMIDI endpoints; no pre-existing output
// is opened. Endpoint receipts prove native words, not physical/acoustic timing.
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawn, spawnSync } from 'node:child_process'
import { createInterface } from 'node:readline'
import { importMidiClip } from '../midi-clip-source.mjs'
import { midiClipPlaybackPlan } from '../midi-clip-playback.mjs'

const directory = await mkdtemp(join(tmpdir(), 'masc-clip-wire-'))
const children = new Set()
try {
  const sources = ['MidiTransport', 'UmpTransport', 'UmpOutput', 'UmpState', 'MidiClipTransport']
    .map(name => fileURLToPath(new URL(`${name}.swift`, import.meta.url)))
  const binary = join(directory, 'music-midi-clip')
  let built = spawnSync('xcrun', ['swiftc', '-parse-as-library', '-D', 'MIDI_LIBRARY', ...sources,
    '-o', binary, '-framework', 'CoreMIDI'], { encoding: 'utf8' })
  assert.equal(built.status, 0, built.stderr)
  await writeFile(join(directory, 'Receiver.swift'), String.raw`
import Foundation
import CoreMIDI
@main enum Receiver {
 static func main() throws {
  var client=MIDIClientRef(),endpoints:[MIDIEndpointRef]=[]
  try checked(MIDIClientCreateWithBlock("MASC Clip wire QA" as CFString,&client,nil),"create private receiver")
  func endpoint(_ tag:String,_ protocolID:MIDIProtocolID)throws->String {
   var endpoint=MIDIEndpointRef()
   try checked(MIDIDestinationCreateWithProtocol(client,"MASC Clip QA \(UUID().uuidString)" as CFString,protocolID,&endpoint,{list,_ in
    var pointer=UnsafeRawPointer(list).advanced(by:MemoryLayout<MIDIEventList>.offset(of: \.packet)!)
    var words:[UInt32]=[]
    for _ in 0..<list.pointee.numPackets {
     let count=Int(pointer.loadUnaligned(fromByteOffset:MemoryLayout<MIDIEventPacket>.offset(of: \.wordCount)!,as:UInt32.self))
     let data=pointer.advanced(by:MemoryLayout<MIDIEventPacket>.offset(of: \.words)!)
     words += (0..<count).map {data.loadUnaligned(fromByteOffset:$0*4,as:UInt32.self)}
     pointer=UnsafeRawPointer(MIDIEventPacketNext(pointer.assumingMemoryBound(to:MIDIEventPacket.self)))
    }
    try? emit(["kind":"received","tag":tag,"words":words,"hostNanoseconds":String(DispatchTime.now().uptimeNanoseconds)])
   }),"create private receiver endpoint")
   endpoints.append(endpoint);var uid:Int32=0
   try checked(MIDIObjectGetIntegerProperty(endpoint,kMIDIPropertyUniqueID,&uid),"read private endpoint")
   return String(uid)
  }
  let native=try endpoint("native2",._2_0), old=try endpoint("native1",._1_0)
  try emit(["kind":"ready","native2":native,"native1":old])
  DispatchQueue.global().async {
   while readLine() != nil {}
   DispatchQueue.main.async {for endpoint in endpoints {MIDIEndpointDispose(endpoint)};MIDIClientDispose(client);exit(0)}
  }
  RunLoop.main.run()
 }
}`)
  built = spawnSync('xcrun', ['swiftc', '-parse-as-library', '-D', 'MIDI_LIBRARY', '-D', 'MIDI_CLIP_LIBRARY',
    ...sources, join(directory, 'Receiver.swift'), '-o', join(directory, 'receiver'), '-framework', 'CoreMIDI'], { encoding: 'utf8' })
  assert.equal(built.status, 0, built.stderr)
  function owner(executable, args) {
    const child = spawn(executable, args, { stdio: ['pipe', 'pipe', 'pipe'] }); children.add(child)
    const rows = [], waiters = new Set(); let detail = '', exited = false
    child.stderr.setEncoding('utf8').on('data', value => { detail += value })
    const lines = createInterface({ input: child.stdout })
    lines.on('line', line => { rows.push(JSON.parse(line)); for (const waiter of waiters) waiter() })
    const completion = new Promise((resolve, reject) => {
      child.once('error', reject)
      child.once('close', (code, signal) => { exited = true; children.delete(child); lines.close(); for (const waiter of waiters) waiter(); resolve({ code, signal, detail }) })
    })
    const until = predicate => new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { waiters.delete(check); reject(new Error(`Native observation did not arrive: ${JSON.stringify(rows)} ${detail}`)) }, 10000)
      const check = () => {
        const result = predicate(rows)
        if (result) { clearTimeout(timeout); waiters.delete(check); resolve(result) }
        else if (exited) { clearTimeout(timeout); waiters.delete(check); reject(new Error(`Native owner exited before observation: ${detail}`)) }
      }
      waiters.add(check); check()
    })
    return { child, rows, until, completion, send: value => child.stdin.write(JSON.stringify(value) + '\n') }
  }
  const receiver = owner(join(directory, 'receiver'), [])
  const endpoints = await receiver.until(rows => rows.find(row => row.kind === 'ready'))
  const raw = words => { const bytes = Buffer.alloc(words.length * 4); words.forEach((word, index) => bytes.writeUInt32BE(word, index * 4)); return bytes }
  const tempo = [0xd0100000, 10000000, 0, 0], meter = [0xd0100001, 0x04020800, 0, 0], program = [0x43c40000, 0x0c000000]
  const pn = [0x43041103, 0xffffffff], pedal = [0x43b44000, 0xffffffff]
  const onA = [0x43941103, 0x00007900], onB = [0x49921100, 0xffff0000]
  const offA = [0x43841100, 0xfedc0000], offB = [0x49821100, 0x12340000], up = [0x43b44000, 0]
  function source(gate = 1000) {
    return importMidiClip(Buffer.concat([Buffer.from('SMF2CLIP'), ...[
      [0x00400000], [0x003003e8], tempo, meter, program, [0x004003e8], [0xf0200000, 0, 0, 0],
      [0x00400000], pn, pedal, onA, onB, [0x00400000 + gate], offA, offB, up,
      [0x004003e8], [0xf0210000, 0, 0, 0],
    ].map(raw)]))
  }
  const words = rows => rows.filter(row => row.kind === 'received' && row.tag === 'native2').flatMap(row => row.words)
  const start = async (tag, destination, document) => {
    const plan = midiClipPlaybackPlan(document, { destination }), path = join(directory, `${tag}.json`)
    await writeFile(path, JSON.stringify(plan))
    const result = owner(binary, ['play', '--file', path, '--destination', destination])
    if (destination === endpoints.native2) {
      await result.until(rows => rows.find(row => row.kind === 'ready'))
      result.send({ kind: 'start' })
    }
    return result
  }
  let cursor = receiver.rows.length
  const full = await start('full', endpoints.native2, source())
  await full.until(rows => rows.find(row => row.kind === 'playing'))
  assert.equal((await full.completion).code, 0)
  const expected = [tempo, meter, program, pn, pedal, onA, onB, offA, offB, up].flat()
  await receiver.until(rows => words(rows.slice(cursor)).length >= expected.length)
  assert.deepEqual(words(receiver.rows.slice(cursor)), expected)
  assert.equal(full.rows.at(-1).reason, 'finished'); assert.equal(full.rows.at(-1).success, true)
  assert.equal(full.rows[0].device.protocol, 2); assert.equal(full.rows[0].device.nativeProtocol, 2)

  cursor = receiver.rows.length
  const controlled = await start('controlled', endpoints.native2, source(10000))
  await controlled.until(rows => rows.find(row => row.kind === 'playing'))
  await receiver.until(rows => words(rows.slice(cursor)).includes(onB[0]))
  controlled.send({ kind: 'pause' })
  const paused = await controlled.until(rows => rows.find(row => row.kind === 'paused'))
  assert.equal(paused.refusal, undefined)
  controlled.send({ kind: 'seek', nanoseconds: '50000000' })
  await controlled.until(rows => rows.find(row => row.kind === 'paused' && row.currentNanoseconds === '50000000'))
  const previousAttacks = words(receiver.rows.slice(cursor)).filter(word => word === onB[0]).length
  controlled.send({ kind: 'resume' })
  await controlled.until(rows => rows.find((row, index) => index > rows.indexOf(paused) && row.kind === 'playing'))
  await receiver.until(rows => words(rows.slice(cursor)).filter(word => word === onB[0]).length > previousAttacks)
  controlled.send({ kind: 'stop' })
  assert.equal((await controlled.completion).code, 0)
  await receiver.until(rows => words(rows.slice(cursor)).slice(-6).filter(word => word === 0x43841100 || word === 0x49821100 || word === 0x43b44000).length === 3)
  assert.equal(controlled.rows.at(-1).reason, 'stop')

  const beforeOld = receiver.rows.filter(row => row.tag === 'native1').length
  const refused = await start('refused-native1', endpoints.native1, source())
  assert.equal((await refused.completion).code, 1)
  assert.ok(refused.rows.some(row => row.kind === 'error' && row.message.includes('MIDI 2.0 destination')))
  assert.equal(receiver.rows.filter(row => row.tag === 'native1').length, beforeOld)
  cursor = receiver.rows.length
  const pendingPath = join(directory, 'cancel-before-start.json')
  await writeFile(pendingPath, JSON.stringify(midiClipPlaybackPlan(source(), { destination: endpoints.native2 })))
  const pending = owner(binary, ['play', '--file', pendingPath, '--destination', endpoints.native2])
  await pending.until(rows => rows.find(row => row.kind === 'ready'))
  pending.send({ kind: 'stop' }); assert.equal((await pending.completion).code, 0)
  assert.equal(pending.rows.some(row => row.kind === 'playing'), false)
  assert.deepEqual(words(receiver.rows.slice(cursor)), [])
  receiver.child.stdin.end(); assert.equal((await receiver.completion).code, 0)
  console.log('MIDI_CLIP_NATIVE_WIRE_PASS: native2 words/order, two groups, velocity0/full16, attribute3, PN32, raw releases, configuration delay, pause/exact seek/resume, owned cleanup and native1 refusal')
} finally {
  await Promise.all([...children].map(child => new Promise(resolve => {
    child.once('close', resolve); child.stdin?.end(); child.kill('SIGTERM')
  })))
  await rm(directory, { recursive: true, force: true })
}
