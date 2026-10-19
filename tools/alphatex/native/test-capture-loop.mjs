// Render the production Voice and compare against explicit original source
// intervals in rational project time. No devices, display or snapshot oracle.
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { spawnSync } from 'node:child_process'
const root=await mkdtemp(join(tmpdir(),'masc-capture-loop-pcm-'))
const gcd=(a,b)=>{a=a<0n?-a:a;while(b)[a,b]=[b,a%b];return a}
const ratio=(n,d=1n)=>{const g=gcd(n,d);return[n/g,d/g]}
const add=([a,b],[c,d])=>ratio(a*d+c*b,b*d),sub=([a,b],[c,d])=>ratio(a*d-c*b,b*d)
const mul=([a,b],[c,d])=>ratio(a*c,b*d),div=([a,b],[c,d])=>ratio(a*d,b*c)
const floor=([a,b])=>a/b-(a<0n&&a%b?1n:0n),less=([a,b],[c,d])=>a*d<c*b
const seconds=([n,d])=>Number(n/d)+Number(n%d)/Number(d)
try{
 const cases=[]
 for(const rate of[48000,44100]){
  const wave=Buffer.alloc(44+128*8);wave.write('RIFF');wave.writeUInt32LE(wave.length-8,4);wave.write('WAVEfmt ',8)
  wave.writeUInt32LE(16,16);wave.writeUInt16LE(3,20);wave.writeUInt16LE(2,22);wave.writeUInt32LE(rate,24)
  wave.writeUInt32LE(rate*8,28);wave.writeUInt16LE(8,32);wave.writeUInt16LE(32,34);wave.write('data',36);wave.writeUInt32LE(128*8,40)
  for(let frame=0;frame<128;frame++){wave.writeFloatLE((frame+1)/512,44+frame*8);wave.writeFloatLE(-(frame+1)/512,48+frame*8)}
  await writeFile(join(root,`${rate}.wav`),wave)
  for(const tempo of[123.5,120.125])for(const[start,end,tick]of[[0,8,1],[1,3,0],[0,2,3],[3,9,0]]){
   const tickSeconds=ratio(1n,BigInt(tempo===123.5?1976:1922))
   const placement=add(mul(ratio(BigInt(tick)),tickSeconds),ratio(1n,7_000_000_000n))
   const ns=mul(placement,ratio(1_000_000_000n)),name=`${rate}-${tempo}-${start}-${end}-${tick}`
   const region={id:name,asset:'source',startSeconds:seconds(placement),offsetFrames:4,frameCount:7,repeat:3,
    component:'audio',audioChannel:{input:2,output:1},startNanoseconds:{numerator:String(ns[0]),denominator:String(ns[1])},
    captureClock:{origin:'18446744073600000000',offset:'71',extent:'24001',numer:125,denom:3,firstAudioHostTime:'18446744073600000250'}}
   cases.push({name,rate,tickSeconds,placement,loop:{start,end,tempo,ppq:960},region})
  }
 }
 await writeFile(join(root,'cases.json'),JSON.stringify(cases,(_,v)=>typeof v==='bigint'?String(v):v))
 const swift=`import Foundation
import AVFoundation
struct Case:Decodable{let name:String;let rate:Double;let loop:WaveLoopClock;let region:Region}
@main enum Probe{static func main()throws{
 let root=CommandLine.arguments[1],cases=try JSONDecoder().decode([Case].self,from:Data(contentsOf:URL(fileURLWithPath:root+"/cases.json")))
 for c in cases{
  let asset=Asset(id:"source",path:root+"/"+String(Int(c.rate))+".wav",sha256:"",sampleRate:c.rate,channels:2,frames:128)
  let plan=Plan(schemaVersion:4,kind:"capture-audio-arrangement",duration:c.loop.duration,assets:[asset],regions:[c.region],midi:nil,ump:nil,umpRegions:nil,loop:c.loop)
  try plan.validate()
  var mismatched=c.region;mismatched.startNanoseconds=CaptureStartNanoseconds(numerator:"1",denominator:"1")
  do{_ = try mismatched.loopLayout(c.loop,rate:c.rate);preconditionFailure("inconsistent exact placement admitted")}catch{}
  let voice=try Voice(region:c.region,asset:asset,capacity:257,outputChannels:2,loop:c.loop)
  let target=AVAudioPCMBuffer(pcmFormat:voice.format,frameCapacity:257)!
  for base:Int64 in [0,4_000_000_000]{
   voice.cursor=base;var samples:[Float]=[]
   for _ in 0..<4{
    let filled=try voice.fill(target);precondition(filled && target.frameLength==257 && voice.buffers.count==2)
    for i in 0..<Int(target.frameLength){samples.append(target.floatChannelData![0][i]);samples.append(target.floatChannelData![1][i])}
   }
   try samples.withUnsafeBytes{Data($0)}.write(to:URL(fileURLWithPath:root+"/"+c.name+"-"+String(base)+".pcm"))
  }
 }
 // Accepted exact fractions may have an intermediate frame*divisor wider
 // than UInt128. This phase must still be representable and streamable.
 let capture=try CaptureAudioClock(origin:"0",offset:"0",extent:"1000000000000000",numer:1,denom:4294967291,firstAudioHostTime:"1000").layout(rate:48000,offsetFrames:0,frameCount:7,repetitions:3)
 let huge=try WaveLoopClock(start:0,end:960,ppq:960,tempo:120.1).layout(rate:48000,start:CaptureStartNanoseconds(numerator:"1",denominator:"7"),startSeconds:1/7e9,capture:capture)
 let span=try huge.span(at:4_000_000_000,maximum:257);precondition(span.count>0)
 // Translating both exact origins must not overflow before cancellation.
 let n:UInt128=15393162788864004225643087868723,d:UInt128=29579501615081061
 let secondsD=d*1_000_000_000
 let translated=try WaveLoopClock(start:1_000_000_000,end:1_000_000_960,ppq:960,tempo:120.1).layout(rate:48000,
  start:CaptureStartNanoseconds(numerator:String(n),denominator:String(d)),
  startSeconds:Double(n/secondsD)+Double(n%secondsD)/Double(secondsD),capture:capture)
 for frame:Int64 in [0,1,24,48,256,4_000_000_000]{
  let original=try huge.span(at:frame,maximum:257),shifted=try translated.span(at:frame,maximum:257)
  precondition(original.source==shifted.source && original.count==shifted.count)
 }
 print("CAPTURE_LOOP_PCM_PASS")
}}
`
 await writeFile(join(root,'Probe.swift'),swift)
 const files=['WaveArrangement.swift','WaveLoopClock.swift','CaptureAudioClock.swift','PulseAudioClock.swift','MidiTransport.swift','UmpTransport.swift','UmpOutput.swift','UmpRegions.swift','HybridMidiTransport.swift','UmpLoopTransport.swift','UmpState.swift'].map(n=>new URL(n,import.meta.url).pathname)
 let result=spawnSync('xcrun',['swiftc','-parse-as-library','-D','MIDI_LIBRARY','-D','ARRANGEMENT_LIBRARY',...files,join(root,'Probe.swift'),'-o',join(root,'probe'),'-framework','AVFoundation','-framework','CoreAudio','-framework','CoreMIDI'],{encoding:'utf8'})
 assert.equal(result.status,0,result.stderr)
 result=spawnSync(join(root,'probe'),[root],{encoding:'utf8'});assert.equal(result.status,0,result.stderr)
 let checked=0
 for(const c of cases)for(const base of[0,4_000_000_000]){
  const data=await readFile(join(root,`${c.name}-${base}.pcm`))
  const rangeStart=mul(ratio(BigInt(c.loop.start)),c.tickSeconds),period=mul(ratio(BigInt(c.loop.end-c.loop.start)),c.tickSeconds)
  const sourcePeriod=ratio(24001n*125n,3_000_000_000n)
  const lead=add(ratio((250n-71n)*125n,3_000_000_000n),ratio(4n,BigInt(c.rate)))
  const intervals=Array.from({length:3},(_,copy)=>{
   const start=add(add(c.placement,mul(ratio(BigInt(copy)),sourcePeriod)),lead)
   return{start,end:add(start,ratio(7n,BigInt(c.rate)))}
  })
  for(let i=0;i<data.length/8;i++){
   const elapsed=ratio(BigInt(base+i),BigInt(c.rate)),project=add(rangeStart,sub(elapsed,mul(period,ratio(floor(div(elapsed,period))))))
   const interval=intervals.find(row=>!less(project,row.start)&&less(project,row.end))
   const source=interval?Number(floor(mul(sub(project,interval.start),ratio(BigInt(c.rate))))):null
   const expected=source===null?0:-(4+source+1)/512
   assert.equal(data.readFloatLE(i*8),expected,`${c.name} frame${base+i}`)
   assert.equal(data.readFloatLE(i*8+4),0,`source channel leaked at ${c.name} frame${base+i}`)
   checked++
  }
 }
 console.log(result.stdout.trim()+`: ${checked} original-interval sample pairs; two rates/tempos, captured gaps/trims/fractional placement/channel routing and far refill`)
}finally{await rm(root,{recursive:true,force:true})}
