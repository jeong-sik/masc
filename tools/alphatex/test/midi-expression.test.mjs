import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { importMidiSource, exportMidiSource, midiSourcePattern, editMidiSourceExpressions } from '../midi-source.mjs'
import { expressionEvent } from '../midi-expression.mjs'
import { newEditor, editorCommand, editorAction } from '../sequencer-editor.mjs'
import { sourceExpressions, selectedExpression } from '../midi-source-editor.mjs'
import { saveProject, loadProject } from '../sequencer-files.mjs'
import { newArrangement } from '../arrangement.mjs'
import { importPhraseDocument } from '../phrase-arrangement.mjs'
import { arrangementEditor, arrangementImported, arrangementCommand } from '../arrangement-editor.mjs'

const chunk=data=>{const header=Buffer.alloc(8);header.write('MTrk');header.writeUInt32BE(data.length,4);return Buffer.concat([header,Buffer.from(data)])}
const smf=(tracks,format=1)=>{
 const header=Buffer.from('4d546864000000060001000101e0','hex');header.writeUInt16BE(format,8);header.writeUInt16BE(tracks.length,10)
 return Buffer.concat([header,...tracks.map(chunk)])
}
const original=()=>smf([[0,0xff,0x51,3,7,0xa1,0x20,0,0xff,0x7f,2,5,6,0,0xb0,1,77,0,0xe0,0,64,
 0,0x90,60,96,0x83,0x60,0x80,60,45,0x83,0x60,0xff,0x2f,0]])
const expressions=source=>midiSourcePattern(source).events.flatMap(event=>expressionEvent(event)??[])

test('expression experiment edits original events, inserts every channel message, and undo/export preserve source provenance and notes',()=>{
 const bytes=original(),source=importMidiSource(bytes),notes=midiSourcePattern(source).notes
 let editor=newEditor(source)
 const command=line=>{editor=editorCommand(editor,line).editor}
 command('events');const id=selectedExpression(editor).id
 command('event-value 88');command('event-move 0.25');command('event-set cc 74 99')
 assert.equal(selectedExpression(editor).id,id);assert.equal(selectedExpression(editor).tick,120)
 command('event-channel 2');assert.equal(selectedExpression(editor).channel,1)
 const edited=editor.project;command('undo');assert.equal(midiSourcePattern(editor.project).events.find(e=>e.id===id).bytes[0],0xb0)
 command('redo');assert.deepEqual(editor.project,edited)
 command('channel 1')
 for(const line of ['bend 16383 0.5','program 33 0.5','pressure 65 0.5','poly-pressure C4 66 0.5','cc 0 2 0.5','cc 32 3 0.5','program 34 0.5'])command(line)
 const at=expressions(editor.project).filter(e=>e.tick===240)
 assert.deepEqual(at.map(e=>[e.kind,e.value]),[['bend',16383],['program',33],['pressure',65],['poly-pressure',66],['cc',2],['cc',3],['program',34]])
 assert.deepEqual(midiSourcePattern(editor.project).notes,notes)
 assert.equal(editor.project.original,source.original)
 assert.deepEqual(exportMidiSource(source),Uint8Array.from(bytes))
 const before=editor.project;command('event-remove');assert.equal(sourceExpressions(editor).some(e=>e.id===before.insertions.at(-1).id),false)
 command('undo');assert.deepEqual(editor.project,before)
 const exported=importMidiSource(exportMidiSource(editor.project))
 assert.deepEqual(expressions(exported).map(({id,...event})=>event),expressions(editor.project).map(({id,...event})=>event))
 assert.deepEqual(midiSourcePattern(exported).events.filter(e=>e.kind==='meta').map(e=>[e.type,e.data]),midiSourcePattern(source).events.filter(e=>e.kind==='meta').map(e=>[e.type,e.data]))
})

