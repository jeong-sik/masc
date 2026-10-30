import test from 'node:test'
import assert from 'node:assert/strict'
import JZZ from 'jzz'
import smf from 'jzz-midi-smf'
import {importMidiSource,midiSourcePattern,editMidiSourceNotes,editMidiSourceTempos,editMidiSourceMeters,exportMidiSource} from '../midi-source.mjs'
smf(JZZ)

test('successive native and inserted note/metadata patches retain array order, source bytes and the final event payloads',()=>{
  const file=new JZZ.MIDI.SMF(0,960)
  file.push(new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.smfBPM(120)).add(0,JZZ.MIDI.smfTimeSignature(4,4))
    .add(0,JZZ.MIDI.noteOn(0,60,80)).add(480,JZZ.MIDI.noteOff(0,60,45)).add(960,JZZ.MIDI.noteOn(0,64,90))
    .add(1440,JZZ.MIDI.noteOn(0,64,0)).add(3840,JZZ.MIDI.smfEndOfTrack()))
  const original=importMidiSource(file.toUint8Array()),notes=midiSourcePattern(original).notes
  let project=editMidiSourceNotes(original,notes.map(n=>({id:n.id,duration:240})))
  project=editMidiSourceNotes(project,[{kind:'insert',track:0,channel:0,pitch:67,velocity:99,start:1920,duration:240}])
  const added=midiSourcePattern(project).notes.find(n=>n.pitch===67),insertionOrder=project.insertions.map(e=>e.id)
  project=editMidiSourceNotes(project,[{id:added.id,velocity:77,duration:480},{id:notes[0].id,duration:360}])
  assert.deepEqual(project.insertions.map(e=>e.id),insertionOrder)
  assert.deepEqual(project.changes.map(e=>e.id),[notes[1].id,notes[1].off,notes[0].id,notes[0].off])
  project=editMidiSourceTempos(project,[{kind:'insert',tick:1920,value:90}])
  project=editMidiSourceMeters(project,[{kind:'insert',tick:1920,value:{numerator:3,denominator:4}}])
  const originalOrder=project.insertions.map(e=>e.id)
  project=editMidiSourceNotes(project,[{kind:'remove',id:added.id}])
  assert.deepEqual(project.insertions.map(e=>e.id),originalOrder.filter(id=>id!==added.id&&id!==added.off))
  assert.equal(project.original,original.original)
  const reopened=midiSourcePattern(importMidiSource(exportMidiSource(project)))
  assert.deepEqual(reopened.notes.map(n=>[n.pitch,n.duration,n.velocity]),[[60,360,80],[64,240,90]])
  assert.ok(reopened.events.some(e=>e.kind==='meta'&&e.type===0x51&&e.tick===1920))
  assert.ok(reopened.events.some(e=>e.kind==='meta'&&e.type===0x58&&e.tick===1920))
  assert.deepEqual(original.changes,[]);assert.deepEqual(original.insertions,[])
})
