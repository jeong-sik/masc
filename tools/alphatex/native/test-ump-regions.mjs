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
// MIDI1 profiles include the selected wire/restoration domain, not expired
// attribute-bearing history or an unreachable high-resolution suffix.
let legacyHistory=source("take",[packet(0,on),packet(100_000_000,off),packet(200_000_000,[0x43953e00,0x80000000]),packet(300_000_000,[0x43853e00,0]),packet(900_000_000,bend)])
let compatible=try owner([legacyHistory],[clip(offset:"150000000",extent:"250000000")])
var profile=UmpMidi1Profile();for row in compatible.output.compatibleEvents! {profile.observe(row)}
try profile.validate();precondition(compatible.output.compatibleEvents!.map{$0.words}==[[0x43953e00,0x80000000],[0x43853e00,0]])
let heldHistory=try owner([legacyHistory],[clip(offset:"50000000",extent:"350000000")])
var heldProfile=UmpMidi1Profile();for row in heldHistory.output.compatibleEvents! {heldProfile.observe(row)}
refuses{try heldProfile.validate()}
for offset in ["0","100000000"] {
 let boundary=try owner([source("take",[packet(UInt64(offset)!,on),packet(200_000_000,off)])],[clip(offset:offset,extent:"300000000")])
 var boundaryProfile=UmpMidi1Profile();for row in boundary.output.compatibleEvents! {boundaryProfile.observe(row)}
 refuses{try boundaryProfile.validate()}
}
// Project-zero crops retain an exact absolute phase across a partial head and
// a compressed tail. Each absolute deadline rounds once, including when the
// first retained host tick is itself a fractional nanosecond after zero.
func exactClip(_ id:String,startN:String,startD:String,start:Double,offset:String,extent:String,repeats:UInt64=1)->UmpRegion {
 var region=clip(id,source:"adjacent",start:start,offset:offset,extent:extent,repeatCount:repeats)
 region.component = .midi
 region.startNanoseconds=ExactNanoseconds(numerator:startN,denominator:startD)
 return region
}
let adjacent=source("adjacent",[packet(0,on),packet(1,off)],numer:125,denom:3,extent:"4800001")
for fractional in [false,true] {
 let head=exactClip("head",startN:fractional ? "95":"0",startD:fractional ? "3":"1",start:fractional ? 95/3/1e9:0,offset:fractional ? "1":"1200000",extent:fractional ? "4800000":"3600001")
 let tailN=fractional ? "600000095":"450000125",tailSeconds=Double(tailN)!/3/1e9
 let tail=exactClip("tail",startN:tailN,startD:"3",start:tailSeconds,offset:"0",extent:"4800001",repeats:2)
 let projected=try owner([adjacent],[tail,head])
 let h=projected.clips.first{$0.id=="head"}!,t=projected.clips.first{$0.id=="tail"}!
 precondition(h.end==t.start && h.next(copy:0,index:h.endIndex)==t.start,"exact adjacent boundary rounds once")
 host=0;sent=[];try projected.stageCoordinated(at:0);try projected.runCoordinated(anchorNanoseconds:10)
 host=10+t.start-1;projected.tick();precondition(!sent.contains{$0.1==on},"tail must not start before its exact rounded deadline")
 host=10+t.start;projected.tick();precondition(sent.last!.1==on,"tail acquires at the common boundary")
 host=10+t.next(copy:0,index:1);projected.tick();precondition(sent.last!.1==off)
 // A real tenth-nanosecond physical overlap is still refused, even if its
 // two integer scheduler boundaries coincide after rounding.
 let overlap=exactClip("overlap",startN:String(UInt128(tailN)!*10-3),startD:"30",start:(Double(tailN)!*10-3)/30/1e9,offset:"0",extent:"4800001")
 refuses{_ = try owner([adjacent],[head,overlap])}
 projected.finish(reason:"test",error:nil,publish:false)
}
let mismatch=exactClip("mismatch",startN:"0",startD:"1",start:1,offset:"0",extent:"1")
refuses{_ = try owner([adjacent],[mismatch])}
// Fractional entry and future deadlines retain original zero-length wire pairs;
// a genuinely late callback still skips a wholly expired pair.
for tick:UInt64 in [1,2] {
 let pairs=source("adjacent",[packet(tick,on),packet(tick,off)],numer:125,denom:3,extent:"4800001")
 let entry=exactClip("entry",startN:"95",startD:"3",start:95/3/1e9,offset:"1",extent:"4800000",repeats:2)
 for late in [false,true] {
  let owner=try owner([pairs],[entry]),c=owner.clips[0]
  host=0;sent=[];try owner.stageCoordinated(at:0);try owner.runCoordinated(anchorNanoseconds:10)
  let due=c.next(copy:0,index:0)
  if tick==2 {host=10+c.start;owner.tick();precondition(sent.isEmpty)}
  host=10+due+(late ? 1:0);owner.tick()
  precondition(sent.map{$0.1} == (late ? []:[on,off]),"ceil-due wire pair differs from expired history")
  if !late {let next=c.next(copy:1,index:0);host=10+next;owner.tick();precondition(Array(sent.suffix(2)).map{$0.1}==[on,off])}
  owner.finish(reason:"test",error:nil,publish:false)
 }
}
// Ordinary fractional tempos produce large exact binary denominators. Compare
// real bounds without overflowing cross products, including unequal fractions.
func display(_ n:UInt128,_ d:UInt128)->Double {let scale=d*1_000_000_000;return Double(n/scale)+Double(n%scale)/Double(scale)}
let tempoN:UInt128=2_111_062_325_329_920_000_000_000,tempoD:UInt128=4_341_751_515_761_869
for differentDenominator in [false,true] {
 let first=exactClip("one",startN:String(tempoN),startD:String(tempoD),start:display(tempoN,tempoD),offset:"0",extent:"4800000")
 let n=tempoN*2*(differentDenominator ? 10:1)+(differentDenominator ? tempoD:0),d=tempoD*(differentDenominator ? 10:1)
 let second=exactClip("two",startN:String(n),startD:String(d),start:display(n,d),offset:"0",extent:"4800000")
 _ = try owner([adjacent],[first,second],duration:2)
}
// A twenty-minute placement at tempo120.1 has an exact final ceil one ns
// beyond the rounded display sum. The prepared horizon must cover that bound.
let longN:UInt128=1_690_327_662_532_287_092_050_000_000,longD:UInt128=1_408_547_695_956_241
let long=exactClip("long",startN:String(longN),startD:String(longD),start:display(longN,longD),offset:"0",extent:"4800000")
refuses{_ = try owner([adjacent],[long],duration:1200.25)}
_ = try owner([adjacent],[long],duration:1200.250000001)
// An optional retained real recording is supplied by the installed-runtime
// probe. It uses the same production decoder/region owner and synthetic send
// edge; no endpoint registration or opening is needed for this reproduction.
if let path=CommandLine.arguments.dropFirst().first {
 do {
  let original=try JSONDecoder().decode(UmpArrangement.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
  let recorded=try UmpRegionTransport(timeline:original),region=recorded.clips[0]
  host=0;sent=[];try recorded.stageCoordinated(at:0);precondition(sent.isEmpty)
  try recorded.runCoordinated(anchorNanoseconds:10)
  let first=region.prefix(at:region.cut,inclusive:false)
  precondition(first<region.endIndex)
  let deadline=region.next(copy:0,index:first)
  host=10+deadline-1;recorded.tick();precondition(sent.isEmpty,"future recorded baseline was emitted early")
  for index in first..<region.endIndex {host=10+region.next(copy:0,index:index);recorded.tick()}
  precondition(sent.map{$0.1}==Array(region.events[first..<region.endIndex]).map{$0.words},"original recorded preamble order/words changed")
  recorded.finish(reason:"test",error:nil,publish:false)
  print("RETAINED_RECORDED_PREAMBLE_PASS")
 }catch{FileHandle.standardError.write(Data("retained recording admission: \\(error)\\n".utf8));exit(1)}
}
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
// A first copy follows no earlier change on its channels: a take whose
// expression follows its Note On is admitted and plays in original order.
let pressure:[UInt32]=[0x43d50000,0x80000000],cc:[UInt32]=[0x43b50100,0x80000000]
let take=try owner([source("take",[packet(0,on),packet(0,bend),packet(10_000_000,pressure),packet(20_000_000,cc),packet(30_000_000,off)])],[clip(extent:"100000000")],duration:0.1)
host=0;sent=[];try take.stageCoordinated(at:0);try take.runCoordinated(anchorNanoseconds:10);host=10;take.tick()
precondition(sent.map{$0.1}==[on,bend],"entry attack with the expression that follows it")
host=40_000_010;take.tick();precondition(sent.map{$0.1}==[on,bend,pressure,cc,off],"expression after the Note On plays")
take.finish(reason:"test",error:nil,publish:false)
// A recorded silent preamble establishes state at its own original deadlines,
// not eagerly at admission or at the region's first scheduler callback.
let control:[UInt32]=[0x43b54a00,0xabcdef01]
let preamble=source("take",[packet(50_000_000,control),packet(100_000_000,bend),packet(200_000_000,on),packet(300_000_000,off)])
let prefaced=try owner([preamble],[clip(repeatCount:2)],duration:2)
host=0;sent=[];try prefaced.stageCoordinated(at:0);precondition(sent.isEmpty)
try prefaced.runCoordinated(anchorNanoseconds:10);host=10;prefaced.tick();precondition(sent.isEmpty)
host=50_000_009;prefaced.tick();precondition(sent.isEmpty)
host=50_000_010;prefaced.tick();precondition(sent.map{$0.1}==[control])
host=100_000_010;prefaced.tick();precondition(sent.map{$0.1}==[control,bend])
host=200_000_010;prefaced.tick();precondition(sent.map{$0.1}==[control,bend,on])
host=300_000_010;prefaced.tick();precondition(sent.map{$0.1}==[control,bend,on,off])
host=1_000_000_010;prefaced.tick();precondition(sent.count==4,"repeated preamble must not be pulled to copy entry")
host=1_050_000_010;prefaced.tick();host=1_100_000_010;prefaced.tick();host=1_200_000_010;prefaced.tick();host=1_300_000_010;prefaced.tick()
precondition(sent.map{$0.1}==[control,bend,on,off,control,bend,on,off])
// Seeking within the silent preamble chases only its past controller; resume
// retains the remaining gap before the future bend and original Note On.
let countBeforeSeek=sent.count;try prefaced.stageCoordinated(at:0.075);precondition(sent.count==countBeforeSeek)
try prefaced.runCoordinated(anchorNanoseconds:host+10);host+=10;prefaced.tick();precondition(Array(sent.suffix(1)).map{$0.1}==[control])
let countBeforeBend=sent.count;host+=24_999_999;prefaced.tick();precondition(sent.count==countBeforeBend)
host+=1;prefaced.tick();precondition(sent.last!.1==bend)
prefaced.finish(reason:"test",error:nil,publish:false)
// A first copy follows no change, so a later bend is admitted; a repeat
// follows its own bend, which the next copy's attack would play stale.
_ = try owner([source("take",[packet(50_000_000,on),packet(100_000_000,bend)])],[clip()])
refuses{_ = try owner([source("take",[packet(50_000_000,on),packet(100_000_000,bend)])],[clip(repeatCount:2)],duration:2)}
// A historical voice and its pre-cut bend are replayed in one batch; a bend
// that comes only after the cut cannot repair it while it keeps sounding.
_ = try owner([source("take",[packet(0,on),packet(100_000_000,bend)])],[clip(offset:"150000000",extent:"50000000",repeatCount:2)],duration:0.1)
refuses{_ = try owner([source("take",[packet(0,on),packet(200_000_000,bend)])],[clip(offset:"150000000",extent:"100000000",repeatCount:2)],duration:0.2)}
// A relative mutation that appeared first in the original stream has no baseline.
refuses{_ = try owner([source("take",[packet(50_000_000,[0x43450000,1]),packet(100_000_000,[0x43250000,0x12345678])])],[clip()])}
// A mutation in another sequential owner cannot be repaired by a baseline
// lying beyond this region's exclusive source end.
let priorBend=source("prior",[packet(0,bend),packet(10_000_000,on)])
let outside=source("take",[packet(50_000_000,on),packet(200_000_000,bend)])
refuses{_ = try owner([priorBend,outside],[clip("prior",source:"prior",extent:"100000000"),clip(start:0.1,extent:"100000000")],duration:0.2)}
let ending=try owner([source("take",[packet(0,on),packet(10_000_000,off)])],[clip(offset:"10000000",extent:"100000000")],duration:0.1)
host=0;sent=[];try ending.stageCoordinated(at:0);try ending.runCoordinated(anchorNanoseconds:10);host=10;ending.tick()
precondition(sent.isEmpty,"a historical note ending exactly at entry must not retrigger")
ending.finish(reason:"test",error:nil,publish:false)
// A historical voice with positive exact overlap at a fractional entry
// restores before its same-deadline original Off. Zero overlap and a genuinely
// expired callback must remain silent, with no invented release attributes.
for release:UInt64 in [1,2] { for late in [false,true] {
 let take=source("adjacent",[packet(0,on),packet(release,off)],numer:1,denom:10,extent:"1000")
 let region=exactClip("fractionalVoice",startN:"1",startD:"10",start:0.1/1e9,offset:"1",extent:"100")
 let retained=try owner([take],[region],duration:20e-9)
 host=0;sent=[];try retained.stageCoordinated(at:0);try retained.runCoordinated(anchorNanoseconds:100)
 host=101+(late ? 1:0);retained.tick()
 precondition(sent.map{$0.1} == (release==2 && !late ? [on,off]:[]),"fractional entry confused positive overlap, zero overlap or expired history")
 precondition(retained.output.held.isEmpty && retained.terminalFailure==nil)
 retained.finish(reason:"test",error:nil,publish:false)
}}
// An original/virtual attack due in a previous batch cannot be recreated
// merely because its final Off shares the current late callback deadline.
for historical in [false,true] {
 let take=source("adjacent",[packet(historical ? 0:1,on),packet(12,off)],numer:1,denom:10,extent:"1000")
 let region=exactClip("lateVoice",startN:historical ? "1":"0",startD:"10",start:historical ? 0.1/1e9:0,offset:historical ? "1":"0",extent:"100")
 let retained=try owner([take],[region],duration:20e-9)
 host=0;sent=[];try retained.stageCoordinated(at:0);try retained.runCoordinated(anchorNanoseconds:100)
 host=102;retained.tick();precondition(sent.isEmpty && retained.output.held.isEmpty,"past acquisition was recreated by exactly-due Off")
 retained.finish(reason:"test",error:nil,publish:false)
}
print("UMP_FRACTIONAL_VOICE_ENTRY_PASS: positive virtual overlap retains original same-deadline On/Off; zero overlap and late history stay silent")
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
// Timing words carry no channel: their status bits must not claim channel 8.
let clocked=source("take",[packet(0,[0x13f80000]),packet(0,[0x00201234]),packet(0,on)]),eighth=source("other",[packet(0,[0x43983c00,0x80000000])])
let timing=try owner([clocked,eighth],[clip(extent:"100000000"),clip("other",source:"other",extent:"100000000")],duration:0.1)
precondition(timing.clips[0].scope==[UmpChannel(source:"42",channel:0x03050000)],"timing words are outside the channel scope")
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
// A repeat follows the copy before it: the patch, Pitch and Detach-frozen
// per-note values it changed need a baseline at the next entry, and continuous
// values by the cut.
let pitch:[UInt32]=[0x43053c03,0x3c000000],pn:[UInt32]=[0x43653c00,0x92345678],detach:[UInt32]=[0x43f53c02,0]
refuses{_ = try owner([source("take",[packet(0,on),packet(1,p0)])],[clip(repeatCount:2)],duration:2)}
refuses{_ = try owner([source("take",[packet(0,on),packet(1,pitch)])],[clip(repeatCount:2)],duration:2)}
refuses{_ = try owner([source("take",[packet(0,on),packet(0,detach),packet(0,pn)])],[clip(repeatCount:2)],duration:2)}
refuses{_ = try owner([source("take",[packet(0,on),packet(1,bend)])],[clip(repeatCount:2)],duration:2)}
// A repeated MIDI 1.0 Program Change latches the Bank Select its copy left.
let pc1:[UInt32]=[0x23c50500],bank1:[UInt32]=[0x23b50001],on1:[UInt32]=[0x23953c7f]
refuses{_ = try owner([source("take",[packet(0,pc1),packet(0,bank1),packet(0,on1)])],[clip(repeatCount:2)],duration:2)}
_ = try owner([source("take",[packet(0,bank1),packet(0,pc1),packet(0,on1)])],[clip(repeatCount:2)],duration:2)
_ = try owner([source("take",[packet(0,p0),packet(0,pitch),packet(0,on),packet(0,pn),packet(0,detach),packet(1,p1),packet(1,pitch),packet(1,pn)])],[clip(repeatCount:2)],duration:2)
// A later region on the same channel follows the earlier one's changes.
refuses{_ = try owner([first,source("other",[packet(0,on),packet(1,p1)])],[clip(extent:"100000000"),clip("second",source:"other",start:0.1,extent:"100000000")],duration:0.2)}
// Admission covers playback in order; a seek back that would bring a later
// change to an entry ahead is refused before either owner changes.
let later=try owner([source("take",[packet(0,on),packet(10_000_000,bend),packet(20_000_000,off)])],[clip(start:0.1,extent:"100000000")],duration:0.2)
host=0;sent=[];try later.stageCoordinated(at:0);try later.runCoordinated(anchorNanoseconds:10)
host=100_000_010;later.tick();host=150_000_010;later.tick();precondition(sent.map{$0.1}==[on,bend,off])
do {try later.stageCoordinated(at:0.05);preconditionFailure("admitted a seek before a changed entry")} catch is UmpRefusal {}
precondition(later.state == .playing && later.timer != nil,"a refused seek leaves the playing owner unchanged")
try later.stageCoordinated(at:0.15);precondition(later.state == .staged)
later.finish(reason:"test",error:nil,publish:false)
refuses{_ = try owner([source("take",[packet(0,[0x30120102,0])])],[clip()])}
let lost=try owner([a],[clip()]);host=0;try lost.stageCoordinated(at:0);try lost.runCoordinated(anchorNanoseconds:10);unavailable=true;host=10;lost.tick();precondition(lost.state == .stopped && lost.terminalFailure != nil)
print("UMP_REGIONS_PASS: exact adjacent ticks and UInt64+1 end, original attributes/releases and active-copy FIFO drain, exact-entry attacks, silent staging, 2M compressed late-copy lookup, pause/seek/resume, independent overlapping scopes, sequential physical baselines, first-copy entry after earlier regions only, repeat and seek-back baselines, uncertain acquisition cleanup, unsupported/overlap admission and endpoint loss")
`
 await writeFile(join(directory,'main.swift'),main)
 const files=['MidiTransport.swift','UmpTransport.swift','UmpState.swift'].map(file=>new URL(file,import.meta.url).pathname)
 let result=spawnSync('xcrun',['swiftc','-D','MIDI_LIBRARY',...files,join(directory,'Output.swift'),join(directory,'Regions.swift'),join(directory,'main.swift'),'-o',join(directory,'probe'),'-framework','CoreMIDI'],{encoding:'utf8'})
 assert.equal(result.status,0,result.stderr)
 result=spawnSync(join(directory,'probe'),process.argv[2]?[process.argv[2]]:[],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);console.log(result.stdout.trim())
}finally{await rm(directory,{recursive:true,force:true})}
