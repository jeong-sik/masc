import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { inspectCalibration } from '../calibration-files.mjs'
import { arrangementEditor, arrangementCommand, arrangementCalibrated } from '../arrangement-editor.mjs'
import { newArrangement, editArrangement } from '../arrangement.mjs'
import { importArrangementCapture, saveArrangement, loadArrangement } from '../arrangement-files.mjs'
import { prepareArrangementCaptureRegions } from '../arrangement-playback.mjs'
import { calibrationSelection, calibrationReference, analyzeCalibration } from '../audio-calibration.mjs'

async function fixture({ shift=37, polarity=1, silent=false, numer=125, denom=3 }={}) {
 const directory=await mkdtemp(join(tmpdir(),'masc-calibration-')),capture=join(directory,'capture');await mkdir(capture)
 const selection={output:'output',inputChannel:2,outputChannel:2,maxLagMs:10},reference=calibrationReference(48000,2,selection)
 const frames=reference.frames+1024,bytes=Buffer.alloc(44+frames*8);reference.wave.copy(bytes,0,0,44);bytes.writeUInt32LE(bytes.length-8,4);bytes.writeUInt32LE(frames*8,40)
 for(let i=0;i<frames;i++)bytes.writeFloatLE(.001*Math.sin(i),44+i*8)
 if(!silent)for(const pulse of reference.pulseFrames)for(let i=0;i<reference.probe.length;i++)bytes.writeFloatLE(polarity*reference.probe[i],44+(pulse+shift+i)*8+4)
 const origin=9007199254740993123n,rate=48000
 const manifest={schemaVersion:1,state:'recorded',failure:null,audio:'audio.wav',audioBlocks:'audio-blocks.jsonl',midi:'midi.ump.jsonl',monitoring:{state:'off'},input:{id:'input',name:'Input'},midiSources:[],sampleRate:rate,channels:2,audioFrames:String(frames),midiPacketCount:'0',
  clock:{kind:'mach-host-time',requestedStart:String(origin),firstAudioHostTime:String(origin),numer,denom}}
 const blocks=[]
 for(let offset=0;offset<frames;offset+=512)blocks.push({kind:'audio',frameOffset:String(offset),frameCount:Math.min(512,frames-offset),hostTime:String(origin+BigInt(offset)*1000000000n*BigInt(denom)/(BigInt(rate)*BigInt(numer))),deviceSampleTime:String(offset),peaks:[[0,0],[0,0]]})
 await Promise.all([writeFile(join(capture,'audio.wav'),bytes),writeFile(join(capture,'session.json'),JSON.stringify(manifest)),writeFile(join(capture,'audio-blocks.jsonl'),blocks.map(JSON.stringify).join('\n')+'\n'),writeFile(join(capture,'midi.ump.jsonl'),'')])
 const playback={kind:'playing',device:{id:'output',name:'Output',outputs:2},clock:{kind:'mach-host-time',anchor:String(origin),position:0,numer,denom,sampleRate:48000,renderQuantum:256,bufferFrames:256,presentationLatency:.01}}
 return {directory,selection,reference,playback,bytes,shift,numer,denom,manifest}
}

test('calibration correlates selected channels with exact large host clocks and signed sample residuals',async()=>{
 for(const options of [{shift:37},{shift:-37,polarity:-1},{shift:123,numer:1,denom:1}]){
  const f=await fixture(options)
  try{
   const result=await analyzeCalibration(f)
   assert.equal(result.kind,'audio-calibration-candidate');assert.equal(result.status,'unapplied')
   assert.equal(result.input.id,'input');assert.equal(result.output.id,'output');assert.equal(result.inputChannel,2);assert.equal(result.outputChannel,2)
   assert.equal(result.matches.length,2)
   for(const [i,m] of result.matches.entries()){
    assert.equal(m.frame,f.reference.pulseFrames[i]+f.shift);assert.ok(Math.abs(m.correlation)>.999999)
    assert.ok(Math.abs(m.residualMs-f.shift/48)<.000001)
    const local=BigInt(m.frame)-BigInt(m.blockFrameOffset),pulse=BigInt(f.reference.pulseFrames[i])
    const expected=(BigInt(m.blockHostTime)-BigInt(f.playback.clock.anchor))*BigInt(f.numer)*48000n+(local-pulse)*1000000000n*BigInt(f.denom)
    assert.equal(m.residualNanoseconds.numerator,String(expected));assert.equal(m.residualNanoseconds.denominator,String(BigInt(f.denom)*48000n))
   }
   assert.deepEqual(await readFile(join(f.directory,'capture','audio.wav')),f.bytes)
  }finally{await rm(f.directory,{recursive:true,force:true})}
 }
})
test('silent, mismatched-clock, cancelled and unavailable channel experiments never produce calibration candidates',async()=>{
 const f=await fixture({silent:true})
 try{
  await assert.rejects(analyzeCalibration(f),/non-silent/)
  await assert.rejects(analyzeCalibration({...f,playback:{...f.playback,clock:{...f.playback.clock,numer:1}}}),/clock/)
  await assert.rejects(analyzeCalibration({...f,selection:{...f.selection,inputChannel:3}}),/clock/)
  const abort=new AbortController();abort.abort();await assert.rejects(analyzeCalibration({...f,signal:abort.signal}),{name:'AbortError'})
 }finally{await rm(f.directory,{recursive:true,force:true})}
 for(const bad of [{inputChannel:0},{outputChannel:1.5},{maxLagMs:0},{maxLagMs:NaN},{output:''}])assert.throws(()=>calibrationSelection({output:'out',inputChannel:1,outputChannel:1,maxLagMs:25,...bad}))
 assert.throws(()=>calibrationReference(48000,1,{output:'out',inputChannel:1,outputChannel:2,maxLagMs:25}))
})

