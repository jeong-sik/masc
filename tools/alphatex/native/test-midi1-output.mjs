// Actual CoreMIDI private endpoints plus the production conversion/admission
// boundary. No existing instrument, output protocol or default route is changed.
import assert from 'node:assert/strict'
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { spawnSync } from 'node:child_process'
const directory=await mkdtemp(join(tmpdir(),'masc-midi1-wire-'))
try {
 const main=String.raw`import Foundation
import CoreMIDI
@main enum Probe {
 static func main() throws {
  func refuses(_ block:()throws->Void,file:StaticString=#file,line:UInt=#line) { do {try block();tracePreconditionFailure("unsupported output admitted",file:file,line:line)} catch {} }
  func event(_ words:[UInt32])->UmpEvent {UmpEvent(seconds:0,source:"A",words:words)}
  // Use the specification's bit-repeat formula as a separate oracle.
  func canonical(_ x:UInt32,_ bits:Int,_ out:Int)->UInt32 {
   if x <= 1 << (bits-1) {return x << (out-bits)}
   let low=x & ((1 << (bits-1))-1)
   var value=x << (out-bits)
   for target in 0..<(out-bits) {let source=(target+(bits-1)-(out-bits) % (bits-1)) % (bits-1);value |= ((low >> source) & 1) << target}
   return value
  }
  for (bits,out) in [(7,16),(7,32),(14,32)] {
   for x in UInt32(0)..<(1 << bits) {
    let y=canonical(x,bits,out)
    tracePrecondition(umpScaleUp(x,from:bits,to:out)==y)
    let inverse=try umpExactDown(y,from:out,to:bits);tracePrecondition(inverse==x)
    if y < UInt32.max >> (32-out) {refuses {_ = try umpExactDown(y+1,from:out,to:bits)}}
   }
  }
  let projectedNote=try umpMidi1Words([0x47903c00,0xb4d30000]);tracePrecondition(projectedNote == [0x20903c5a])
  let projectedPitch=try umpMidi1Words([0x47e20000,0x80000000]);tracePrecondition(projectedPitch == [0x20e20040])
  let projectedBank=try umpMidi1Words([0x47c20001,0x05000102]);tracePrecondition(projectedBank == [0x20b20001,0x20b22002,0x20c20500])
  for words:[UInt32] in [[0x40903c00,0],[0x40903c01,0x80000000],[0x40903c00,0x80000001],
   [0x40b20000,0],[0x40b20600,0],[0x40c20002,0],[0x40c20000,1],[0x40d20001,0],
   [0x40e20000,0x80000001],[0x40120000,0],[0x10f88000],[0x20c20001],[0x30010101,0],[0x50000000,0,0,0]] {
   refuses {_ = try umpMidi1Words(words)}
  }
  var client=MIDIClientRef(),destinations:[MIDIEndpointRef]=[]
  try checked(MIDIClientCreate("MASC owned MIDI1 wire probe" as CFString,nil,nil,&client),"private client")
  defer {for endpoint in destinations {MIDIEndpointDispose(endpoint)};MIDIClientDispose(client)}
  let lock=NSCondition();var received:[Int:[[UInt32]]]=[:]
  // CoreMIDI delivers on its receive thread. A send/close return and a fixed
  // sleep do not establish that this private endpoint observed the final word.
  func receivedWords(_ index:Int,count:Int)->[UInt32] {
   lock.lock();defer {lock.unlock()}
   let deadline=Date().addingTimeInterval(5)
   while received[index,default:[]].reduce(0,{$0+$1.count}) < count {
    if !lock.wait(until:deadline) {
     let actual=received[index,default:[]].flatMap{$0}
     tracePrecondition(actual.count >= count,"private endpoint missing words: \(actual)")
    }
   }
   return received[index,default:[]].flatMap{$0}
  }
  func endpoint(_ native:MIDIProtocolID,_ index:Int)throws->String {
   var result=MIDIEndpointRef()
   try checked(MIDIDestinationCreateWithProtocol(client,"MASC wire \(UUID().uuidString)" as CFString,native,&result,{list,_ in
    var rows:[[UInt32]]=[]
    withUnsafePointer(to:list.pointee.packet) { first in
     var packet=first
     for _ in 0..<list.pointee.numPackets {
      let count=Int(packet.pointee.wordCount)
      let words=withUnsafePointer(to:packet.pointee.words) {ptr in ptr.withMemoryRebound(to:UInt32.self,capacity:count){Array(UnsafeBufferPointer(start:$0,count:count))}}
      rows.append(words);packet=UnsafePointer(MIDIEventPacketNext(packet))
     }
    }
    wireTrace.record(.receive,UInt32(index),packets:rows)
    lock.lock();received[index,default:[]].append(contentsOf:rows);lock.broadcast();lock.unlock()
   }),"private destination")
   destinations.append(result);var uid:Int32=0
   try checked(MIDIObjectGetIntegerProperty(result,kMIDIPropertyUniqueID,&uid),"private UID");return String(uid)
  }
  let midi1=try endpoint(._1_0,1),midi2=try endpoint(._2_0,2)
  let rows:[[UInt32]]=[[0x47923c00,0xb4d30000],[0x47b24000,0x80000000],[0x47e20000,0x80000000],
    [0x47c20001,0x05000102],[0x47d20000,0x80000000],[0x47a23c00,0x80000000],
    [0x17f80000],[0x37020102,0],[0x47823c00,0]]
  let output=UmpOutput(bindings:[UmpBinding(source:"A",destination:midi1)],compatibleEvents:rows.map(event))
  try output.prepare();tracePrecondition(output.nativeProtocols[midi1] == .midi1)
  for row in rows {try output.apply(event(row))}
  tracePrecondition(output.held.isEmpty);try output.close()
  tracePrecondition(output.pedals.isEmpty)
  let actual=receivedWords(1,count:13)
  tracePrecondition(actual == [0x20923c5a,0x20b24040,0x20e20040,0x20b20001,0x20b22002,0x20c20500,
   0x20d24000,0x20a23c40,0x10f80000,0x30020102,0,0x20823c00,0x20b24000],"actual MIDI1 wire or cleanup differs: \(actual)")
  let raw:[UInt32]=[0x47923c03,0x90011234]
  let exact=UmpOutput(bindings:[UmpBinding(source:"A",destination:midi2)],compatibleEvents:[event(raw)])
  try exact.prepare();try exact.apply(event(raw));try exact.close()
  tracePrecondition(exact.held.isEmpty && exact.pedals.isEmpty)
  let native2Expected=raw+[0x47823c00,0]
  tracePrecondition(receivedWords(2,count:native2Expected.count)==native2Expected)
  for incompatible in [[event([0x47923c00,0xb4d30000]),event([0x48923c00,0xb4d30000])],
    [event([0x27923c5a]),event([0x47823c00,0])],[event(raw)]] {
   let denied=UmpOutput(bindings:[UmpBinding(source:"A",destination:midi1)],compatibleEvents:incompatible)
   refuses {try denied.prepare()};tracePrecondition(denied.port==0 && denied.client==0 && denied.selected.isEmpty)
  }
  let future=UmpOutput(bindings:[UmpBinding(source:"A",destination:midi1)])
  refuses {try future.prepare()};tracePrecondition(future.port==0 && future.client==0)
  // Physical ownership is checked after the native protocol is pinned: g7/ch2
  // collides with SMF group0/ch2 on MIDI1, but g7/ch3 remains independent.
  func hybrid(_ channel:Int)throws->HybridMidiTransport {
   let object:[String:Any] = ["schemaVersion":6,"kind":"hybrid-arrangement","duration":1,
    "midi":["schemaVersion":3,"duration":1,"sources":[["id":"notes","timeline":["schemaVersion":2,"duration":1,
     "bindings":[["port":0,"destination":midi1]],"events":[["seconds":0.2,"port":0,"bytes":[0x92,60,90]],["seconds":0.3,"port":0,"bytes":[0x82,60,0]]]]]],
     "regions":[["id":"smf","source":"notes","startSeconds":0,"sourceStart":0,"sourceEnd":1,"repeatCount":1,
       "startNanoseconds":["numerator":"0","denominator":"1"],"periodNanoseconds":["numerator":"1000000000","denominator":"1"]]]],
    "umpRegions":["schemaVersion":1,"duration":1,"sources":[["id":"take","extent":"1000000000","timeline":["schemaVersion":4,"duration":1,
     "clock":["origin":"0","numer":1,"denom":1],"bindings":[["source":"A","destination":midi1]],
     "packets":[["kind":"midi","protocol":2,"hostTime":"200000000","source":"A","timestampOrigin":"packet","words":[0x47903c00 | channel << 16,0xb4d30000]],
       ["kind":"midi","protocol":2,"hostTime":"300000000","source":"A","timestampOrigin":"packet","words":[0x47803c00 | channel << 16,0]]]]]],
      "regions":[["id":"captured","source":"take","startSeconds":0,"offset":"0","extent":"1000000000","repeatCount":1]]]]
   struct Envelope:Decodable {let midi:Timeline;let umpRegions:UmpArrangement}
   let envelope=try JSONDecoder().decode(Envelope.self,from:JSONSerialization.data(withJSONObject:object))
   return try HybridMidiTransport(midi:envelope.midi,ump:envelope.umpRegions)
  }
  let collision=try hybrid(2);refuses{try collision.prepare()};tracePrecondition(collision.state == .stopped)
  let disjoint=try hybrid(3);try disjoint.prepare();disjoint.finish(reason:"test",error:nil,publish:false)
  // CoreMIDI documents protocol mutation for drivers after MIDI-CI negotiation,
  // not a synchronous virtual-client setter contract. Keep real endpoint
  // identity/admission/wire checks, then inject only its observed protocol read.
  let live=try UmpLiveInput(plan:UmpLivePlan(schemaVersion:1,routes:[UmpLiveRoute(key:"a",source:"1",destination:midi2,scope:.endpoint)],reserved:[UmpLiveClaim(destination:midi1,scope:.endpoint,nativeProtocol:1)]))
  tracePrecondition(output.nativeProtocols[midi1] == .midi1 && !output.selected.isEmpty)
  try output.checkDestinations();try live.checkReservations()
  wireProtocolReadOverride=(destinations[0],2)
  let beforeOutput=wireProtocolReadOverrideCount
  refuses {try output.checkDestinations()}
  tracePrecondition(wireProtocolReadOverrideCount>beforeOutput)
  let beforeReservation=wireProtocolReadOverrideCount
  refuses {try live.checkReservations()}
  tracePrecondition(wireProtocolReadOverrideCount>beforeReservation)
  wireProtocolReadOverride=nil
  try output.checkDestinations();try live.checkReservations()
  print("MIDI1_OUTPUT_PASS: 16640 canonical inverses, precision/attributes/compound/mixed-group refusal, actual private MIDI1 bank/note/pressure/pitch/system/SysEx and cleanup, exact native2, deterministic observed-protocol drift rejection for output and live reservation")
 }
}`
 await writeFile(join(directory,'Probe.swift'),main)
 const originalOutput=await readFile(new URL('UmpOutput.swift',import.meta.url),'utf8')
 let tracedOutput=originalOutput
 for(const [from,to] of [['MIDISendEventList(', 'traceSend('],['MIDIPortDispose(', 'tracePortDispose('],['MIDIClientDispose(', 'traceClientDispose('],['MIDIObjectGetIntegerProperty(', 'traceIntegerProperty(']]) {
  assert.ok(tracedOutput.includes(from),`Missing diagnostic API edge ${from}`)
  tracedOutput=tracedOutput.replaceAll(from,to)
 }
 const sourceEdge='        let payload = try wire == .midi1 ? umpMidi1Words(words) : words'
 assert.equal(tracedOutput.split(sourceEdge).length,2)
 tracedOutput=tracedOutput.replace(sourceEdge,'        wireTrace.record(.source,UInt32(wire.rawValue),packets:[words])\n'+sourceEdge)
 for(const edge of ['        closed = true','        try silence()']) {
  assert.equal(tracedOutput.split(edge).length,2)
  const state='wireTrace.record(.owner,port,client,owner:WireOwnerState(held:held.values.reduce(0,+),pedals:pedals.count,exclusive:exclusive.count,closed:closed))'
  tracedOutput=tracedOutput.replace(edge,edge+'\n        '+state)
 }
 await writeFile(join(directory,'Output.swift'),tracedOutput+String.raw`
enum WireTraceKind:String,Codable {case source,send,sendResult,portDispose,portDisposed,clientDispose,clientDisposed,receive,owner}
struct WireOwnerState:Encodable {let held:Int,pedals:Int,exclusive:Int;let closed:Bool}
struct WireTraceRow:Encodable {
 let serial:Int,host:UInt64,kind:WireTraceKind,first:UInt32,second:UInt32,status:Int32?,packets:[[UInt32]],owner:WireOwnerState?
}
final class WireTrace {
 let lock=NSLock();var rows:[WireTraceRow]=[]
 func record(_ kind:WireTraceKind,_ first:UInt32=0,_ second:UInt32=0,status:Int32?=nil,packets:[[UInt32]]=[],owner:WireOwnerState?=nil) {
  lock.lock();defer{lock.unlock()}
  rows.append(WireTraceRow(serial:rows.count,host:DispatchTime.now().uptimeNanoseconds,kind:kind,first:first,second:second,status:status,packets:packets,owner:owner))
 }
 func dump() {
  lock.lock();let snapshot=rows;lock.unlock()
  // Formatting and I/O happen only after an assertion already failed.
  if let data=try? JSONEncoder().encode(snapshot) {FileHandle.standardError.write(Data("MIDI_WIRE_FAILURE_TRACE ".utf8)+data+Data([10]))}
 }
}
let wireTrace=WireTrace()
// Test-only boundary: all reads still call CoreMIDI first. Only a successful
// protocol read of the exact owned destination can report the injected change.
var wireProtocolReadOverride:(endpoint:MIDIEndpointRef,protocolID:Int32)?
var wireProtocolReadOverrideCount=0
func traceIntegerProperty(_ object:MIDIObjectRef,_ property:CFString,_ value:UnsafeMutablePointer<Int32>)->OSStatus {
 let status=MIDIObjectGetIntegerProperty(object,property,value)
 if status==0,CFEqual(property,kMIDIPropertyProtocolID),let changed=wireProtocolReadOverride,object==changed.endpoint {
  value.pointee=changed.protocolID;wireProtocolReadOverrideCount+=1
 }
 return status
}
func tracePrecondition(_ condition:@autoclosure()->Bool,_ message:@autoclosure()->String="",file:StaticString=#file,line:UInt=#line) {
 if !condition(){wireTrace.dump();preconditionFailure(message(),file:file,line:line)}
}
func tracePreconditionFailure(_ message:String,file:StaticString=#file,line:UInt=#line)->Never {
 wireTrace.dump();preconditionFailure(message,file:file,line:line)
}
func traceSend(_ port:MIDIPortRef,_ destination:MIDIEndpointRef,_ list:UnsafePointer<MIDIEventList>)->OSStatus {
 var rows:[[UInt32]]=[]
 var packet=UnsafeRawPointer(list).advanced(by:MemoryLayout<MIDIEventList>.offset(of:\.packet)!).assumingMemoryBound(to:MIDIEventPacket.self)
 for _ in 0..<list.pointee.numPackets {
  let words=UnsafeRawPointer(packet).advanced(by:MemoryLayout<MIDIEventPacket>.offset(of:\.words)!).assumingMemoryBound(to:UInt32.self)
  rows.append(Array(UnsafeBufferPointer(start:words,count:Int(packet.pointee.wordCount))))
  packet=UnsafePointer(MIDIEventPacketNext(packet))
 }
 wireTrace.record(.send,port,destination,packets:rows)
 let status=MIDISendEventList(port,destination,list)
 wireTrace.record(.sendResult,port,destination,status:status);return status
}
@discardableResult func tracePortDispose(_ port:MIDIPortRef)->OSStatus {
 wireTrace.record(.portDispose,port);let status=MIDIPortDispose(port)
 wireTrace.record(.portDisposed,port,status:status);return status
}
@discardableResult func traceClientDispose(_ client:MIDIClientRef)->OSStatus {
 wireTrace.record(.clientDispose,client);let status=MIDIClientDispose(client)
 wireTrace.record(.clientDisposed,client,status:status);return status
}
`)
 const names=['MidiTransport','UmpTransport','UmpOutput','UmpState','UmpLiveInput','UmpRegions','UmpLoopTransport','HybridMidiTransport','CaptureAudioClock','SourceAudioClock','WaveLoopClock','PulseAudioClock','PulseLoopClock']
 let r=spawnSync('xcrun',['swiftc','-parse-as-library','-D','MIDI_LIBRARY',...names.map(n=>n==='UmpOutput'?join(directory,'Output.swift'):new URL(n+'.swift',import.meta.url).pathname),join(directory,'Probe.swift'),'-o',join(directory,'probe'),'-framework','CoreMIDI'],{encoding:'utf8'})
 assert.equal(r.status,0,r.stderr)
 r=spawnSync(join(directory,'probe'),[],{encoding:'utf8'});assert.equal(r.status,0,r.stdout+r.stderr);process.stdout.write(r.stdout)
} finally {await rm(directory,{recursive:true,force:true})}
