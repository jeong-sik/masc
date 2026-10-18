import test from 'node:test'
import assert from 'node:assert/strict'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { importMidiSource, exportMidiSource, midiSourcePattern, midiSourceHarmony, editMidiSourceNote } from '../midi-source.mjs'
midiFiles(JZZ)
const chunk = (type, data, little = false) => {
  const header = Buffer.alloc(8); header.write(type)
  if (little) header.writeUInt32LE(data.length, 4); else header.writeUInt32BE(data.length, 4)
  return Buffer.concat([header, data])
}
const smf = (tracks, { format = 1, division = 480, extra = [] } = {}) => {
  const header = Buffer.alloc(6);header.writeUInt16BE(format);header.writeUInt16BE(tracks.length,2);header.writeUInt16BE(division,4)
  return Buffer.concat([chunk('MThd', header), ...extra, ...tracks.map(data => chunk('MTrk', Buffer.from(data)))])
}
const vlq = value => { const bytes = [value & 127];while ((value = Math.floor(value / 128))) bytes.unshift((value & 127) | 128);return bytes }
const end = [0,255,47,0]
// Actual bytes deliberately retain running status, unknown chunks/meta, both
// SysEx forms and expressive messages that the phrase schema cannot represent.
const conductor = [0,255,81,3,7,161,32, 0,255,88,4,4,2,24,8, 0x83,0x60,255,81,3,15,66,64, 0x83,0x60,255,47,0]
const expressive = [0,255,3,4,66,97,115,115, 0,0xb0,0,4, 0,0xc0,33,
  0,0xb0,64,127, 0,0xe0,0,65, 0,0xd0,60, 0,0xa0,60,70,
  0,0xf0,4,0x7e,0x7f,9,0xf7, 0,0xf7,2,0xf8,0xfa,
  0,0x90,60,100, 0,64,90, 0,67,80,
  0x83,0x60,0x90,60,0, 0,64,0, 0,67,0,
  0,255,0x7f,4,0xff,0xfe,0xfd,0xfc, ...end]

test('import, JSON save/reopen, harmony and note edits retain an expressive performance and opaque data', () => {
  const bytes = smf([conductor, expressive], { extra: [chunk('Xtra', Buffer.from([0,255,7]))] })
  const source = importMidiSource(bytes, { name: 'Performance experiment' })
  assert.deepEqual(Buffer.from(exportMidiSource(source)), bytes)
  const reopened = JSON.parse(JSON.stringify(source))
  const before = midiSourcePattern(reopened)
  assert.equal(before.seconds, 1.5)
  assert.equal(before.notes.length, 3)
  assert.ok(midiSourceHarmony(reopened, 0.25).candidates.includes('CM'))
  assert.deepEqual(before.notes.map(n => n.durationSeconds), [.5,.5,.5])
  const changed = editMidiSourceNote(reopened, { id: before.notes[0].id, pitch: 62, velocity: 111, start: 240, duration: 480 })
  const output = exportMidiSource(changed), reparsed = importMidiSource(output)
  const after = midiSourcePattern(reparsed)
  assert.equal(after.notes.find(n => n.pitch === 62).durationSeconds, .75)
  assert.equal(after.notes.find(n => n.pitch === 62).velocity, 111)
  const unrelated = performance => performance.events.filter(e => !(e.kind === 'meta' && e.type === 0x2f)).filter(e => e.kind !== 'channel' || ![0x80,0x90].includes(e.bytes[0]&0xf0))
    .map(({id,seconds,...e}) => e)
  assert.deepEqual(unrelated(after), unrelated(before))
  assert.equal(after.events.find(e => e.track===1 && e.kind==='meta' && e.type===0x2f).tick,720)
  assert.ok(Buffer.from(output).includes(Buffer.from('Xtra')))
  assert.deepEqual(midiSourcePattern(source).notes.map(n => n.pitch), [60,64,67])
  const independent = new JZZ.MIDI.SMF(output)
  assert.ok([...independent].filter(t => t.type === 'MTrk').flatMap(t => [...t]).some(e => e[0]===0x90 && e[1]===62 && e[2]===111))
  const bytesAfter = Buffer.from(output)
  assert.ok(bytesAfter.includes(chunk('MTrk', Buffer.from(conductor))))
})

