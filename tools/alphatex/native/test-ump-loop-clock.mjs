// Production rational clock/window with an independent BigInt interval oracle.
// No MIDI/audio client, endpoint or player is constructed.
import assert from 'node:assert/strict'
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises'
import {tmpdir} from 'node:os'
import {join} from 'node:path'
import {spawnSync} from 'node:child_process'
const root=await mkdtemp(join(tmpdir(),'masc-ump-loop-clock-'))
const gcd=(a,b)=>{a=a<0n?-a:a;while(b)[a,b]=[b,a%b];return a}
const frac=(n,d=1n)=>{const g=gcd(n,d);return[n/g,d/g]}
const add=([a,b],[c,d])=>frac(a*d+c*b,b*d),sub=([a,b],[c,d])=>frac(a*d-c*b,b*d)
const mul=([a,b],[c,d])=>frac(a*c,b*d),div=([a,b],[c,d])=>frac(a*d,b*c)
const floor=([n,d])=>n/d-(n<0n&&n%d?1n:0n),ceil=r=>-floor([-r[0],r[1]])
const less=([a,b],[c,d])=>a*d<c*b
const same=(a,b,message)=>assert.equal(a[0]*b[1],b[0]*a[1],message)
function binary(value){const b=new DataView(new ArrayBuffer(8));b.setFloat64(0,value);const bits=b.getBigUint64(0),e=Number(bits>>52n&2047n),n=(bits&((1n<<52n)-1n))+(e?1n<<52n:0n),s=e?e-1075:-1074;return s>=0?frac(n<<BigInt(s)):frac(n,1n<<BigInt(-s))}
const cases=[]
for(const tempo of[123.5,120.1,137,40000000])for(const start of[0,1,1000000000])for(const shift of[frac(-1n,7n),frac(0n),frac(1n,7n)]){
 const step=div(frac(60000000000n,960n),binary(tempo)),origin=mul(frac(BigInt(start)),step),placement=add(origin,shift)
 if(placement[0]<0n)continue
 cases.push({tempo,start,end:start+960,n:String(placement[0]),d:String(placement[1]),numer:125,denom:3,extent:'4800001',repeat:2000000})
}
for(const start of[0,1000000000])for(const shift of[frac(-1n,7n),frac(0n),frac(1n,7n)]){
 const step=div(frac(60000000000n,960n),binary(120.1)),placement=add(mul(frac(BigInt(start)),step),shift)
 if(placement[0]<0n)continue
 cases.push({tempo:120.1,start,end:start+960,n:String(placement[0]),d:String(placement[1]),numer:1,denom:4294967291,extent:'1000000000000000',repeat:3})
}
// Equivalent authored placements must not inflate the native common clock.
const redundant=(1n<<90n)-1n
for(const [n,d]of [['1','1'],[String(redundant),String(redundant)],['0',String(redundant)]])
 cases.push({tempo:120.1,start:0,end:960,n,d,numer:125,denom:3,extent:'4800001',repeat:3})
