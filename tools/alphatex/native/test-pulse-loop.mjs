// Sample the production loop pulse against independent BigInt project/beat
// intervals. No devices, display strings or repeat-sized message schedules.
import assert from 'node:assert/strict'
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises'
import {tmpdir} from 'node:os'
import {join} from 'node:path'
import {spawnSync} from 'node:child_process'
import {practiceClock} from '../arrangement-practice.mjs'
const gcd=(a,b)=>{while(b)[a,b]=[b,a%b];return a}
const ratio=(n,d=1n)=>{const g=gcd(n,d);return [n/g,d/g]}
const add=([a,b],[c,d])=>ratio(a*d+c*b,b*d),mul=([a,b],[c,d])=>ratio(a*c,b*d)
const div=([a,b],[c,d])=>ratio(a*d,b*c),floor=([n,d])=>n/d
const subtract=([a,b],[c,d])=>ratio(a*d-c*b,b*d)
const ieee=value=>{const v=new DataView(new ArrayBuffer(8));v.setFloat64(0,value);const bits=v.getBigUint64(0),e=Number(bits>>52n&2047n);let n=(bits&((1n<<52n)-1n))+(e?1n<<52n:0n),d=1n,shift=e?e-1075:-1074;if(shift<0)d<<=BigInt(-shift);else n<<=BigInt(shift);return ratio(n,d)}
const cases=[]
for(const [tempo,unit,beats,rate,start,end] of [
 [137,8,7,48000,137,3500],[123.5,4,4,44100,960,2880],
 [120.1,16,5,48000,3,1691],[137,512,3,44100,15,83],
 [120,4,4,48000,0,3840],[120,4,4,48000,960,2880],
 [120,4,4,48000,1_000_000_000_000,1_000_000_003_840],
 [65537,4,4,48000,0,65537],
]){
 const practice={countInBars:1,metronome:true},clock=practiceClock({tempo,meter:[beats,unit],practice})
 cases.push({tempo,unit,beats,rate,start,end,period:clock.period})
}
const root=await mkdtemp(join(tmpdir(),'masc-pulse-loop-'))
try{
 await writeFile(join(root,'cases.json'),JSON.stringify(cases))
 for(const rate of [48000,44100]){
  const bytes=Buffer.alloc(44+576*4);bytes.write('RIFF');bytes.writeUInt32LE(bytes.length-8,4);bytes.write('WAVEfmt ',8)
  bytes.writeUInt32LE(16,16);bytes.writeUInt16LE(3,20);bytes.writeUInt16LE(1,22);bytes.writeUInt32LE(rate,24);bytes.writeUInt32LE(rate*4,28)
  bytes.writeUInt16LE(4,32);bytes.writeUInt16LE(32,34);bytes.write('data',36);bytes.writeUInt32LE(576*4,40)
  for(let i=0;i<576;i++)bytes.writeFloatLE((i+1)/1024,44+i*4)
  await writeFile(join(root,rate+'.wav'),bytes)
 }
 const swift=`import Foundation
import AVFoundation
struct Case:Decodable{let tempo:Double;let unit:Int64,beats:Int64,rate:Double,start:Int64,end:Int64;let period:PulseAudioClock.Period}
@main enum Probe{static func main()throws{
 let root=CommandLine.arguments[1],cases=try JSONDecoder().decode([Case].self,from:Data(contentsOf:URL(fileURLWithPath:root+"/cases.json")))
 var rows:[[String:Any]]=[]
 let boundaryPulse=PulseAudioClock(period:.init(numerator:"1000000000",denominator:"1"),beatsPerBar:4,duration:1)
 for (start,end):(Int64,Int64) in [(Int64.min,Int64.max),(-1,960),(960,960),(961,960),(0,Int64.max)] {
  do{
   _ = try PulseLoopLayout(loop:WaveLoopClock(start:start,end:end,ppq:960,tempo:120),pulse:boundaryPulse,unit:4,rate:48000,frameCount:576)
   preconditionFailure("invalid loop admitted")
  }catch{}
 }
 for (index,c) in cases.enumerated(){
  let loop=WaveLoopClock(start:c.start,end:c.end,ppq:960,tempo:c.tempo)
  let pulse=PulseAudioClock(period:c.period,beatsPerBar:c.beats,duration:loop.duration)
  let layout=try PulseLoopLayout(loop:loop,pulse:pulse,unit:c.unit,rate:c.rate,frameCount:576)
  var region=Region(id:"click",asset:"a",startSeconds:0,offsetFrames:0,frameCount:576,repetitions:1,captureClock:nil)
  region.pulseClock=pulse;region.pulseLoopUnit=c.unit
  let asset=Asset(id:"a",path:root+"/"+String(Int(c.rate))+".wav",sha256:"",sampleRate:c.rate,channels:1,frames:576)
  var plan=Plan(schemaVersion:1,kind:"wave-arrangement",duration:loop.duration,assets:[asset],regions:[region],midi:nil,ump:nil,umpRegions:nil)
  plan.loop=loop;plan.practice=PracticePlan(countInSeconds:0,duration:loop.duration,loop:LoopPracticePlan(period:c.period,countInBeats:"0",beatsPerBar:c.beats,unit:c.unit,metronome:true))
  try plan.validate()
  let voice=try Voice(region:region,asset:asset,capacity:257,outputChannels:1,loop:loop)
  let buffer=AVAudioPCMBuffer(pcmFormat:voice.format,frameCapacity:257)!
  for base:Int64 in [0,1,4000000000,Int64.max-257]{
   voice.cursor=base
   let filled=try voice.fill(buffer);precondition(filled && buffer.frameLength==257 && voice.buffers.count==2)
   try Data(bytes:buffer.floatChannelData![0],count:257*4).write(to:URL(fileURLWithPath:root+"/pcm-"+String(index)+"-"+String(base)))
   var frame=base
   while frame<base+257{
    let span=try layout.span(at:frame,maximum:base+257-frame)
    precondition(span.count>0 && span.count<=base+257-frame)
    rows.append(["case":index,"frame":String(frame),"count":span.count,"source":span.source as Any? ?? NSNull(),"gain":span.gain])
    frame+=span.count
   }
  }
  // Reconstructed streams cannot silently run an unrelated pulse tempo.
  do{_ = try PulseLoopLayout(loop:loop,pulse:PulseAudioClock(period:.init(numerator:"1",denominator:"1"),beatsPerBar:c.beats,duration:loop.duration),unit:c.unit,rate:c.rate,frameCount:576);preconditionFailure("wrong pulse admitted")}catch{}
 }
 try JSONSerialization.data(withJSONObject:rows).write(to:URL(fileURLWithPath:root+"/rows.json"))
 print("PULSE_LOOP_NATIVE_PASS")
}}
`
 await writeFile(join(root,'Probe.swift'),swift)
 const names=['WaveArrangement','WaveLoopClock','CaptureAudioClock','PulseAudioClock','PulseLoopClock','MidiTransport','UmpTransport','UmpOutput','UmpRegions','UmpLoopTransport','HybridMidiTransport','UmpState']
 let r=spawnSync('xcrun',['swiftc','-parse-as-library','-D','MIDI_LIBRARY','-D','ARRANGEMENT_LIBRARY',...names.map(n=>new URL(n+'.swift',import.meta.url).pathname),join(root,'Probe.swift'),'-o',join(root,'probe'),'-framework','AVFoundation','-framework','CoreAudio','-framework','CoreMIDI'],{encoding:'utf8'})
 assert.equal(r.status,0,r.stderr);r=spawnSync(join(root,'probe'),[root],{encoding:'utf8'});assert.equal(r.status,0,r.stdout+r.stderr)
 let checked=0
 for(const row of JSON.parse(await readFile(join(root,'rows.json'),'utf8'))){
  const c=cases[row.case],quarter=div([60n,1n],ieee(c.tempo)),tick=div(quarter,[960n,1n])
  const period=mul(tick,[BigInt(c.end-c.start),1n]),origin=mul(tick,[BigInt(c.start),1n])
  const beat=mul(quarter,[4n,BigInt(c.unit)]),length=Math.min(576,Number(floor(mul(beat,[BigInt(c.rate),1n]))))
  for(let offset=0;offset<row.count;offset++){
   const frame=BigInt(row.frame)+BigInt(offset),time=[frame,BigInt(c.rate)]
   const phase=subtract(time,mul(period,[floor(div(time,period)),1n])),position=add(origin,phase)
   const copy=floor(div(position,beat)),local=subtract(position,mul(beat,[copy,1n]))
   const sample=Number(floor(mul(local,[BigInt(c.rate),1n])))
   assert.equal(row.source===null?null:row.source+offset,sample<length?sample:null,`case${row.case} sample${frame}`)
   // Gain on a silence span carries no audible authority and can cross
   // several virtual beat indices between adjacent source samples.
   if(sample<length)assert.equal(row.gain,copy%BigInt(c.beats)===0n?1:.5)
   checked++
  }
 }
 // Verify the actual retained Voice PCM separately from layout return values.
 for(let i=0;i<cases.length;i++)for(const base of [0n,1n,4_000_000_000n,9223372036854775550n]){
  const pcm=await readFile(join(root,`pcm-${i}-${base}`)),c=cases[i]
  const quarter=div([60n,1n],ieee(c.tempo)),tick=div(quarter,[960n,1n]),period=mul(tick,[BigInt(c.end-c.start),1n])
  const origin=mul(tick,[BigInt(c.start),1n]),beat=mul(quarter,[4n,BigInt(c.unit)])
  const length=Math.min(576,Number(floor(mul(beat,[BigInt(c.rate),1n]))))
  for(let offset=0;offset<257;offset++){
   const time=[base+BigInt(offset),BigInt(c.rate)],phase=subtract(time,mul(period,[floor(div(time,period)),1n]))
   const position=add(origin,phase),copy=floor(div(position,beat)),sample=Number(floor(mul(subtract(position,mul(beat,[copy,1n])),[BigInt(c.rate),1n])))
   assert.equal(pcm.readFloatLE(offset*4),sample<length?(sample+1)/1024*(copy%BigInt(c.beats)===0n?1:.5):0,`PCM case${i} frame${base+BigInt(offset)}`)
  }
 }
 console.log(r.stdout.trim()+`: ${cases.length} original meter grids / ${checked} rational span samples plus ${checked} actual Voice PCM samples, partial bars, two rates, small loops, translated origin and far full-width phase; five invalid clocks refused`)
}finally{await rm(root,{recursive:true,force:true})}
