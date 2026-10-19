import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { newArrangement, editArrangement, validateArrangement } from '../arrangement.mjs'
import { arrangementEditor, arrangementCommand } from '../arrangement-editor.mjs'
import { arrangementRoute, arrangementPlaybackRequest } from '../arrangement-playback.mjs'
import { importMidiSource, exportMidiSource } from '../midi-source.mjs'
import { arrangementLoop, loopMidiRegions } from '../arrangement-loop.mjs'
import { loadArrangement } from '../arrangement-files.mjs'
function project(){
 const bytes=Buffer.from('4d546864000000060000000101e04d54726b0000000000b0010000903c608740803c2d00ff2f00','hex');bytes.writeUInt32BE(bytes.length-22,18)
 let p=newArrangement({tempo:120});p=editArrangement(p,{kind:'asset-add',asset:{id:'asset-1',kind:'midi',name:'Practice',source:importMidiSource(bytes)}})
 p=editArrangement(p,{kind:'lane-add',sourceKind:'midi',name:'Keys'})
 return editArrangement(p,{kind:'region-add',lane:p.lanes[0].id,asset:'asset-1',name:'Repeated phrase',position:0,offset:0,extent:960,repeat:4})
}
function client(){const worker=new Worker(new URL('../arrangement-worker.mjs',import.meta.url));let id=0;return{worker,async request(job){const reply=once(worker,'message');worker.postMessage({...job,id:++id});return(await reply)[0]}}}
const ok=r=>{assert.equal(r.ok,true,r.error);return r.result}

test('arrangement loop range is an immutable project decision and worker preparation preserves source clocks in compressed partial repeats',async()=>{
 const directory=await mkdtemp(join(tmpdir(),'masc-arrangement-loop-')),c=client()
 try{
  const initial=project(),original=Buffer.from(exportMidiSource(initial.assets[0].source));let e=arrangementEditor(initial)
  e=arrangementCommand(e,'loop 1.5 6.5').editor
  assert.deepEqual(e.project.playbackLoop,{start:1440,end:6240})
  assert.deepEqual(arrangementLoop(e.project),{start:.75,end:3.25,duration:2.5})
  assert.equal(arrangementCommand(e,'undo').editor.project,initial)
  const off=arrangementCommand(e,'loop off').editor;assert.equal(off.project.playbackLoop,undefined);assert.deepEqual(arrangementCommand(off,'undo').editor.project,e.project)
  const path=join(directory,'song.json');ok(await c.request({kind:'save',path,project:e.project,revision:null,sourceRoot:directory}))
  assert.deepEqual((await loadArrangement(path)).project,e.project)
  const prepared=ok(await c.request({kind:'prepare-midi',project:e.project,directory,midiOutput:'123'}))
  assert.equal(prepared.loop,true);assert.equal(prepared.originSeconds,.75);assert.equal(prepared.duration,2.5)
  const plan=JSON.parse(await readFile(prepared.path,'utf8'));assert.equal(plan.duration,2.5)
  assert.deepEqual(plan.regions.map(r=>[r.startSeconds,r.sourceStart,r.sourceEnd,r.repeatCount]),[[0,.75,1,1],[.25,0,1,2],[2.25,0,.25,1]])
  assert.deepEqual(Buffer.from(exportMidiSource(e.project.assets[0].source)),original)
  assert.deepEqual(plan.sources[0].timeline.events.map(e=>e.bytes),[[0xb0,1,0],[0x90,60,96],[0x80,60,45]])
 }finally{await c.worker.terminate();await rm(directory,{recursive:true,force:true})}
})

test('one loop window retains a compressed run even for a long finite source region and never selects outside assets',()=>{
 const region={id:'a',source:'s',startSeconds:0,sourceStart:0,sourceEnd:1,repeatCount:1000000000}
 const selected=loopMidiRegions([region],{start:.25,end:999999999.75})
 assert.deepEqual(selected.map(v=>v.repeatCount),[1,999999998,1]);assert.equal(selected[2].sourceEnd,.75)
 assert.equal(new Set(selected.map(v=>v.id)).size,3)
 let p=project();p=editArrangement(p,{kind:'lane-add',sourceKind:'wave',name:'Outside loop'})
 const sha256='a'.repeat(64),asset={id:'wave',kind:'wave',name:'Outside',sha256,file:`assets/${sha256}.wav`,metadata:{encoding:'pcm',sampleRate:48000,channels:1,frames:48000,bitsPerSample:16,validBits:16,blockAlign:2}}
 p=editArrangement(p,{kind:'asset-add',asset});p=editArrangement(p,{kind:'region-add',lane:p.lanes[1].id,asset:'wave',name:'Outside',position:96000,offset:0,extent:48000,repeat:1})
 p=editArrangement(p,{kind:'loop',range:{start:0,end:960}})
 assert.equal(arrangementPlaybackRequest(p,arrangementRoute({midiOutput:'123'})).kind,'prepare-midi')
 const weird={...region,sourceEnd:1.12500025,repeatCount:1}
 assert.deepEqual(loopMidiRegions([weird],{start:.5,end:1})[0],{...weird,id:JSON.stringify(['a','leading']),startSeconds:0,sourceStart:.5,sourceEnd:1})
})

