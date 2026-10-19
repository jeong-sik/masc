import test from 'node:test'
import assert from 'node:assert/strict'
import { recordingEpoch, recordedLoopRegions, attachRecordedTake } from '../arrangement-recording.mjs'
import { newArrangement, editArrangement } from '../arrangement.mjs'
import { captureRange } from '../capture-time.mjs'
import { projectCapturedPlacement, manualCapturePlacement } from '../capture-placement.mjs'
import { arrangementEditor, arrangementImported, arrangementAction } from '../arrangement-editor.mjs'

const origin = 9007199254740993123n
function source(start = origin) {
 return {kind:'capture',id:'asset-1',name:'Input',parts:Object.fromEntries(['manifest','audio','audioBlocks','midi'].map(role=>[role,{sha256:'a'.repeat(64),file:`assets/${'a'.repeat(64)}.${role==='audio'?'wav':'capture'}`}])),
  manifest:{schemaVersion:1,state:'recorded',failure:null,audio:'audio.wav',audioBlocks:'audio-blocks.jsonl',midi:'midi.ump.jsonl',
   clock:{kind:'mach-host-time',numer:125,denom:3,requestedStart:String(start),firstAudioHostTime:String(start+2400000n)},sampleRate:48000,channels:1,audioFrames:'48000',midiPacketCount:'2',input:{id:'input',name:'Input'},midiSources:[{id:'keys',name:'Keys'}]},
  midiTime:{first:String(start+1200000n),last:String(start+12000000n)}}
}
const project = () => editArrangement(newArrangement({tempo:120}),{kind:'loop',range:{start:1920,end:2400}})
function epoch(p,anchor=origin,position=0) {
 return recordingEpoch({kind:'playing',loop:true,duration:(p.playbackLoop.end-p.playbackLoop.start)/p.ppq*60/p.tempo,
  clock:{kind:'mach-host-time',anchor:String(anchor),position,numer:125,denom:3,cycle:{kind:'project',...p.playbackLoop,ppq:p.ppq,tempo:p.tempo}}})
}
function contiguous(asset,regions,first=0n) {
 let cursor=first
 for(const r of regions){assert.equal(BigInt(r.offset),cursor);assert.ok(BigInt(r.extent)>0n);cursor+=BigInt(r.extent)}
 assert.equal(cursor,BigInt(captureRange(asset).extent))
}
function correctPosition(p,asset,e,region,advance=0n) {
 const part=projectCapturedPlacement(p,asset,region)[0], f=part.startNanoseconds
 // This fixture's quarter tick is 1,562,500/3ns, period 250ms.
 const anchor=BigInt(e.clock.anchor), phase=BigInt(Math.round(e.clock.position*1e9))
 const elapsed=(origin-anchor+BigInt(region.offset))*125n+phase*3n-advance*3n
 const period=750000000n, local=((elapsed%period)+period)%period
 assert.equal(BigInt(f.numerator)*3n,(3000000000n+local)*BigInt(f.denominator))
}

test('original host ticks partition across partial and complete loop takes with exact project placement',()=>{
 const p=project(),asset=source(),e=epoch(p,origin-36000001n,.125)
 const result=recordedLoopRegions(p,asset,e)
 contiguous(asset,result.regions)
 assert.equal(result.regions[0].cycle,'6')
 for(const r of result.regions)correctPosition(p,asset,e,r)
 assert.ok(result.regions.some(r=>BigInt(r.clockOffsetNanoseconds.numerator)!==0n))
 assert.deepEqual(result.alignment.epoch,e)
})

test('count-in is excluded; all source ticks after the musical epoch are retained once',()=>{
 const p=project(),asset=source(),e=epoch(p,origin+24000000n)
 const {regions}=recordedLoopRegions(p,asset,e)
 contiguous(asset,regions,24000000n)
 assert.equal(regions[0].position,1920);assert.equal(regions[0].cycle,'0')
 for(const r of regions)correctPosition(p,asset,e,r)
 assert.throws(()=>recordedLoopRegions(p,asset,epoch(p,origin+48000000n)),/ended before/)
})

