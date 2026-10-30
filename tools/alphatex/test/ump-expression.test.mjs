import test from 'node:test'
import assert from 'node:assert/strict'
import {Worker} from 'node:worker_threads'
import {once} from 'node:events'
import {mkdir,readFile,rm} from 'node:fs/promises'
import {dirname,join} from 'node:path'
import JZZ from 'jzz'
import {packet,capturedMidiFixture} from './helpers/captured-midi-fixture.mjs'
import {materializeUmp,umpSourceExpressions,editUmpExpressions} from '../ump-source.mjs'
import {newUmpEditor,umpEditorAction,umpEditorCommand} from '../ump-editor.mjs'
import {arrangementEditor,arrangementCommand,arrangementImported} from '../arrangement-editor.mjs'
import {saveArrangement,loadArrangement,readUmpCapture,exportUmpCapture} from '../arrangement-files.mjs'
import {prepareCapturedPlayback} from '../capture-playback.mjs'
const hash='a'.repeat(64),asset={name:'Recorded gestures',parts:{midi:{sha256:hash}}}
const rows=()=>[
  packet(-100n,'A',[JZZ.UMP.umpPnRPN(3,5,60,3,0x7b123456),JZZ.UMP.umpPnNRPN(3,5,60,255,0x12345678),JZZ.UMP.umpNoteOn(3,5,60,0x9001)]),
  packet(2400000n,'B',[JZZ.UMP.umpNoteOn(9,2,60,0)]),
  packet(4800000n,'A',[JZZ.UMP.umpPnPitchBend(3,5,60,0x87654321),JZZ.UMP.umpAftertouch(3,5,60,0xabcdef01)]),
  packet(7200000n,'B',[JZZ.UMP.umpNoteOff(9,2,60,0x4567)]),
  packet(12000000n,'A',[JZZ.UMP.umpNoteOff(3,5,60,0x1234),JZZ.UMP([0x43,0xf5,60,3,0,0,0,0])]),
  {...packet(12000001n,'A',[]),words:[0x50000000,0x12345678,0xabcdef01,0x87654321,0xf0000000,1,2,3]},
]
const command=(editor,line)=>umpEditorCommand(editor,line).editor
const changes=['expressions','value32 4294967295','select-expression 0:2','value32 0','select-expression 2:0','value32 2147483648','select-expression 2:2','value32 305419896']
const edit=editor=>changes.reduce(command,editor)
const expected=original=>{
 const result=structuredClone(original);result[0].words[1]=0xffffffff;result[0].words[3]=0
 result[2].words[1]=0x80000000;result[2].words[3]=0x12345678;return result
}

test('four native expression kinds retain all addresses, clocks, other sources and opaque words across mixed note edits and history',()=>{
 const packets=rows(),snapshot=structuredClone(packets),initial=newUmpEditor(asset,packets)
 assert.deepEqual(initial.expressions.map(e=>[e.id,e.kind,e.index,e.controller]),[
  ['0:0','registered-per-note',60,3],['0:2','assignable-per-note',60,255],['2:0','per-note-pitch-bend',60,undefined],['2:2','poly-pressure',60,undefined]])
 const edited=edit(initial)
 assert.deepEqual(materializeUmp(packets,edited.asset.ump,hash),expected(snapshot));assert.deepEqual(packets,snapshot)
 assert.equal(edited.undo.length,4)
 const undo=command(edited,'undo');assert.equal(undo.expressions.at(-1).value,0xabcdef01)
 assert.deepEqual(command(undo,'redo').asset,edited.asset)
 const notes=command(command(edited,'notes'),'pitch-absolute 60.5')
 assert.deepEqual(notes.asset.ump.expressions,edited.asset.ump.expressions)
 assert.deepEqual(command(notes,'reset-note').asset.ump,edited.asset.ump)
 let reset=command(edited,'reset-expression');assert.equal(reset.asset.ump.expressions.length,3)
 for(const id of ['0:0','0:2','2:0'])reset=command(command(reset,'select-expression '+id),'reset-expression')
 assert.deepEqual(reset.asset,asset)
 assert.equal(command(command(edited,'scope A 4 6'),'value32 1').expressions[0].value,1)
})

test('expression-only takes open and move without inventing notes; modes refuse hidden-target edits',()=>{
 const packets=[packet(0n,'A',[JZZ.UMP.umpPnPitchBend(0,0,17,0),JZZ.UMP.umpAftertouch(0,0,17,1)])]
 const initial=newUmpEditor(asset,packets);assert.deepEqual(initial.selection,{kind:'expression',id:'0:0'});assert.equal(initial.notes.length,0)
 const moved=umpEditorAction(initial,{kind:'move',direction:1});assert.equal(moved.selection.id,'0:2')
 const edited=command(moved,'value32 4294967295');assert.equal(edited.expressions[1].value,0xffffffff)
 for(const line of ['notes','pitch-absolute 60','velocity 2','revoice Cmaj7 close','harmony','reset-note'])assert.throws(()=>command(edited,line))
 const notes=newUmpEditor(asset,rows());assert.throws(()=>command(notes,'value32 1'));assert.throws(()=>command(notes,'reset-expression'))
})

