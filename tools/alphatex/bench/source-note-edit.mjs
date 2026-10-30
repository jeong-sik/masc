// Manual experiment, not a timing gate. Fixture construction is outside timing.
import {performance} from 'node:perf_hooks'
import {resolve,join} from 'node:path'
import {fileURLToPath,pathToFileURL} from 'node:url'
import JZZ from 'jzz'
import smf from 'jzz-midi-smf'
smf(JZZ)
const root=resolve(process.argv[2]??fileURLToPath(new URL('../',import.meta.url)))
const {newEditor,editorCommand}=await import(pathToFileURL(join(root,'sequencer-editor.mjs')))
const {importMidiSource}=await import(pathToFileURL(join(root,'midi-source.mjs')))
const {assertMidiTimingOrder}=await import(pathToFileURL(join(root,'note-overlap.mjs')))
const rows=[]
for(const count of [1000,3000,6000]) {
  const file=new JZZ.MIDI.SMF(0,960),track=new JZZ.MIDI.SMF.MTrk()
  for(let i=0;i<count;i++)track.add(i*960,JZZ.MIDI.noteOn(0,60,80)).add(i*960+240,JZZ.MIDI.noteOff(0,60,45))
  file.push(track.add(count*960,JZZ.MIDI.smfEndOfTrack()))
  const editor=editorCommand(newEditor(importMidiSource(file.toUint8Array())),'select-all').editor
  const started=performance.now(),next=editorCommand(editor,'duration-add-notes 1/4').editor
  const editorMilliseconds=performance.now()-started,guardMilliseconds=[]
  for(let i=0;i<3;i++) {
    const started=performance.now();assertMidiTimingOrder(editor.performance,next.performance)
    guardMilliseconds.push(performance.now()-started)
  }
  if(next.performance.notes.length!==count||next.performance.notes.some(note=>note.duration!==480))throw new Error('Edited notes do not match fixture')
  rows.push({notes:count,editorMilliseconds,guardMilliseconds})
}
console.log(JSON.stringify({node:process.version,source:root,command:'select-all; duration-add-notes 1/4',rows},null,2))
