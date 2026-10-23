import test from 'node:test'
import assert from 'node:assert/strict'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { newEditor, editorCommand } from '../sequencer-editor.mjs'
import { importMidiSource, midiSourcePattern } from '../midi-source.mjs'
import { projectMidi } from '../sequencer-files.mjs'
midiFiles(JZZ)
const command = (editor, line) => editorCommand(editor, line).editor
const symbols = 'G7 Em7 Cmaj7 G7#11'
// Independently enumerated dictionary path: motion31, versus best greedy35.
const expected = [[53,57,59,64],[55,59,62,66],[52,55,59,62],[53,57,61,65]]
function source({ smpte = false, format = 1, channels = [4], portChange = false, occupied = false } = {}) {
  const file = smpte ? new JZZ.MIDI.SMF(format,29,80) : new JZZ.MIDI.SMF(format,1001)
  const conductor = new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.smfBPM(120))
    .add(1000,JZZ.MIDI.smfBPM(81)).add(20000,JZZ.MIDI.smfEndOfTrack())
  const backing = new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.smfMidiPort(occupied.port ?? 3))
    .add(0,JZZ.MIDI.noteOn(0,24,77)).add(500,JZZ.MIDI.noteOff(0,24,45))
  if (occupied) backing.add(occupied.start ?? 0,JZZ.MIDI.noteOn(occupied.channel ?? 4,53,77))
    .add((occupied.start ?? 0)+(occupied.duration ?? 1000),JZZ.MIDI.noteOff(occupied.channel ?? 4,53,45))
  backing.add(20000,JZZ.MIDI.smfEndOfTrack())
  const target = new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.smfMidiPort(3))
    .add(0,JZZ.MIDI.smfText('Original source expression'))
  for (const channel of channels) target.add(0,JZZ.MIDI.program(channel,33))
    .add(0,JZZ.MIDI.control(channel,64,127)).add(100,JZZ.MIDI.pitchBend(channel,9001))
  if (portChange) target.add(200,JZZ.MIDI.smfMidiPort(7))
  target.add(20000,JZZ.MIDI.smfEndOfTrack())
  file.push(conductor); file.push(backing); file.push(target)
  return importMidiSource(file.toUint8Array())
}
const target = project => command(newEditor(project),'track 3')

for (const smpte of [false,true]) test(`imported ${smpte ? 'drop-frame SMPTE' : 'PPQ1001'} composes the global path in native fractional units and one undo`, () => {
  const original=source({smpte}), editor=target(original), before=structuredClone(editor)
  const start=smpte ? '8.3' : '1/7', duration=smpte ? '1/5' : '1/7'
  const startTick=smpte ? 664 : 143, length=smpte ? 16 : 143
  const next=command(editor,`progression-led ${start} ${duration} rootless C3 C5 ${symbols}`)
  const added=next.performance.notes.filter(n=>n.track===2)
  assert.deepEqual(Array.from({length:4},(_,i)=>added.filter(n=>n.start===startTick+i*length).map(n=>n.pitch)),expected)
  assert.ok(added.every(n=>n.duration===length && n.velocity===96 && n.channel===4 && n.port===3))
  const native = events => events.map(({seconds,...event})=>event)
  assert.deepEqual(native(next.performance.events.filter(e=>editor.performance.events.some(old=>old.id===e.id))),native(editor.performance.events))
  assert.equal(next.project.original,original.original)
  assert.equal(next.undo.length,1)
  assert.deepEqual(command(next,'undo').project,original)
  assert.deepEqual(command(command(next,'undo'),'redo').project,next.project)
  assert.deepEqual(editor,before)
  const exported=midiSourcePattern(importMidiSource(projectMidi(next.project)))
  assert.deepEqual(exported.timing,editor.performance.timing)
  assert.deepEqual(exported.notes.filter(n=>n.track===2).map(n=>[n.start,n.duration,n.pitch,n.velocity,n.channel,n.port]),
    added.map(n=>[n.start,n.duration,n.pitch,n.velocity,n.channel,n.port]))
})

