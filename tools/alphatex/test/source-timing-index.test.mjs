import test from 'node:test'
import assert from 'node:assert/strict'
import JZZ from 'jzz'
import smf from 'jzz-midi-smf'
import {importMidiSource,midiSourcePattern,editMidiSourceNotes} from '../midi-source.mjs'
import {assertMidiTimingOrder} from '../note-overlap.mjs'
smf(JZZ)

// Deliberately exhaustive specification, independent of the indexed range
// representation. Exercise real parsed/candidate MIDI rather than tree internals.
function newlyEnclosed(before,after) {
  const previous=new Map(before.events.map((event,index)=>[event.id,index]))
  const current=new Map(after.events.map((event,index)=>[event.id,index]))
  const notes=new Map(after.notes.map(note=>[note.id,note]))
  const oldDiagnostics=new Set(before.diagnostics.filter(d=>d.kind==='overlapping-key').map(d=>d.event))
  if(after.diagnostics.some(d=>d.kind==='overlapping-key'&&!oldDiagnostics.has(d.event)))return true
  for(const note of before.notes)for(const attack of before.events) {
    if(attack.kind!=='channel'||(attack.bytes[0]&0xf0)!==0x90||!attack.bytes[2]
      ||attack.port!==note.port||(attack.bytes[0]&15)!==note.channel||attack.bytes[1]!==note.pitch)continue
    const edited=notes.get(note.id)
    if(!edited)continue
    const inside=(ranks,interval)=>ranks.get(interval.id)<ranks.get(attack.id)&&ranks.get(attack.id)<ranks.get(interval.off)
    if(inside(current,edited)&&!inside(previous,note))return true
  }
  return false
}

test('indexed timing decisions match exhaustive original attack containment over real source edits and independent routes',()=>{
  const file=new JZZ.MIDI.SMF(1,1000)
  for(let track=0;track<3;track++) {
    const events=new JZZ.MIDI.SMF.MTrk().add(0,JZZ.MIDI.smfMidiPort(track===2?1:0)),channel=track===2?1:0
    for(let i=0;i<7;i++) {
      const start=100+i*400+track*20,duration=i%3?100:0,pitch=60+i%2
      events.add(start,JZZ.MIDI.noteOn(channel,pitch,70+i)).add(start+duration,JZZ.MIDI.noteOff(channel,pitch,45))
    }
    events.add(3000,JZZ.MIDI.noteOn(channel,60,80)).add(3100,JZZ.MIDI.noteOn(channel,60,90))
    file.push(events.add(5000,JZZ.MIDI.smfEndOfTrack()))
  }
  const source=importMidiSource(file.toUint8Array()),before=midiSourcePattern(source)
  let allowed=false,refused=false
  for(const note of before.notes)for(const shift of [-100,0,150,400])for(const duration of [0,50,250,800]) {
    let candidate
    try{candidate=editMidiSourceNotes(source,[{kind:'change',id:note.id,start:note.start+shift,duration}])}
    catch{continue} // The original pairing/port authority refuses before either guard.
    const after=midiSourcePattern(candidate),expected=newlyEnclosed(before,after)
    if(expected){assert.throws(()=>assertMidiTimingOrder(before,after),/overlapping/);refused=true}
    else{assert.doesNotThrow(()=>assertMidiTimingOrder(before,after));allowed=true}
  }
  assert.ok(allowed&&refused,'The candidate set must exercise both semantic outcomes')
})
