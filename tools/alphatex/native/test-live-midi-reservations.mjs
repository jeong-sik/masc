// The real command compiles actual playback prefix scopes without device I/O.
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { spawnSync } from 'node:child_process'
const directory=await mkdtemp(join(tmpdir(),'masc-live-midi-reservations-'))
try {
 const names=['MidiTransport','UmpTransport','UmpOutput','UmpState','UmpLiveInput','UmpRegions','HybridMidiTransport','UmpLoopTransport','CaptureAudioClock','WaveLoopClock','LiveMidiReservations','LiveMidiMain']
 let result=spawnSync('xcrun',['swiftc','-parse-as-library','-D','MIDI_LIBRARY',...names.map(name=>new URL(name+'.swift',import.meta.url).pathname),'-o',join(directory,'probe'),'-framework','CoreMIDI'],{encoding:'utf8'})
 assert.equal(result.status,0,result.stderr)
 let serial=0
 async function inspect(plan,format,fail=false){
  const path=join(directory,String(serial++)+'.json');await writeFile(path,JSON.stringify(plan))
  const r=spawnSync(join(directory,'probe'),['reservations','--file',path,'--format',format],{encoding:'utf8'})
  if(fail){assert.equal(r.status,1,r.stdout);return}
  assert.equal(r.status,0,r.stdout+r.stderr);const value=JSON.parse(r.stdout);assert.equal(value.kind,'reservations');return value.reserved
 }
 const midi={schemaVersion:3,duration:1,sources:[{id:'source',timeline:{schemaVersion:2,duration:1,bindings:[{port:7,destination:'42'}],events:[
  {seconds:0,port:7,bytes:[0xc2,5]},{seconds:.01,port:7,bytes:[0xe2,0,64]},
  {seconds:.2,port:7,bytes:[0x92,60,100]},{seconds:.3,port:7,bytes:[0x82,60,77]},
  {seconds:.9,port:7,bytes:[0x93,61,100]},{seconds:1,port:7,bytes:[0x83,61,0]}]}}],
  regions:[{id:'clip',source:'source',startSeconds:0,sourceStart:.1,sourceEnd:.5,repeatCount:2}]}
 const claim=(destination,group,channel)=>({destination,scope:{kind:'channels',channels:[{group,channel}]}})
 assert.deepEqual(await inspect(midi,'midi-arrangement'),[claim('42',0,2)])
 const ump={schemaVersion:1,duration:1,sources:[{id:'take',extent:'1000000000',timeline:{schemaVersion:4,duration:1,clock:{origin:'0',numer:1,denom:1},bindings:[{source:'keys',destination:'42'}],packets:[
  {kind:'midi',protocol:2,hostTime:'0',source:'keys',timestampOrigin:'packet',words:[0x43e50000,0x87654321]},
  {kind:'midi',protocol:2,hostTime:'200000000',source:'keys',timestampOrigin:'packet',words:[0x43953c00,0x90010000]},
  {kind:'midi',protocol:2,hostTime:'300000000',source:'keys',timestampOrigin:'packet',words:[0x43853c00,0x12340000]},
  {kind:'midi',protocol:2,hostTime:'900000000',source:'keys',timestampOrigin:'packet',words:[0x41923d00,0x90010000]}]}}],regions:[{id:'take-clip',source:'take',startSeconds:0,offset:'100000000',extent:'400000000',repeatCount:2}]}
 assert.deepEqual(await inspect({schemaVersion:5,kind:'capture-arrangement',duration:1,umpRegions:ump},'capture-arrangement'),[claim('42',3,5)])
 assert.deepEqual(await inspect({schemaVersion:6,kind:'hybrid-arrangement',duration:1,midi,umpRegions:ump},'hybrid-arrangement'),[{destination:'42',scope:{kind:'channels',channels:[{group:0,channel:2},{group:3,channel:5}]}}])
 assert.deepEqual(await inspect({schemaVersion:2,kind:'mixed-arrangement',duration:1,midi},'mixed-arrangement'),[claim('42',0,2)])
 assert.deepEqual(await inspect({schemaVersion:4,kind:'capture-audio-arrangement',duration:1},'capture-audio-arrangement'),[])
 await inspect({schemaVersion:4,kind:'capture-audio-arrangement',duration:1,midi},'capture-audio-arrangement',true)
 await inspect({schemaVersion:6,kind:'hybrid-arrangement',duration:2,midi,umpRegions:ump},'hybrid-arrangement',true)
 const collision=structuredClone(ump);for(const row of collision.sources[0].timeline.packets)row.words[0]=(row.words[0]&0xf0f0ffff)|0x00020000
 await inspect({schemaVersion:6,kind:'hybrid-arrangement',duration:1,midi,umpRegions:collision},'hybrid-arrangement',true)
 const malformed=structuredClone(midi);malformed.regions[0].source='missing';await inspect(malformed,'midi-arrangement',true)
 // A short authored cycle keeps the original arrangement horizon intact.
 const loop={start:192,end:768,ppq:960,tempo:120},duration=(loop.end-loop.start)/960*60/120
 const looping={schemaVersion:5,kind:'capture-arrangement',duration,loop,umpRegions:ump}
 assert.deepEqual(await inspect(looping,'capture-arrangement'),[claim('42',3,5)])
 assert.deepEqual(await inspect({...looping,schemaVersion:6,kind:'hybrid-arrangement',midi},'hybrid-arrangement'),[{destination:'42',scope:{kind:'channels',channels:[{group:0,channel:2},{group:3,channel:5}]}}])
 const silent={...looping,loop:{...loop,start:2304,end:2880}}
 assert.deepEqual(await inspect(silent,'capture-arrangement'),[])
 await inspect({...looping,duration:1},'capture-arrangement',true)
 await inspect({...looping,schemaVersion:6,kind:'hybrid-arrangement',midi,umpRegions:collision},'hybrid-arrangement',true)
 console.log('LIVE_MIDI_RESERVATIONS_PASS: actual MIDI/UMP prefix scopes, physical port/group/channel merge, trimmed future exclusion, hybrid collision, hidden/malformed backing refusal; no devices opened')
} finally { await rm(directory,{recursive:true,force:true}) }
