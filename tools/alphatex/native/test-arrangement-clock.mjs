// Production lifecycle decisions with synthetic audio/MIDI effects. No device is opened.
import assert from 'node:assert/strict'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'
const source=await readFile(new URL('./WaveArrangement.swift',import.meta.url),'utf8')
const part=(first,last)=>{const a=source.indexOf(first),b=source.indexOf(last,a);assert.ok(a>=0&&b>a);return source.slice(a,b)}
const methods=[part('    var completed: Bool', '    func checkOutput()'),part('    func currentTime()', '    func snapshot('),part('    func stopVoices()', '    func monitor('),part('    func receive(', '    func finish(')].join('\n').replaceAll('mach_absolute_time()', 'reviewHost').replaceAll('DispatchSource.makeTimerSource(queue: .main)', 'reviewTimer()')
const command=part('enum AudioCommand: Decodable', 'final class ArrangementTransport')
const future=part('func futureHost(', 'struct Asset:')
const swift=`import Foundation
import AVFoundation
import CoreAudio
var reviewHost: UInt64 = 1_000_000_000
var epochReplies:[[String:Any]]=[]
func audioEmit(_ event:[String:Any])throws{epochReplies.append(event)}
final class FakeTimer {
 var handler:(()->Void)?,cancelled=false
 func schedule(deadline:DispatchTime,leeway:DispatchTimeInterval){}
 func setEventHandler(handler:@escaping()->Void){self.handler=handler}
 func resume(){}
 func cancel(){cancelled=true}
 func fire(){handler?()}
}
func reviewTimer()->FakeTimer{FakeTimer()}

${future}
${command}
struct FakePractice {let countInSeconds:Double;let duration:Double;var loop:LoopPracticePlan?=nil}
struct FakeLoop {let duration=1.0}
struct FakePlan { var duration=1.0;let captured=false;var clocked=false;var practice:FakePractice?=nil;var loop:FakeLoop?=nil }
struct FakeRegion { var id="region-1";var startSeconds=0.0;var pulseClock:Bool?=nil;var pulseLoopUnit:Int64?=nil }
final class FakePlayer { var lastRenderTime:AVAudioTime?=AVAudioTime(hostTime:reviewHost);var plays=0;var whens:[UInt64]=[];func play(at:AVAudioTime){plays+=1;whens.append(at.hostTime)} }
final class FakeVoice {
 var region=FakeRegion();let player=FakePlayer();var end=1.0, prepares=0, stops=0;var positions:[Double]=[];var completion:(()->Void)?
 func prepare(from seconds:Double,finished:@escaping()->Void,failed:@escaping(Error)->Void)throws->Bool{prepares+=1;positions.append(seconds);completion=finished;return seconds<end}
 func stop(){stops+=1}
}
struct FakeFormat {let sampleRate=48000.0}
final class FakeOutput {var lastRenderTime:AVAudioTime?=AVAudioTime(hostTime:reviewHost);let presentationLatency=0.0;func outputFormat(forBus:Int)->FakeFormat{FakeFormat()}}
final class FakeEngine {let outputNode=FakeOutput();var starts=0,stops=0,pauses=0;func prepare(){};func start()throws{starts+=1};func pause(){pauses+=1};func stop(){stops+=1}}
final class FakeMidi { var stages:[Double]=[], runs:[UInt64]=[];func stageCoordinated(at seconds:Double)throws{stages.append(seconds)};func runCoordinated(anchorNanoseconds:UInt64)throws{runs.append(anchorNanoseconds)} }\nfinal class Probe {
 enum State {case prepared,playing,paused,stopped}
 var plan=FakePlan();let engine=FakeEngine(),renderQuantum=1024
 var horizon:FakeTimer?;var horizonEnded=false
 var midi:FakeMidi?;var midiEnded=false\n var state=State.prepared,voices=[FakeVoice()],active=Set<String>(),position=0.0,anchor:UInt64=0,musicalAnchor:UInt64=0,generation:UInt64=0,introRemainingHost:UInt64?=nil,finished=0,published=0
 func checkOutput()throws{}
 func publish(){published+=1}
 func snapshot(_ kind:String)->[String:Any]{["kind":kind,"clock":["anchor":String(anchor),"position":position]]}
 func finish(reason:String,error:Error?=nil){guard state != .stopped else{return};precondition(error==nil);state = .stopped;finished+=1;stopVoices();engine.stop()}
 ${methods}
}
let ahead=Probe();ahead.midi=FakeMidi()
let futureRender=try futureHost(0.1,from:reviewHost)
ahead.voices[0].player.lastRenderTime=AVAudioTime(hostTime:futureRender)
try ahead.schedule(from:0,playing:true)
precondition(ahead.anchor>futureRender && ahead.midi!.runs==[AudioConvertHostTimeToNanos(ahead.anchor)],"one common anchor must follow the active render frontier")
let missing=Probe();missing.voices[0].player.lastRenderTime=nil
do {try missing.schedule(from:0,playing:true);preconditionFailure("missing active render clock admitted")}catch{}
precondition(missing.voices[0].player.plays==0)
let audioFirst=Probe();audioFirst.midi=FakeMidi();try audioFirst.schedule(from:0,playing:true)
audioFirst.voices[0].completion!()
precondition(audioFirst.active.isEmpty && audioFirst.state == .playing && audioFirst.finished==0)
audioFirst.midiReachedEnd();precondition(audioFirst.finished==1 && audioFirst.state == .stopped)
audioFirst.midiReachedEnd();audioFirst.voices[0].completion!();precondition(audioFirst.finished==1)
let midiFirst=Probe();midiFirst.midi=FakeMidi();try midiFirst.schedule(from:0,playing:true)
midiFirst.midiReachedEnd();precondition(midiFirst.state == .playing && midiFirst.finished==0)
midiFirst.voices[0].completion!();precondition(midiFirst.finished==1)
let wavOnly=Probe();try wavOnly.schedule(from:0,playing:true)
wavOnly.voices[0].completion!();precondition(wavOnly.finished==1)
let paired=Probe();paired.midi=FakeMidi();try paired.schedule(from:0,playing:true)
let stale=paired.voices[0].completion!
precondition(paired.midi!.stages==[0] && paired.midi!.runs==[AudioConvertHostTimeToNanos(paired.anchor)])
paired.engine.outputNode.lastRenderTime=AVAudioTime(hostTime:try futureHost(0.25,from:paired.anchor))
paired.receive(#"{"kind":"pause"}"#)
precondition(paired.state == .paused && abs(paired.position-0.25)<1e-6 && paired.midi!.stages.last==paired.position)
stale();precondition(paired.finished==0)
paired.receive(#"{"kind":"seek","seconds":0.4}"#)
precondition(paired.position==0.4 && paired.midi!.stages.last==0.4 && paired.midi!.runs.count==1)
paired.receive(#"{"kind":"resume"}"#)
precondition(paired.state == .playing && paired.midi!.runs.count==2)
let request="9f6465e2-4acd-4df1-90cd-32c94e10db48"
paired.receive(#"{"kind":"recordingEpoch","request":"9f6465e2-4acd-4df1-90cd-32c94e10db48"}"#)
precondition(epochReplies.count==1 && epochReplies[0]["recordingRequest"] as? String==request)
let acknowledged=epochReplies[0]["clock"] as! [String:Any]
precondition(acknowledged["anchor"] as? String==String(paired.anchor) && acknowledged["position"] as? Double==0.4)
stale();precondition(paired.finished==0 && paired.active==["region-1"])
let waiting=Probe();waiting.midi=FakeMidi();waiting.voices[0].end=0.2;waiting.engine.outputNode.lastRenderTime=nil;waiting.voices[0].player.lastRenderTime=nil;try waiting.schedule(from:0.8,playing:true)
precondition(waiting.state == .playing && waiting.active.isEmpty && waiting.finished==0 && waiting.midi!.stages==[0.8])
waiting.midiReachedEnd();precondition(waiting.finished==1)
let silent=Probe();silent.plan.clocked=true;silent.voices[0].end=0;silent.engine.outputNode.lastRenderTime=nil;silent.voices[0].player.lastRenderTime=nil
try silent.schedule(from:0,playing:true);precondition(silent.state == .playing && silent.active.isEmpty && silent.finished==0)
silent.horizon!.fire();precondition(silent.finished==1)
let silentLoop=Probe();silentLoop.plan.clocked=true;silentLoop.plan.loop=FakeLoop();silentLoop.voices=[]
try silentLoop.schedule(from:0,playing:true)
precondition(silentLoop.state == .playing && silentLoop.horizon==nil && !silentLoop.completed)
silentLoop.engine.outputNode.lastRenderTime=AVAudioTime(hostTime:try futureHost(3.25,from:silentLoop.anchor))
precondition(abs(silentLoop.currentTime()-0.25)<1e-6)
silentLoop.midiReachedEnd();precondition(silentLoop.finished==0)
silentLoop.receive(#"{"kind":"pause"}"#);precondition(silentLoop.state == .paused)
silentLoop.receive(#"{"kind":"seek","seconds":1}"#);precondition(silentLoop.position==0)
silentLoop.receive(#"{"kind":"resume"}"#);precondition(silentLoop.state == .playing && silentLoop.horizon==nil)
silentLoop.receive(#"{"kind":"stop"}"#);precondition(silentLoop.finished==1)
let every=Probe();every.plan.clocked=true;every.midi=FakeMidi();try every.schedule(from:0,playing:true)
every.midiReachedEnd();every.voices[0].completion!();precondition(every.finished==0)
every.horizon!.fire();precondition(every.finished==1)
let horizonFirst=Probe();horizonFirst.plan.clocked=true;horizonFirst.midi=FakeMidi();try horizonFirst.schedule(from:0,playing:true)
horizonFirst.horizon!.fire();horizonFirst.voices[0].completion!();precondition(horizonFirst.finished==0)
horizonFirst.midiReachedEnd();precondition(horizonFirst.finished==1)
let staleTimer=Probe();staleTimer.plan.clocked=true;try staleTimer.schedule(from:0,playing:true)
let cancelled=staleTimer.horizon!;staleTimer.receive(#"{"kind":"pause"}"#);precondition(cancelled.cancelled)
cancelled.fire();precondition(staleTimer.finished==0 && !staleTimer.horizonEnded)
staleTimer.receive(#"{"kind":"seek","seconds":0.25}"#);staleTimer.receive(#"{"kind":"resume"}"#)
cancelled.fire();precondition(staleTimer.finished==0 && !staleTimer.horizonEnded)
let stoppedTimer=staleTimer.horizon!;staleTimer.receive(#"{"kind":"stop"}"#);stoppedTimer.fire();precondition(staleTimer.finished==1)
let practice=Probe();practice.plan.practice=FakePractice(countInSeconds:0.6,duration:0.4);practice.plan.clocked=true
try practice.schedule(from:0,playing:true)
let downbeat = try futureHost(0.6,from:practice.anchor)
precondition(practice.musicalAnchor == downbeat)
let beforePause=practice.voices[0].completion!
practice.engine.outputNode.lastRenderTime=AVAudioTime(hostTime:try futureHost(0.2,from:practice.anchor))
practice.receive(#"{"kind":"pause"}"#);precondition(abs(practice.position-0.2)<1e-6)
practice.receive(#"{"kind":"resume"}"#)
precondition(abs(AVAudioTime.seconds(forHostTime:practice.musicalAnchor-practice.anchor)-0.4)<1e-6)
beforePause();precondition(practice.finished==0)
practice.receive(#"{"kind":"seek","seconds":0.1}"#)
precondition(abs(practice.position-0.7)<1e-6 && practice.musicalAnchor==practice.anchor)
practice.receive(#"{"kind":"stop"}"#);precondition(practice.finished==1)
let looping=Probe();looping.plan.loop=FakeLoop();looping.voices[0].region.startSeconds=0.8
try looping.schedule(from:0,playing:true)
precondition(looping.voices[0].player.whens==[looping.anchor])
looping.engine.outputNode.lastRenderTime=AVAudioTime(hostTime:try futureHost(3.25,from:looping.anchor))
precondition(abs(looping.currentTime()-0.25)<1e-6 && looping.engine.starts==1 && looping.voices[0].prepares==1)
looping.receive(#"{"kind":"pause"}"#);precondition(looping.state == .paused && abs(looping.position-0.25)<1e-6)
looping.receive(#"{"kind":"seek","seconds":1}"#);precondition(looping.position==0 && looping.finished==0)
looping.receive(#"{"kind":"resume"}"#);precondition(looping.state == .playing)
looping.receive(#"{"kind":"stop"}"#);precondition(looping.finished==1)
let practiceLoop=Probe();practiceLoop.plan.clocked=true;practiceLoop.plan.loop=FakeLoop();practiceLoop.midi=FakeMidi()
let loopClock=LoopPracticePlan(period:.init(numerator:"1000000000",denominator:"3"),countInBeats:"1",beatsPerBar:1,unit:4,metronome:true)
// A sub-second introduction followed by the independent one-second backing.
practiceLoop.plan.duration=4.0/3
practiceLoop.plan.practice=FakePractice(countInSeconds:1.0/3,duration:1,loop:loopClock)
let intro=FakeVoice();intro.region.pulseClock=true;intro.end=1.0/3
let click=FakeVoice();click.region.pulseClock=true;click.region.pulseLoopUnit=4
// The harness IDs are distinct just as admitted production regions are.
intro.region.id="intro";click.region.id="click"
practiceLoop.voices += [intro,click]
try practiceLoop.schedule(from:0,playing:true)
var tb=mach_timebase_info_data_t();mach_timebase_info(&tb)
let ticks=try loopClock.hostTicks(numer:tb.numer,denom:tb.denom)
precondition(practiceLoop.musicalAnchor==practiceLoop.anchor+ticks)
precondition(practiceLoop.midi!.runs==[AudioConvertHostTimeToNanos(practiceLoop.musicalAnchor)])
precondition(intro.player.whens==[practiceLoop.anchor] && click.player.whens==[practiceLoop.musicalAnchor] && practiceLoop.voices[0].player.whens==[practiceLoop.musicalAnchor])
let introRender=practiceLoop.anchor+ticks/3
practiceLoop.engine.outputNode.lastRenderTime=AVAudioTime(hostTime:introRender)
practiceLoop.receive(#"{"kind":"pause"}"#)
precondition(practiceLoop.introRemainingHost==ticks-ticks/3 && practiceLoop.midi!.stages.last==0)
practiceLoop.receive(#"{"kind":"resume"}"#)
precondition(practiceLoop.musicalAnchor-practiceLoop.anchor==ticks-ticks/3)
practiceLoop.engine.outputNode.lastRenderTime=AVAudioTime(hostTime:try futureHost(3.25,from:practiceLoop.musicalAnchor))
precondition(abs(practiceLoop.currentTime()-(1.0/3+0.25))<1e-6)
practiceLoop.receive(#"{"kind":"pause"}"#)
precondition(abs(practiceLoop.midi!.stages.last!-0.25)<1e-6)
practiceLoop.receive(#"{"kind":"seek","seconds":1}"#)
precondition(practiceLoop.position==1.0/3 && practiceLoop.introRemainingHost==0 && practiceLoop.midi!.stages.last==0)
practiceLoop.receive(#"{"kind":"resume"}"#)
precondition(practiceLoop.musicalAnchor==practiceLoop.anchor && !practiceLoop.active.contains("intro"))
practiceLoop.receive(#"{"kind":"seek","seconds":0.4}"#)
precondition(abs(practiceLoop.midi!.stages.last!-0.4)<1e-6 && practiceLoop.musicalAnchor==practiceLoop.anchor)
practiceLoop.receive(#"{"kind":"stop"}"#);precondition(practiceLoop.finished==1)
// A coarser native timebase requires a single outward projection, not ceil(ns)
// followed by truncation to ticks (1/3ns on a125/3 clock is one host tick).
let fine=LoopPracticePlan(period:.init(numerator:"1",denominator:"3"),countInBeats:"1",beatsPerBar:1,unit:4,metronome:true)
let outward=try fine.hostTicks(numer:125,denom:3);precondition(outward==1)
print("ARRANGEMENT_CLOCK_DECISIONS_PASS: clocked silent horizon, either-order audio/MIDI/horizon completion, cancelled timer isolation across pause/seek/resume/stop; either-part-first completion, WAV-only continuity, one stop, common anchor conversion, paired pause/seek/resume, stale callback isolation, MIDI tail without audio voices")
`
const dir=await mkdtemp(join(process.env.TMPDIR ?? '/tmp','masc-arrangement-clock-'))
try {
await writeFile(join(dir,'main.swift'),swift)
let result=spawnSync('xcrun',['swiftc',join(dir,'main.swift'),new URL('CaptureAudioClock.swift',import.meta.url).pathname,new URL('PulseAudioClock.swift',import.meta.url).pathname,'-module-cache-path',join(dir,'modules'),'-o',join(dir,'probe'),'-framework','AVFoundation'],{encoding:'utf8'})
assert.equal(result.status,0,result.stderr)
result=spawnSync(join(dir,'probe'),[],{encoding:'utf8'})
assert.equal(result.status,0,result.stderr)
console.log(result.stdout.trim())
} finally { await rm(dir,{recursive:true,force:true}) }