test('invalid expression values, wrong message identities, malformed overlays and partially invalid batches leave candidates intact',()=>{
 const packets=rows(),editor=command(newUmpEditor(asset,packets),'expressions'),snapshot=structuredClone(editor)
 for(const value of ['-1','4294967296','9007199254740993','1.5','NaN','Infinity','1e3','0x80000000','01'])assert.throws(()=>command(editor,'value32 '+value))
 for(const id of ['0:1','0:4','4:2','5:0','99:0'])assert.throws(()=>command(editor,'select-expression '+id))
 const valid={schemaVersion:1,midiSha256:hash,notes:[],expressions:[{packet:0,word:0,value:1}]}
 for(const overlay of [{...valid,expressions:null},{...valid,expressions:[...valid.expressions,...valid.expressions]},
  {...valid,expressions:[{packet:0,word:0}]},{...valid,expressions:[{packet:0,word:0,value:1,extra:true}]},
  {...valid,notes:[{packet:0,word:0,velocity:1}]},{...valid,midiSha256:'b'.repeat(64)}])assert.throws(()=>materializeUmp(packets,overlay,hash))
 assert.throws(()=>editUmpExpressions(packets,undefined,hash,[{kind:'expression',id:'0:0',value:2},{kind:'expression',id:'0:2',value:-1}]))
 for(const word of [0x4365bc00,0x43653c01,0x43a53c01,0x43b54a00])assert.throws(()=>editUmpExpressions([{...packets[0],words:[word,0]}],undefined,hash,[{kind:'expression',id:'0:0',value:1}]))
 assert.deepEqual(editor,snapshot)
})

test('actual Worker expression variant → standalone/arrangement playback → native export → portable reopen uses the same edited words',()=>capturedMidiFixture(async({root,path,imported,rows:packets})=>{
 const directory=join(root,'scratch');await mkdir(directory)
 const worker=new Worker(new URL('../arrangement-worker.mjs',import.meta.url));let id=0
 const options={sourceRoot:dirname(path),directory}
 const request=async job=>{const response=once(worker,'message');worker.postMessage({...job,id:++id});const [message]=await response;assert.equal(message.ok,true,message.error);return message.result}
 try{
  const source=await request({kind:'prepare-ump',project:imported.project,asset:imported.asset,...options})
  const editor=edit(newUmpEditor(source.asset,source.packets))
  const variant=await request({kind:'import-ump',project:imported.project,asset:imported.asset,ump:editor.asset.ump,...options})
  let parent=arrangementImported(arrangementEditor(imported.project),variant)
  assert.deepEqual(parent.project.assets[0],imported.project.assets[0])
  parent=arrangementCommand(parent,`place ${variant.asset} 0`).editor
  const prepared=await request({kind:'prepare-take',project:parent.project,asset:variant.asset,...options})
  const expectedPackets=expected(packets)
  const standalone=await prepareCapturedPlayback(prepared.directory,{directory,sourceBindings:[{source:'A',destination:'10'},{source:'B',destination:'11'}]})
  assert.deepEqual(JSON.parse(await readFile(standalone.path)).ump.packets,expectedPackets)
  const arranged=await request({kind:'prepare-capture',project:parent.project,sourceBindings:[{asset:variant.asset,source:'A',destination:'10'},{asset:variant.asset,source:'B',destination:'11'}],...options})
  assert.deepEqual(JSON.parse(await readFile(arranged.path)).umpRegions.sources[0].timeline.packets,expectedPackets)
  const output=join(root,'export');await request({kind:'export-ump',project:parent.project,asset:variant.asset,path:output,...options})
  assert.deepEqual((await readFile(join(output,'midi.ump.jsonl'),'utf8')).trimEnd().split('\n').map(JSON.parse),expectedPackets)
  assert.deepEqual((await readFile(join(output,'original-midi.ump.jsonl'),'utf8')).trimEnd().split('\n').map(JSON.parse),packets)
  const copy=join(root,'portable/song.json');await saveArrangement(copy,parent.project,null,{sourceRoot:dirname(path)})
  await rm(dirname(path),{recursive:true,force:true})
  const reopened=await loadArrangement(copy);assert.deepEqual(reopened.project,parent.project)
  const restored=await readUmpCapture(reopened.project,variant.asset,{sourceRoot:dirname(copy),directory})
  assert.deepEqual(restored.packets,packets)
  assert.deepEqual(umpSourceExpressions(restored.packets,restored.asset.ump,restored.asset.parts.midi.sha256).map(e=>e.value),[0xffffffff,0,0x80000000,0x12345678])
  const reexport=join(root,'reexport');await exportUmpCapture(reopened.project,variant.asset,reexport,{sourceRoot:dirname(copy),directory})
  for(const file of ['midi.ump.jsonl','audio.wav','audio-blocks.jsonl','session.json','original-midi.ump.jsonl','ump-source.json'])assert.deepEqual(await readFile(join(reexport,file)),await readFile(join(output,file)))
 }finally{await worker.terminate()}
},rows()))
