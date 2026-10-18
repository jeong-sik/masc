// Production region scheduler with explicit clock/send edges. Actual MIDI2 and
// audio delivery are exercised separately by installed private endpoint probes.
import assert from 'node:assert/strict'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { spawnSync } from 'node:child_process'
const directory=await mkdtemp(join(tmpdir(),'masc-ump-regions-'))
try {
 let output=await readFile(new URL('UmpOutput.swift',import.meta.url),'utf8')
 const replace=(first,last,value)=>{const a=output.indexOf(first),b=output.indexOf(last,a);assert.ok(a>=0&&b>a);output=output.slice(0,a)+value+'\n'+output.slice(b)}
 replace('    func checkDestinations()', '    func send(', '    func checkDestinations() throws { if unavailable { throw MidiFailure("endpoint lost") } }')
 replace('    func send(', '    func apply(', '    func send(_ words:[UInt32],source:String)throws { sent.append((source,words));if failNext {failNext=false;throw MidiFailure("uncertain acquisition")} }')
 await writeFile(join(directory,'Output.swift'),output+'\nvar sent:[(String,[UInt32])]=[];var unavailable=false;var failNext=false;var host:UInt64=0\n')
 const regions=(await readFile(new URL('UmpRegions.swift',import.meta.url),'utf8')).replaceAll('DispatchTime.now().uptimeNanoseconds','host')
 await writeFile(join(directory,'Regions.swift'),regions)
 const main=`import Foundation
func refuses(_ action:()throws->Void){do{try action();preconditionFailure("invalid region admitted")}catch{}}
let on:[UInt32]=[0x43953c03,0x80012345],off:[UInt32]=[0x43853c00,0x12340000],bend:[UInt32]=[0x43e50000,0x80000000]
func packet(_ tick:UInt64,_ words:[UInt32],source:String="A")->UmpPacket{UmpPacket(kind:"midi",protocolID:2,hostTime:String(tick),source:source,timestampOrigin:"packet",words:words)}
func source(_ id:String,_ rows:[UmpPacket],numer:UInt32=1,denom:UInt32=1,extent:String="1000000000",destination:String="42")->UmpRegionSource{
 UmpRegionSource(id:id,extent:extent,timeline:UmpTimeline(schemaVersion:4,duration:Double(extent)!*Double(numer)/Double(denom)/1e9,clock:UmpClock(origin:"0",numer:numer,denom:denom),bindings:[UmpBinding(source:"A",destination:destination)],packets:rows))
}
func clip(_ id:String="clip",source:String="take",start:Double=0,offset:String="0",extent:String="1000000000",repeatCount:UInt64=1)->UmpRegion{UmpRegion(id:id,source:source,startSeconds:start,offset:offset,extent:extent,repeatCount:repeatCount)}
func owner(_ sources:[UmpRegionSource],_ clips:[UmpRegion],duration:Double=1)throws->UmpRegionTransport{try UmpRegionTransport(timeline:UmpArrangement(schemaVersion:1,duration:duration,sources:sources,regions:clips))}
// A clock-only capture can share a paired arrangement without fabricating UMP.
let silent=UmpRegionSource(id:"silent",extent:"1000000000",timeline:UmpTimeline(schemaVersion:4,duration:1,clock:UmpClock(origin:"0",numer:1,denom:1),bindings:[],packets:[]))
refuses{_ = try silent.timeline.timedEvents()}
let silentOwner=try owner([silent],[clip(source:"silent")]);precondition(silentOwner.clips[0].events.isEmpty && silentOwner.output.bindings.isEmpty)
host=0;sent=[];try silentOwner.stageCoordinated(at:0);try silentOwner.runCoordinated(anchorNanoseconds:10);host=1_000_000_010;silentOwner.tick();precondition(sent.isEmpty && silentOwner.state == .ended)
// Adjacent raw ticks merge as Double seconds at this source offset. Exact cuts
// and stable source order must still deliver each original word exactly once.
let huge:UInt64=1_000_000_000_000_000_000
let exactSource=source("take",[packet(huge+2,off),packet(huge,on),packet(huge+1,[0x43e50000,0x87654321]),packet(huge-1,bend)],extent:"1000000000000000003")
let parsed=try exactSource.timeline.timedEvents();precondition(parsed.map{$0.ticks}==[huge-1,huge,huge+1,huge+2])
precondition(parsed[1].event.seconds==parsed[2].event.seconds)
let exact=try owner([exactSource],[clip(offset:String(huge),extent:"3",repeatCount:2)],duration:6e-9)
host=0;sent=[];try exact.stageCoordinated(at:0);precondition(sent.isEmpty);try exact.runCoordinated(anchorNanoseconds:100)
host=99;exact.tick();precondition(sent.isEmpty)
host=100;exact.tick();precondition(sent.map{$0.1}==[bend,on])
host=101;exact.tick();precondition(sent.last!.1==[0x43e50000,0x87654321] && exact.output.held.count==1)
host=102;exact.tick();precondition(sent.last!.1==off && exact.output.held.isEmpty)
host=103;exact.tick();precondition(Array(sent.suffix(2)).map{$0.1}==[bend,on])
host=106;exact.tick();precondition(exact.state == .ended && exact.output.held.isEmpty && sent.last!.1==off)
// Events due exactly at entry are original wire data, not expired history.
let attack=try owner([source("take",[packet(0,bend),packet(0,on),packet(0,off)])],[clip()])
host=0;sent=[];try attack.stageCoordinated(at:0);try attack.runCoordinated(anchorNanoseconds:10);host=10;attack.tick()
precondition(sent.map{$0.1}==[bend,on,off],"entry attack and original release survive the exact cut")
attack.finish(reason:"test",error:nil,publish:false)
refuses{_ = try owner([source("take",[packet(0,on),packet(0,bend)])],[clip()])}
let ending=try owner([source("take",[packet(0,on),packet(10_000_000,off)])],[clip(offset:"10000000",extent:"100000000")],duration:0.1)
host=0;sent=[];try ending.stageCoordinated(at:0);try ending.runCoordinated(anchorNanoseconds:10);host=10;ending.tick()
precondition(sent.isEmpty,"a historical note ending exactly at entry must not retrigger")
ending.finish(reason:"test",error:nil,publish:false)
// The final host stamp belongs to a half-open bound one past UInt64max.
let endpoint=source("take",[packet(UInt64.max,on)],extent:"18446744073709551616")
let last=try owner([endpoint],[clip(offset:String(UInt64.max),extent:"1")],duration:1e-9)
host=0;sent=[];try last.stageCoordinated(at:0);try last.runCoordinated(anchorNanoseconds:10);host=10;last.tick();precondition(sent.map{$0.1}==[on]);host=11;last.tick();precondition(last.output.held.isEmpty)
// A mid-note trim restores its exact original attributes/release and repeats
// without expanding two million copies or replaying fully expired intervals.
let performance=source("take",[packet(0,bend),packet(100_000_000,on),packet(200_000_000,off)])
let repeated=try owner([performance],[clip(offset:"150000000",extent:"100000000",repeatCount:2_000_000)],duration:200000)
host=0;sent=[];try repeated.stageCoordinated(at:0);try repeated.runCoordinated(anchorNanoseconds:100)
host=100;repeated.tick();precondition(sent.map{$0.1}==[bend,on])
host=50_000_100;repeated.tick();precondition(sent.last!.1==off)
host=199_999_975_000_100;repeated.tick();precondition(repeated.cursors["clip"]!.copy==1_999_999)
precondition(Array(sent.suffix(1)).map{$0.1}==[bend] && repeated.output.held.isEmpty,"late copy must not retrigger a note that ended in its current phase")
let before=sent.count;try repeated.stageCoordinated(at:0.025);precondition(sent.count==before && repeated.state == .staged)
try repeated.runCoordinated(anchorNanoseconds:host+100);host+=99;repeated.tick();precondition(sent.count==before)
host+=1;repeated.tick();precondition(Array(sent.suffix(2)).map{$0.1}==[bend,on])
repeated.finish(reason:"stop",error:nil,publish:false);precondition(repeated.output.held.isEmpty && repeated.output.closed)
// A callback delayed beyond an active region drains its original release,
// while a wholly missed later key pair never acquires a note.
let expiredSource=source("take",[packet(0,on),packet(10_000_000,[0x43953c00,0x90000000]),packet(20_000_000,off),packet(30_000_000,[0x43853c00,0x45670000])])
let expired=try owner([expiredSource],[clip(extent:"100000000")],duration:0.2)
host=0;sent=[];try expired.stageCoordinated(at:0);try expired.runCoordinated(anchorNanoseconds:10);host=10;expired.tick()
host=100_000_010;expired.tick();precondition(sent.map{$0.1}==[on,off],"only acquired FIFO instance keeps its original release")
expired.finish(reason:"test",error:nil,publish:false)
// Delay within an already active copy, preserving existing releases while
// excluding newly missed expired keys; currently live missed voices still enter.
let delayed=source("take",[packet(0,bend),packet(10_000_000,on),packet(20_000_000,off),packet(60_000_000,on),packet(90_000_000,off)])
let same=try owner([delayed],[clip(extent:"100000000")],duration:0.1)
host=0;sent=[];try same.stageCoordinated(at:0);try same.runCoordinated(anchorNanoseconds:10);host=10;same.tick()
host=50_000_010;same.tick();precondition(sent.map{$0.1}==[bend],"same-copy expired acquisitions stay silent")
host=75_000_010;same.tick();precondition(sent.last!.1==on && same.output.held.count==1,"late but live note must enter")
host=100_000_010;same.tick();precondition(sent.map{$0.1}==[bend,on,off],"already acquired late live key retains its original release")
// Independent physical channels can overlap even when both assets call their
// logical input A and bind the same endpoint. Region cleanup is channel-scoped.
let otherOn:[UInt32]=[0x41923d00,0x90010000]
let a=source("take",[packet(0,on)]),b=source("other",[packet(0,otherOn)])
let overlap=try owner([a,b],[clip(extent:"100000000"),clip("other",source:"other",extent:"200000000")],duration:0.3)
host=0;sent=[];try overlap.stageCoordinated(at:0);try overlap.runCoordinated(anchorNanoseconds:10);host=10;overlap.tick();precondition(overlap.output.held.count==2)
host=100_000_010;overlap.tick();precondition(overlap.output.held.count==1 && overlap.output.held.keys.first!.number==61)
let keys=overlap.output.held;failNext=true;refuses{try overlap.output.apply(UmpEvent(seconds:0,source:"42",words:otherOn))};precondition(overlap.output.held.values.reduce(0,+)==2)
overlap.finish(reason:"cancel",error:nil,publish:false);precondition(overlap.output.held.isEmpty)
refuses{_ = try owner([a,source("other",[packet(0,on)])],[clip(extent:"200000000"),clip("other",source:"other",start:0.1,extent:"200000000")],duration:0.3)}
// A sequential asset on the same channel re-establishes physical state from
// explicit original baselines. Array order must not reorder cleanup/acquisition.
let p0:[UInt32]=[0x43c50000,0x05000000],p1:[UInt32]=[0x43c50000,0x06000000]
let first=source("take",[packet(0,p0),packet(0,on)]),second=source("other",[packet(0,p1),packet(0,on)])
let sequence=try owner([first,second],[clip("second",source:"other",start:0.1,extent:"100000000"),clip(extent:"100000000")],duration:0.2)
host=0;sent=[];try sequence.stageCoordinated(at:0);try sequence.runCoordinated(anchorNanoseconds:10);host=10;sequence.tick();host=100_000_010;sequence.tick()
precondition(Array(sent.suffix(3)).map{$0.1}==[[0x43853c00,0],p1,on],"outgoing scoped cleanup precedes incoming patch and key")
sequence.finish(reason:"test",error:nil,publish:false)
refuses{_ = try owner([source("take",[packet(0,on),packet(1,p0)])],[clip(repeatCount:2)],duration:2)}
refuses{_ = try owner([source("take",[packet(0,[0x30120102,0])])],[clip()])}
let lost=try owner([a],[clip()]);host=0;try lost.stageCoordinated(at:0);try lost.runCoordinated(anchorNanoseconds:10);unavailable=true;host=10;lost.tick();precondition(lost.state == .stopped && lost.terminalFailure != nil)
print("UMP_REGIONS_PASS: exact adjacent ticks and UInt64+1 end, original attributes/releases and active-copy FIFO drain, exact-entry attacks, silent staging, 2M compressed late-copy lookup, pause/seek/resume, independent overlapping scopes, sequential physical baselines, uncertain acquisition cleanup, unsupported/overlap admission and endpoint loss")
`
 await writeFile(join(directory,'main.swift'),main)
 const files=['MidiTransport.swift','UmpTransport.swift','UmpState.swift'].map(file=>new URL(file,import.meta.url).pathname)
 let result=spawnSync('xcrun',['swiftc','-D','MIDI_LIBRARY',...files,join(directory,'Output.swift'),join(directory,'Regions.swift'),join(directory,'main.swift'),'-o',join(directory,'probe'),'-framework','CoreMIDI'],{encoding:'utf8'})
 assert.equal(result.status,0,result.stderr)
 result=spawnSync(join(directory,'probe'),[],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);console.log(result.stdout.trim())
}finally{await rm(directory,{recursive:true,force:true})}