test('nonintegral cycle boundaries make adjacent cuts without per-pass rounding accumulation',()=>{
 const p={...project(),tempo:137,playbackLoop:{start:960,end:1001}},asset=source(),e=epoch(p)
 const {regions}=recordedLoopRegions(p,asset,e)
 contiguous(asset,regions)
 assert.ok(regions.length>50)
 for(const r of regions){
  // Host offset maps to musical tick = offset * 125 *137*960/(3*60e9).
  const tickN=BigInt(r.offset)*125n*137n*960n,tickD=180000000000n
  const phaseN=tickN-BigInt(r.cycle)*41n*tickD
  const f=projectCapturedPlacement(p,asset,r)[0].startNanoseconds
  const expectedN=(960n*tickD+phaseN)*60000000000n,expectedD=tickD*137n*960n
  assert.equal(BigInt(f.numerator)*expectedD,expectedN*BigInt(f.denominator))
 }
})

test('take lanes retain every pass, last pass unmuted, one import undo and redo, and immutable source',()=>{
 const p=project(),asset=source(),e=epoch(p)
 const result=attachRecordedTake(p,{project:{...p,assets:[asset]},asset:asset.id},e)
 assert.ok(result.project.lanes.length>1)
 assert.ok(result.project.lanes.slice(0,-1).every(l=>l.muted));assert.equal(result.project.lanes.at(-1).muted,false)
 assert.equal(result.project.clips.length,result.project.lanes.length)
 assert.deepEqual(result.project.assets[0].manifest,asset.manifest);assert.deepEqual(result.project.assets[0].parts,asset.parts)
 const view=arrangementImported(arrangementEditor(p),result)
 assert.equal(arrangementAction(view,{kind:'undo'}).project,p)
 assert.deepEqual(arrangementAction(arrangementAction(view,{kind:'undo'}),{kind:'redo'}).project,result.project)
 assert.throws(()=>attachRecordedTake(result.project,{project:result.project,asset:asset.id},e),/already/)
 assert.equal(p.clips.length,0)
})

test('audio correction is applied before cycle partition while MIDI keeps the original host placement',()=>{
 for(const ms of ['12.345','-12.345']){
  const p=project(),asset=source(),e=epoch(p),placement=manualCapturePlacement(ms)
  const correction={kind:'audio',input:'input',output:'output',audioChannel:{input:1,output:2},placement}
  const {regions}=recordedLoopRegions(p,asset,e,correction),audio=regions.filter(r=>r.component==='audio'),midi=regions.filter(r=>r.component==='midi')
  const advance=BigInt(placement.advanceNanoseconds.numerator)/BigInt(placement.advanceNanoseconds.denominator)
  contiguous(asset,midi);contiguous(asset,audio,advance>0n?(advance*3n+124n)/125n:0n)
  for(const r of audio)correctPosition(p,asset,e,r,advance)
  for(const r of midi)correctPosition(p,asset,e,r)
  const result=attachRecordedTake(p,{project:{...p,assets:[asset]},asset:asset.id},e,correction)
  assert.equal(result.project.lanes.filter(l=>!l.muted).length,2)
  assert.deepEqual(result.alignment.correction,correction)
 }
})

test('native nanosecond loop epochs keep their actual binary64 period and reject stale project cycles',()=>{
 const start=240000000000000n,p=project(),asset=source(start),ns=start*125n/3n
 const e=recordingEpoch({kind:'playing',loop:true,duration:.25,clock:{kind:'mach-nanoseconds',anchor:String(ns),position:.1,cycle:{kind:'seconds',duration:.25}}})
 contiguous(asset,recordedLoopRegions(p,asset,e).regions)
 assert.throws(()=>recordedLoopRegions({...p,playbackLoop:{start:0,end:480}},asset,epoch(p)),/changed/)
 for(const cycle of [undefined,{kind:'project',start:0,end:0,ppq:960,tempo:120},{kind:'seconds',duration:.3}])assert.throws(()=>recordingEpoch({kind:'playing',loop:true,duration:.25,clock:{...e.clock,cycle}}))
})

