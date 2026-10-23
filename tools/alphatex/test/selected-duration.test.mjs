import test from 'node:test'
import assert from 'node:assert/strict'
import {mkdtemp,rm} from 'node:fs/promises'
import {tmpdir} from 'node:os'
import {join} from 'node:path'
import {Worker} from 'node:worker_threads'
import {once} from 'node:events'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import {newEditor,editorCommand,selectedNotes} from '../sequencer-editor.mjs'
import {importMidiSource,midiSourcePattern} from '../midi-source.mjs'
import {saveProject,loadProject,projectMidi} from '../sequencer-files.mjs'
import {phraseDocument} from '../phrase-arrangement.mjs'
midiFiles(JZZ)
const command=(editor,line)=>editorCommand(editor,line).editor
const commands=(editor,lines)=>lines.reduce(command,editor)
const native=events=>events.map(({seconds,durationSeconds,...event})=>event)

function source({smpte=false,point=false,portChange=false}={}) {
  const file=smpte?new JZZ.MIDI.SMF(1,29,80):new JZZ.MIDI.SMF(1,1001)
  const track=new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.smfMidiPort(3))
    .add(0,JZZ.MIDI.control(0,1,77)).add(0,JZZ.MIDI.smfBPM(120))
    .add(0,JZZ.MIDI.noteOn(0,60,80)).add(143,JZZ.MIDI.noteOff(0,60,45))
    .add(1001,JZZ.MIDI.noteOn(0,64,99)).add(point?1001:1287,JZZ.MIDI.noteOn(0,64,0))
    .add(2002,JZZ.MIDI.noteOn(1,48,70)).add(3003,JZZ.MIDI.noteOff(1,48,12))
  if(portChange)track.add(200,JZZ.MIDI.smfMidiPort(7))
  file.push(track.add(4004,JZZ.MIDI.smfEndOfTrack()))
  file.push(new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.noteOn(4,72,55)).add(1001,JZZ.MIDI.noteOff(4,72,9)).add(4004,JZZ.MIDI.smfEndOfTrack()))
  return importMidiSource(file.toUint8Array())
}

test('phrase absolute and relative gates preserve onsets, dynamics, selection, clipboard and other tracks with one undo each',async()=>{
  const editor=commands(newEditor(),['note C4 0 0.5 70','note E4 1 1 99','note G4 3 1 80',
    'track-add Bass','note C2 0 2 50','track 1','select-notes 0 2','copy-notes'])
  const before=structuredClone(editor)
  const longer=command(editor,'duration-add-notes 1/3')
  assert.deepEqual(selectedNotes(longer).map(n=>[n.start,n.duration,n.velocity]),[[0,800,70],[960,1280,99]])
  assert.deepEqual(longer.noteSelection,editor.noteSelection);assert.deepEqual(longer.noteClipboard,editor.noteClipboard)
  assert.deepEqual(longer.project.tracks[1],editor.project.tracks[1])
  assert.deepEqual(longer.project.tracks[0].notes[2],editor.project.tracks[0].notes[2])
  assert.equal(longer.undo.length,editor.undo.length+1)
  const short=command(longer,'duration-notes 1/3')
  assert.deepEqual(selectedNotes(short).map(n=>n.duration),[320,320])
  assert.deepEqual(command(short,'undo').project,longer.project)
  assert.deepEqual(command(command(short,'undo'),'redo').project,short.project)
  assert.deepEqual(command(longer,'undo').project,editor.project)
  assert.deepEqual(editor,before)
  const directory=await mkdtemp(join(tmpdir(),'masc-duration-'))
  try {
    const path=join(directory,'phrase.json');await saveProject(path,short.project)
    const reopened=(await loadProject(path)).project;assert.deepEqual(reopened,short.project)
    const exported=midiSourcePattern(importMidiSource(projectMidi(reopened)))
    assert.deepEqual(exported.notes.filter(n=>n.track===1).map(n=>[n.start,n.duration,n.velocity]),[[0,320,70],[960,320,99],[2880,960,80]])
  }finally{await rm(directory,{recursive:true,force:true})}
})

for(const smpte of [false,true])test(`selected ${smpte?'SMPTE':'PPQ1001'} gates retain release identity/form, controllers and the original clock through export`,()=>{
  const original=source({smpte}),editor=commands(newEditor(original),['channel 1','select-all'])
  const next=command(editor,`duration-add-notes ${smpte?'1/5':'1/7'}`),delta=smpte?16:143
  assert.deepEqual(selectedNotes(next).map(n=>[n.start,n.duration,n.velocity]),[[0,143+delta,80],[1001,286+delta,99]])
  const releases=new Set(selectedNotes(editor).map(n=>n.off))
  assert.deepEqual(native(next.performance.events.filter(e=>!releases.has(e.id))),native(editor.performance.events.filter(e=>!releases.has(e.id))))
  assert.deepEqual(selectedNotes(next).map(n=>[n.id,n.off]),selectedNotes(editor).map(n=>[n.id,n.off]))
  const exported=midiSourcePattern(importMidiSource(projectMidi(next.project))),events=new Map(exported.events.map(e=>[e.id,e]))
  assert.deepEqual(exported.notes.filter(n=>n.track===0&&n.channel===0).map(n=>[n.start,n.duration,n.velocity,events.get(n.off).bytes]),
    [[0,143+delta,80,[0x80,60,45]],[1001,286+delta,99,[0x90,64,0]]])
  assert.deepEqual(exported.timing,editor.performance.timing)
  assert.equal(next.project.original,original.original)
  assert.deepEqual(command(next,'undo').project,editor.project)
  const zero=command(editor,'duration-notes 0')
  assert.ok(selectedNotes(zero).every(n=>n.duration===0))
  const grown=command(zero,`duration-add-notes ${smpte?'1/5':'1/7'}`)
  assert.ok(selectedNotes(grown).every(n=>n.duration===delta))
})

