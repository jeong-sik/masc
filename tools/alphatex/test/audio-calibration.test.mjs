import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { calibrationSelection, calibrationReference, analyzeCalibration } from '../audio-calibration.mjs'

async function fixture({ shift=37, polarity=1, silent=false, numer=125, denom=3 }={}) {
 const directory=await mkdtemp(join(tmpdir(),'masc-calibration-')),capture=join(directory,'capture');await mkdir(capture)
 const selection={output:'output',inputChannel:2,outputChannel:2,maxLagMs:10},reference=calibrationReference(48000,2,selection)
 const frames=reference.frames+1024,bytes=Buffer.alloc(44+frames*8);reference.wave.copy(bytes,0,0,44);bytes.writeUInt32LE(bytes.length-8,4);bytes.writeUInt32LE(frames*8,40)
 for(let i=0;i<frames;i++)bytes.writeFloatLE(.001*Math.sin(i),44+i*8)
 if(!silent)for(const pulse of reference.pulseFrames)for(let i=0;i<reference.probe.length;i++)bytes.writeFloatLE(polarity*reference.probe[i],44+(pulse+shift+i)*8+4)
 const origin=9007199254740993123n,rate=48000
 const manifest={schemaVersion:1,state:'recorded',input:{id:'input',name:'Input'},midiSources:[],sampleRate:rate,channels:2,audioFrames:String(frames),midiPacketCount:'0',
  clock:{kind:'mach-host-time',requestedStart:String(origin),firstAudioHostTime:String(origin),numer,denom}}
 const blocks=[]
 for(let offset=0;offset<frames;offset+=512)blocks.push({kind:'audio',frameOffset:String(offset),frameCount:Math.min(512,frames-offset),hostTime:String(origin+BigInt(offset)*1000000000n*BigInt(denom)/(BigInt(rate)*BigInt(numer))),deviceSampleTime:String(offset),peaks:[[0,0],[0,0]]})
 await Promise.all([writeFile(join(capture,'audio.wav'),bytes),writeFile(join(capture,'session.json'),JSON.stringify(manifest)),writeFile(join(capture,'audio-blocks.jsonl'),blocks.map(JSON.stringify).join('\n')+'\n'),writeFile(join(capture,'midi.ump.jsonl'),'')])
 const playback={kind:'playing',device:{id:'output',name:'Output',outputs:2},clock:{kind:'mach-host-time',anchor:String(origin),position:0,numer,denom,sampleRate:48000,presentationLatency:.01}}
 return {directory,selection,reference,playback,bytes,shift,numer,denom}
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
