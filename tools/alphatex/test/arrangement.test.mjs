import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, readFile, stat, rename, mkdir, symlink, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { newArrangement, editArrangement, arrangementClipTime, arrangementSchedule } from '../arrangement.mjs'
import { importArrangementWave, importArrangementMidi, loadArrangement, saveArrangement } from '../arrangement-files.mjs'
import { midiSourcePattern, exportMidiSource, importMidiSource } from '../midi-source.mjs'
const PPQ=960
const chunk=(name,bytes)=>{const h=Buffer.alloc(8);h.write(name);h.writeUInt32BE(bytes.length,4);return Buffer.concat([h,Buffer.from(bytes)])}
const vlq=n=>{const b=[n&127];while((n=Math.floor(n/128)))b.unshift(n&127|128);return b}
function midi(tracks,format=1,division=1001){const h=Buffer.alloc(6);h.writeUInt16BE(format);h.writeUInt16BE(tracks.length,2);h.writeUInt16BE(division,4);return Buffer.concat([chunk('MThd',h),...tracks.map(t=>chunk('MTrk',t))])}
const end=[0,255,47,0]
const performance=midi([[0,255,81,3,7,161,32,...vlq(1001),255,81,3,15,66,64,...vlq(1001),255,47,0],
  [0,255,33,1,7,0,0xb0,1,88,0,0xe0,1,65,0,0xf0,3,0x7d,1,0xf7,0,0x90,60,100,...vlq(2002),0x80,60,77,...end]])
function wave({rate=48000,channels=2,frames=48000}={}){
 const b=Buffer.alloc(44+frames*channels*2);b.write('RIFF');b.writeUInt32LE(b.length-8,4);b.write('WAVEfmt ',8);b.writeUInt32LE(16,16);b.writeUInt16LE(1,20);b.writeUInt16LE(channels,22);b.writeUInt32LE(rate,24);b.writeUInt32LE(rate*channels*2,28);b.writeUInt16LE(channels*2,32);b.writeUInt16LE(16,34);b.write('data',36);b.writeUInt32LE(b.length-44,40)
 for(let i=44;i<b.length;i+=2)b.writeInt16LE((i/2)%2000-1000,i)
 return b
}
async function workspace(run){const root=await mkdtemp(join(tmpdir(),'masc-arrangement-'));try{await run(root)}finally{await rm(root,{recursive:true,force:true})}}
const region=(asset,lane,values={})=>({kind:'region-add',name:'Take',asset,lane,position:0,offset:0,extent:1,...values})

test('arrange WAV/MIDI sources, trim/repeat/duplicate, save/reopen and relocate without changing originals',async()=>workspace(async root=>{
 const input=join(root,'original.wav'),inputMidi=join(root,'original.mid'),path=join(root,'project','song.json')
 const bytes=wave();await writeFile(input,bytes);await writeFile(inputMidi,performance)
 let project=newArrangement({tempo:120})
 const imported=await importArrangementWave(project,input,{projectPath:path});project=imported.project
 project=editArrangement(project,{kind:'lane-add',sourceKind:'wave',name:'Bass audio'})
 project=editArrangement(project,region(imported.asset,'lane-1',{position:4*PPQ,offset:12000,extent:24000,repeat:2}))
 project=editArrangement(project,{kind:'region-duplicate',id:'region-1',position:8*PPQ})
 const original=structuredClone(project)
 project=editArrangement(project,{kind:'region-change',id:'region-2',offset:24000,extent:12000,repeat:3})
 assert.deepEqual(original.clips[1],{id:'region-2',name:'Take',asset:'asset-1',lane:'lane-1',position:8*PPQ,offset:12000,extent:24000,repeat:2})
 const midiImport=await importArrangementMidi(project,inputMidi);project=midiImport.project
 project=editArrangement(project,{kind:'lane-add',sourceKind:'midi',name:'Expression'})
 project=editArrangement(project,region(midiImport.asset,'lane-2',{position:2*PPQ,offset:500,extent:1001,repeat:2}))
 const timing=arrangementClipTime(project,project.clips[2]);assert.equal(timing.startSeconds,1)
 assert.equal(timing.sourceStartSeconds,500/1001*.5);assert.equal(timing.sourceEndSeconds,.5+500/1001)
 assert.equal(timing.durationSeconds,timing.sourceEndSeconds-timing.sourceStartSeconds)
 const revision=await saveArrangement(path,project);const loaded=await loadArrangement(path)
 assert.equal(loaded.revision,revision);assert.deepEqual(loaded.project,project)
 const moved=join(root,'relocated','copy.json');await saveArrangement(moved,project,null,{sourceRoot:dirname(path)})
 const copied=await loadArrangement(moved);assert.deepEqual(copied.project,project)
 await rename(join(dirname(path),'assets'),join(root,'old-assets'))
 assert.deepEqual((await loadArrangement(moved)).project,project)
 const source=copied.project.assets.find(a=>a.kind==='midi').source
 assert.deepEqual(Buffer.from(exportMidiSource(source)),performance)
 assert.ok(midiSourcePattern(source).events.some(e=>e.kind==='channel'&&e.bytes.join()==='224,1,65'))
 assert.equal(midiSourcePattern(source).notes[0].port,7)
 assert.deepEqual(await readFile(input),bytes);assert.deepEqual(await readFile(inputMidi),performance)
 assert.notEqual((await stat(input)).ino,(await stat(join(dirname(moved),project.assets[0].file))).ino)
 const removed=editArrangement(project,{kind:'lane-remove',id:'lane-1'})
 assert.equal(removed.clips.length,1);assert.deepEqual(removed.assets,project.assets)
}))

