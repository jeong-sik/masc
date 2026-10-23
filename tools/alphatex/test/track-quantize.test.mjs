import test from 'node:test'
import assert from 'node:assert/strict'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { newEditor, editorCommand } from '../sequencer-editor.mjs'
import { importMidiSource, midiSourcePattern } from '../midi-source.mjs'
import { projectMidi } from '../sequencer-files.mjs'
import { quantizeTick } from '../note-quantize.mjs'
midiFiles(JZZ)
const command = (editor, line) => editorCommand(editor, line).editor
const native = notes => notes.map(({ seconds, durationSeconds, ...note }) => note)

function source(tracks, { format = 1, smpte = false } = {}) {
  const file = smpte ? new JZZ.MIDI.SMF(format,25,80) : new JZZ.MIDI.SMF(format,1000)
  for (const { notes, port = 0, channel = 0, portChange = false } of tracks) {
    const track = new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.smfMidiPort(port))
      .add(0,JZZ.MIDI.control(channel,1,77))
    if (portChange) track.add(100,JZZ.MIDI.smfMidiPort(port + 1))
    for (const [start,duration,pitch = 60,velocity = 80,release = 45] of notes) {
      track.add(start,JZZ.MIDI.noteOn(channel,pitch,velocity))
        .add(start + duration, release === null ? JZZ.MIDI.noteOn(channel,pitch,0) : JZZ.MIDI.noteOff(channel,pitch,release))
    }
    file.push(track.add(4000,JZZ.MIDI.smfEndOfTrack()))
  }
  return newEditor(importMidiSource(file.toUint8Array()))
}

test('whole-track MIDI quantize refuses newly overlapping held or point notes without publishing history', () => {
  for (const notes of [[[140,100],[360,300]],[[140,0],[160,0]]]) {
    const editor = source([{notes}]), before = structuredClone(editor)
    assert.throws(() => command(editor,'quantize 0.25'), /overlapping/)
    assert.deepEqual(editor,before)
    assert.throws(() => command(command(editor,'select-all'),'quantize-notes 0.25'), /overlapping/)
  }
})

test('whole-track quantize checks unchanged source tracks sharing port/channel/key, keeping independent routes editable', () => {
  for (const [port,channel] of [[0,0],[1,0],[0,1]]) {
    const editor = source([{notes:[[140,200]]},{notes:[[360,300]],port,channel}])
    const before = structuredClone(editor)
    if (port === 0 && channel === 0) {
      assert.throws(() => command(editor,'quantize 0.25'), /overlapping/)
      assert.deepEqual(editor,before)
    } else {
      const next = command(editor,'quantize 0.25')
      assert.equal(next.performance.notes[0].start,250)
      assert.deepEqual(native(next.view.tracks[1].notes),native(editor.view.tracks[1].notes))
      assert.deepEqual(command(next,'undo').project,editor.project)
    }
  }
})

test('original MIDI overlap remains supported and a separate SMF2 pattern cannot create a false collision', () => {
  const editor = source([{notes:[[140,300],[360,300]]}])
  const next = command(editor,'quantize 0.25')
  assert.deepEqual(next.performance.notes.map(n => [n.start,n.duration]),[[250,300],[250,300]])
  assert.deepEqual(command(next,'undo').project,editor.project)
  let independent = source([{notes:[[140,200]]},{notes:[[360,300]]}],{format:2})
  assert.throws(()=>command(independent,'quantize 0.25'),/Choose a MIDI pattern/)
  independent = command(independent,'pattern 1')
  const projected = command(independent,'quantize 0.25')
  assert.equal(projected.performance.notes[0].start,250)
  const other = midiSourcePattern(importMidiSource(projectMidi(projected.project)),{pattern:1})
  assert.deepEqual(other.notes.map(n=>[n.start,n.duration]),[[360,300]])
})

for (const smpte of [false,true]) test(`track and select-all quantize agree in ${smpte ? 'SMPTE frames' : 'PPQ beats'} and retain real exported release/controller data`, () => {
  const editor = source([{notes:[[130,300,60,80,45],[760,250,64,99,null]]} ,
    {notes:[[0,1000,72,55,9]],channel:4}],{smpte})
  const grid = smpte ? '1' : '0.25'
  const next = command(editor,`quantize ${grid}`)
  const selected = command(command(editor,'select-all'),`quantize-notes ${grid}`)
  assert.deepEqual(next.project,selected.project)
  assert.equal(next.undo.length,editor.undo.length + 1)
  assert.deepEqual(command(next,'undo').project,editor.project)
  assert.deepEqual(command(command(next,'undo'),'redo').project,next.project)
  const exported = midiSourcePattern(importMidiSource(projectMidi(next.project)))
  const expected = smpte ? [[160,300,80],[800,250,99]] : [[250,300,80],[750,250,99]]
  assert.deepEqual(exported.notes.filter(n=>n.track===0).map(n=>[n.start,n.duration,n.velocity]),expected)
  const events = new Map(exported.events.map(e=>[e.id,e]))
  assert.deepEqual(exported.notes.filter(n=>n.track===0).map(n=>events.get(n.off).bytes),[[0x80,60,45],[0x90,64,0]])
  assert.deepEqual(exported.timing,editor.performance.timing)
  assert.deepEqual(exported.events.filter(e=>e.kind==='channel' && e.bytes[0]===0xb0).map(e=>e.bytes),[[0xb0,1,77]])
  assert.deepEqual(native(next.view.tracks[1].notes),native(editor.view.tracks[1].notes))
  assert.equal(next.project.original,editor.project.original)
})

test('phrase track quantize and selected quantize share half-up rounding and leave the other track intact', () => {
  let editor = newEditor()
  for (const line of ['note C4 0.125 0.125 70','note E4 0.8 0.5 99','track-add Bass','note C2 1 1 50','track 1']) editor=command(editor,line)
  const next = command(editor,'quantize 0.25')
  const selected = command(command(editor,'select-all'),'quantize-notes 0.25')
  assert.deepEqual(next.project,selected.project)
  assert.deepEqual(next.project.tracks[0].notes.map(n=>[n.start,n.duration,n.velocity]),[[240,120,70],[720,480,99]])
  assert.deepEqual(next.project.tracks[1],editor.project.tracks[1])
})

test('track quantize retains source-port refusal and invalid input remains transactional', () => {
  const editor = source([{notes:[[130,300]],portChange:true}]),before=structuredClone(editor)
  assert.throws(()=>command(editor,'quantize 1'),/source port/)
  for (const value of ['0','-1','NaN','Infinity','0.0001','0.25 extra']) assert.throws(()=>command(editor,`quantize ${value}`))
  assert.deepEqual(editor,before)
})

test('native-tick half-up rounding is exact at safe-integer limits and rejects an unsafe snapped result', () => {
  assert.equal(quantizeTick(9007199254740991,3),9007199254740990)
  assert.equal(quantizeTick(125,250),250)
  assert.throws(()=>quantizeTick(9007199254740991,2))
  for (const [tick,grid] of [[-1,1],[1,0],[1,1.5],[NaN,1],[1,Infinity]]) assert.throws(()=>quantizeTick(tick,grid))
})
