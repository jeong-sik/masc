// Production PCM streaming and parser checks, without opening an audio device.
import assert from 'node:assert/strict'
import {mkdtemp,writeFile,readFile,rm}from'node:fs/promises'
import {join}from'node:path'
import {tmpdir}from'node:os'
import {spawnSync}from'node:child_process'
const root=await mkdtemp(join(tmpdir(),'masc-wave-loop-native-'))
try{
 for(const rate of[48000,44100]){
  const bytes=Buffer.alloc(44+64*4);bytes.write('RIFF');bytes.writeUInt32LE(bytes.length-8,4);bytes.write('WAVEfmt ',8);bytes.writeUInt32LE(16,16);bytes.writeUInt16LE(3,20);bytes.writeUInt16LE(1,22);bytes.writeUInt32LE(rate,24);bytes.writeUInt32LE(rate*4,28);bytes.writeUInt16LE(4,32);bytes.writeUInt16LE(32,34);bytes.write('data',36);bytes.writeUInt32LE(256,40)
  for(let n=0;n<64;n++)bytes.writeFloatLE((n+1)/128,44+n*4)
  await writeFile(join(root,rate+'.wav'),bytes)
 }
 const swift=`import Foundation
import AVFoundation
@main enum Probe {static func main() throws {
let root=CommandLine.arguments[1]
for rate in [48000,44100] { for (index,spec) in [(0,[Int64(0),2,1,7,2,0]),(1,[1,3,0,60,1,0]),(2,[0,2,0,7,1000000,8])] {
 let clock=WaveLoopClock(start:spec[0],end:spec[1],ppq:960,tempo:123.5)
 var region=Region(id:"r",asset:"a",startSeconds:Double(spec[2])/960*60/123.5,offsetFrames:spec[5],frameCount:spec[3],repetitions:spec[4],captureClock:nil)
 region.projectTick=spec[2]
 let asset=Asset(id:"a",path:root+"/"+String(rate)+".wav",sha256:"",sampleRate:Double(rate),channels:1,frames:64)
 var plan=Plan(schemaVersion:1,kind:"wave-arrangement",duration:clock.duration,assets:[asset],regions:[region],midi:nil,ump:nil,umpRegions:nil);plan.loop=clock
 try plan.validate()
 let voice=try Voice(region:region,asset:asset,capacity:257,outputChannels:1,loop:clock)
 let buffer=AVAudioPCMBuffer(pcmFormat:voice.format,frameCapacity:257)!
 var samples:[Float]=[]
 for _ in 0..<4 {let filled=try voice.fill(buffer);precondition(filled);samples+=Array(UnsafeBufferPointer(start:buffer.floatChannelData![0],count:Int(buffer.frameLength)))}
 let data=samples.withUnsafeBytes{Data($0)};try data.write(to:URL(fileURLWithPath:root+"/"+String(rate)+"-"+String(index)+".pcm"))
 // Far positions remain compressed and bounded by the same two stream buffers.
 voice.cursor=4_000_000_000;let filled=try voice.fill(buffer);precondition(filled && buffer.frameLength==257 && voice.buffers.count==2)
 let far=Data(bytes:buffer.floatChannelData![0],count:Int(buffer.frameLength)*4);try far.write(to:URL(fileURLWithPath:root+"/"+String(rate)+"-"+String(index)+"-far.pcm"))
}}
print("WAVE_LOOP_PCM_PASS")
}}
`
 await writeFile(join(root,'Probe.swift'),swift)
 const files=['WaveArrangement.swift','WaveLoopClock.swift','SourceAudioClock.swift','CaptureAudioClock.swift','PulseAudioClock.swift','PulseLoopClock.swift','MidiTransport.swift','UmpTransport.swift','UmpOutput.swift','UmpRegions.swift','HybridMidiTransport.swift','UmpLoopTransport.swift','UmpState.swift'].map(n=>new URL(n,import.meta.url).pathname)
 let r=spawnSync('xcrun',['swiftc','-parse-as-library','-D','MIDI_LIBRARY','-D','ARRANGEMENT_LIBRARY',...files,join(root,'Probe.swift'),'-o',join(root,'probe'),'-framework','AVFoundation','-framework','CoreAudio','-framework','CoreMIDI'],{encoding:'utf8'});assert.equal(r.status,0,r.stderr)
 r=spawnSync(join(root,'probe'),[root],{encoding:'utf8'});assert.equal(r.status,0,r.stderr)
 // Independently sample the authored half-open source signal in project time.
 // At123.5 BPM and960PPQ one tick is exactly rate/1976 source frames.
 for(const rate of[48000,44100])for(const[index,[start,end,tick,extent,repeat,offset]]of [[0,[0,2,1,7,2,0]],[1,[1,3,0,60,1,0]],[2,[0,2,0,7,1000000,8]]]){
  for(const base of [0,4_000_000_000]){
  const bytes=await readFile(join(root,`${rate}-${index}${base?'-far':''}.pcm`))
  for(let local=0;local<bytes.length/4;local++){
   const frame=base+local
   const phase=(BigInt(frame)*1976n)%BigInt((end-start)*rate),position=phase+BigInt((start-tick)*rate)
   const source=position<0n?null:Number(position/1976n)
   const expected=source===null||source>=extent*repeat?0:(offset+source%extent+1)/128
   assert.equal(bytes.readFloatLE(local*4),expected,`rate${rate} scenario${index} frame${frame}`)
  }
 }
 }
 console.log(r.stdout.trim()+': 7710 exact PCM samples; two rates, partial cuts, gaps, finite source repeats, million-copy clip and far refill')
}finally{await rm(root,{recursive:true,force:true})}