test('MIDI patterns, native clock domains, region bounds and lane identity remain explicit and transactional',()=>{
 const data=midi([[0,0x90,60,100,...vlq(2400),0x80,60,77,...end],[0,0x90,64,100,...vlq(2400),0x80,64,55,...end]],2,0xe350)
 let project=editArrangement(newArrangement(),{kind:'asset-add',asset:{id:'asset-1',name:'Independent patterns',kind:'midi',source:importMidiSource(data)}})
 project=editArrangement(project,{kind:'lane-add',sourceKind:'midi',name:'MIDI'})
 assert.throws(()=>editArrangement(project,region('asset-1','lane-1',{extent:2400})),/pattern explicitly/)
 project=editArrangement(project,region('asset-1','lane-1',{offset:1200,extent:1200,pattern:1,repeat:4,position:3*PPQ}))
 assert.equal(arrangementClipTime(project,project.clips[0]).durationSeconds,.5005)
 const before=structuredClone(project)
 for(const change of [{extent:1201},{offset:-1},{repeat:0},{offset:.5},{pattern:2},{lane:'missing'}])assert.throws(()=>editArrangement(project,{kind:'region-change',id:'region-1',...change}))
 assert.deepEqual(project,before)
 const faster=editArrangement(project,{kind:'tempo',tempo:200})
 assert.equal(arrangementClipTime(faster,faster.clips[0]).startSeconds,.9)
 assert.equal(arrangementClipTime(faster,faster.clips[0]).durationSeconds,.5005)
 const zero=editArrangement(newArrangement(),{kind:'asset-add',asset:{id:'zero',name:'Endpoint note',kind:'midi',source:importMidiSource(midi([[0,0x90,60,100,0,0x80,60,77,...end]],0))}})
 const withLane=editArrangement(zero,{kind:'lane-add',sourceKind:'midi',name:'Zero'})
 const placed=editArrangement(withLane,region('zero','lane-1',{extent:0,position:PPQ}))
 assert.equal(arrangementClipTime(placed,placed.clips[0]).durationSeconds,0)
})

test('WAV assets are independently owned, verified on reopen, deduplicated without overwrites and cancellation preserves documents',async()=>workspace(async root=>{
 const input=join(root,'take.wav'),path=join(root,'song.json'),bytes=wave({rate:44100,channels:1,frames:4410})
 await writeFile(input,bytes);let project=newArrangement()
 const aborted=new AbortController();aborted.abort()
 await assert.rejects(importArrangementWave(project,input,{projectPath:path,signal:aborted.signal}))
 assert.deepEqual(project,newArrangement())
 project=(await importArrangementWave(project,input,{projectPath:path})).project
 project=(await importArrangementWave(project,input,{projectPath:path,name:'Same source, second label'})).project
 assert.equal(project.assets[0].file,project.assets[1].file)
 assert.equal(project.assets[0].metadata.sampleRate,44100);assert.equal(project.assets[0].metadata.frames,4410)
 const revision=await saveArrangement(path,project)
 await writeFile(path,JSON.stringify({...project,title:'Other editor'}))
 await assert.rejects(saveArrangement(path,{...project,title:'Local edit'},revision),/changed on disk/)
 assert.equal(JSON.parse(await readFile(path)).title,'Other editor')
 const assetPath=join(root,project.assets[0].file);await import('node:fs/promises').then(fs=>fs.chmod(assetPath,0o600))
 const corrupt=Buffer.from(bytes);corrupt[44]^=127;await writeFile(assetPath,corrupt)
 await assert.rejects(loadArrangement(path),/content changed/)
 await assert.rejects(importArrangementWave(project,input,{projectPath:path}),/content changed/)
 assert.deepEqual(await readFile(assetPath),corrupt);assert.deepEqual(await readFile(input),bytes)
 const outside=join(root,'outside'),linked=join(root,'linked');await mkdir(outside);await mkdir(linked);await symlink(outside,join(linked,'assets'))
 await assert.rejects(importArrangementWave(newArrangement(),input,{projectPath:join(linked,'song.json')}),/not a symlink/)
}))

test('arrangement audibility and region edits retain original sources and native-speed timing',()=>{
 let p=editArrangement(newArrangement({tempo:120}),{kind:'asset-add',asset:{id:'m',name:'Performance',kind:'midi',source:importMidiSource(performance)}})
 for(const name of ['One','Two'])p=editArrangement(p,{kind:'lane-add',sourceKind:'midi',name})
 p=editArrangement(p,region('m','lane-1',{extent:2002,position:4*PPQ,repeat:2}))
 p=editArrangement(p,region('m','lane-2',{extent:2002,position:PPQ}))
 const before=structuredClone(p),schedule=arrangementSchedule(p)
 assert.deepEqual(schedule.map(c=>[c.position,c.startSeconds,c.durationSeconds,c.endSeconds]),[[PPQ,.5,1.5,2],[4*PPQ,2,1.5,5]])
 const solo=editArrangement(p,{kind:'lane-solo',id:'lane-1'});assert.deepEqual(arrangementSchedule(solo).map(c=>c.lane),['lane-1'])
 const muted=editArrangement(solo,{kind:'lane-mute',id:'lane-1'});assert.deepEqual(arrangementSchedule(muted),[])
 assert.equal(arrangementSchedule(muted,{all:true}).length,2)
 const removed=editArrangement(p,{kind:'region-remove',id:'region-1'});assert.deepEqual(removed.assets,p.assets);assert.deepEqual(p,before)
})
