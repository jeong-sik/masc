// Production UMP protocol/clock/cleanup decisions with synthetic send and clock
// edges. Real CoreMIDI delivery is a separate installed runtime scenario.
import assert from 'node:assert/strict'
import {readFile,writeFile,mkdtemp,rm} from 'node:fs/promises'
import {join} from 'node:path'
import {spawnSync} from 'node:child_process'
const directory=await mkdtemp('/private/tmp/masc-ump-decisions-')
try {
  let source=await readFile(new URL('./UmpTransport.swift',import.meta.url),'utf8')
  const replaceMethod=(first,last,replacement)=>{const a=source.indexOf(first),b=source.indexOf(last,a);assert.ok(a>=0&&b>a);source=source.slice(0,a)+replacement+'\n'+source.slice(b)}
  source=source.replaceAll('DispatchTime.now().uptimeNanoseconds','reviewClock')
  replaceMethod('    func checkDestinations()', '    func send(', '    func checkDestinations() throws {if reviewUnavailable {throw MidiFailure("removed endpoint")}}')
  replaceMethod('    func send(', '    func apply(', `    func send(_ words:[UInt32],source:String)throws {
      if reviewFail {reviewFail=false;throw MidiFailure("uncertain send")}
      reviewSent.append((source,words))
    }`)
  const globals='var reviewClock:UInt64=0;var reviewSent:[(String,[UInt32])]=[];var reviewFail=false;var reviewUnavailable=false\n'
  await writeFile(join(directory,'Ump.swift'),source+'\n'+globals)
  const main=`import Foundation
func requireFailure(_ action:()throws->Void){do{try action();preconditionFailure("admitted invalid source")}catch{}}
let clock=UmpClock(origin:"9007199254740993123",numer:125,denom:3)
func packet(_ delta:UInt64,_ source:String,_ words:[UInt32])->UmpPacket {UmpPacket(kind:"midi",protocolID:2,hostTime:String(9007199254740993123+delta),source:source,timestampOrigin:"packet",words:words)}
func timeline(_ packets:[UmpPacket],_ bindings:[UmpBinding]=[UmpBinding(source:"A",destination:"42")])->UmpTimeline {UmpTimeline(schemaVersion:4,duration:1,clock:clock,bindings:bindings,packets:packets)}
let zeroOn:[UInt32]=[0x43953c00,0],on:[UInt32]=[0x43953c00,0x90010000],off:[UInt32]=[0x43853c00,0x12340000]
let bend:[UInt32]=[0x43e50000,0x87654321]
let a=try UmpTransport(timeline:timeline([packet(2400000,"A",on),packet(3600000,"A",bend),packet(4800000,"A",off)]))
var ended=0;a.onCoordinatedEnd={ended+=1}
try a.stageCoordinated(at:0);try a.runCoordinated(anchorNanoseconds:1_000_000_000)
reviewClock=999_999_999;a.tick();precondition(reviewSent.isEmpty)
reviewClock=1_250_000_000;a.tick();precondition(reviewSent.map{$0.1}==[on,bend,off]);precondition(a.held.isEmpty)
reviewClock=2_000_000_000;a.tick();precondition(ended==1 && a.state == .ended)
a.tick();precondition(ended==1)
requireFailure{try a.stageCoordinated(at:0.5)}
let owned=try UmpTransport(timeline:timeline([packet(0,"A",zeroOn)]));reviewSent=[]
try owned.apply(UmpEvent(seconds:0,source:"A",words:zeroOn));precondition(owned.held.values.reduce(0,+)==1)
try owned.silence();precondition(owned.held.isEmpty && reviewSent.last!.1==[0x43853c00,0])
try owned.apply(UmpEvent(seconds:0,source:"A",words:on));reviewFail=true
requireFailure{try owned.apply(UmpEvent(seconds:0,source:"A",words:off))};precondition(!owned.held.isEmpty)
try owned.silence();precondition(owned.held.isEmpty)
let count=reviewSent.count;try owned.silence();precondition(reviewSent.count==count)
let pedal:[UInt32]=[0x43b54000,0xffffffff]
try owned.apply(UmpEvent(seconds:0,source:"A",words:pedal));try owned.silence();precondition(reviewSent.last!.1==[0x43b54000,0])
let sx:[UInt32]=[0x33120102,0];try owned.apply(UmpEvent(seconds:0,source:"A",words:sx));try owned.silence()
precondition(reviewSent.last!.1==[0x33300000,0])
let bindings=[UmpBinding(source:"A",destination:"42"),UmpBinding(source:"B",destination:"42")]
requireFailure{_ = try timeline([packet(0,"A",on),packet(1,"B",on)],bindings).events()}
_ = try timeline([packet(0,"A",on),packet(1,"B",[0x41923c00,0x90010000])],bindings).events()
requireFailure{_ = try timeline([packet(0,"A",[0x30100102,0]),packet(1,"B",[0x30100304,0])],bindings).events()}
requireFailure{_ = try timeline([packet(0,"A",[0xf0000000,0,0,0]),packet(1,"B",[0x41923c00,0x90010000])],bindings).events()}
requireFailure{_ = try timeline([packet(0,"A",[0x43953c00])]).events()}
requireFailure{_ = try timeline([packet(0,"A",on)],[UmpBinding(source:"A",destination:"042")]).events()}
let removal=try UmpTransport(timeline:timeline([packet(0,"A",on)]));var failures=0
removal.onCoordinatedFailure={_,error in precondition(error != nil);failures+=1}
reviewClock=0;try removal.stageCoordinated(at:0);try removal.runCoordinated(anchorNanoseconds:1)
reviewUnavailable=true;reviewClock=2;removal.tick();precondition(failures==1 && removal.state == .stopped)
print("UMP_DECISIONS_PASS: UInt64 source clocks, no early send, complete ordered late stream, original release/expression, MIDI2 zero velocity ownership, uncertain release retry, pedals/SysEx cleanup, group/global ownership, invalid packet/binding refusal, endpoint loss")
`
  await writeFile(join(directory,'main.swift'),main)
  let result=spawnSync('xcrun',['swiftc','-module-cache-path',join(directory,'modules'),'-D','MIDI_LIBRARY',new URL('./MidiTransport.swift',import.meta.url).pathname,join(directory,'Ump.swift'),join(directory,'main.swift'),'-o',join(directory,'probe'),'-framework','CoreMIDI'],{encoding:'utf8'})
  assert.equal(result.status,0,result.stderr)
  result=spawnSync(join(directory,'probe'),[],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);console.log(result.stdout.trim())
}finally{await rm(directory,{recursive:true,force:true})}