test('channel and independent pattern choices are explicit and leave other source tracks byte-identical', () => {
  const original=source({channels:[4,5]})
  const editor=target(original), before=structuredClone(editor)
  assert.throws(()=>command(editor,`progression-led 1 1 rootless C3 C5 ${symbols}`),/channel/)
  assert.deepEqual(editor,before)
  const next=command(command(editor,'channel 6'),`progression-led 1 1 rootless C3 C5 ${symbols}`)
  assert.ok(next.performance.notes.filter(n=>n.track===2).every(n=>n.channel===5))
  const originalTracks=new JZZ.MIDI.SMF(projectMidi(original)), tracks=new JZZ.MIDI.SMF(projectMidi(next.project))
  assert.equal(tracks[0].dump(),originalTracks[0].dump()); assert.equal(tracks[1].dump(),originalTracks[1].dump())
  let independent=newEditor(source({format:2}))
  assert.throws(()=>command(independent,`progression-led 1 1 rootless C3 C5 ${symbols}`),/pattern/)
  independent=command(independent,'pattern 3')
  const chosen=command(independent,`progression-led 1 1 rootless C3 C5 ${symbols}`)
  const chosenTracks=new JZZ.MIDI.SMF(projectMidi(chosen.project)), baseline=new JZZ.MIDI.SMF(projectMidi(independent.project))
  assert.equal(chosenTracks[0].dump(),baseline[0].dump()); assert.equal(chosenTracks[1].dump(),baseline[1].dump())
})

test('invalid voicings, fractional ticks, unsafe timing, drum channels and routing conflicts never publish edits or history', () => {
  for (const [project,lines] of [
    [source(),['progression-led 0 0 close C3 C5 Cmaj7','progression-led 0 1/3 close C3 C5 Cmaj7',
      'progression-led 0 1 close C5 C3 Cmaj7','progression-led 0 1 rootless C3 C5 Cmaj7/E',
      'progression-led 0 1 close C3 C5 Cmaj7 Dm','progression-led 0 1 unknown C3 C5 Cmaj7',
      'progression-led 0 1 close C3 C5 NotAChord','progression-led 9007199254740991/1001 1 close C3 C5 Cmaj7']],
    [source({channels:[9]}),[`progression-led 1 1 rootless C3 C5 ${symbols}`]],
    [source({portChange:true}),[`progression-led 0 1 rootless C3 C5 ${symbols}`]],
    [source({occupied:true}),[`progression-led 0 1 rootless C3 C5 ${symbols}`]],
  ]) {
    const editor=target(project), before=structuredClone(editor)
    for (const line of lines) { assert.throws(()=>command(editor,line),line); assert.deepEqual(editor,before) }
  }
})

test('point collisions and same-tick pairing changes refuse while independent ports/channels remain editable', () => {
  for (const start of [0,1001]) {
    const blocked=target(source({occupied:{start,duration:0}})), before=structuredClone(blocked)
    // At the release boundary the original point precedes the inserted off:
    // preserving that order cannot preserve the new note's release identity.
    assert.throws(()=>command(blocked,`progression-led 0 1 rootless C3 C5 ${symbols}`),/overlapping|pairing/)
    assert.deepEqual(blocked,before)
  }
  for (const occupied of [{port:4},{channel:5}]) {
    const editor=target(source({occupied})), next=command(editor,`progression-led 0 1 rootless C3 C5 ${symbols}`)
    assert.equal(next.performance.notes.filter(n=>n.track===2).length,16)
    assert.deepEqual(next.performance.notes.filter(n=>n.track===1).map(({seconds,durationSeconds,...n})=>n),
      editor.performance.notes.filter(n=>n.track===1).map(({seconds,durationSeconds,...n})=>n))
  }
})