cases.push({tempo:40000000,start:0,end:1,n:'0',d:'1',numer:1,denom:20,extent:'2000',repeat:3})
cases.push({tempo:40000000,start:0,end:1,n:'0',d:'1',numer:1,denom:6,extent:'2',repeat:5})
try{
 await writeFile(join(root,'cases.json'),JSON.stringify(cases))
 const swift=`import Foundation
struct ClockCase:Decodable{let tempo:Double;let start:Int64;let end:Int64;let n:String;let d:String;let numer:UInt32;let denom:UInt32;let extent:String;let repeatCount:UInt64
 enum CodingKeys:String,CodingKey{case tempo,start,end,n,d,numer,denom,extent;case repeatCount="repeat"}}
@main enum Probe{static func main()throws{
 let root=CommandLine.arguments[1],cases=try JSONDecoder().decode([ClockCase].self,from:Data(contentsOf:URL(fileURLWithPath:root+"/cases.json")))
 var rows:[[String:Any]]=[]
 for c in cases{
  let cycle=try WaveLoopClock(start:c.start,end:c.end,ppq:960,tempo:c.tempo).midiCycle()
  let window=try UmpLoopWindow(cycle:cycle,start:(UInt128(c.n)!,UInt128(c.d)!),numer:c.numer,denom:c.denom,extent:UInt128(c.extent)!,repetitions:c.repeatCount)
  var phases:[[String:Any]]=[]
  for elapsed:UInt64 in [0,1,2,100,4_000_000_000,UInt64.max-1]{
   let p=try cycle.phaseParts(elapsed:elapsed,offset:0),s=try window.phase(remainder:p.remainder),batch=try window.dueBatch(elapsed:elapsed,initial:0)
   precondition(batch.upper.index-batch.lower.index<=1)
   var ranges:[[String:Any]]=[]
   for index in batch.lower.index...batch.upper.index{let low=index==batch.lower.index ? batch.lower.remainder:0,high=index==batch.upper.index ? batch.upper.remainder:window.period
    let copies=try window.copies(lower:low,upper:high)
    ranges.append(["index":String(index),"lower":String(low),"upper":String(high),"first":copies.map{String($0.lowerBound)} as Any? ?? NSNull(),"last":copies.map{String($0.upperBound)} as Any? ?? NSNull()])
   }
   phases.append(["elapsed":String(elapsed),"index":String(p.index),"remainder":String(p.remainder),"copy":s.map{String($0.copy)} as Any? ?? NSNull(),"local":s.map{String($0.local)} as Any? ?? NSNull(),"batchLowerIndex":String(batch.lower.index),"batchLower":String(batch.lower.remainder),"batchUpperIndex":String(batch.upper.index),"batchUpper":String(batch.upper.remainder),"batchIncludesLower":batch.includesLower,"ranges":ranges])
  }
  var packets:[[String:Any]]=[]
  for copy in Set<UInt64>([0,1,min(c.repeatCount-1,2),min(c.repeatCount-1,3),c.repeatCount-1]) where copy<c.repeatCount{
   let deltas:Set<UInt128> = c.extent=="2000" ? [0,1,2,4,28,29,1999] : [0,1,UInt128(c.extent)!-1]
   for delta in deltas{
    let p=try window.packetPhase(copy:copy,delta:delta*window.tick)
    var deadlines:[[String:Any]]=[]
    if let p{for index:UInt128 in [0,1,4_000_000_000]{for initial in [UInt128(0),window.period/3]{
     do{let deadline=try window.deadline(phase:p,index:index,initial:initial,anchor:100);deadlines.append(["index":String(index),"initial":String(initial),"deadline":String(deadline)])}
     catch{deadlines.append(["index":String(index),"initial":String(initial),"deadline":NSNull()])}
    }}}
    packets.append(["copy":String(copy),"delta":String(delta),"phase":p.map{String($0)} as Any? ?? NSNull(),"deadlines":deadlines])
   }
  }
  rows.append(["period":String(window.period),"divisor":String(window.divisor),"sourcePeriod":String(window.sourcePeriod),"sourceEnd":String(window.sourceEnd),"offset":String(window.offset),"masterDivisor":String(cycle.divisor),"originN":String(cycle.exactStart!.numerator),"originD":String(cycle.exactStart!.divisor),"phases":phases,"packets":packets])
 }
 // The authored loop origin is an equally exact rational input.
 let redundant:UInt128=(UInt128(1)<<90)-1
 let normalized=try MidiCycle(start:1e-9,end:1.000000001,duration:1,period:1_000_000_000,divisor:1,exactStart:(1,1))
 let unreduced=try MidiCycle(start:1e-9,end:1.000000001,duration:1,period:1_000_000_000,divisor:1,exactStart:(redundant,redundant))
 let a=try UmpLoopWindow(cycle:normalized,start:(0,1),numer:125,denom:3,extent:4800001,repetitions:3)
 let b=try UmpLoopWindow(cycle:unreduced,start:(0,redundant),numer:125,denom:3,extent:4800001,repetitions:3)
 precondition(a.period==b.period && a.divisor==b.divisor && a.offset==b.offset && a.tick==b.tick && a.sourceEnd==b.sourceEnd)
 // Equal master periods must not inflate the original source horizon.
 let scaled=try MidiCycle(start:0,end:1,duration:1,period:1_000_000_000*redundant,divisor:redundant,exactStart:(0,1))
 let simple=try MidiCycle(start:0,end:1,duration:1,period:1_000_000_000,divisor:1,exactStart:(0,1))
 let wa=try UmpLoopWindow(cycle:simple,start:(0,1),numer:125,denom:3,extent:4800001,repetitions:2_000_000)
 let wb=try UmpLoopWindow(cycle:scaled,start:(0,1),numer:125,denom:3,extent:4800001,repetitions:2_000_000)
 precondition(wa.period==wb.period && wa.divisor==wb.divisor && wa.sourceEnd==wb.sourceEnd)
 for elapsed:UInt64 in [0,1,2,100,UInt64.max-1]{
  let a=try simple.phaseParts(elapsed:elapsed,offset:0),b=try scaled.phaseParts(elapsed:elapsed,offset:0)
  precondition(a.index==b.index && a.remainder==b.remainder)
  let sa=try wa.phase(remainder:a.remainder),sb=try wb.phase(remainder:b.remainder)
  precondition(sa?.copy==sb?.copy && sa?.local==sb?.local)
 }
 let producer=try WaveLoopClock(start:0,end:65537,ppq:960,tempo:65537).midiCycle()
 let legal=try UmpLoopWindow(cycle:producer,start:(0,1),numer:1,denom:4294967291,extent:UInt128(1)<<64,repetitions:9007199254740991)
 precondition(legal.period==62_500_000*legal.divisor)
 // This legal shared cycle's elapsed product exceeds UInt128, while its
 // quotient and remainder are representable throughout the UInt64 host clock.
 let d:UInt128=(UInt128(1)<<110)-17,p:UInt128=(UInt128(1)<<115)+3
 let wide=try MidiCycle(start:0,end:Double(p)/Double(d)/1e9,duration:Double(p)/Double(d)/1e9,period:p,divisor:d)
 let phase=try wide.phaseParts(elapsed:UInt64.max-1,offset:0)
 try JSONSerialization.data(withJSONObject:["rows":rows,"wide":["period":String(p),"divisor":String(d),"index":String(phase.index),"remainder":String(phase.remainder)]]).write(to:URL(fileURLWithPath:root+"/result.json"))
 print("UMP_LOOP_CLOCK_PASS")
}}
`
 await writeFile(join(root,'Probe.swift'),swift)
 const files=['WaveArrangement.swift','WaveLoopClock.swift','CaptureAudioClock.swift','PulseAudioClock.swift','PulseLoopClock.swift','MidiTransport.swift','UmpTransport.swift','UmpOutput.swift','UmpRegions.swift','HybridMidiTransport.swift','UmpLoopTransport.swift','UmpState.swift'].map(n=>new URL(n,import.meta.url).pathname)
 let result=spawnSync('xcrun',['swiftc','-parse-as-library','-D','MIDI_LIBRARY','-D','ARRANGEMENT_LIBRARY',...files,join(root,'Probe.swift'),'-o',join(root,'probe'),'-framework','AVFoundation','-framework','CoreAudio','-framework','CoreMIDI'],{encoding:'utf8'})
 assert.equal(result.status,0,result.stderr)
 result=spawnSync(join(root,'probe'),[root],{encoding:'utf8'});assert.equal(result.status,0,result.stderr)
 const {rows,wide}=JSON.parse(await readFile(join(root,'result.json'),'utf8'));let observations=0
 for(let i=0;i<rows.length;i++){
  const c=cases[i],row=rows[i],D=BigInt(row.divisor),step=div(frac(60000000000n,960n),binary(c.tempo)),L=mul(frac(BigInt(c.start)),step),M=mul(frac(BigInt(c.end-c.start)),step),A=frac(BigInt(c.n),BigInt(c.d)),tick=frac(BigInt(c.numer),BigInt(c.denom)),P=mul(frac(BigInt(c.extent)),tick),end=mul(P,frac(BigInt(c.repeat)))
  same(frac(BigInt(row.originN),BigInt(row.originD)),L,'authored exact origin')
  for(const [key,expected]of Object.entries({period:M,sourcePeriod:P,sourceEnd:end,offset:sub(L,A)}))same(frac(BigInt(row[key]),D),expected,key)
  for(const phase of row.phases){const E=frac(BigInt(phase.elapsed)),index=floor(div(E,M)),remainder=sub(E,mul(frac(index),M)),source=add(remainder,sub(L,A))
   assert.equal(BigInt(phase.index),index);same(frac(BigInt(phase.remainder),BigInt(row.masterDivisor)),remainder,'master remainder')
   if(source[0]<0n||!less(source,end))assert.equal(phase.copy,null)
   else{const copy=floor(div(source,P));assert.equal(BigInt(phase.copy),copy);same(frac(BigInt(phase.local),D),sub(source,mul(frac(copy),P)),'source local')}
   const previous=phase.elapsed==='0'?E:frac(BigInt(phase.elapsed)-1n),lowerIndex=floor(div(previous,M)),lower=sub(previous,mul(frac(lowerIndex),M))
   assert.equal(BigInt(phase.batchLowerIndex),lowerIndex);same(frac(BigInt(phase.batchLower),D),lower,'batch lower')
   assert.equal(BigInt(phase.batchUpperIndex),index);same(frac(BigInt(phase.batchUpper),D),remainder,'batch upper')
   assert.equal(phase.batchIncludesLower,phase.elapsed==='0')
   for(const range of phase.ranges){const low=add(frac(BigInt(range.lower),D),sub(L,A)),high=add(frac(BigInt(range.upper),D),sub(L,A))
    if(high[0]<0n||!less(low,end)){assert.equal(range.first,null);continue}
    const first=low[0]<=0n?0n:floor(div(low,P)),last=less(high,end)?floor(div(high,P)):BigInt(c.repeat)-1n
    assert.equal(BigInt(range.first),first);assert.equal(BigInt(range.last),last)
   }
   observations++
  }
  for(const packet of row.packets){const position=sub(add(add(A,mul(frac(BigInt(packet.copy)),P)),mul(frac(BigInt(packet.delta)),tick)),L)
   if(position[0]<0n||!less(position,M)){assert.equal(packet.phase,null);continue}
   same(frac(BigInt(packet.phase),D),position,'source packet exact window')
   for(const item of packet.deadlines){const distance=sub(add(mul(frac(BigInt(item.index)),M),position),frac(BigInt(item.initial),D)),deadline=100n+ceil(distance)
    if(distance[0]<0n||deadline>=(1n<<64n))assert.equal(item.deadline,null)
    else assert.equal(BigInt(item.deadline),deadline,'one final ceil')
    observations++
   }
  }
 }
 const wideValue=((1n<<64n)-2n)*BigInt(wide.divisor)
 assert.equal(BigInt(wide.index),wideValue/BigInt(wide.period));assert.equal(BigInt(wide.remainder),wideValue%BigInt(wide.period))
 // Read the actual production deadlines across both sides of a master wrap.
 const masterBatch=rows.at(-2).packets.filter(p=>p.copy==='0').flatMap(p=>p.deadlines.filter(d=>d.initial==='0'&&((['28','29'].includes(p.delta)&&d.index==='0')||(['2','4'].includes(p.delta)&&d.index==='1'))).map(d=>BigInt(d.deadline)))
 assert.equal(masterBatch.length,4);assert.ok(masterBatch.every(deadline=>deadline===102n))
 const sourceBatch=rows.at(-1).packets.filter(p=>p.phase!==null&&p.deadlines.some(d=>d.index==='0'&&d.initial==='0'&&d.deadline==='101')).sort((a,b)=>BigInt(a.phase)<BigInt(b.phase)?-1:1).map(p=>[p.copy,p.delta])
 assert.deepEqual(sourceBatch,[['0','1'],['1','0'],['1','1'],['2','0'],['2','1'],['3','0']])
 console.log(`${result.stdout.trim()}: ${cases.length} layouts, ${observations} rational phase/deadline observations and full-width host product`)
}finally{await rm(root,{recursive:true,force:true})}