test('decimal loop cuts prepare source-preserving regions inside the actual normalized native horizon',async()=>{
 const directory=await mkdtemp(join(tmpdir(),'masc-loop-decimal-')),c=client()
 try{
  const initial=project()
  for(const [extent,repeat,tempo,command]of [[96,100,120,'loop 0.5 1.8'],[960,1,100,'loop 0.25 0.75']]){
   const p={...initial,tempo,clips:initial.clips.map(clip=>({...clip,extent,repeat}))}
   const selected=arrangementCommand(arrangementEditor(p),command).editor.project
   const before=structuredClone(selected),range=arrangementLoop(selected)
   const prepared=ok(await c.request({kind:'prepare-midi',project:selected,directory,midiOutput:'123'}))
   const plan=JSON.parse(await readFile(prepared.path,'utf8'))
   assert.equal(prepared.loop,true);assert.equal(prepared.originSeconds,range.start)
   assert.ok(plan.duration>=range.duration)
   let priorEnd=0
   for(const region of plan.regions){
    const end=region.startSeconds+(region.sourceEnd-region.sourceStart)*region.repeatCount
    assert.ok(region.startSeconds>=priorEnd);assert.ok(end<=plan.duration)
    assert.ok(region.sourceStart>=0&&region.sourceEnd<=extent/480*60/120)
    priorEnd=end
   }
   assert.deepEqual(selected,before)
   assert.deepEqual(plan.sources[0].timeline.events.map(e=>e.bytes),[[0xb0,1,0],[0x90,60,96],[0x80,60,45]])
  }
 }finally{await c.worker.terminate();await rm(directory,{recursive:true,force:true})}
})

test('adjacent original clips share their normalized native boundary across different source periods',async()=>{
 const directory=await mkdtemp(join(tmpdir(),'masc-loop-adjacent-')),c=client()
 try{
  const initial=project(),p={...initial,clips:initial.clips.map(clip=>({...clip,extent:96,repeat:9}))}
  const joined=editArrangement(p,{kind:'region-add',lane:p.lanes[0].id,asset:'asset-1',name:'Adjacent',position:1728,offset:0,extent:192,repeat:1})
  const selected=arrangementCommand(arrangementEditor(joined),'loop 0.5 2.2').editor.project
  const prepared=ok(await c.request({kind:'prepare-midi',project:selected,directory,midiOutput:'123'}))
  const plan=JSON.parse(await readFile(prepared.path,'utf8'))
  const ends=plan.regions.map(r=>r.startSeconds+(r.sourceEnd-r.sourceStart)*r.repeatCount)
  for(let n=1;n<plan.regions.length;n++)assert.ok(ends[n-1]<=plan.regions[n].startSeconds)
  assert.equal(ends[1],plan.regions[2].startSeconds)
  assert.ok(ends.at(-1)<=plan.duration)
  assert.deepEqual(plan.regions.map(r=>r.repeatCount),[1,6,1])
  assert.deepEqual(selected.assets,initial.assets)
 }finally{await c.worker.terminate();await rm(directory,{recursive:true,force:true})}
})

test('invalid or silent loop ranges refuse and pending audio, UMP, click and recording paths cannot silently play one-shot',async()=>{
 const p=project(),before=structuredClone(p),e=arrangementEditor(p),c=client(),directory=await mkdtemp(join(tmpdir(),'masc-loop-refusal-'))
 try{
  for(const command of ['loop -1 1','loop 1 1','loop 2 1','loop 0','loop 0 1 2'])assert.throws(()=>arrangementCommand(e,command))
  for(const playbackLoop of [null,{start:0,end:960,unknown:true},{start:0,end:Infinity},{start:.5,end:960}])assert.throws(()=>validateArrangement({...p,playbackLoop}))
  assert.deepEqual(p,before)
  const selected=arrangementCommand(e,'loop 1 2').editor.project
  for(const kind of ['prepare-audio','prepare-mixed','prepare-capture']){
   const r=await c.request({kind,project:selected,sourceRoot:directory,directory,midiOutput:'123'})
   assert.equal(r.ok,false);assert.match(r.error,/loop playback/)
  }
  const clicks={...selected,practice:{countInBars:1,metronome:true}}
  const r=await c.request({kind:'prepare-midi',project:clicks,directory,midiOutput:'123'});assert.equal(r.ok,false);assert.match(r.error,/count-in or metronome/)
  const silent=arrangementCommand(e,'loop 100 101').editor.project
  assert.throws(()=>arrangementPlaybackRequest(silent,arrangementRoute({midiOutput:'123'})),/No audible/)
 }finally{await c.worker.terminate();await rm(directory,{recursive:true,force:true})}
})
