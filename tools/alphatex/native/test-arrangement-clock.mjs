// Production lifecycle decisions with synthetic audio/MIDI effects. No device is opened.
import assert from 'node:assert/strict'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'
const source=await readFile(new URL('./WaveArrangement.swift',import.meta.url),'utf8')
const part=(first,last)=>{const a=source.indexOf(first),b=source.indexOf(last,a);assert.ok(a>=0&&b>a);return source.slice(a,b)}
const methods=[part('    func midiReachedEnd()', '    func checkOutput()'),part('    func currentTime()', '    func snapshot('),part('    func stopVoices()', '    func monitor('),part('    func receive(', '    func finish(')].join('\n').replaceAll('mach_absolute_time()', 'reviewHost')
const command=part('enum AudioCommand: Decodable', 'final class ArrangementTransport')
const future=part('func futureHost(', 'struct Asset:')
const swift=`import Foundation
import AVFoundation
import CoreAudio
var reviewHost: UInt64 = 1_000_000_000
struct AudioFailure: Error { let description: String; init(_ value:String){description=value} }
${future}
${command}
struct FakePlan { let duration=1.0;let captured=false;var capturedAudio=false }
struct FakeRegion { let id="region-1", startSeconds=0.0 }
final class FakePlayer { var plays=0;func play(at:AVAudioTime){plays+=1} }
final class FakeVoice {
 let region=FakeRegion(), player=FakePlayer();var end=1.0, prepares=0, stops=0;var completion:(()->Void)?
 func prepare(from seconds:Double,finished:@escaping()->Void,failed:@escaping(Error)->Void)throws->Bool{prepares+=1;completion=finished;return seconds<end}
 func stop(){stops+=1}
}
struct FakeFormat {let sampleRate=48000.0}
final class FakeOutput {var lastRenderTime:AVAudioTime?;let presentationLatency=0.0;func outputFormat(forBus:Int)->FakeFormat{FakeFormat()}}
final class FakeEngine {let outputNode=FakeOutput();var starts=0,stops=0,pauses=0;func prepare(){};func start()throws{starts+=1};func pause(){pauses+=1};func stop(){stops+=1}}
final class FakeMidi { var stages:[Double]=[], runs:[UInt64]=[];func stageCoordinated(at seconds:Double)throws{stages.append(seconds)};func runCoordinated(anchorNanoseconds:UInt64)throws{runs.append(anchorNanoseconds)} }\nfinal class Probe {
 enum State {case prepared,playing,paused,stopped}
 var plan=FakePlan();let engine=FakeEngine(),renderQuantum=1024
 var horizon:DispatchSourceTimer?;var horizonEnded=false
 var midi:FakeMidi?;var midiEnded=false\n var state=State.prepared,voices=[FakeVoice()],active=Set<String>(),position=0.0,anchor:UInt64=0,generation:UInt64=0,finished=0,published=0
 func checkOutput()throws{}
 func publish(){published+=1}
 func finish(reason:String,error:Error?=nil){guard state != .stopped else{return};precondition(error==nil);state = .stopped;finished+=1;stopVoices();engine.stop()}
 ${methods}
}
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
stale();precondition(paired.finished==0 && paired.active==["region-1"])
let waiting=Probe();waiting.midi=FakeMidi();waiting.voices[0].end=0.2;try waiting.schedule(from:0.8,playing:true)
precondition(waiting.state == .playing && waiting.active.isEmpty && waiting.finished==0 && waiting.midi!.stages==[0.8])
waiting.midiReachedEnd();precondition(waiting.finished==1)
print("ARRANGEMENT_CLOCK_DECISIONS_PASS: either-part-first completion, WAV-only continuity, one stop, common anchor conversion, paired pause/seek/resume, stale callback isolation, MIDI tail without audio voices")
`
const dir=await mkdtemp(join(process.env.TMPDIR ?? '/tmp','masc-arrangement-clock-'))
try {
await writeFile(join(dir,'Probe.swift'),swift)
let result=spawnSync('xcrun',['swiftc',join(dir,'Probe.swift'),'-module-cache-path',join(dir,'modules'),'-o',join(dir,'probe'),'-framework','AVFoundation'],{encoding:'utf8'})
assert.equal(result.status,0,result.stderr)
result=spawnSync(join(dir,'probe'),[],{encoding:'utf8'})
assert.equal(result.status,0,result.stderr)
console.log(result.stdout.trim())
} finally { await rm(dir,{recursive:true,force:true}) }
