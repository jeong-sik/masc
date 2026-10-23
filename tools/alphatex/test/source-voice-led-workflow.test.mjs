import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { newEditor, editorCommand } from '../sequencer-editor.mjs'
import { importMidiSource, midiSourcePattern } from '../midi-source.mjs'
import { projectMidi, saveProject, loadProject } from '../sequencer-files.mjs'
import { loadArrangement } from '../arrangement-files.mjs'
import { phraseDocument } from '../phrase-arrangement.mjs'
midiFiles(JZZ)
const command=(editor,line)=>editorCommand(editor,line).editor
const expected=[[53,57,59,64],[55,59,62,66],[52,55,59,62],[53,57,61,65]]

test('actual workers analyze, hand off and reopen a newly composed expressive MIDI source without losing provenance',async()=>{
  const directory=await mkdtemp(join(tmpdir(),'masc-source-progression-'))
  const sequence=new Worker(new URL('../sequencer-worker.mjs',import.meta.url))
  const arrangement=new Worker(new URL('../arrangement-worker.mjs',import.meta.url))
  let id=0
  const request=async(worker,job)=>{
    const reply=once(worker,'message'); worker.postMessage({...job,id:++id})
    const value=(await reply)[0]; assert.equal(value.ok,true,value.error); return value.result
  }
  try {
    const file=new JZZ.MIDI.SMF(1,1001)
    file.push(new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.smfBPM(120)).add(1001,JZZ.MIDI.smfBPM(81)).add(12012,JZZ.MIDI.smfEndOfTrack()))
    file.push(new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.smfMidiPort(3))
      .add(0,JZZ.MIDI.program(4,33)).add(0,JZZ.MIDI.control(4,64,127))
      .add(100,JZZ.MIDI.pitchBend(4,9001)).add(200,JZZ.MIDI([0xf0,0x7d,1,0xf7]))
      .add(10010,JZZ.MIDI.noteOn(4,24,77)).add(11011,JZZ.MIDI.noteOff(4,24,45))
      .add(12012,JZZ.MIDI.smfEndOfTrack()))
    const opaque=Buffer.from('5874726100000003616263','hex')
    const bytes=Buffer.concat([Buffer.from(file.toUint8Array()),opaque])
    const originalPath=join(directory,'original.mid'); await writeFile(originalPath,bytes)
    const source=importMidiSource(bytes), editor=command(newEditor(source),'track 2')
    const changed=command(editor,'progression-led 1/7 1 rootless C3 C5 G7 Em7 Cmaj7 G7#11')
    const path=join(directory,'experiment.json'); await saveProject(path,changed.project)
    const reopened=(await loadProject(path)).project
    assert.deepEqual(reopened,changed.project)
    assert.deepEqual(await readFile(originalPath),bytes)
    assert.deepEqual(Buffer.from(reopened.original,'base64'),bytes)
    const exported=Buffer.from(projectMidi(reopened))
    assert.ok(exported.subarray(-opaque.length).equals(opaque))
    const exportedPerformance=midiSourcePattern(importMidiSource(exported))
    const native=events=>events.map(({id,order,seconds,...event})=>event)
    assert.deepEqual(native(exportedPerformance.events.filter(e=>e.kind==='sysex'||e.kind==='meta'&&[0x51,0x21].includes(e.type)||e.kind==='channel'&&[0xb4,0xc4,0xe4].includes(e.bytes[0]))),
      native(editor.performance.events.filter(e=>e.kind==='sysex'||e.kind==='meta'&&[0x51,0x21].includes(e.type)||e.kind==='channel'&&[0xb4,0xc4,0xe4].includes(e.bytes[0]))))
    assert.ok(exportedPerformance.events.some(e=>e.bytes?.join()==='132,24,45'))
    const cancel=new SharedArrayBuffer(4)
    const analysis=await request(sequence,{project:reopened,cancel,options:{format:'harmony',scope:{kind:'track',id:'1',channel:4}}})
    assert.deepEqual(analysis.axis,{per:1001,label:'beats'})
    for (const [index,pitches] of expected.entries()) {
      const row=analysis.rows.find(row=>row.start===143+index*1001)
      assert.deepEqual(row.pitches,pitches); assert.ok(row.candidates.length)
    }
    const seed=await request(sequence,{project:reopened,cancel,options:{format:'arrangement'}})
    assert.deepEqual(phraseDocument(seed.project,seed.asset),reopened)
    const arranged=join(directory,'backing','song.json')
    await request(arrangement,{kind:'save',project:seed.project,path:arranged,revision:null,sourceRoot:directory})
    const portable=(await loadArrangement(arranged)).project
    assert.deepEqual(phraseDocument(portable,seed.asset),reopened)
    assert.deepEqual(Buffer.from(projectMidi(phraseDocument(portable,seed.asset))),exported)
    assert.deepEqual(command(changed,'undo').project,source)
    assert.deepEqual(command(command(changed,'undo'),'redo').project,reopened)
  } finally { await Promise.all([sequence.terminate(),arrangement.terminate()]); await rm(directory,{recursive:true,force:true}) }
})
