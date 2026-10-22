import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile, readFile, readdir, rm } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import JZZ from 'jzz'
import { prepareCapturedPlayback, prepareCapturedWave } from '../capture-playback.mjs'

async function fixture(run) {
  const root=await mkdtemp(join(tmpdir(),'masc-capture-play-test-')),input=join(root,'original')
  try {
    await mkdir(input)
    const origin=9007199254740993123n,at=delta=>String(origin+BigInt(Math.round(delta*24000000)))
    const manifest={schemaVersion:1,state:'recorded',failure:null,audio:'audio.wav',audioBlocks:'audio-blocks.jsonl',midi:'midi.ump.jsonl',
      sampleRate:48000,channels:1,audioFrames:'4800',midiPacketCount:'3',input:{id:'interface',name:'Interface'},midiSources:[{id:'A',name:'Keys'},{id:'B',name:'Pads'}],
      clock:{kind:'mach-host-time',numer:125,denom:3,requestedStart:String(origin),firstAudioHostTime:at(.1)}}
    const wave=Buffer.alloc(44+9600);wave.write('RIFF');wave.writeUInt32LE(wave.length-8,4);wave.write('WAVEfmt ',8);wave.writeUInt32LE(16,16)
    wave.writeUInt16LE(1,20);wave.writeUInt16LE(1,22);wave.writeUInt32LE(48000,24);wave.writeUInt32LE(96000,28);wave.writeUInt16LE(2,32);wave.writeUInt16LE(16,34);wave.write('data',36);wave.writeUInt32LE(9600,40)
    const packet=(delta,source,message)=>{const bytes=Buffer.from([...message]);return {kind:'midi',protocol:2,source,hostTime:at(delta),timestampOrigin:'packet',words:Array.from({length:bytes.length/4},(_,i)=>bytes.readUInt32BE(i*4))}}
    const packets=[packet(.25,'A',JZZ.UMP.umpNoteOff(3,5,60,0x1234)),packet(-.02,'A',JZZ.UMP.umpNoteOn(3,5,60,0x9001)),packet(.05,'B',JZZ.UMP.umpPitchBend(1,2,0x87654321))]
    await writeFile(join(input,'audio.wav'),wave);await writeFile(join(input,'session.json'),JSON.stringify(manifest))
    await writeFile(join(input,'audio-blocks.jsonl'),JSON.stringify({kind:'audio',hostTime:at(.1),deviceSampleTime:'-12',frameOffset:'0',frameCount:4800,peaks:[[0,0]]})+'\n')
    const midi=packets.map(row=>JSON.stringify(row)).join('\n')+'\n';await writeFile(join(input,'midi.ump.jsonl'),midi)
    await run({root,input,manifest,packets,midi,wave})
  } finally {await rm(root,{recursive:true,force:true})}
}
test('a complete capture plan keeps raw packet order and integer clocks, pre-roll, delayed WAV origin and a MIDI tail',async()=>fixture(async({root,input,manifest,packets,midi,wave})=>{
  const prepared=await prepareCapturedPlayback(input,{directory:root,sourceBindings:[{source:'A',destination:'42'},{source:'B',destination:'-43'}]})
  const plan=JSON.parse(await readFile(prepared.path,'utf8'))
  assert.equal(prepared.format,'capture-session');assert.equal(plan.schemaVersion,3)
  assert.equal(plan.ump.clock.origin,packets[1].hostTime);assert.deepEqual(plan.ump.packets,packets)
  assert.equal(plan.assets[0].frames,4800);assert.equal(plan.regions[0].startSeconds,.12);assert.equal(plan.duration,.27)
  assert.equal(prepared.timelineOffsetSeconds,-.02)
  assert.ok(Math.abs(plan.regions[0].startSeconds+prepared.timelineOffsetSeconds-.1)<=manifest.clock.numer/manifest.clock.denom/1e9)
  assert.deepEqual(prepared.bindings,[{port:0,destination:'42'},{port:1,destination:'-43'}])
  assert.deepEqual(await readFile(plan.assets[0].path),wave);assert.equal(await readFile(join(input,'midi.ump.jsonl'),'utf8'),midi)
  await rm(input,{recursive:true});assert.deepEqual(await readFile(plan.assets[0].path),wave)
  assert.equal(manifest.clock.requestedStart,'9007199254740993123')
}))
test('capture route admission refuses missing/unused/duplicate source bindings and removes its private root',async()=>fixture(async({root,input,manifest})=>{
  const before=await readdir(root)
  for(const options of [{},{midiOutput:'01'},{sourceBindings:[{source:'A',destination:'42'},{source:'A',destination:'43'}]},
    {midiOutput:'42',sourceBindings:[{source:'missing',destination:'43'}]},
    {midiOutput:'42',expectedManifest:{...manifest,clock:{...manifest.clock,requestedStart:'0'}}}]) {
    await assert.rejects(prepareCapturedPlayback(input,{directory:root,...options}))
    assert.deepEqual(await readdir(root),before)
  }
  const abort=new AbortController();abort.abort()
  await assert.rejects(prepareCapturedPlayback(input,{directory:root,midiOutput:'42',signal:abort.signal}),{name:'AbortError'})
  assert.deepEqual(await readdir(root),before)
}))
test('selected-output WAV audition owns a native source snapshot independently of original capture files',async()=>fixture(async({root,input,wave,manifest})=>{
  const before=await readdir(root)
  await assert.rejects(prepareCapturedWave(input,{directory:root,expectedManifest:{...manifest,clock:{...manifest.clock,requestedStart:'0'}}}),/Captured take changed/)
  assert.deepEqual(await readdir(root),before)
  const prepared=await prepareCapturedWave(input,{directory:root,expectedManifest:manifest})
  assert.equal(prepared.format,'wave');assert.deepEqual(await readFile(prepared.path),wave)
  assert.equal(prepared.timelineOffsetSeconds,.1)
  await rm(input,{recursive:true});assert.deepEqual(await readFile(prepared.path),wave)
  assert.ok(dirname(prepared.path).startsWith(root))
}))
