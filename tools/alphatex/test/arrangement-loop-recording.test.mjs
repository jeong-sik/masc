import test from 'node:test'
import assert from 'node:assert/strict'
import { recordingEpoch, recordedLoopRegions, attachRecordedTake } from '../arrangement-recording.mjs'
import { newArrangement, editArrangement, arrangementSchedule, arrangementTakes, validateArrangement } from '../arrangement.mjs'
import { captureRange } from '../capture-time.mjs'
import { projectCapturedPlacement, manualCapturePlacement } from '../capture-placement.mjs'
import { arrangementEditor, arrangementImported, arrangementAction, arrangementCommand } from '../arrangement-editor.mjs'

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

test('take lanes retain every pass, last pass selected, one import undo and redo, and immutable source',()=>{
 const p=project(),asset=source(),e=epoch(p)
 const result=attachRecordedTake(p,{project:{...p,assets:[asset]},asset:asset.id},e)
 assert.ok(result.project.lanes.length>1)
 assert.ok(result.project.lanes.every(l=>!l.muted));assert.equal(arrangementSchedule(result.project).length,1)
 assert.equal(arrangementSchedule(result.project)[0].takeCycle,result.project.assets[0].selectedTake)
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
  assert.equal(arrangementSchedule(result.project).length,2)
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
  const selected=arrangementSchedule(result.project)
  assert.equal(selected.length,1);assert.equal(selected[0].takeCycle,'4');assert.equal(selected[0].component,component)
  assert.ok(result.alignment.passes.some(r=>r.cycle==='3' && r.component!==component))
 }
})


test('one take command selects the paired original pass, undo/redo and renamed reordered lanes retain identity',()=>{
 const p=project(),asset=source(),e=epoch(p),correction={kind:'audio',input:'input',output:'output',audioChannel:{input:1,output:2},placement:manualCapturePlacement('-12.345')}
 const attached=attachRecordedTake(p,{project:{...p,assets:[asset]},asset:asset.id},e,correction)
 let view=arrangementImported(arrangementEditor(p),attached)
 const original=view.project,sourceFiles=structuredClone(original.assets[0].parts),passes=structuredClone(original.assets[0].recording)
 const command=line=>{view=arrangementCommand(view,line).editor}
 command('take 2')
 const selected=view.project
 assert.equal(selected.assets[0].selectedTake,'1')
 assert.deepEqual(arrangementSchedule(selected).map(c=>[c.takeCycle,c.component]).sort(),[['1','audio'],['1','midi']])
 assert.equal(view.undo.length,2)
 command('take 2');assert.equal(view.project,selected);assert.equal(view.undo.length,2)
 command('undo');assert.equal(view.project,original)
 command('redo');assert.equal(view.project,selected)
 command('lane-name arbitrary label')
 command('take next');assert.equal(view.project.assets[0].selectedTake,'2')
 command('take previous');assert.equal(view.project.assets[0].selectedTake,'1')
 assert.deepEqual(view.project.assets[0].parts,sourceFiles);assert.deepEqual(view.project.assets[0].recording,passes)
 const reordered={...view.project,clips:[...view.project.clips].reverse(),lanes:[...view.project.lanes].reverse()}
 view=arrangementEditor(reordered);view={...view,asset:asset.id}
 command('take 1');assert.ok(arrangementSchedule(view.project).every(c=>c.takeCycle==='0'))
 assert.deepEqual(arrangementCommand(view,'takes').effect,{kind:'takes',asset:asset.id})
})

