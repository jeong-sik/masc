// Production live-input decisions with only device/property/send effects replaced.
// No CoreMIDI registration, discovery, audio, hardware sends or TUI snapshots.
import assert from 'node:assert/strict'
import {readFile,writeFile,mkdtemp,rm} from 'node:fs/promises'
import {join} from 'node:path'
import {tmpdir} from 'node:os'
import {spawnSync} from 'node:child_process'
const directory=await mkdtemp(join(tmpdir(),'masc-live-midi-decisions-'))
try {
 let output=await readFile(new URL('UmpOutput.swift',import.meta.url),'utf8')
 const replace=(first,last,value)=>{const a=output.indexOf(first),b=output.indexOf(last,a);assert.ok(a>=0&&b>a);output=output.slice(0,a)+value+'\n'+output.slice(b)}
 replace('    func checkDestinations()', '    func send(', '    func checkDestinations() throws { if unavailable { throw MidiFailure("endpoint lost") } }')
 replace('    func send(', '    func apply(', '    func send(_ words:[UInt32],source:String)throws { sent.append((source,words));if failNext {failNext=false;throw MidiFailure("uncertain acquisition")} }')
 await writeFile(join(directory,'Output.swift'),output+'\nvar sent:[(String,[UInt32])]=[];var unavailable=false;var failNext=false\n')
 const live=(await readFile(new URL('UmpLiveInput.swift',import.meta.url),'utf8')).replaceAll('MIDIObjectGetIntegerProperty(', 'reviewProperty(').replaceAll('kMIDIPropertyUniqueID', 'reviewIdentityKey').replaceAll('kMIDIPropertyOffline', 'reviewOfflineKey')
 await writeFile(join(directory,'Live.swift'),live)
 const main=`import Foundation
import CoreMIDI
func refuses(_ action:()throws->Void){do{try action();preconditionFailure("invalid live input admitted")}catch{}}
let reviewIdentityKey = "uniqueID" as CFString,reviewOfflineKey = "offline" as CFString
var identity:Int32=10,propertyFailure=false,offline:Int32=0
func reviewProperty(_ object:MIDIObjectRef,_ key:CFString,_ value:UnsafeMutablePointer<Int32>)->OSStatus {
 if propertyFailure{return -1};value.pointee = key == reviewIdentityKey ? identity : offline;return 0
}
func pump(until condition:()->Bool){let end=Date().addingTimeInterval(3);while !condition(){precondition(Date()<end,"owned lifecycle did not drain");RunLoop.main.run(until:Date().addingTimeInterval(0.001))}}
func scope(_ group:UInt8,_ channel:UInt8)->UmpLiveScope{.channels([UmpLiveChannel(group:group,channel:channel)])}
func plan(_ routes:[UmpLiveRoute],_ reserved:[UmpLiveClaim]=[])->UmpLivePlan{UmpLivePlan(schemaVersion:1,routes:routes,reserved:reserved)}
func route(_ source:String="10",_ destination:String="42",_ scope:UmpLiveScope = .endpoint)->UmpLiveRoute{UmpLiveRoute(source:source,destination:destination,scope:scope)}
let on:[UInt32]=[0x43953c03,0x90012345],off:[UInt32]=[0x43853c00,0x12340000],bend:[UInt32]=[0x43e50000,0x87654321]
let pedal:[UInt32]=[0x43b54000,0xffffffff],sx:[UInt32]=[0x33120102,0]
// Admission compares physical destination/group/channel, including reservations.
refuses{try plan([route(),route("11")]).validate()}
refuses{try plan([route()], [UmpLiveClaim(destination:"42",scope:scope(3,5))]).validate()}
refuses{try plan([route("010")]).validate()}
refuses{try plan([route("10","42",.channels([]))]).validate()}
refuses{try plan([route("10","42",scope(16,0))]).validate()}
try plan([route("10","42",scope(3,5)),route("11","42",scope(1,2))], [UmpLiveClaim(destination:"42",scope:scope(0,1))]).validate()
for invalid in [#"{"kind":"endpoint","channels":[]}"#,#"{"kind":"channels","channels":[{"group":0,"channel":0},{"group":0,"channel":0}]}"#,#"{"kind":"unknown"}"#] {refuses{_ = try JSONDecoder().decode(UmpLiveScope.self,from:Data(invalid.utf8))}}
let source=UmpLiveSource(endpoint:9,uid:10);try source.check();identity=11;refuses{try source.check()};identity=10
propertyFailure=true;refuses{try source.check()};propertyFailure=false;offline=1;refuses{try source.check()};offline=0
func owner(_ value:UmpLivePlan=plan([route()]))throws->UmpLiveInput{let o=try UmpLiveInput(plan:value);o.sources=[9:source];o.state = .running;o.accepting=true;o.now={100};return o}
func input(_ owner:UmpLiveInput,_ words:[UInt32],host:UInt64=100,protocolID:MIDIProtocolID = ._2_0){
 let size=MemoryLayout<MIDIEventList>.size+words.count*4
 let raw=UnsafeMutableRawPointer.allocate(byteCount:size,alignment:MemoryLayout<MIDIEventList>.alignment);defer{raw.deallocate()}
 let list=raw.assumingMemoryBound(to:MIDIEventList.self),first=MIDIEventListInit(list,protocolID)
 words.withUnsafeBufferPointer{_ = MIDIEventListAdd(list,size,first,host,$0.count,$0.baseAddress!)}
 owner.receive(UnsafePointer(list),context:UnsafeMutableRawPointer(bitPattern:9))
}
func close(_ owner:UmpLiveInput,_ failed:Bool=false){var ended=0;owner.onClosed={error in precondition((error != nil)==failed);ended+=1};owner.stop();pump{owner.state == .closed};precondition(ended==1 && owner.pendingWords==0 && owner.pending.isEmpty && !owner.accepting && owner.outputs.allSatisfy{$0.closed});owner.stop();precondition(ended==1)}
// A large variable-sized event packet preserves complete messages and exact words.
let large=try owner();sent=[];let words=Array(repeating:on+off,count:40).flatMap{$0};input(large,words)
precondition(large.pendingWords==160);pump{large.pendingWords==0};precondition(sent.flatMap{$0.1}==words);close(large)
// Future packets remain queued, sorting by timestamp then callback admission.
let future=try owner();sent=[]
input(future,bend,host:1_000_000_000_000);input(future,on,host:1_000_000_000_000);input(future,off,host:2_000_000_000_000)
pump{future.pending.count==3};precondition(sent.isEmpty)
future.now={999_999_999_999};future.tick();precondition(sent.isEmpty)
future.now={1_000_000_000_000};future.tick();precondition(sent.map{$0.1}==[bend,on] && future.pendingWords==2)
future.now={2_000_000_000_000};future.tick();precondition(sent.map{$0.1}==[bend,on,off]);close(future)
// Channel filters do not forward another group or system/SysEx traffic.
let selected=try owner(plan([route("10","42",scope(3,5)),route("10","42",scope(1,2))]));sent=[]
let other:[UInt32]=[0x41923d00,0x80010000];input(selected,on+other+sx);pump{selected.pendingWords==0}
precondition(sent.map{$0.1}==[on,other] && selected.forwarded==2 && selected.filtered==4);close(selected)
// Shutdown closes callback admission before queued handoffs. None can send, and
// the stopped acknowledgement follows their reservation release.
let handoff=try owner();sent=[];input(handoff,on);input(handoff,bend,host:1_000_000_000_000)
precondition(handoff.pendingWords==4);close(handoff);precondition(sent.isEmpty)
// Due voice/pedal/partial-exclusive acquisitions are cleaned, not broad resets.
let owned=try owner();sent=[];input(owned,on+pedal+sx);pump{owned.pendingWords==0};close(owned)
precondition(sent.count==6 && owned.outputs[0].held.isEmpty && owned.outputs[0].pedals.isEmpty && owned.outputs[0].exclusive.isEmpty)
// An uncertain send still retains ownership so stop attempts its scoped release.
let uncertain=try owner();sent=[];failNext=true;var failed=false;uncertain.onClosed={error in failed=error != nil}
input(uncertain,on);pump{uncertain.state == .closed};precondition(failed && sent.map{$0.1}==[on,[0x43853c00,0]] && uncertain.pendingWords==0)
// Truncated frames are rejected before any message from that packet is sent.
let truncated=try owner();sent=[];input(truncated,bend+[on[0]]);pump{truncated.state == .closed};precondition(truncated.firstFailure != nil && sent.isEmpty && truncated.pendingWords==0)
// Pending payload capacity includes callback handoffs, not cumulative usage.
let saturated=try owner();sent=[];input(saturated,Array(repeating:UInt32(0),count:UmpLiveInput.maximumPendingWords),host:1_000_000_000_000)
precondition(saturated.pendingWords==UmpLiveInput.maximumPendingWords);input(saturated,on)
pump{saturated.state == .closed};precondition(saturated.firstFailure != nil && saturated.pendingWords==0 && sent.isEmpty)
let reused=try owner();sent=[];for _ in 0..<3{input(reused,Array(repeating:UInt32(0),count:32_768));pump{reused.pendingWords==0}}
precondition(reused.forwarded==98_304);close(reused)
let protocolFailure=try owner();sent=[];input(protocolFailure,[0x20903c7f],protocolID:._1_0);pump{protocolFailure.state == .closed};precondition(protocolFailure.firstFailure != nil && sent.isEmpty)
print("LIVE_MIDI_DECISIONS_PASS: physical leases, UID pinning, raw variable packet fidelity, exact ordered future deadlines, filtering, queued callback stop barrier, scoped/uncertain cleanup, truncated framing, explicit bounded in-flight overflow, reusable capacity, protocol refusal")
`
 await writeFile(join(directory,'main.swift'),main)
 const files=['MidiTransport.swift','UmpTransport.swift','UmpState.swift'].map(file=>new URL(file,import.meta.url).pathname)
 let result=spawnSync('xcrun',['swiftc','-D','MIDI_LIBRARY',...files,join(directory,'Output.swift'),join(directory,'Live.swift'),join(directory,'main.swift'),'-o',join(directory,'probe'),'-framework','CoreMIDI'],{encoding:'utf8'})
 assert.equal(result.status,0,result.stderr)
 result=spawnSync(join(directory,'probe'),[],{encoding:'utf8'});assert.equal(result.status,0,JSON.stringify({error:result.error,signal:result.signal,stdout:result.stdout,stderr:result.stderr}));console.log(result.stdout.trim())
}finally{await rm(directory,{recursive:true,force:true})}