test('format-2 patterns remain independent, SMPTE drop-frame time ignores tempo, and RIFF originals roundtrip', () => {
  const first = [0,0x90,60,100,...vlq(2400),0x80,60,45,...end]
  const second = [0,255,81,3,15,66,64,0,0x90,64,90,...vlq(2400),0x80,64,50,...end]
  const bytes = smf([first,second], { format:2, division:0xe350 }) // -29,80 ticks/frame
  const source = importMidiSource(bytes)
  assert.throws(() => midiSourcePattern(source), /pattern explicitly/)
  const one = midiSourcePattern(source,{pattern:0}), two = midiSourcePattern(source,{pattern:1})
  assert.equal(one.seconds,1.001);assert.equal(two.seconds,1.001)
  assert.deepEqual(one.notes.map(n=>n.pitch),[60]);assert.deepEqual(two.notes.map(n=>n.pitch),[64])
  const body = Buffer.concat([Buffer.from('RMID'), chunk('JUNK',Buffer.from([7,8]),true), chunk('data',bytes,true),...(bytes.length%2?[Buffer.from([0])]:[])])
  const riff = chunk('RIFF',body,true), wrapped = importMidiSource(riff)
  assert.deepEqual(Buffer.from(exportMidiSource(wrapped)),riff)
  const changed = editMidiSourceNote(wrapped,{id:two.notes[0].id,pitch:65,pattern:1})
  const after = importMidiSource(exportMidiSource(changed))
  assert.equal(midiSourcePattern(after,{pattern:1}).notes[0].pitch,65)
  assert.ok(Buffer.from(exportMidiSource(changed)).includes(chunk('JUNK',Buffer.from([7,8]),true)))
  assert.equal(midiSourcePattern(source,{pattern:1}).notes[0].pitch,64)
})

test('cross-track note ownership, note-off velocity and malformed input remain explicit', () => {
  const source = importMidiSource(smf([[0,0x90,60,100,...vlq(480),255,47,0], [...vlq(480),0x80,60,77,...end]]))
  const note = midiSourcePattern(source).notes[0]
  assert.equal(note.track,0);assert.equal(note.off,'1:0')
  const changed = editMidiSourceNote(source,{id:note.id,pitch:61})
  assert.ok(midiSourcePattern(changed).events.some(e => e.kind==='channel' && e.bytes.join() === '128,61,77'))
  const broken = smf([[0,0x90,60,100,0,255,1,0,0,60,0,...end]])
  assert.throws(() => importMidiSource(broken), /running status/)
  assert.throws(() => importMidiSource(smf([[0,0x90,60]])), /Truncated/)
  assert.throws(() => importMidiSource(smf([[...end,0,0x90,60,100]])), /follow/)
  const incomplete = importMidiSource(smf([[0,0x90,60,100,...end]]))
  assert.deepEqual(midiSourcePattern(incomplete).diagnostics,[{kind:'unclosed-note',event:'0:0'}])
  const malformed = structuredClone(source);malformed.changes=[{id:'0:0',tick:0,bytes:[0x90,128,100]}]
  assert.throws(()=>exportMidiSource(malformed),/channel message/)
  assert.deepEqual(Buffer.from(exportMidiSource(source)), Buffer.from(exportMidiSource(JSON.parse(JSON.stringify(source)))))
})

test('editing notes does not cap a large vendor payload or normalize an untouched track', () => {
  const payload=Buffer.alloc(140000,0x40)
  const data=Buffer.concat([Buffer.from([0,0xf0,...vlq(payload.length)]),payload,Buffer.from([0,0xf7,1,0xf7,0,0x90,60,100,1,0x80,60,0,...end])])
  const source=importMidiSource(smf([data],{format:0}))
  const note=midiSourcePattern(source).notes[0]
  const output=exportMidiSource(editMidiSourceNote(source,{id:note.id,pitch:62}))
  const after=midiSourcePattern(importMidiSource(output))
  assert.deepEqual(after.events.find(e=>e.kind==='sysex').data,[...payload])
  assert.equal(after.notes[0].pitch,62)
})
