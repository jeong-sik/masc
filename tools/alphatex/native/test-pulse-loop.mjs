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
 const swift=`import Foundation
struct Case:Decodable{let tempo:Double;let unit:Int64,beats:Int64,rate:Double,start:Int64,end:Int64;let period:PulseAudioClock.Period}
@main enum Probe{static func main()throws{
 let root=CommandLine.arguments[1],cases=try JSONDecoder().decode([Case].self,from:Data(contentsOf:URL(fileURLWithPath:root+"/cases.json")))
 var rows:[[String:Any]]=[]
 for (index,c) in cases.enumerated(){
  let loop=WaveLoopClock(start:c.start,end:c.end,ppq:960,tempo:c.tempo)
  let pulse=PulseAudioClock(period:c.period,beatsPerBar:c.beats,duration:loop.duration)
  let layout=try PulseLoopLayout(loop:loop,pulse:pulse,unit:c.unit,rate:c.rate,frameCount:576)
  for base:Int64 in [0,1,4000000000,Int64.max-257]{
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
 console.log(r.stdout.trim()+`: ${cases.length} original meter grids / ${checked} samples, partial bars, two rates, small loops, translated origin and far full-width phase`)
}finally{await rm(root,{recursive:true,force:true})}
