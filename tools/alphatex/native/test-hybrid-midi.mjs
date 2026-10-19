// Joint resource/lifecycle ownership and production channel admission. Clock,
// endpoint checks and sends are injected; real protocol delivery is separate.
import assert from 'node:assert/strict'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { spawnSync } from 'node:child_process'
const directory=await mkdtemp(join(tmpdir(),'masc-hybrid-midi-'))
try {
 const swift=`import Foundation
final class Edge:CoordinatedMidiTransport {
 var anchor:UInt64=0;var terminalFailure:Error?;var onCoordinatedFailure:((String,Error?)->Void)?;var onCoordinatedEnd:(()->Void)?
 var stages:[Double]=[];var runs:[UInt64]=[];var prepares=0;var closes=0;var fail="";let id:String;let protocolID:Int
 init(_ id:String,_ p:Int){self.id=id;protocolID=p}
 func prepare()throws{prepares+=1;if fail=="prepare"{throw MidiFailure("prepare edge")}}
 func stageCoordinated(at seconds:Double)throws{stages.append(seconds);if fail=="stage"{throw MidiFailure("stage edge")}}
 func runCoordinated(anchorNanoseconds:UInt64)throws{runs.append(anchorNanoseconds);anchor=anchorNanoseconds;if fail=="run"{throw MidiFailure("run edge")}}
 func position(at host:UInt64)->Double{0}
 func snapshot(_ kind:String)->[String:Any]{["bindings":[["port":0,"device":["kind":"midi","id":id,"name":id,"protocol":protocolID]]]]}
 func finish(reason:String,error:Error?,publish:Bool){closes+=1;terminalFailure=error ?? (fail=="close" ? MidiFailure("cleanup edge"):nil);onCoordinatedFailure?(reason,terminalFailure)}
}
func refuses(_ block:()throws->Void){do{try block();preconditionFailure("invalid admitted")}catch{}}
let a=Edge("42",1),b=Edge("42",2),g=HybridMidiTransport(owners:[a,b],duration:2)
try g.prepare();try g.stageCoordinated(at:0.5);try g.runCoordinated(anchorNanoseconds:100)
precondition(a.runs==b.runs && a.stages==b.stages && g.position(at:1_000_000_100)==1.5)
let bindings=g.snapshot("playing")["bindings"] as! [[String:Any]];precondition(bindings.map{$0["port"] as! Int}==[0,1]);precondition((bindings[0]["device"] as! [String:Any])["protocol"] as! Int==1)
var ends=0;g.onCoordinatedEnd={ends+=1};b.onCoordinatedEnd?();precondition(ends==0);a.onCoordinatedEnd?();precondition(ends==1 && g.state == .ended)
try g.stageCoordinated(at:0.1);a.onCoordinatedEnd?();precondition(ends==1);try g.runCoordinated(anchorNanoseconds:200);a.onCoordinatedEnd?();precondition(ends==1);b.onCoordinatedEnd?();precondition(ends==2)
g.finish(reason:"test",error:nil,publish:false);g.finish(reason:"again",error:nil,publish:false);precondition(a.closes==1 && b.closes==1)
for edge in ["prepare","stage","run"] {
 let first=Edge("42",1),second=Edge("43",2),group=HybridMidiTransport(owners:[first,second],duration:2);second.fail=edge
 var failures=0;group.onCoordinatedFailure={_,error in precondition(error != nil);failures+=1}
 refuses{try group.prepare();try group.stageCoordinated(at:0);try group.runCoordinated(anchorNanoseconds:100)}
 precondition(group.state == .stopped && first.closes==1 && second.closes==1 && failures==1 && group.terminalFailure != nil)
 if edge=="run"{precondition(first.runs==[100])}
}
let first=Edge("42",1),second=Edge("43",2),errorGroup=HybridMidiTransport(owners:[first,second],duration:2);second.fail="close"
errorGroup.finish(reason:"stop",error:nil,publish:false);precondition(errorGroup.terminalFailure != nil && first.closes==1 && second.closes==1)
// Derive actual channel state from parsed, decoder-complete SMF regions. UMP
// in another group/channel can share a destination, a shared scope cannot.
let wire:[String:Any]=["schemaVersion":3,"duration":1,"sources":[["id":"s","timeline":["schemaVersion":2,"duration":1,"bindings":[["port":0,"destination":"42"]],"events":[["seconds":0,"port":0,"bytes":[144,60,100]],["seconds":0.8,"port":0,"bytes":[128,60,77]]]]]],"regions":[["id":"r","source":"s","startSeconds":0,"sourceStart":0,"sourceEnd":1,"repeatCount":1]]]
let midi=try JSONDecoder().decode(Timeline.self,from:JSONSerialization.data(withJSONObject:wire))
func capture(_ group:UInt32,_ channel:UInt32,_ uid:String="42") -> UmpArrangement {
 let prefix=group<<24|channel<<16
 return UmpArrangement(schemaVersion:1,duration:1,sources:[UmpRegionSource(id:"take",extent:"1000000000",timeline:UmpTimeline(schemaVersion:4,duration:1,clock:UmpClock(origin:"0",numer:1,denom:1),bindings:[UmpBinding(source:"A",destination:uid)],packets:[UmpPacket(kind:"midi",protocolID:2,hostTime:"0",source:"A",timestampOrigin:"packet",words:[0x40903c00|prefix,0x80000000]),UmpPacket(kind:"midi",protocolID:2,hostTime:"800000000",source:"A",timestampOrigin:"packet",words:[0x40803c00|prefix,0x12340000])]))],regions:[UmpRegion(id:"c",source:"take",startSeconds:0,offset:"0",extent:"1000000000",repeatCount:1)])
}
_ = try HybridMidiTransport(midi:midi,ump:capture(3,0));_ = try HybridMidiTransport(midi:midi,ump:capture(0,1));_ = try HybridMidiTransport(midi:midi,ump:capture(0,0,"43"))
refuses{_ = try HybridMidiTransport(midi:midi,ump:capture(0,0))}
let cycle=try MidiCycle(start:0.1,end:0.4,duration:0.3,period:300000000,divisor:1,exactStart:(100000000,1))
let retained=try HybridMidiTransport(midi:midi,ump:capture(3,0),cycle:cycle)
precondition(retained.duration==0.3 && retained.cycle != nil && retained.owners[1] is UmpLoopTransport)
refuses{_ = try HybridMidiTransport(midi:midi,ump:capture(0,0),cycle:cycle)}
let left=Edge("42",1),right=Edge("43",2),looped=HybridMidiTransport(owners:[left,right],duration:0.3,cycle:cycle)
try looped.stageCoordinated(at:0.1);try looped.runCoordinated(anchorNanoseconds:100)
var loopEnds=0;looped.onCoordinatedEnd={loopEnds+=1};left.onCoordinatedEnd?();right.onCoordinatedEnd?()
precondition(looped.state == .playing && loopEnds==0 && abs(looped.position(at:1_000_000_100)-0.2)<1e-8)
try looped.stageCoordinated(at:0);precondition(left.stages==[0.1,0] && right.stages==left.stages)
looped.finish(reason:"stop-loop",error:nil,publish:false);precondition(left.closes==1 && right.closes==1)
print("HYBRID_MIDI_PASS: actual physical group/channel admission, shared UID streams, common epoch, both completion orders, silent stage, prepare/stage/start failure unwind, reentrant and cleanup error drain")
`
 await writeFile(join(directory,'main.swift'),swift)
 const files=['MidiTransport.swift','UmpTransport.swift','UmpOutput.swift','UmpRegions.swift','UmpState.swift','HybridMidiTransport.swift','UmpLoopTransport.swift'].map(file=>new URL(file,import.meta.url).pathname)
 const compiled=spawnSync('xcrun',['swiftc','-D','MIDI_LIBRARY',...files,join(directory,'main.swift'),'-o',join(directory,'probe'),'-framework','CoreMIDI'],{encoding:'utf8'})
 assert.equal(compiled.status,0,compiled.stderr)
 const run=spawnSync(join(directory,'probe'),[],{encoding:'utf8'});assert.equal(run.status,0,run.stdout+run.stderr);process.stdout.write(run.stdout)
} finally {await rm(directory,{recursive:true,force:true})}