test('take selection preserves independent lane choices and does not activate unrelated assets or manually placed regions',()=>{
 const p=project(),asset=source(),e=epoch(p),a=attachRecordedTake(p,{project:{...p,assets:[asset]},asset:asset.id},e)
 let doc=a.project
 const other={...source(),id:'asset-2',name:'Another recording'}
 const second=attachRecordedTake(doc,{project:editArrangement(doc,{kind:'asset-add',asset:other}),asset:other.id},e)
 doc=editArrangement(second.project,{kind:'take-select',asset:asset.id,cycle:'1'})
 assert.equal(doc.assets[1].selectedTake,second.project.assets[1].selectedTake)
 const browsing=arrangementCommand({...arrangementEditor(doc),asset:asset.id},'takes asset-2')
 assert.equal(browsing.editor.asset,'asset-2');assert.equal(browsing.effect.asset,'asset-2')
 const compare=arrangementCommand(browsing.editor,'take next').editor
 assert.equal(compare.project.assets[0].selectedTake,'1');assert.equal(compare.project.assets[1].selectedTake,'0')

 const c=doc.clips.find(c=>c.asset===asset.id&&c.takeCycle==='1')
 doc=editArrangement(doc,{kind:'lane-mute',id:c.lane})
 const muted=doc.lanes.find(l=>l.id===c.lane)
 doc=editArrangement(doc,{kind:'take-select',asset:asset.id,cycle:'2'})
 assert.deepEqual(doc.lanes.find(l=>l.id===c.lane),muted)
 // Normal copied source placement is independent; duplication keeps take identity.
 doc=editArrangement(doc,{kind:'region-duplicate',id:c.id,position:4000})
 assert.equal(doc.clips.at(-1).takeCycle,'1')
 assert.ok(!arrangementSchedule(doc).some(active=>active.id===doc.clips.at(-1).id))
 doc=editArrangement(doc,{kind:'region-add',asset:asset.id,lane:c.lane,name:'Independent placement',position:8000,offset:'0',extent:'2400000'})
 assert.equal(doc.clips.at(-1).takeCycle,undefined)
 doc=editArrangement(doc,{kind:'lane-mute',id:c.lane})
 assert.ok(arrangementSchedule(doc).some(active=>active.id===doc.clips.at(-1).id))
 assert.equal(arrangementSchedule(doc,{all:true}).length,doc.clips.length)
})

test('partial corrected passes stay paired through selection, splitting, duplication and removal; unavailable numbers fail closed',()=>{
 const p=project(),asset=source();asset.manifest.audioFrames='42912'
 const e=epoch(p),correction={kind:'audio',input:'input',output:'output',audioChannel:{input:1,output:2},placement:manualCapturePlacement('-12.345')}
 const a=attachRecordedTake(p,{project:{...p,assets:[asset]},asset:asset.id},e,correction)
 let view=arrangementImported(arrangementEditor(p),a)
 assert.deepEqual(arrangementSchedule(view.project).map(c=>[c.takeCycle,c.component]),[['4','audio']])
 view=arrangementCommand(view,'take previous').editor
 assert.deepEqual(arrangementSchedule(view.project).map(c=>[c.takeCycle,c.component]).sort(),[['3','audio'],['3','midi']])
 for(const clip of view.project.clips.filter(c=>c.takeCycle==='3'))view={...view,project:editArrangement(view.project,{kind:'region-remove',id:clip.id})}
 assert.equal(arrangementSchedule(view.project).length,0)
 assert.throws(()=>arrangementCommand(view,'take 4'),/no remaining/)
 view=arrangementCommand(view,'take next').editor;assert.equal(view.project.assets[0].selectedTake,'4')
 view=arrangementCommand(view,'take next').editor;assert.equal(view.project.assets[0].selectedTake,'0')
 for(const bad of ['take 0','take -1','take 01','take 1.5','take 9007199254740993','take next missing'])assert.throws(()=>arrangementCommand(view,bad))
 const paired=attachRecordedTake(p,{project:{...p,assets:[source()]},asset:asset.id},e).project
 const original=paired.clips[0]
 const split=editArrangement(paired,{kind:'capture-split',id:original.id})
 assert.equal(split.clips.at(-1).takeCycle,original.takeCycle)
 const chosen=editArrangement(split,{kind:'take-select',asset:asset.id,cycle:original.takeCycle})
 assert.deepEqual(arrangementSchedule(chosen).map(c=>c.component).sort(),['audio','midi'])
})

test('saved take metadata rejects invalid cycles and stays exact beyond numeric tick precision',()=>{
 const p=project(),asset=source(),a=attachRecordedTake(p,{project:{...p,assets:[asset]},asset:asset.id},epoch(p))
 const doc=structuredClone(a.project),huge='9007199254740993000001'
 doc.assets[0].recording.passes[0].cycle=huge;doc.clips[0].takeCycle=huge
 doc.assets[0].selectedTake=huge
 validateArrangement(doc)
 const view=arrangementCommand({...arrangementEditor(doc),asset:asset.id},`take ${BigInt(huge)+1n}`).editor
 assert.equal(view.project.assets[0].selectedTake,huge)
 assert.equal(arrangementTakes(view.project,asset.id).takes.at(-1).cycle,huge)
 assert.deepEqual(JSON.parse(JSON.stringify(view.project)),view.project)
 for(const invalid of [-1,1,'01','-0','1.5','']){
  const broken=structuredClone(a.project);broken.clips[0].takeCycle=invalid;assert.throws(()=>validateArrangement(broken))
  const selection=structuredClone(a.project);selection.assets[0].selectedTake=invalid;assert.throws(()=>validateArrangement(selection))
 }
 const missing=structuredClone(a.project);missing.clips[0].takeCycle='99999';assert.throws(()=>validateArrangement(missing),/missing/)
})
