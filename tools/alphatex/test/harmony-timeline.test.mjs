import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { harmonyTimeline, PPQ } from '../sequencer-project.mjs'
import { newEditor, editorCommand } from '../sequencer-editor.mjs'
import { importMidiSource } from '../midi-source.mjs'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
midiFiles(JZZ)

test('harmonic changes keep overlapping shared keys, inversions and rests without attack-window heuristics', () => {
  const notes = [55,60,64,71].map(pitch => ({ pitch, start: 0, duration: 4 * PPQ }))
  notes.push({ pitch: 60, start: PPQ, duration: PPQ })
  notes.push(...[62,65,69,72].map(pitch => ({ pitch, start: 4 * PPQ, duration: 4 * PPQ })))
  const before = structuredClone(notes), rows = harmonyTimeline(notes, 12 * PPQ)
  assert.deepEqual(rows.map(row => [row.start, row.end, row.pitches]),
    [[0,4*PPQ,[55,60,64,71]],[4*PPQ,8*PPQ,[62,65,69,72]],[8*PPQ,12*PPQ,[]]])
  assert.ok(rows[0].candidates.includes('Cmaj7/G'))
  assert.ok(rows[1].candidates.includes('Dm7'))
  assert.deepEqual(notes, before)
})

test('instant source notes remain point events while surrounding intervals use half-open key durations', () => {
  const rows = harmonyTimeline([{ pitch: 60, start: 0, duration: 4 }, { pitch: 60, start: 4, duration: 4 },
    { pitch: 64, start: 4, duration: 0 }, { pitch: 67, start: 8, duration: 0 }], 8)
  assert.deepEqual(rows.map(row => [row.kind,row.start,row.end,row.pitches]),
    [['span',0,4,[60]],['point',4,4,[60,64]],['span',4,8,[60]],['point',8,8,[67]]])
  assert.deepEqual(harmonyTimeline([], 0), [])
})

async function withWorker(run) {
  const worker = new Worker(new URL('../sequencer-worker.mjs', import.meta.url))
  let serial = 0
  async function job(project, scope, { pattern, cancel = new Int32Array(new SharedArrayBuffer(4)) } = {}) {
    const result = once(worker, 'message')
    worker.postMessage({ id: ++serial, project, cancel: cancel.buffer, options: { format: 'harmony', scope, pattern } })
    return (await result)[0]
  }
  try { await run(job) } finally { await worker.terminate() }
}

test('actual worker analyzes audible phrase mix or one chosen track without modifying the document', async () => {
  let editor = newEditor()
  for (const line of ['chord Cmaj7 0 4','track-add Bass','note C2 0 8','mute']) editor = editorCommand(editor,line).editor
  const project = editor.project, before = structuredClone(project)
  await withWorker(async job => {
    const mix = await job(project,{kind:'mix'})
    assert.equal(mix.ok,true)
    assert.deepEqual(mix.result.rows[0].pitches,[60,64,67,71])
    const bass = await job(project,{kind:'track',id:project.tracks[1].id})
    assert.deepEqual(bass.result.rows[0].pitches,[36])
    assert.equal((await job(project,{kind:'track',id:'absent'})).ok,false)
    const cancel = new Int32Array(new SharedArrayBuffer(4));Atomics.store(cancel,0,1)
    assert.equal((await job(project,{kind:'mix'},{cancel})).ok,false)
  })
  assert.deepEqual(project,before)
})

test('actual worker preserves original MIDI pattern, channel scope and native tick axis', async () => {
  const file = new JZZ.MIDI.SMF(2,1001)
  file.push(new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.noteOn(0,48,90)).add(1001,JZZ.MIDI.noteOff(0,48)).add(1001,JZZ.MIDI.smfEndOfTrack()))
  const track = new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.smfBPM(60)).add(0,JZZ.MIDI.control(1,64,127))
  for (const pitch of [60,64,67,71]) track.add(0,JZZ.MIDI.noteOn(1,pitch,90)).add(2002,JZZ.MIDI.noteOff(1,pitch,45))
  track.add(0,JZZ.MIDI.noteOn(2,36,100)).add(3003,JZZ.MIDI.noteOff(2,36)).add(4004,JZZ.MIDI.smfEndOfTrack());file.push(track)
  const source = importMidiSource(file.toUint8Array()), before = structuredClone(source)
  await withWorker(async job => {
    assert.equal((await job(source,{kind:'mix'})).ok,false)
    const result = await job(source,{kind:'track',id:'1',channel:1},{pattern:1})
    assert.equal(result.ok,true)
    assert.deepEqual(result.result.axis,{per:1001,label:'beats'})
    assert.deepEqual(result.result.rows.map(row=>[row.start,row.end,row.pitches]),[[0,2002,[60,64,67,71]],[2002,4004,[]]])
    assert.ok(result.result.rows[0].candidates.includes('Cmaj7'))
  })
  assert.deepEqual(source,before)
  const smpteBytes = Buffer.from(file.toUint8Array()); smpteBytes.writeUInt16BE(0xe350,12) // -29, 80 ticks/frame
  const smpte = importMidiSource(smpteBytes), smpteBefore = structuredClone(smpte)
  await withWorker(async job => {
    const result = await job(smpte,{kind:'track',id:'1',channel:1},{pattern:1})
    assert.equal(result.ok,true)
    assert.deepEqual(result.result.axis,{per:80,label:'frames'})
    assert.deepEqual(result.result.rows.map(row=>[row.start,row.end,row.pitches]),[[0,2002,[60,64,67,71]],[2002,4004,[]]])
  })
  assert.deepEqual(smpte,smpteBefore)
})
