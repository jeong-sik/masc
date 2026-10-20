// Production UMP protocol/clock/cleanup decisions with synthetic send and clock
// edges. Real CoreMIDI delivery is a separate installed runtime scenario.
import assert from 'node:assert/strict'
import {readFile,writeFile,mkdtemp,rm} from 'node:fs/promises'
import {join} from 'node:path'
import {spawnSync} from 'node:child_process'
const directory=await mkdtemp('/private/tmp/masc-ump-decisions-')
try {
  let transportSource=await readFile(new URL('./UmpTransport.swift',import.meta.url),'utf8')
  let source=await readFile(new URL('./UmpOutput.swift',import.meta.url),'utf8')
  const replaceMethod=(first,last,replacement)=>{const a=source.indexOf(first),b=source.indexOf(last,a);assert.ok(a>=0&&b>a);source=source.slice(0,a)+replacement+'\n'+source.slice(b)}
  source=source.replaceAll('DispatchTime.now().uptimeNanoseconds','reviewClock')
  replaceMethod('    func checkDestinations()', '    func send(', '    func checkDestinations() throws {if reviewUnavailable {throw MidiFailure("removed endpoint")}}')
  replaceMethod('    func send(', '    func apply(', `    func send(_ words:[UInt32],source:String)throws {
      if reviewFail {reviewFail=false;throw MidiFailure("uncertain send")}
      reviewSent.append((source,words))
    }`)
  const globals='var reviewClock:UInt64=0;var reviewSent:[(String,[UInt32])]=[];var reviewFail=false;var reviewUnavailable=false\n'
  await writeFile(join(directory,'Ump.swift'),source+'\n'+transportSource.replaceAll('DispatchTime.now().uptimeNanoseconds','reviewClock')+'\n'+globals)
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
reviewClock=1_250_000_000;a.tick();precondition(reviewSent.map{$0.1}==[on,bend,off]);precondition(a.output.held.isEmpty)
reviewClock=2_000_000_000;a.tick();precondition(ended==1 && a.state == .ended)
a.tick();precondition(ended==1)
try a.stageCoordinated(at:0.5);precondition(a.state == .staged)
let owned=try UmpTransport(timeline:timeline([packet(0,"A",zeroOn)]));reviewSent=[]
try owned.output.apply(UmpEvent(seconds:0,source:"A",words:zeroOn));precondition(owned.output.held.values.reduce(0,+)==1)
try owned.output.silence();precondition(owned.output.held.isEmpty && reviewSent.last!.1==[0x43853c00,0])
try owned.output.apply(UmpEvent(seconds:0,source:"A",words:on));reviewFail=true
requireFailure{try owned.output.apply(UmpEvent(seconds:0,source:"A",words:off))};precondition(!owned.output.held.isEmpty)
try owned.output.silence();precondition(owned.output.held.isEmpty)
let count=reviewSent.count;try owned.output.silence();precondition(reviewSent.count==count)
let pedal:[UInt32]=[0x43b54000,0xffffffff]
try owned.output.apply(UmpEvent(seconds:0,source:"A",words:pedal));try owned.output.silence();precondition(reviewSent.last!.1==[0x43b54000,0])
let sx:[UInt32]=[0x33120102,0];try owned.output.apply(UmpEvent(seconds:0,source:"A",words:sx));try owned.output.silence()
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
// Chasing is a source-state operation: expired key pairs disappear, while
// controllers, note attributes, original releases and pedal ordering survive.
func event(_ time:Double,_ words:[UInt32])->UmpEvent {UmpEvent(seconds:time,source:"A",words:words)}
func checkRestore(_ value:@autoclosure ()throws->Bool,_ why:String)throws {let actual=try value();precondition(actual,why)}
func restore(_ rows:[UmpEvent],_ at:Double,_ prior:UmpFootprint=UmpFootprint())throws->[[UInt32]] {try umpRestoration(rows,before:at,replacing:prior).events.map{$0.words}}
func footprint(_ rows:[UmpEvent])->UmpFootprint {var value=UmpFootprint();for row in rows{value.observe(UmpMessage(row))};return value}
let reset:[UInt32]=[0x43b57900,0],sost:[UInt32]=[0x43b54200,0xffffffff]
let pn:[UInt32]=[0x43653c00,0x92345678],pn2:[UInt32]=[0x43653c00,0xa2345678]
let manage:[UInt32]=[0x43f53c03,0],pnon:[UInt32]=[0x43953c03,0x80012345]
let noteRows=[event(0,pn),event(0.1,pnon),event(0.2,manage),event(0.3,on),event(0.4,pn2)]
let noteReplay=try restore(noteRows,0.5)
precondition(noteReplay==noteRows.map{$0.words},"per-note prehistory and detach+reset order")
let repeated=[event(0,on),event(0.1,off),event(0.2,zeroOn)]
let repeatReplay=try restore(repeated,0.3);precondition(repeatReplay==[zeroOn],"expired pair cannot release/retrigger surviving note index")
let sustainRows=[event(0,on),event(0.1,pedal),event(0.2,off)]
try checkRestore(restore(sustainRows,0.3)==[on,pedal,off],"original pedal-held release")
let sostRows=[event(0,on),event(0.1,sost),event(0.2,off),event(0.3,zeroOn),event(0.4,[0x43853c00,0x45670000])]
try checkRestore(restore(sostRows,0.5)==[on,sost,off],"sostenuto captures only held voices on its rising edge")
let pnPrior=footprint([event(0,pn)])
requireFailure{_ = try restore([event(0,reset)],0.5,pnPrior)}
try checkRestore(restore([event(0,pn),event(0.1,reset),event(0.2,on)],0.5,pnPrior)==[pn,reset,on],"CC121 preserves known MIDI2 per-note pitch")
let p0:[UInt32]=[0x43c50001,0x05000102],p1:[UInt32]=[0x43c50000,0x06000000]
let programPrior=footprint([event(0,p0)])
requireFailure{_ = try restore([event(0,p1)],0.5,programPrior)}
requireFailure{_ = try restore([event(0,on),event(0.1,p0)],0.5,programPrior)}
try checkRestore(restore([event(0,p0),event(0.1,on),event(0.2,p1)],0.5,programPrior)==[p0,on,p1],"bank-valid=0 preserves bank and initial patch precedes Note On")
let absRpn:[UInt32]=[0x43250102,0x80000000],rel:[UInt32]=[0x43450102,0xfffffff0]
requireFailure{_ = try restore([event(0,rel)],0.5)}
try checkRestore(restore([event(0,absRpn),event(0.1,rel)],0.5,footprint([event(0,rel)]))==[absRpn,rel],"absolute baseline then original signed relative words")
requireFailure{_ = try restore([event(0,sx)],0.5)}
requireFailure{_ = try restore([],0.5,footprint([event(0,sx)]))}
requireFailure{_ = try restore([event(0,on),event(0.1,[0x23953c7f])],0.5)}
requireFailure{_ = try restore([event(0,[0x43b55400,0x78000000]),event(0.1,on),event(0.2,off),event(0.3,zeroOn)],0.5)}
let midi1=[event(0,[0x23953c7f]),event(0.1,[0x23953c00]),event(0.2,[0x23953d7f])]
try checkRestore(restore(midi1,0.3)==[[0x23953d7f]],"MIDI1 UMP zero velocity releases its key")
// The replay is sent at once: a continuous value set after a surviving Note On
// reaches it, so only attack selections and Detach-frozen per-note values need
// an earlier baseline for fields this transport changed.
let poly:[UInt32]=[0x43a53c00,0x80000000],pressure:[UInt32]=[0x43d50000,0x80000000]
let pedalHeld=[event(0.1,on),event(0.2,pedal),event(0.3,off)]
try checkRestore(restore(pedalHeld,0.45,footprint(pedalHeld))==[on,pedal,off],"sustain after a surviving Note On")
for later in [poly,pressure,bend,[0x43b50100,0x80000000]] as [[UInt32]] {
  let rows=[event(0.1,on),event(0.2,later)]
  try checkRestore(restore(rows,0.45,footprint(rows))==[on,later],"continuous value after a surviving Note On")
}
let pitch:[UInt32]=[0x43053c03,0x3c000000],bank1:[UInt32]=[0x23b50005]
requireFailure{_ = try restore([event(0,on),event(0.1,pitch)],0.5,footprint([event(0,pitch)]))}
try checkRestore(restore([event(0,pitch),event(0.1,on)],0.5,footprint([event(0,pitch)]))==[pitch,on],"Pitch 7.25 precedes the Note On that may select its sample")
let resetOnly:[UInt32]=[0x43f53c01,0],resetPrior=footprint([event(0,resetOnly)])
requireFailure{_ = try restore([event(0,pitch),event(0.1,on),event(0.2,resetOnly)],0.5,resetPrior)}
try checkRestore(restore([event(0,resetOnly),event(0.1,on)],0.5,resetPrior)==[resetOnly,on],"a per-note reset before the attack re-establishes every per-note value")
// Portamento, tuning selection, MPE layout, per-note pitch range and vendor
// assignable controllers are not known to reach a voice after its attack.
let kept:[[UInt32]]=[[0x43b54100,0xffffffff],[0x43b50500,0x40000000],[0x43250003,0x0a000000],[0x43250004,0x02000000],[0x43250006,0x10000000],
  [0x43250007,0x10000000],[0x43351005,0x80000000],[0x43153c05,0x80000000]]
for value in kept {
  requireFailure{_ = try restore([event(0,on),event(0.1,value)],0.5,footprint([event(0,value)]))}
  try checkRestore(restore([event(0,value),event(0.1,on)],0.5,footprint([event(0,value)]))==[value,on],"value kept by the attack precedes the Note On")
}
// MIDI 1.0 Bank Select takes effect at the next Program Change: a replayed
// Program Change needs a changed Bank Select before it, the Note On does not.
let pc1:[UInt32]=[0x23c50500],on1:[UInt32]=[0x23953c7f]
for rows in [[event(0,pc1),event(0.05,bank1),event(0.1,on1)],[event(0,pc1),event(0.05,bank1)]] { requireFailure{_ = try restore(rows,0.5,footprint(rows))} }
let latched=[event(0,bank1),event(0.05,pc1),event(0.1,on1)]
try checkRestore(restore(latched,0.5,footprint(latched))==[bank1,pc1,on1],"Bank Select before its Program Change")
try checkRestore(restore([event(0,on1),event(0.1,bank1)],0.5,footprint([event(0,bank1)]))==[on1,bank1],"Bank Select without a Program Change keeps the patch")
let detach:[UInt32]=[0x43f53c02,0]
requireFailure{_ = try restore([event(0,on),event(0.1,detach),event(0.2,pn)],0.5,pnPrior)}
try checkRestore(restore([event(0,on),event(0.1,pn),event(0.2,detach),event(0.3,pn2)],0.5,pnPrior)==[on,pn,detach,pn2],"per-note pitch reaches the sounding voice before its Detach")
try checkRestore(restore([event(0,on),event(0.1,pn)],0.5,pnPrior)==[on,pn],"per-note pitch after a surviving Note On without Detach")
try checkRestore(restore([event(0,on),event(0.1,off),event(0.2,detach),event(0.3,pn)],0.5,pnPrior)==[detach,pn],"Detach freezes no expired voice")
let timing:[[UInt32]]=[[0x13f80000],[0x13fe0000],[0x00000000],[0x00101234],[0x00201234]]
let timed=timing.map{event(0,$0)}+[event(0.1,on),event(0.2,bend)]
try checkRestore(restore(timed,0.5,footprint(timed))==[on,bend],"timing and liveness messages are neither obstacles nor replayed")
for opaque in [[0x13fa0000],[0x13ff0000],[0x00300060]] as [[UInt32]] { requireFailure{_ = try restore([event(0,opaque)],0.5)} }
// Real transport methods with a synthetic clock/send edge: staging releases
// owned keys but sounds no restored key until the common epoch. A late first
// callback reconstructs its current phase instead of retriggering expired keys.
reviewUnavailable=false;reviewClock=0;reviewSent=[]
let phase=try UmpTransport(timeline:timeline([packet(0,"A",bend),packet(2400000,"A",on),packet(4800000,"A",off),packet(14400000,"A",zeroOn)]))
try phase.stageCoordinated(at:0.15);precondition(reviewSent.isEmpty)
try phase.runCoordinated(anchorNanoseconds:1_000_000_000)
reviewClock=999_999_999;phase.tick();precondition(reviewSent.isEmpty)
reviewClock=1_200_000_000;phase.tick();precondition(reviewSent.map{$0.1}==[bend],"late epoch must not retrigger expired source keys")
reviewClock=1_500_000_000;phase.tick();precondition(reviewSent.map{$0.1}==[bend,zeroOn])
try phase.stageCoordinated(at:0.7);precondition(phase.output.held.isEmpty && phase.state == .staged)
let pausedCount=reviewSent.count;reviewClock=2_000_000_000;phase.tick();precondition(reviewSent.count==pausedCount && phase.position(at:reviewClock)==0.7)
try phase.runCoordinated(anchorNanoseconds:3_000_000_000)
reviewClock=2_999_999_999;phase.tick();precondition(reviewSent.count==pausedCount)
reviewClock=3_000_000_000;phase.tick();precondition(Array(reviewSent.suffix(2)).map{$0.1}==[bend,zeroOn])
phase.finish(reason:"test",error:nil,publish:false);precondition(phase.output.held.isEmpty)
// Pausing after a pedal-held release or an Active Sensing message stays playable;
// a refused stage changes nothing, so its owner can keep the current playback.
let takes:[([UmpPacket],[[UInt32]])]=[([packet(2400000,"A",on),packet(4800000,"A",pedal),packet(7200000,"A",off)],[on,pedal,off]),
  ([packet(0,"A",[0x13fe0000]),packet(2400000,"A",on),packet(4800000,"A",off)],[])]
for (packets,restored) in takes {
  reviewClock=0;reviewSent=[]
  let take=try UmpTransport(timeline:timeline(packets))
  try take.stageCoordinated(at:0);try take.runCoordinated(anchorNanoseconds:1_000_000_000)
  reviewClock=1_450_000_000;take.tick();precondition(reviewSent.count==packets.count)
  try take.stageCoordinated(at:0.45);try take.runCoordinated(anchorNanoseconds:2_000_000_000)
  let staged=reviewSent.count;reviewClock=2_000_000_000;take.tick()
  precondition(Array(reviewSent[staged...]).map{$0.1}==restored,"pause after a pedal-held release or Active Sensing restores its take")
  take.finish(reason:"test",error:nil,publish:false)
}
let refused=try UmpTransport(timeline:timeline([packet(0,"A",sx),packet(2400000,"A",on)]));reviewClock=0
try refused.stageCoordinated(at:0);try refused.runCoordinated(anchorNanoseconds:1_000_000_000)
reviewClock=1_050_000_000;refused.tick()
do {try refused.stageCoordinated(at:0.05);preconditionFailure("admitted SysEx reconstruction")} catch is UmpRefusal {}
precondition(refused.state == .playing && refused.timer != nil,"a refused stage leaves the playing owner unchanged")
refused.finish(reason:"test",error:nil,publish:false)
let expired=try UmpTransport(timeline:timeline([packet(24000000,"A",on)]));reviewClock=0;reviewSent=[]
try expired.stageCoordinated(at:0.5);try expired.runCoordinated(anchorNanoseconds:1_000_000_000)
var expiredEnds=0;expired.onCoordinatedEnd={expiredEnds+=1}
reviewClock=3_000_000_000;expired.tick();expired.tick()
precondition(reviewSent.isEmpty && expired.state == .ended && expiredEnds==1,"expired reconstructed interval must not acquire even an endpoint key")
print("UMP_DECISIONS_PASS: UInt64 source clocks, no early send, complete ordered late stream, original release/expression, MIDI2 zero velocity ownership, uncertain release retry, pedals/SysEx cleanup, group/global ownership, invalid packet/binding refusal, endpoint loss; live voice/pedal/PN/bank/program/relative baseline reconstruction, attack and Detach baselines only, stateless timing messages, unchanged refused stage; silent staging, late epoch, pause/resume cleanup")
`
  await writeFile(join(directory,'main.swift'),main)
  let result=spawnSync('xcrun',['swiftc','-module-cache-path',join(directory,'modules'),'-D','MIDI_LIBRARY',new URL('./MidiTransport.swift',import.meta.url).pathname,new URL('./UmpState.swift',import.meta.url).pathname,join(directory,'Ump.swift'),join(directory,'main.swift'),'-o',join(directory,'probe'),'-framework','CoreMIDI'],{encoding:'utf8'})
  assert.equal(result.status,0,result.stderr)
  result=spawnSync(join(directory,'probe'),[],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);console.log(result.stdout.trim())
}finally{await rm(directory,{recursive:true,force:true})}
