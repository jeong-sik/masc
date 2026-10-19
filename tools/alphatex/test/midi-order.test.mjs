import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { importMidiSource, exportMidiSource, midiSourcePattern, orderMidiSourceExpression, validateMidiSource } from '../midi-source.mjs'
import { newEditor, editorCommand, editorAction } from '../sequencer-editor.mjs'
import { selectedExpression } from '../midi-source-editor.mjs'
import { saveProject, loadProject } from '../sequencer-files.mjs'

const chunk=data=>{const head=Buffer.alloc(8);head.write('MTrk');head.writeUInt32BE(data.length,4);return Buffer.concat([head,Buffer.from(data)])}
function smf(tracks,format=1){const header=Buffer.from('4d546864000000060001000101e0','hex');header.writeUInt16BE(format,8);header.writeUInt16BE(tracks.length,10);return Buffer.concat([header,...tracks.map(chunk)])}
const wire=()=>smf([[0,0x90,60,96,0,0xb0,1,77,0,0xe0,0,64,0,0xff,0x7f,2,5,6,0x83,0x60,0x80,60,45,0,0xff,0x2f,0]])
const events=source=>midiSourcePattern(source).events
const bytes=source=>events(source).filter(event=>event.kind==='channel').map(event=>event.bytes)

test('explicit same-tick expression order precedes an existing first note without shifting notes, source clocks or unrelated order',async()=>{
 const source=importMidiSource(wire());let editor=newEditor(source)
 const original=events(source),notes=midiSourcePattern(source).notes
 const command=line=>{editor=editorCommand(editor,line).editor}
 for(const line of ['cc 1 0 0','bend 8192 0','cc 0 2 0','cc 32 3 0','program 33 0']){
  command(line);command('event-before first-note')
 }
 const ordered=events(editor.project),on=ordered.findIndex(event=>event.bytes?.[0]===0x90)
 assert.deepEqual(ordered.slice(0,on).map(event=>event.bytes),[[0xb0,1,0],[0xe0,0,64],[0xb0,0,2],[0xb0,32,3],[0xc0,33]])
 assert.deepEqual(midiSourcePattern(editor.project).notes,notes)
 assert.deepEqual(ordered.filter(event=>original.some(old=>old.id===event.id)),original)
 assert.equal(editor.project.original,source.original)
 const reset=editorCommand(editor,'event-order-reset').editor
 assert.deepEqual(bytes(reset.project).slice(0,3),[[0x90,60,96],[0xb0,1,77],[0xe0,0,64]])
 assert.deepEqual(editorCommand(reset,'undo').editor.project,editor.project)
 const directory=await mkdtemp(join(tmpdir(),'masc-midi-order-')),worker=new Worker(new URL('../sequencer-worker.mjs',import.meta.url))
 try{
  const path=join(directory,'source.json');await saveProject(path,editor.project);assert.deepEqual((await loadProject(path)).project,editor.project)
  const reply=once(worker,'message');worker.postMessage({id:1,project:editor.project,path:join(directory,'plan.json'),cancel:new SharedArrayBuffer(4),options:{format:'midi',midiOutput:'123'}})
  const [result]=await reply;assert.equal(result.ok,true,result.error)
  const timeline=JSON.parse(await readFile(result.result.path,'utf8'))
  assert.deepEqual(timeline.events.slice(0,5).map(event=>event.bytes),ordered.slice(0,5).map(event=>event.bytes))
  assert.deepEqual(bytes(importMidiSource(exportMidiSource(editor.project))),bytes(editor.project))
 }finally{await worker.terminate();await rm(directory,{recursive:true,force:true})}
})

test('ordered event values and membership follow insert, removal, note retiming and immutable history without dangling anchors',()=>{
 let editor=newEditor(importMidiSource(wire()))
 const command=line=>{editor=editorCommand(editor,line).editor}
 command('cc 74 99 0');const id=selectedExpression(editor).id;command('event-before first-note')
 const before=editor.project;command('event-value 88')
 assert.equal(bytes(editor.project)[0][2],88)
 command('program 33 0');assert.equal(bytes(editor.project).at(-1)[0],0x80)
 assert.ok(editor.project.orders[0].events.includes(selectedExpression(editor).id))
 command('event-remove');assert.ok(!editor.project.orders[0].events.includes('new:2'))
 command('event '+id);command('event-move 0.25')
 assert.ok(!editor.project.orders?.some(order=>order.events.includes(id)))
 command('undo');assert.equal(bytes(editor.project)[0][2],88)
 command('select 0:0');editor=editorAction(editor,{kind:'move-note',ticks:120})
 assert.ok(!editor.project.orders?.some(order=>order.tick===0&&order.events.includes('0:0')))
 validateMidiSource(editor.project)
 command('undo');command('undo');command('undo');command('undo');assert.deepEqual(editor.project,before)
})

test('order-only exports are materialized while malformed permutations, note reorder and source port changes refuse transactionally',()=>{
 const source=importMidiSource(wire()),original=exportMidiSource(source)
 const ordered=orderMidiSourceExpression(source,{id:'0:1',before:'0:0'})
 assert.equal(ordered.changes.length,0);assert.equal(ordered.insertions.length,0)
 assert.deepEqual(bytes(importMidiSource(exportMidiSource(ordered)))[0],[0xb0,1,77])
 for(const change of [null,[{track:0,tick:0,events:['0:1','0:1']}],[{track:0,tick:1,events:['0:1','0:0']}],[{track:0,tick:0,events:['missing','0:0']}],
  [{track:0,tick:0,events:['0:3','0:1','0:2','0:0']}],
  [{track:0,tick:0,events:['0:0','0:1','0:2','0:3']},{track:0,tick:0,events:['0:0','0:1','0:2','0:3']}]]){
  assert.throws(()=>validateMidiSource({...source,orders:change}))
 }
 const portSource=importMidiSource(smf([[0,0xb0,1,77,0,0xff,0x21,1,7,0,0x90,60,96,0,0xb0,74,99,0x83,0x60,0x80,60,45,0,0xff,0x2f,0]]))
 assert.throws(()=>orderMidiSourceExpression(portSource,{id:'0:3',before:'0:1'}),/source port/)
 let editor=editorCommand(newEditor(portSource),'cc 11 90 0').editor
 assert.throws(()=>editorCommand(editor,'event-before 0:1'),/source port/)
 assert.throws(()=>orderMidiSourceExpression(source,{id:'0:0',before:'0:1'}),/expression event/)
 assert.throws(()=>orderMidiSourceExpression(source,{id:'0:1',before:'0:1'}),/another/)
 assert.deepEqual(exportMidiSource(source),original)
})

test('a note arriving at an ordered tick keeps natural note order while the expression permutation remains valid',()=>{
 const source=importMidiSource(smf([[0,0x90,60,96,120,0x90,64,90,0,0xb0,74,99,0x82,0x68,0x80,60,45,0,0x80,64,44,0,0xff,0x2f,0]]))
 let editor=editorCommand(newEditor(source),'event 0:2').editor
 editor=editorCommand(editor,'event-before first-note').editor
 editor=editorCommand(editor,'select 0:0').editor
 editor=editorAction(editor,{kind:'move-note',ticks:120})
 validateMidiSource(editor.project)
 assert.deepEqual(events(editor.project).filter(event=>event.tick===120&&event.bytes?.[0]===0x90).map(event=>event.bytes[1]),[60,64])
 assert.deepEqual(midiSourcePattern(editor.project).notes.map(note=>[note.pitch,note.start,note.duration]),[[64,120,360],[60,120,480]])
})