import {EventEmitter} from 'node:events'
import {PassThrough} from 'node:stream'
import {openPlayback} from '../playback.mjs'
test('a loop recording uses a correlated native epoch barrier and retains the cycle descriptor',async()=>{
 const child=Object.assign(new EventEmitter(),{stdin:new PassThrough(),stdout:new PassThrough(),stderr:new PassThrough(),kill(){}}),commands=[]
 child.stdin.on('data',bytes=>commands.push(...bytes.toString().trim().split('\n').map(JSON.parse)))
 const handle=openPlayback({path:'/plan.json',format:'wave-arrangement',loop:true,output:'output',spawnProcess:()=>child})
 const p=project(),e=epoch(p),send=extra=>child.stdout.write(JSON.stringify({kind:'playing',currentTime:0,device:{id:'output',name:'Output',outputs:2},...e,...extra})+'\n')
 send();await handle.ready
 handle.seek(.125)
 let admitted=false
 const pending=handle.recordingEpoch().then(event=>{admitted=true;return recordingEpoch(event)})
 const request=commands.at(-1);assert.equal(request.kind,'recordingEpoch');assert.equal(commands[0].kind,'seek')
 send({recordingRequest:'old'});await new Promise(resolve=>setImmediate(resolve));assert.equal(admitted,false)
 send({recordingRequest:request.request})
 assert.deepEqual((await pending).clock.cycle,e.clock.cycle)
 const rejected=handle.recordingEpoch();send({kind:'paused',recordingRequest:commands.at(-1).request});await assert.rejects(rejected,/not playing/)
 send({kind:'stopped'});child.emit('close',0,null);await handle.completion
})

test('an absolute successful backing-stop fence trims source ticks without changing the repeating period',()=>{
 const p=project(),asset=source(),e={...epoch(p),end:String(origin+15600001n)}
 const result=recordedLoopRegions(p,asset,e),last=result.regions.at(-1)
 assert.equal(result.alignment.epoch.duration,.25)
 assert.equal(BigInt(last.offset)+BigInt(last.extent),15600001n)
 assert.equal(result.regions.length,3)
 for(const r of result.regions)correctPosition(p,asset,e,r)
 const start=240000000000000n,ns=start*125n/3n
 const midi=recordingEpoch({kind:'playing',loop:true,duration:.25,end:String(ns+650000001n),clock:{kind:'mach-nanoseconds',anchor:String(ns),position:0,cycle:{kind:'seconds',duration:.25}}})
 const cut=recordedLoopRegions(p,source(start),midi).regions.at(-1)
 assert.equal(BigInt(cut.offset)+BigInt(cut.extent),15600001n)
})

test('latency correction crossing a boundary never auto-selects audio and MIDI from different performances',()=>{
 for(const [seconds,ms,component] of [[.994,'-12.345','audio'],[1.004,'12.345','midi']]){
  const p=project(),asset=source();asset.manifest.audioFrames=String(Math.round((seconds-.1)*48000))
  const correction={kind:'audio',input:'input',output:'output',audioChannel:{input:1,output:2},placement:manualCapturePlacement(ms)}
  const result=attachRecordedTake(p,{project:{...p,assets:[asset]},asset:asset.id},epoch(p),correction)
  const selected=result.project.clips.flatMap((clip,index)=>result.project.lanes.find(l=>l.id===clip.lane).muted?[]:[result.alignment.passes[index]])
  assert.equal(selected.length,1);assert.equal(selected[0].cycle,'4');assert.equal(selected[0].component,component)
  assert.ok(result.alignment.passes.some(r=>r.cycle==='3' && r.component!==component))
 }
})