test('new paired, point and masked unclosed collisions refuse without changing any editor state',()=>{
  for(const mode of ['paired','point','unclosed']) {
    const file=new JZZ.MIDI.SMF(0,1000),track=new JZZ.MIDI.SMF.MTrk()
    track.add(0,JZZ.MIDI.noteOn(0,60,80)).add(200,JZZ.MIDI.noteOff(0,60,45))
    if(mode==='unclosed')track.add(100,JZZ.MIDI.noteOn(0,60,77)).add(300,JZZ.MIDI.noteOn(0,60,70))
    else track.add(300,JZZ.MIDI.noteOn(0,60,77)).add(mode==='point'?300:400,JZZ.MIDI.noteOff(0,60,12))
    file.push(track.add(2000,JZZ.MIDI.smfEndOfTrack()))
    const editor=command(newEditor(importMidiSource(file.toUint8Array())),'select-notes 0 0.1'),before=structuredClone(editor)
    assert.throws(()=>command(editor,'duration-notes 0.5'),/overlapping/);assert.deepEqual(editor,before)
  }
  const editor=commands(newEditor(),['note C4 0 1','note C4 2 1','select-notes 0 1'])
  const before=structuredClone(editor);assert.throws(()=>command(editor,'duration-add-notes 2'),/overlapping/);assert.deepEqual(editor,before)
})

test('phrase bounds, nonintegral/unsafe gates and source-port moves refuse the whole transaction',()=>{
  for(const editor of [commands(newEditor(),['note C4 15 1','select-all']),commands(newEditor(source()),['channel 1','select-all'])]) {
    const before=structuredClone(editor)
    for(const line of ['duration-notes -1','duration-notes NaN','duration-notes 0.000001','duration-notes 1 extra',
      'duration-add-notes -10','duration-add-notes Infinity','duration-add-notes 9007199254740991']) {
      assert.throws(()=>command(editor,line),line);assert.deepEqual(editor,before)
    }
  }
  const phrase=commands(newEditor(),['note C4 15 1','select-all']),before=structuredClone(phrase)
  for(const line of ['duration-notes 0','duration-add-notes 1']){assert.throws(()=>command(phrase,line));assert.deepEqual(phrase,before)}
  const routed=commands(newEditor(source({portChange:true})),['channel 1','select-notes 0 1/7']),original=structuredClone(routed)
  assert.throws(()=>command(routed,'duration-notes 1'),/source port/);assert.deepEqual(routed,original)
  assert.throws(()=>command(newEditor(),'duration-notes 1/3'),/Select notes/)
})

test('release-boundary raw attacks follow actual cross-track event order even with masked diagnostics',()=>{
  for(const masked of [false,true])for(const rawFirst of [false,true])for(const line of ['duration-notes 0.41','duration-add-notes 0.11']) {
    const file=new JZZ.MIDI.SMF(1,1000),paired=new JZZ.MIDI.SMF.MTrk()
      .add(140,JZZ.MIDI.noteOn(0,60,80)).add(440,JZZ.MIDI.noteOff(0,60,45)).add(2000,JZZ.MIDI.smfEndOfTrack())
    const raw=new JZZ.MIDI.SMF.MTrk()
    if(masked)raw.add(300,JZZ.MIDI.noteOn(0,60,70))
    raw.add(550,JZZ.MIDI.noteOn(0,60,77)).add(2000,JZZ.MIDI.smfEndOfTrack())
    file.push(rawFirst?raw:paired);file.push(rawFirst?paired:raw)
    const editor=command(newEditor(importMidiSource(file.toUint8Array())),'select-all'),before=structuredClone(editor)
    if(rawFirst){assert.throws(()=>command(editor,line),/overlapping/);assert.deepEqual(editor,before)}
    else {
      const next=command(editor,line),exported=midiSourcePattern(importMidiSource(projectMidi(next.project)))
      assert.equal(exported.notes[0].duration,410)
      assert.deepEqual(command(next,'undo').project,editor.project)
    }
  }
})

test('actual harmony and arrangement workers consume edited source release times and retain portable editable gates',async()=>{
  const editor=commands(newEditor(source()),['channel 1','select-all','duration-notes 1/7'])
  const worker=new Worker(new URL('../sequencer-worker.mjs',import.meta.url))
  const directory=await mkdtemp(join(tmpdir(),'masc-duration-flow-'));let id=0
  const request=async options=>{
    const reply=once(worker,'message');worker.postMessage({id:++id,project:editor.project,cancel:new SharedArrayBuffer(4),options})
    const result=(await reply)[0];assert.equal(result.ok,true,result.error);return result.result
  }
  try {
    const harmony=await request({format:'harmony',scope:{kind:'track',id:'0',channel:0}})
    assert.deepEqual(harmony.rows.map(row=>[row.start,row.end,row.pitches]),[[0,143,[60]],[143,1001,[]],[1001,1144,[64]],[1144,4004,[]]])
    const arranged=await request({format:'arrangement'})
    assert.deepEqual(phraseDocument(arranged.project,arranged.asset),editor.project)
    const path=join(directory,'arrangement.json');await saveProject(path,arranged.project)
    const reopened=(await loadProject(path)).project
    assert.deepEqual(phraseDocument(reopened,arranged.asset),editor.project)
    const exported=midiSourcePattern(importMidiSource(projectMidi(phraseDocument(reopened,arranged.asset))))
    assert.deepEqual(exported.notes.filter(n=>n.track===0&&n.channel===0).map(n=>n.duration),[143,143])
  }finally{await worker.terminate();await rm(directory,{recursive:true,force:true})}
})