test('selected pattern, source port, event kind and protocol ranges constrain expression edits without changing other data',()=>{
 const bytes=smf([[0,0x90,55,90,0x83,0x60,0x80,55,4,0,0xff,0x2f,0],
  [0,0xff,0x21,1,7,60,0xb0,1,77,0x81,0x34,0xff,0x21,1,8,0x81,0x70,0xff,0x2f,0]],2)
 const source=importMidiSource(bytes);let editor=newEditor(source)
 assert.throws(()=>editorCommand(editor,'cc 1 2 0'),/channel|pattern/)
 editor=editorCommand(editor,'pattern 2').editor;editor=editorCommand(editor,'events').editor
 const id=selectedExpression(editor).id
 assert.equal(selectedExpression(editorCommand(editor,'event-move 0.5').editor).port,7)
 assert.throws(()=>editorCommand(editor,'event-move 0.75'),/source port/)
 editor=editorCommand(editor,'cc 74 99 0.25').editor
 assert.equal(selectedExpression(editor).port,7)
 assert.throws(()=>editorCommand(editor,'event-move 0.75'),/source port/)
 for(const line of ['cc 128 1','cc 1 128','bend 16384','program -1','pressure 128','poly-pressure C4 128','event-value NaN','event-channel 17'])assert.throws(()=>editorCommand(editor,line))
 assert.throws(()=>editMidiSourceExpressions(source,[{kind:'change',id:'0:0',message:{kind:'cc',channel:0,controller:1,value:0}}],{pattern:1}),/expression event/)
 assert.throws(()=>editMidiSourceExpressions(source,[{kind:'insert',track:0,tick:0,message:{kind:'cc',channel:0,controller:1,value:0}}],{pattern:1}),/selected MIDI pattern/)
 assert.deepEqual(Buffer.from(exportMidiSource(source)),bytes)
 assert.deepEqual(midiSourcePattern(editor.project,{pattern:0}),midiSourcePattern(source,{pattern:0}))
 assert.ok(midiSourcePattern(editor.project,{pattern:1}).events.some(e=>e.id===id))
 editor=editorCommand(editor,'pattern 1').editor;assert.equal(selectedExpression(editor),undefined)
})

test('actual workers and persistence carry expression edits through MIDI export and immutable arrangement variants',async()=>{
 const directory=await mkdtemp(join(tmpdir(),'masc-expression-workflow-')),worker=new Worker(new URL('../sequencer-worker.mjs',import.meta.url)),arrange=new Worker(new URL('../arrangement-worker.mjs',import.meta.url))
 let id=0
 const request=async(worker,job)=>{const reply=once(worker,'message');worker.postMessage({...job,id:++id});const[result]=await reply;assert.equal(result.ok,true,result.error);return result.result}
 try{
  const source=importMidiSource(original());let editor=newEditor(source)
  for(const line of ['cc 74 99 0.25','bend 12345 0.5','program 33 0.5','pressure 64 0.5','poly-pressure C4 63 0.5'])editor=editorCommand(editor,line).editor
  const path=join(directory,'source.json');await saveProject(path,editor.project);assert.deepEqual((await loadProject(path)).project,editor.project)
  const rendered=await request(worker,{path:join(directory,'source-midi.json'),project:editor.project,cancel:new SharedArrayBuffer(4),options:{format:'midi',midiOutput:'123'}})
  const timeline=JSON.parse(await readFile(rendered.path,'utf8'))
  for(const bytes of [[0xb0,74,99],[0xe0,57,96],[0xc0,33],[0xd0,64],[0xa0,60,63]])assert.ok(timeline.events.some(event=>JSON.stringify(event.bytes)===JSON.stringify(bytes)))
  const old=importPhraseDocument(newArrangement(),source),variant=await request(arrange,{kind:'import-phrase',project:old.project,document:editor.project})
  let state=arrangementImported(arrangementEditor(old.project),variant);state=arrangementCommand(state,'place '+variant.asset+' 2').editor
  const prepared=await request(arrange,{kind:'prepare-midi',project:state.project,directory,midiOutput:'123'})
  const backing=JSON.parse(await readFile(prepared.path,'utf8'));assert.ok(backing.sources[0].timeline.events.some(event=>JSON.stringify(event.bytes)==='[176,74,99]'))
  assert.deepEqual(Buffer.from(exportMidiSource(state.project.assets[0].source)),original())
  assert.deepEqual(arrangementCommand(state,'undo').editor.project,variant.project)
 }finally{await Promise.all([worker.terminate(),arrange.terminate()]);await rm(directory,{recursive:true,force:true})}
})