async function retainExperiment(f) {
 const candidate=await analyzeCalibration(f)
 await Promise.all([writeFile(join(f.directory,'measurement.json'),JSON.stringify(candidate,null,2)),
  writeFile(join(f.directory,'reference.wav'),f.reference.wave),writeFile(join(f.directory,'playback.json'),JSON.stringify(f.playback,null,2))])
 return candidate
}
test('worker-inspected measured audio placement is explicit, undoable, portable and independent of original MIDI',async()=>{
 const f=await fixture(),portable=await mkdtemp(join(tmpdir(),'masc-calibration-portable-'))
 let worker
 try {
  await retainExperiment(f)
  worker=new Worker(new URL('../arrangement-worker.mjs',import.meta.url))
  const completed=once(worker,'message');worker.postMessage({id:1,kind:'inspect-calibration',path:f.directory})
  const [response]=await completed;assert.equal(response.ok,true,response.error)
  const profile=response.result;assert.deepEqual(profile,await inspectCalibration(f.directory))
  assert.equal(profile.pulses.length,2);assert.equal(profile.input.channel,2)
  const target=join(f.directory,'original-take');await mkdir(target)
  const packets=[{kind:'midi',protocol:2,hostTime:String(BigInt(f.manifest.clock.requestedStart)+240000n),source:'keys',timestampOrigin:'packet',words:[0x43953c00,0x90010000]},
   {kind:'midi',protocol:2,hostTime:String(BigInt(f.manifest.clock.requestedStart)+480000n),source:'keys',timestampOrigin:'packet',words:[0x43853c00,0x12340000]}]
  for(const name of ['audio.wav','audio-blocks.jsonl'])await writeFile(join(target,name),await readFile(join(f.directory,'capture',name)))
  await writeFile(join(target,'session.json'),JSON.stringify({...f.manifest,midiPacketCount:'2',midiSources:[{id:'keys',name:'Keys'}]}))
  await writeFile(join(target,'midi.ump.jsonl'),packets.map(JSON.stringify).join('\n')+'\n')
  const path=join(f.directory,'project','song.json'),imported=await importArrangementCapture(newArrangement(),target,{projectPath:path})
  let editor=arrangementEditor(imported.project)
  for(const line of ['place asset-1 1','split-take','capture-channel 2 2'])editor=arrangementCommand(editor,line).editor
  const options={sourceRoot:dirname(path),directory:f.directory,midiOutput:'42'}
  const before=editor.project,baseline=JSON.parse(await readFile((await prepareArrangementCaptureRegions(before,options)).path))
  const applied=arrangementCalibrated(editor,{profile,match:0,output:'output'}),clip=applied.project.clips[0]
  assert.deepEqual(clip.placement.advanceNanoseconds,{numerator:'2312500',denominator:'3'})
  assert.equal(clip.placement.kind,'calibrated');assert.equal(clip.placement.match,0)
  assert.deepEqual(applied.project.clips[1],before.clips[1])
  assert.equal(arrangementCommand(applied,'undo').editor.project,before)
  assert.equal(arrangementCommand(arrangementCommand(applied,'undo').editor,'redo').editor.project,applied.project)
  const plan=JSON.parse(await readFile((await prepareArrangementCaptureRegions(applied.project,options)).path))
  assert.ok(plan.regions[0].startSeconds<baseline.regions[0].startSeconds)
  assert.deepEqual(plan.regions[0].calibrationOutput,{id:'output',sampleRate:48000,bufferFrames:256})
  assert.deepEqual(plan.umpRegions,baseline.umpRegions)
  assert.deepEqual(plan.umpRegions.sources[0].timeline.packets,packets)
  for(const change of [{input:{...profile.input,id:'other'}},{input:{...profile.input,sampleRate:44100}},{input:{...profile.input,channel:1}}]) {
   assert.throws(()=>arrangementCalibrated(editor,{profile:{...profile,...change},match:0,output:'output'}))
  }
  assert.throws(()=>arrangementCalibrated(editor,{profile,match:0,output:'other'}),/match/)
  assert.throws(()=>arrangementCalibrated(editor,{profile,match:2,output:'output'}),/pulse/)
  const forged=structuredClone(profile);forged.output.id='other'
  assert.throws(()=>arrangementCalibrated(editor,{profile:forged,match:0,output:'other'}))
  const forgedSaved=structuredClone(applied.project);forgedSaved.clips[0].placement.profile.output.id='other'
  assert.throws(()=>arrangementEditor(forgedSaved))
  const changedPulse=structuredClone(applied.project);changedPulse.clips[0].placement.profile.pulses[0].blockHostTime=String(BigInt(profile.pulses[0].blockHostTime)+1n)
  assert.throws(()=>arrangementEditor(changedPulse))
  assert.throws(()=>arrangementCommand(applied,'capture-channel 1 2'),/match/)
  assert.throws(()=>editArrangement(applied.project,{kind:'region-change',id:clip.id,placement:{...clip.placement,advanceNanoseconds:{numerator:'1',denominator:'1'}}}),/disagrees/)
  const manual=arrangementCommand(applied,'capture-offset 0').editor
  assert.deepEqual(manual.project.clips[0].placement,{kind:'manual',advanceNanoseconds:{numerator:'0',denominator:'1'}})
  assert.doesNotThrow(()=>arrangementCommand(manual,'capture-channel all'))
  const saved=join(portable,'song.json');await saveArrangement(saved,applied.project,null,{sourceRoot:dirname(path)})
  await rm(f.directory,{recursive:true,force:true})
  const reopened=await loadArrangement(saved);assert.deepEqual(reopened.project,applied.project)
  const portablePlan=JSON.parse(await readFile((await prepareArrangementCaptureRegions(reopened.project,{sourceRoot:portable,directory:portable,midiOutput:'42'})).path))
  assert.deepEqual(portablePlan.umpRegions,plan.umpRegions);assert.deepEqual(portablePlan.regions[0].calibrationOutput,plan.regions[0].calibrationOutput)
  profile.input.id='caller-mutated';assert.equal(clip.placement.profile.input.id,'input')
 }finally{await worker?.terminate();await rm(f.directory,{recursive:true,force:true});await rm(portable,{recursive:true,force:true})}
})
test('inspection derives evidence from samples and clocks instead of trusting edited candidates or references',async()=>{
 const f=await fixture({shift:-37,polarity:-1})
 try {
  const candidate=await retainExperiment(f),profile=await inspectCalibration(f.directory)
  assert.ok(profile.pulses.every(p=>p.correlation<-.999))
  const changed=structuredClone(candidate);changed.matches[0].residualNanoseconds.numerator='0'
  await writeFile(join(f.directory,'measurement.json'),JSON.stringify(changed))
  await assert.rejects(inspectCalibration(f.directory),/disagrees/)
  await writeFile(join(f.directory,'measurement.json'),JSON.stringify(candidate,null,2))
  const bad=Buffer.from(f.reference.wave);bad[bad.length-1]^=1;await writeFile(join(f.directory,'reference.wav'),bad)
  await assert.rejects(inspectCalibration(f.directory),/reference/)
  await writeFile(join(f.directory,'reference.wav'),f.reference.wave)
  const corrupt=Buffer.from(f.bytes);corrupt[44]^=1;await writeFile(join(f.directory,'capture','audio.wav'),corrupt)
  await assert.rejects(inspectCalibration(f.directory),/disagrees/)
  const abort=new AbortController();abort.abort();await assert.rejects(inspectCalibration(f.directory,{signal:abort.signal}),{name:'AbortError'})
 }finally{await rm(f.directory,{recursive:true,force:true})}
})
