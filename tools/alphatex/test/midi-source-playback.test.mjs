import test from 'node:test'
import assert from 'node:assert/strict'
import { importMidiSource, midiSourcePattern } from '../midi-source.mjs'
import { sourceMidiTimeline, sourceTickAtSeconds } from '../midi-source-playback.mjs'
import { newEditor, editorCommand } from '../sequencer-editor.mjs'
const chunk = (type, bytes) => {
  const head = Buffer.alloc(8); head.write(type); head.writeUInt32BE(bytes.length, 4)
  return Buffer.concat([head, Buffer.from(bytes)])
}
const source = (tracks, format = 1, division = 480) => {
  const head = Buffer.alloc(6); head.writeUInt16BE(format); head.writeUInt16BE(tracks.length, 2); head.writeUInt16BE(division, 4)
  return importMidiSource(Buffer.concat([chunk('MThd', head), ...tracks.map(bytes => chunk('MTrk', bytes))]))
}
const end = [0,255,47,0]
test('source audition retains ordered expression, F0/F7 wire semantics, tempo map and release velocity', () => {
  const doc = source([[0,255,81,3,7,161,32,0x83,0x60,255,81,3,15,66,64,0x83,0x60,...end.slice(1)],
    [0,0xb0,0,4,0,0xc0,33,0,0xb0,1,80,0,0xe0,1,65,0,0xd0,60,0,0xa0,60,70,
      0,0xf0,2,0x7d,1,0x83,0x60,0xf7,2,2,0xf7,0,0xf7,5,0x90,60,100,60,0,
      0x83,0x60,0x90,62,100,0,0x80,62,77,...end]])
  const before = structuredClone(doc), timeline = sourceMidiTimeline(doc, { midiOutput: '-123' })
  assert.equal(timeline.schemaVersion, 2); assert.equal(timeline.duration, 1.5)
  assert.deepEqual(timeline.bindings, [{ port: 0, destination: '-123' }])
  assert.deepEqual(timeline.events.map(event => [event.seconds,event.bytes]), [
    [0,[176,0,4]],[0,[192,33]],[0,[176,1,80]],[0,[224,1,65]],[0,[208,60]],[0,[160,60,70]],
    [0,[240,125,1]],[.5,[2,247]],[.5,[144,60,100,60,0]],[1.5,[144,62,100]],[1.5,[128,62,77]],
  ])
  const performance = midiSourcePattern(doc)
  assert.equal(sourceTickAtSeconds(performance,.25),240)
  assert.equal(sourceTickAtSeconds(performance,1),720)
  assert.equal(sourceTickAtSeconds(performance,9),960)
  assert.deepEqual(doc,before)
})
test('distinct source ports require complete explicit endpoint bindings and independent format-2 selection', () => {
  const doc = source([[0,255,33,1,2,0,0x90,60,100,1,0x80,60,0,...end],
    [0,255,33,1,7,0,0x91,64,100,1,0x81,64,0,...end]])
  assert.throws(()=>sourceMidiTimeline(doc,{midiOutput:'42'}),/each source MIDI port/)
  assert.throws(()=>sourceMidiTimeline(doc,{portBindings:[{port:2,destination:'42'}]}),/every source MIDI port/)
  assert.throws(()=>sourceMidiTimeline(doc,{portBindings:[{port:2,destination:'42'},{port:7,destination:'42'}]}),/distinct destinations/)
  const bindings=[{port:7,destination:'-456'},{port:2,destination:'123'}]
  const timeline=sourceMidiTimeline(doc,{portBindings:bindings})
  assert.deepEqual(timeline.bindings,[bindings[1],bindings[0]])
  assert.deepEqual(timeline.events.map(e=>e.port),[2,7,2,7])
  const patterns=source([[0,0x90,60,1,1,0x80,60,0,...end],[0,0x90,64,1,1,0x80,64,0,...end]],2)
  assert.throws(()=>sourceMidiTimeline(patterns,{midiOutput:'123'}),/pattern explicitly/)
  assert.equal(sourceMidiTimeline(patterns,{pattern:1,midiOutput:'123'}).events[0].bytes[1],64)
  const effect=editorCommand(newEditor(doc),'midi-port 7 -456').effect
  assert.deepEqual(effect,{kind:'midi-port',port:7,destination:'-456'})
})
test('source audition preserves SMPTE clock and zero-length messages, and refuses undefined routing or looping', () => {
  const doc=source([[0,255,81,3,15,66,64,0,0x90,60,100,0x92,0x60,0x80,60,70,...end]],0,0xe350)
  const timeline=sourceMidiTimeline(doc,{midiOutput:'123'})
  assert.equal(timeline.duration,1.001)
  const zero=source([[0,0x90,60,100,0,0x80,60,70,...end]],0)
  const z=sourceMidiTimeline(zero,{midiOutput:'123'})
  assert.equal(z.duration,0);assert.equal(z.events.length,2)
  assert.throws(()=>sourceMidiTimeline(zero),/every source MIDI port/)
  assert.throws(()=>sourceMidiTimeline(zero,{midiOutput:'01'}),/exact signed/)
  assert.throws(()=>sourceMidiTimeline(zero,{midiOutput:'123',loop:true}),/once/)
})
