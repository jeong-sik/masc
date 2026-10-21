// Actual loop admission, source/instance cursors and ownership effects with
// controlled clock/send edges. No MIDI/audio client or endpoint is created.
import assert from 'node:assert/strict'
import {mkdtemp,readFile,writeFile,rm} from 'node:fs/promises'
import {join} from 'node:path'
import {tmpdir} from 'node:os'
import {spawnSync} from 'node:child_process'
const root=await mkdtemp(join(tmpdir(),'masc-ump-loop-effects-'))
try{
 let output=await readFile(new URL('UmpOutput.swift',import.meta.url),'utf8')
 const replace=(first,last,body)=>{const a=output.indexOf(first),b=output.indexOf(last,a);assert.ok(a>=0&&b>a);output=output.slice(0,a)+body+'\n'+output.slice(b)}
 replace('    func checkDestinations()', '    func send(', '    func checkDestinations() throws { if unavailable { throw MidiFailure("endpoint lost") } }')
 replace('    func send(', '    func apply(', '    func send(_ words:[UInt32],source:String)throws { sent.append((source,words));if failWords==words {failWords=nil;throw MidiFailure("uncertain send")} }')
 await writeFile(join(root,'Output.swift'),output+'\nvar sent:[(String,[UInt32])]=[];var unavailable=false;var failWords:[UInt32]?;var host:UInt64=0;var armed:[UInt64]=[]\n')
 let owner=(await readFile(new URL('UmpLoopTransport.swift',import.meta.url),'utf8')).replaceAll('DispatchTime.now().uptimeNanoseconds','host')
 const a=owner.indexOf('    func arm('),b=owner.indexOf('    func schedule(',a);assert.ok(a>=0&&b>a)
 owner=owner.slice(0,a)+'    func arm(_ when:UInt64) { armed.append(when) }\n'+owner.slice(b)
 await writeFile(join(root,'Loop.swift'),owner)
 const swift=`import Foundation
let on:[UInt32]=[0x43953c03,0x80012345],off:[UInt32]=[0x43853c00,0x12340000]
let earlyOn:[UInt32]=[0x43953e03,0x90012345],earlyOff:[UInt32]=[0x43853e00,0x43210000]
func packet(_ tick:UInt64,_ words:[UInt32])->UmpPacket{UmpPacket(kind:"midi",protocolID:2,hostTime:String(tick),source:"A",timestampOrigin:"packet",words:words)}
func source(_ rows:[UmpPacket],id:String="take",numer:UInt32=1,denom:UInt32=1,extent:String="1000000000")->UmpRegionSource {
 UmpRegionSource(id:id,extent:extent,timeline:UmpTimeline(schemaVersion:4,duration:Double(extent)!*Double(numer)/Double(denom)/1e9,clock:UmpClock(origin:"0",numer:numer,denom:denom),bindings:rows.isEmpty ? []:[UmpBinding(source:"A",destination:"42")],packets:rows))
}
func region(_ id:String="clip",source:String="take",n:String="0",d:String="1",cut:String="0",extent:String="1000000000",repeats:UInt64=1)->UmpRegion {
 UmpRegion(id:id,source:source,startSeconds:Double(n)!/Double(d)!/1e9,offset:cut,extent:extent,repeatCount:repeats,startNanoseconds:ExactNanoseconds(numerator:n,denominator:d))
}
func owner(_ sources:[UmpRegionSource],_ regions:[UmpRegion],cycle:MidiCycle)throws->UmpLoopTransport {
 try UmpLoopTransport(timeline:UmpArrangement(schemaVersion:1,duration:10,sources:sources,regions:regions),cycle:cycle)
}
func start(_ owner:UmpLoopTransport,at seconds:Double=0)throws {
 host=0;sent=[];armed=[];try owner.stageCoordinated(at:seconds);precondition(sent.isEmpty);try owner.runCoordinated(anchorNanoseconds:100)
}
func observe(_ owner:UmpLoopTransport,_ at:UInt64)throws {
 host=at
 do {if try owner.beginBatch(at:host) {while try owner.advanceBatch() {}}}
 catch {owner.finish(reason:"test-native-batch-failure",error:error,publish:false);throw error}
}
func stop(_ owner:UmpLoopTransport){owner.finish(reason:"test",error:nil,publish:false)}
@main enum Probe {static func main()throws {
 let tiny=try WaveLoopClock(start:0,end:1,ppq:960,tempo:40_000_000).midiCycle()
 let raw=source([packet(2,earlyOn),packet(4,earlyOff),packet(28,on),packet(29,off)],numer:1,denom:20,extent:"2000")
 for initial in [false,true] {
  let o=try owner([raw],[region(extent:"2000",repeats:3)],cycle:tiny);try start(o)
  if !initial {try observe(o,100);sent=[]}
  try observe(o,102)
  precondition(sent.map{$0.1}==[on,off,earlyOn,earlyOff],"old raw pair must precede master cleanup and incoming pair")
  let count=sent.count;try observe(o,102);precondition(sent.count==count,"same host batch replayed")
  precondition(o.state == .playing && armed.last!>102 && o.output.held.isEmpty);stop(o)
 }
 print("UMP_LOOP_MASTER_BATCH_PASS")
 let m1On:[UInt32]=[0x23953c64],m1Off:[UInt32]=[0x23853c4d]
 let m1=try owner([source([packet(28,m1On),packet(29,m1Off)],numer:1,denom:20,extent:"2000")],[region(extent:"2000")],cycle:tiny)
 try start(m1);try observe(m1,102);precondition(sent.map{$0.1}==[m1On,m1Off],"MIDI1 UMP payload or release byte changed");stop(m1)
 let copies=source([packet(0,on),packet(1,off)],numer:1,denom:6,extent:"2")
 let c=try owner([copies],[region(extent:"2",repeats:5)],cycle:tiny);try start(c);try observe(c,100);precondition(sent.map{$0.1}==[on]);sent=[]
 try observe(c,101);precondition(sent.map{$0.1}==[off,on,off,on,off,on],"integer batch lost original sub-ns copy")
 precondition(c.output.held.values.reduce(0,+)==1);stop(c)
 print("UMP_LOOP_SOURCE_BATCH_PASS")
 // Historical virtual-entry ownership, including a release whose native
 // host deadline equals entry. Its zero-overlap sibling owns no channel.
 for release:UInt64 in [1,2] { for late in [false,true] {
  let take=source([packet(0,on),packet(release,off)],numer:1,denom:10,extent:"1000")
  let o=try owner([take],[region(n:"1",d:"10",cut:"1",extent:"100")],cycle:tiny)
  try start(o);try observe(o,late ? 103:101)
  // At elapsed3ns the current master has a new entry due at4ns, so no
  // earlier acquisition is recreated merely by a currently due release.
  if !late {precondition(sent.map{$0.1} == (release==2 ? [on,off]:[]))}
  else {precondition(sent.isEmpty)}
  if release==1 {precondition(o.plan.bindings.isEmpty,"zero-overlap release reserved an unowned physical channel")}
  stop(o)
 }}
 let offsetClock=try MidiCycle(start:0.2,end:0.6,duration:0.4,period:400_000_000,divisor:1,exactStart:(200_000_000,1))
 let opaque=source([packet(0,[0x43c50001,0x05000102]),packet(300_000_000,on),packet(400_000_000,off),packet(800_000_000,[0x33017d00,0])])
 let clean=try owner([opaque],[region()],cycle:offsetClock);try start(clean);try observe(clean,450_000_101)
 precondition(clean.state == .playing && !sent.contains{$0.1[0]>>28==3},"unreachable suffix entered loop reconstruction");stop(clean)
 let seek=try owner([source([packet(100_000_000,on),packet(300_000_000,off)])],[region()],cycle:offsetClock)
 try start(seek,at:0.05);try observe(seek,100);precondition(sent.map{$0.1}==[on]);sent=[]
 try observe(seek,50_000_100);precondition(sent.map{$0.1}==[off]);let oldToken=seek.generation
 try seek.stageCoordinated(at:0);let count=sent.count;seek.continueBatch(oldToken);precondition(sent.count==count && seek.state == .staged);stop(seek)
 print("UMP_LOOP_ENTRY_WINDOW_STAGE_PASS")
 // A late batch may enter an instance whose end is also due. Its voice held
 // to that end has no native time before the close and is not re-attacked.
 let cutClock=try MidiCycle(start:0,end:0.6125,duration:0.6125,period:612_500_000,divisor:1,exactStart:(0,1))
 let heldToEnd=source([packet(100_000_000,on),packet(124_000_000,off)],extent:"125000000")
 for active in [true,false] { for late:UInt64 in [0,1,2_000_000] {
  let o=try owner([heldToEnd],[region(extent:"125000000",repeats:8)],cycle:cutClock);try start(o)
  if active {try observe(o,100);try observe(o,490_000_100);sent=[]}
  try observe(o,612_500_100+late)
  precondition(sent.map{$0.1} == (active ? [off]:[]),"late batch re-attacked a voice held to an instance end due in the same batch")
  precondition(o.state == .playing && o.output.held.isEmpty);stop(o)
 }}
 // The trim ends before the original Off, so every copy holds its voice to
 // an inner copy end. A late first batch at that exact end stays silent.
 let inner=try owner([heldToEnd],[region(extent:"110000000",repeats:8)],cycle:cutClock);try start(inner)
 try observe(inner,110_000_100)
 precondition(sent.isEmpty && inner.output.held.isEmpty,"late first batch re-attacked a voice held to an inner copy end");stop(inner)
 print("UMP_LOOP_LATE_CLOSE_PASS: late batches at an exact wrap or inner copy end keep voices held to that end silent; acquired releases and 1 ns-late wraps unchanged")
 let normal=try MidiCycle(start:0,end:1,duration:1,period:1_000_000_000,divisor:1,exactStart:(0,1))
 let fifo=source([packet(100_000_000,on),packet(200_000_000,[0x43953c03,0x90012345]),packet(300_000_000,off),packet(800_000_000,[0x43853c00,0x45670000])])
 for fail in [false,true] {
  let o=try owner([fifo],[region()],cycle:normal);try start(o);try observe(o,100);sent=[];try observe(o,400_000_100)
  precondition(sent.map{$0.1}==[[0x43953c03,0x90012345]],"expired A stole still-live B")
  let release:[UInt32]=[0x43853c00,0x45670000];if fail {failWords=release}
  do {try observe(o,800_000_100);precondition(!fail)} catch {precondition(fail && o.terminalFailure != nil)}
  precondition(sent.map{$0.1}.contains(release) && o.output.held.isEmpty)
  if fail {precondition(Array(sent.suffix(2)).map{$0.1}==[release,[0x43853c00,0]])}
  stop(o)
 }
 print("UMP_LOOP_FIFO_UNCERTAINTY_PASS")
 let farSource=source([packet(1_249_999_991,on),packet(1_249_999_992,off)],numer:1,denom:10,extent:"1250000000")
 let far=try owner([farSource],[region(extent:"1250000000",repeats:2_000_000)],cycle:normal)
 try start(far);try observe(far,100);sent=[];try observe(far,1_000_000_000_100)
 precondition(sent.map{$0.1}==[on,off],"far master lookup skipped precisely-due original source copy7")
 precondition(far.cursors[0]!.instance.master==1000 && far.cursors[0]!.instance.copy==0);stop(far)
 let laterOn:[UInt32]=[0x43953c03,0x90012345],laterOff:[UInt32]=[0x43853c00,0x45670000]
 let left=source([packet(50_000_000,on),packet(200_000_000,off)],id:"left")
 let right=source([packet(50_000_000,laterOn),packet(200_000_000,laterOff)],id:"right")
 let handoff=try owner([left,right],[region("left",source:"left",extent:"400000000"),region("right",source:"right",n:"400000000",extent:"400000000")],cycle:normal)
 try start(handoff);try observe(handoff,50_000_100);precondition(sent.map{$0.1}==[on]);sent=[]
 try observe(handoff,500_000_100);precondition(sent.map{$0.1}==[off,laterOn],"physical handoff acquired incoming note before outgoing original release")
 sent=[];try observe(handoff,600_000_100);precondition(sent.map{$0.1}==[laterOff]);stop(handoff)
 do {_ = try owner([left,right],[region("left",source:"left",extent:"400000000"),region("right",source:"right",n:"300000000",extent:"400000000")],cycle:normal);preconditionFailure("actual channel overlap admitted")} catch {}
 let deadOn:[UInt32]=[0x43964600,0x80000000],deadOff:[UInt32]=[0x43864600,0x12340000]
 let liveOn:[UInt32]=[0x43964000,0x80000000],liveOff:[UInt32]=[0x43864000,0x45670000]
 let scopeA=source([packet(10_000_000,deadOn),packet(100_000_000,deadOff),packet(300_000_000,on),packet(400_000_000,off)],id:"scopeA")
 let scopeB=source([packet(250_000_000,liveOn),packet(500_000_000,liveOff)],id:"scopeB")
 let disjoint=try owner([scopeA,scopeB],[region("scopeA",source:"scopeA"),region("scopeB",source:"scopeB")],cycle:offsetClock)
 precondition(disjoint.plan.clips[0].shapes.flatMap{$0.scope}.allSatisfy{$0.channel==0x03050000},"expired prefix key reserved an unowned channel")
 try start(disjoint);try observe(disjoint,100_000_100);precondition(sent.map{$0.1}.contains(on) && sent.map{$0.1}.contains(liveOn));stop(disjoint)
 // Timing words carry no channel: their status bits must not claim channel 8.
 let eighthOn:[UInt32]=[0x43983c00,0x80000000],eighthOff:[UInt32]=[0x43883c00,0x12340000]
 let clocked=source([packet(0,[0x13f80000]),packet(0,[0x00201234]),packet(50_000_000,on),packet(200_000_000,off)],id:"clocked")
 let eighth=source([packet(50_000_000,eighthOn),packet(200_000_000,eighthOff)],id:"eighth")
 let timing=try owner([clocked,eighth],[region("clocked",source:"clocked",extent:"400000000"),region("eighth",source:"eighth",extent:"400000000")],cycle:normal)
 precondition(timing.plan.clips[0].shapes.flatMap{$0.scope}.allSatisfy{$0.channel==0x03050000},"timing words claimed a channel")
 print("UMP_LOOP_FAR_LOOKUP_SCOPE_HANDOFF_PASS")
 let huge:UInt64=1_000_000_000_000_000_000
 let baseBend:[UInt32]=[0x43e50000,0x80000000],motion:[UInt32]=[0x43e50000,0x87654321]
 let original=source([packet(huge-1,baseBend),packet(huge,on),packet(huge+1,motion),packet(huge+2,off)],numer:125,denom:3,extent:String(UInt128(huge)+3))
 let exact=try owner([original],[region(cut:String(huge),extent:"3",repeats:3)],cycle:normal)
 try start(exact);try observe(exact,100);precondition(sent.map{$0.1}==[baseBend,on]);sent=[]
 try observe(exact,141);precondition(sent.isEmpty);try observe(exact,142);precondition(sent.map{$0.1}==[motion]);sent=[]
 try observe(exact,184);precondition(sent.map{$0.1}==[off]);sent=[];try observe(exact,225);precondition(sent.map{$0.1}==[baseBend,on]);stop(exact)
 let cancel=try owner([raw],[region(extent:"2000",repeats:3)],cycle:tiny);try start(cancel);host=102
 let began=try cancel.beginBatch(at:host),entered=try cancel.advanceBatch(),acquired=try cancel.advanceBatch();precondition(began && entered && acquired)
 precondition(sent.map{$0.1}==[on]);let token=cancel.generation
 try cancel.stageCoordinated(at:0);precondition(sent.map{$0.1}==[on,[0x43853c00,0]])
 let drained=sent.count;cancel.continueBatch(token);precondition(sent.count==drained && cancel.state == .staged)
 try cancel.runCoordinated(anchorNanoseconds:202);try observe(cancel,202);precondition(sent.count==drained);stop(cancel)
 print("UMP_LOOP_ORIGINAL_TICKS_CANCEL_PASS")
 // Exact fractional source cuts retain raw words across copies and wraps.
 let fractionalCycle=try MidiCycle(start:0,end:500e-9,duration:500e-9,period:500,divisor:1,exactStart:(0,1))
 var fractionalRegion=region(cut:"1",extent:"4",repeats:2);fractionalRegion.sourceDivisor="2"
 let fractionalSource=source([packet(1,on),packet(2,off)],numer:125,denom:3,extent:"10")
 let fractional=try owner([fractionalSource],[fractionalRegion],cycle:fractionalCycle)
 try start(fractional)
 for (time,count) in [(UInt64(120),0),(121,1),(163,2),(205,3),(246,4),(620,4),(621,5),(663,6),(705,7),(746,8)] {
  try observe(fractional,time);precondition(sent.filter{$0.1==on || $0.1==off}.count==count)
 }
 precondition(sent.filter{$0.1==on || $0.1==off}.map{$0.1}==[on,off,on,off,on,off,on,off]);stop(fractional)
 var badFraction=fractionalRegion;badFraction.sourceDivisor="0"
 do{_ = try owner([fractionalSource],[badFraction],cycle:fractionalCycle);preconditionFailure("zero fractional source divisor admitted")}catch{}
 print("UMP_FRACTIONAL_LOOP_PASS")
 let silent=try owner([source([],numer:1,denom:6,extent:"2")],[region(extent:"2",repeats:2_000_000)],cycle:tiny)
 try start(silent);try observe(silent,100);try observe(silent,1_000_000_100)
 precondition(silent.state == .playing && sent.isEmpty && armed.last!>host)
 try silent.stageCoordinated(at:0);precondition(silent.state == .staged && sent.isEmpty);stop(silent)
 let lost=try owner([fifo],[region()],cycle:normal);try start(lost);unavailable=true
 do {try observe(lost,100);preconditionFailure("destination loss ignored")} catch {precondition(lost.state == .stopped && lost.terminalFailure != nil)}
 unavailable=false
 print("UMP_LOOP_SILENT_LIFETIME_PASS")
}}
`
 await writeFile(join(root,'Probe.swift'),swift)
 const files=['WaveArrangement.swift','WaveLoopClock.swift','SourceAudioClock.swift','CaptureAudioClock.swift','PulseAudioClock.swift','PulseLoopClock.swift','MidiTransport.swift','UmpTransport.swift','UmpRegions.swift','HybridMidiTransport.swift','UmpState.swift'].map(n=>new URL(n,import.meta.url).pathname)
 let r=spawnSync('xcrun',['swiftc','-parse-as-library','-D','MIDI_LIBRARY','-D','ARRANGEMENT_LIBRARY',...files,join(root,'Output.swift'),join(root,'Loop.swift'),join(root,'Probe.swift'),'-o',join(root,'probe'),'-framework','AVFoundation','-framework','CoreAudio','-framework','CoreMIDI'],{encoding:'utf8'})
 assert.equal(r.status,0,r.stderr)
 r=spawnSync(join(root,'probe'),[],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);console.log(r.stdout.trim())
}finally{await rm(root,{recursive:true,force:true})}
