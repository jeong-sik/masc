// Actual production plan parsing and PCM refill; no device or terminal oracle.
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { spawnSync } from 'node:child_process'
import { sourceAudioFrames } from '../source-audio-clock.mjs'
const root = await mkdtemp(join(tmpdir(), 'masc-source-audio-clock-'))
const gcd=(a,b)=>{while(b)[a,b]=[b,a%b];return a}
const rat=(n,d=1n)=>{const g=gcd(n<0n?-n:n,d);return[n/g,d/g]}
const add=([a,b],[c,d])=>rat(a*d+c*b,b*d),sub=([a,b],[c,d])=>rat(a*d-c*b,b*d)
const mul=([a,b],[c,d])=>rat(a*c,b*d),div=([a,b],[c,d])=>rat(a*d,b*c)
const floor=([a,b])=>a/b-(a<0n&&a%b?1n:0n),less=([a,b],[c,d])=>a*d<c*b
const ceil=([n,d])=>n/d+(n%d?1n:0n)
try {
 const cases=[]
 for(const rate of [44100,48000]) {
  const frames=65536,b=Buffer.alloc(44+frames*4)
  b.write('RIFF');b.writeUInt32LE(b.length-8,4);b.write('WAVEfmt ',8);b.writeUInt32LE(16,16);b.writeUInt16LE(3,20);b.writeUInt16LE(1,22)
  b.writeUInt32LE(rate,24);b.writeUInt32LE(rate*4,28);b.writeUInt16LE(4,32);b.writeUInt16LE(32,34);b.write('data',36);b.writeUInt32LE(frames*4,40)
  for(let i=0;i<frames;i++)b.writeFloatLE((i+1)/131072,44+i*4)
  await writeFile(join(root,rate+'.wav'),b)
  for(const [index,clock]of[
   {start:'0',end:'437956',denominator:'1000000'},
   {start:'1',end:'17',denominator:'200000'},
   {start:'1',end:'2',denominator:'1000000000'},
   {start:'0',end:'1',denominator:'1000000000'},
   {start:'1001',end:'2002',denominator:'2400000'},
  ].entries())for(const loop of [false,true]) {
   const cut=sourceAudioFrames(clock,rate),repeat=2000000,name=`${rate}-${index}-${loop}`
   const region={id:name,asset:'source',startSeconds:1/1976,projectTick:1,...cut,repeat,sourceClock:clock}
   const period=rat((BigInt(clock.end)-BigInt(clock.start))*BigInt(repeat),BigInt(clock.denominator))
   const total=ceil(mul(period,rat(BigInt(rate))))
   const bases=loop?[0,4000000000]:[0,Number(total/2n),Math.max(0,Number(total)-257)]
   cases.push({name,rate,region,loop:loop?{start:0,end:960,ppq:960,tempo:123.5}:null,bases})
  }
 }
 await writeFile(join(root,'cases.json'),JSON.stringify(cases))
 await writeFile(join(root,'Probe.swift'),`import Foundation
import AVFoundation
struct Case: Decodable { let name:String; let rate:Double; let region:Region; let loop:WaveLoopClock?; let bases:[Int64] }
@main enum Probe { static func main() throws {
 let root=CommandLine.arguments[1]
 let cases=try JSONDecoder().decode([Case].self,from:Data(contentsOf:URL(fileURLWithPath:root+"/cases.json")))
 var rows:[[String:Any]]=[]
 for c in cases {
  let asset=Asset(id:"source",path:root+"/"+String(Int(c.rate))+".wav",sha256:"",sampleRate:c.rate,channels:1,frames:65536)
  let layout=try c.region.sourceClock!.layout(rate:c.rate,offsetFrames:c.region.offsetFrames,frameCount:c.region.frameCount,repetitions:c.region.repetitions)
  let duration=c.loop?.duration ?? c.region.startSeconds+Double(layout.totalFrames)/c.rate
  let plan=Plan(schemaVersion:1,kind:"wave-arrangement",duration:duration,assets:[asset],regions:[c.region],midi:nil,ump:nil,umpRegions:nil,loop:c.loop)
  try plan.validate()
  do { _ = try c.region.sourceClock!.layout(rate:c.rate,offsetFrames:c.region.offsetFrames,frameCount:c.region.frameCount+1,repetitions:c.region.repetitions);preconditionFailure("wrong sample cut admitted") }catch{}
  let voice=try Voice(region:c.region,asset:asset,capacity:257,outputChannels:1,loop:c.loop)
  let target=AVAudioPCMBuffer(pcmFormat:voice.format,frameCapacity:257)!
  for base in c.bases {
   voice.cursor=base;var samples:[Float]=[]
   for _ in 0..<4 { if try !voice.fill(target) {break};samples+=Array(UnsafeBufferPointer(start:target.floatChannelData![0],count:Int(target.frameLength))) }
   precondition(!samples.isEmpty && voice.buffers.count==2)
   let file=c.name+"-"+String(base)+".pcm"
   try samples.withUnsafeBytes{Data($0)}.write(to:URL(fileURLWithPath:root+"/"+file))
   rows.append(["name":c.name,"base":base,"file":file,"frames":samples.count])
  }
 }
 let reply=try JSONSerialization.data(withJSONObject:rows);try reply.write(to:URL(fileURLWithPath:root+"/rows.json"))
 print("SOURCE_AUDIO_PCM_PASS")
}}
`)
 const files=['WaveArrangement.swift','WaveLoopClock.swift','SourceAudioClock.swift','CaptureAudioClock.swift','PulseAudioClock.swift','PulseLoopClock.swift','MidiTransport.swift','UmpTransport.swift','UmpOutput.swift','UmpRegions.swift','HybridMidiTransport.swift','UmpLoopTransport.swift','UmpState.swift'].map(n=>new URL(n,import.meta.url).pathname)
 let result=spawnSync('xcrun',['swiftc','-parse-as-library','-D','MIDI_LIBRARY','-D','ARRANGEMENT_LIBRARY',...files,join(root,'Probe.swift'),'-o',join(root,'probe'),'-framework','AVFoundation','-framework','CoreAudio','-framework','CoreMIDI'],{encoding:'utf8'})
 assert.equal(result.status,0,result.stderr)
 result=spawnSync(join(root,'probe'),[root],{encoding:'utf8'});assert.equal(result.status,0,result.stderr)
 let checked=0
 for(const row of JSON.parse(await readFile(join(root,'rows.json'),'utf8'))) {
  const c=cases.find(c=>c.name===row.name),r=c.region,clock=r.sourceClock
  const start=rat(BigInt(clock.start),BigInt(clock.denominator)),end=rat(BigInt(clock.end),BigInt(clock.denominator)),period=sub(end,start)
  const first=ceil(mul(start,rat(BigInt(c.rate)))),after=ceil(mul(end,rat(BigInt(c.rate))))
  const bytes=await readFile(join(root,row.file))
  for(let i=0;i<row.frames;i++) {
   let relative=rat(BigInt(row.base+i),BigInt(c.rate))
   if(c.loop)relative=sub(add(rat(BigInt(c.loop.start),1976n),sub(relative,mul(rat(floor(div(relative,rat(BigInt(c.loop.end-c.loop.start),1976n)))),rat(BigInt(c.loop.end-c.loop.start),1976n)))),rat(1n,1976n))
   let expected=0
   if(!less(relative,rat(0n))) {
    const copy=floor(div(relative,period))
    if(copy<BigInt(r.repeat)) {
     const source=add(start,sub(relative,mul(period,rat(copy)))),sample=floor(mul(source,rat(BigInt(c.rate))))
     if(sample>=first&&sample<after)expected=(Number(sample)+1)/131072
    }
   }
   assert.equal(bytes.readFloatLE(i*4),expected,`${c.name} frame${row.base+i}`);checked++
  }
 }
 console.log(`${result.stdout.trim()}: ${checked} exact production PCM samples; fractional PPQ/SMPTE cuts, two million compressed copies, empty/subframe cuts, loop and far seek`)
}finally { await rm(root,{recursive:true,force:true}) }
