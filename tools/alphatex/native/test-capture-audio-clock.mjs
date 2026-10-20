// Decode actual PCM with the production Voice. No display snapshots or hardware.
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { spawnSync } from 'node:child_process'
const directory = await mkdtemp(join(tmpdir(), 'masc-capture-audio-clock-'))
try {
  const wave = Buffer.alloc(44 + 4800 * 8)
  wave.write('RIFF'); wave.writeUInt32LE(wave.length - 8, 4); wave.write('WAVEfmt ', 8); wave.writeUInt32LE(16, 16)
  wave.writeUInt16LE(3, 20); wave.writeUInt16LE(2, 22); wave.writeUInt32LE(48000, 24); wave.writeUInt32LE(384000, 28)
  wave.writeUInt16LE(8, 32); wave.writeUInt16LE(32, 34); wave.write('data', 36); wave.writeUInt32LE(wave.length - 44, 40)
  for (let i = 0; i < 4800; i++) { wave.writeFloatLE(.25 + i / 32768, 44 + i * 8); wave.writeFloatLE(-.5, 48 + i * 8) }
  await writeFile(join(directory, 'audio.wav'), wave)
  const mono = Buffer.alloc(44 + 4800 * 4); wave.copy(mono, 0, 0, 44)
  mono.writeUInt32LE(mono.length - 8, 4); mono.writeUInt16LE(1, 22); mono.writeUInt32LE(192000, 28)
  mono.writeUInt16LE(4, 32); mono.writeUInt32LE(4800 * 4, 40)
  for (let i = 0; i < 4800; i++) mono.writeFloatLE(-.5, 44 + i * 4)
  await writeFile(join(directory, 'mono.wav'), mono)
  const swift = `import Foundation
import AVFoundation
@main enum Probe {
static func main() throws {
let clock = CaptureAudioClock(origin:"18446744073600000000",offset:"0",extent:"4800001",numer:125,denom:3,firstAudioHostTime:"18446744073602400000")
let layout = try clock.layout(rate:48000,offsetFrames:0,frameCount:4800,repetitions:3)
precondition(layout.totalFrames==28801 && layout.start(0)==4800 && layout.start(1)==14401 && layout.start(2)==24001)
let regionJSON = #"{"id":"clip","asset":"audio","startSeconds":0,"offsetFrames":0,"frameCount":4800,"repeat":3,"captureClock":{"origin":"18446744073600000000","offset":"0","extent":"4800001","numer":125,"denom":3,"firstAudioHostTime":"18446744073602400000"}}"#
let region = try JSONDecoder().decode(Region.self,from:Data(regionJSON.utf8))
let asset = Asset(id:"audio",path:CommandLine.arguments[1],sha256:"",sampleRate:48000,channels:2,frames:4800)
let raw=UmpPacket(kind:"midi",protocolID:2,hostTime:"18446744073600000000",source:"A",timestampOrigin:"packet",words:[0x43953c00,0x80000000])
let source=UmpRegionSource(id:"audio",extent:"4801001",timeline:UmpTimeline(schemaVersion:4,duration:1,clock:UmpClock(origin:"18446744073600000000",numer:125,denom:3),bindings:[UmpBinding(source:"A",destination:"42")],packets:[raw]))
func paired(_ offset:String)->Plan {
 let notes=UmpRegion(id:"clip",source:"audio",startSeconds:0,offset:offset,extent:"4800001",repeatCount:3)
 return Plan(schemaVersion:5,kind:"capture-arrangement",duration:1,assets:[asset],regions:[region],midi:nil,ump:nil,umpRegions:UmpArrangement(schemaVersion:1,duration:1,sources:[source],regions:[notes]))
}
try paired("0").validate()
do { try paired("1").validate();preconditionFailure("mismatched paired source cut accepted") } catch {}
var separateAudio = region; separateAudio.component = .audio
var separateMidi = UmpRegion(id:"notes",source:"audio",startSeconds:0.01,offset:"1",extent:"4800001",repeatCount:3)
separateMidi.component = .midi
let separated = Plan(schemaVersion:5,kind:"capture-arrangement",duration:1,assets:[asset],regions:[separateAudio],midi:nil,ump:nil,umpRegions:UmpArrangement(schemaVersion:1,duration:1,sources:[source],regions:[separateMidi]))
try separated.validate()
var wrongWave = separateAudio; wrongWave.component = .midi
do { try Plan(schemaVersion:5,kind:"capture-arrangement",duration:1,assets:[asset],regions:[wrongWave],midi:nil,ump:nil,umpRegions:separated.umpRegions).validate();preconditionFailure("MIDI component accepted as WAV") } catch {}
var wrongNotes = separateMidi; wrongNotes.component = .audio
do { _ = try UmpRegionTransport(timeline:UmpArrangement(schemaVersion:1,duration:1,sources:[source],regions:[wrongNotes]));preconditionFailure("audio component accepted as UMP") } catch {}
wrongNotes = separateMidi; wrongNotes = UmpRegion(id:"clip",source:"audio",startSeconds:0,offset:"0",extent:"4800001",repeatCount:3);wrongNotes.component = .midi
do { try Plan(schemaVersion:5,kind:"capture-arrangement",duration:1,assets:[asset],regions:[region],midi:nil,ump:nil,umpRegions:UmpArrangement(schemaVersion:1,duration:1,sources:[source],regions:[wrongNotes])).validate();preconditionFailure("paired WAV silently matched separated MIDI") } catch {}
let voice = try Voice(region:region,asset:asset,capacity:257,outputChannels:2)
let buffer = AVAudioPCMBuffer(pcmFormat:voice.file.processingFormat,frameCapacity:257)!
var verified = 0
while try voice.fill(buffer) {
  let first = voice.cursor - Int64(buffer.frameLength)
  for i in 0..<Int(buffer.frameLength) {
    let frame = first + Int64(i)
    // Independently enumerate the three original source intervals. Do not use
    // the production locator or its division formula as the oracle.
    let starts:[Int64] = [4800,14401,24001]
    let offset = starts.first(where: { frame >= $0 && frame < $0 + 4800 }).map { frame - $0 }
    precondition(buffer.floatChannelData![0][i] == offset.map { Float(0.25 + Double($0)/32768) } ?? 0)
    precondition(buffer.floatChannelData![1][i] == (offset == nil ? 0 : -0.5))
    verified += 1
  }
}
precondition(verified==28801)
// The same owner can refill from a seek inside a silent edge or the third copy.
for position:Int64 in [0,4799,4800,9600,14400,14401,24003,28800] {
  voice.cursor=position;let filled=try voice.fill(buffer);precondition(filled)
  let starts:[Int64] = [4800,14401,24001]
  let expected = starts.first(where:{position >= $0 && position < $0+4800}).map{Float(0.25+Double(position-$0)/32768)} ?? 0
  precondition(buffer.floatChannelData![0][0]==expected)
}
// Source cache/scratch stay in the recorded format, while routed output
// buffers use the real destination channel count and silence every other bus.
for (input,output,capacity,outputs) in [(1,2,257,2),(2,1,8192,2),(1,4,257,4)] {
 var routed=separateAudio;routed.audioChannel=CaptureAudioChannel(input:UInt32(input),output:UInt32(output))
 let selected=try Voice(region:routed,asset:asset,capacity:UInt32(capacity),outputChannels:UInt32(outputs))
 let target=AVAudioPCMBuffer(pcmFormat:selected.format,frameCapacity:UInt32(capacity))!
 precondition(selected.file.processingFormat.channelCount==2 && selected.format.channelCount==UInt32(outputs))
 var count=0
 while try selected.fill(target) {
  let first=selected.cursor-Int64(target.frameLength)
  for i in 0..<Int(target.frameLength) {
   let frame=first+Int64(i),starts:[Int64]=[4800,14401,24001]
   let local=starts.first(where:{frame >= $0 && frame < $0+4800}).map{frame-$0}
   let expected:Float=local.map{input==1 ? Float(0.25+Double($0)/32768): -0.5} ?? 0
   for channel in 0..<outputs {precondition(target.floatChannelData![channel][i]==(channel==output-1 ? expected:0),"selected source channel leaked or changed")}
   count+=1
  }
 }
 precondition(count==28801)
}
var invalid=separateAudio;invalid.audioChannel=CaptureAudioChannel(input:3,output:1)
do {try Plan(schemaVersion:4,kind:"capture-audio-arrangement",duration:1,assets:[asset],regions:[invalid],midi:nil,ump:nil,umpRegions:nil).validate();preconditionFailure("missing input channel admitted")}catch{}
invalid=region;invalid.audioChannel=CaptureAudioChannel(input:1,output:1)
do {try Plan(schemaVersion:4,kind:"capture-audio-arrangement",duration:1,assets:[asset],regions:[invalid],midi:nil,ump:nil,umpRegions:nil).validate();preconditionFailure("paired source channel routing admitted")}catch{}
invalid=separateAudio;invalid.audioChannel=CaptureAudioChannel(input:1,output:3)
do {_ = try Voice(region:invalid,asset:asset,capacity:257,outputChannels:2);preconditionFailure("missing physical output channel admitted")}catch{}
let monoAsset=Asset(id:"audio",path:CommandLine.arguments[2],sha256:"",sampleRate:48000,channels:1,frames:4800)
let calibration=CalibrationOutput(id:"measured-output",sampleRate:48000,bufferFrames:256)
try calibration.validate(deviceUID:"measured-output",rate:48000,frames:256)
for (uid,rate,frames):(String,Double,UInt32) in [("other",48000,256),("measured-output",44100,256),("measured-output",48000,512)] {
 do {try calibration.validate(deviceUID:uid,rate:rate,frames:frames);preconditionFailure("stale measured output configuration admitted")}catch{}
}
var calibrated=separateAudio;calibrated.audioChannel=CaptureAudioChannel(input:1,output:2);calibrated.calibrationOutput=calibration
try Plan(schemaVersion:4,kind:"capture-audio-arrangement",duration:1,assets:[asset],regions:[calibrated],midi:nil,ump:nil,umpRegions:nil).validate()
calibrated.audioChannel=nil
do {try Plan(schemaVersion:4,kind:"capture-audio-arrangement",duration:1,assets:[asset],regions:[calibrated],midi:nil,ump:nil,umpRegions:nil).validate();preconditionFailure("unrouted calibration admitted")}catch{}
for capacity:UInt32 in [257,8192] {
 var routed=separateAudio;routed.audioChannel=CaptureAudioChannel(input:1,output:2)
 let mono=try Voice(region:routed,asset:monoAsset,capacity:capacity,outputChannels:2,outputLayout:AVAudioChannelLayout(layoutTag:kAudioChannelLayoutTag_Stereo))
 let target=AVAudioPCMBuffer(pcmFormat:mono.format,frameCapacity:capacity)!
 precondition(mono.file.processingFormat.channelCount==1 && mono.format.channelCount==2)
 while try mono.fill(target) {
  let first=mono.cursor-Int64(target.frameLength)
  for i in 0..<Int(target.frameLength) {
   let frame=first+Int64(i),starts:[Int64]=[4800,14401,24001]
   let present=starts.contains{frame >= $0 && frame < $0+4800}
   precondition(target.floatChannelData![0][i]==0 && target.floatChannelData![1][i]==(present ? -0.5:0),"mono input duplicated or routed to the wrong output")
  }
 }
}
let grain=CaptureAudioClock(origin:"0",offset:"0",extent:"751",numer:125,denom:3,firstAudioHostTime:"1")
let large=try grain.layout(rate:48000,offsetFrames:0,frameCount:1,repetitions:2_000_000)
precondition(large.totalFrames==3_004_000 && large.start(1_999_999)==3_003_999)
precondition(large.span(at:3_003_999,maximum:100).source==0)
let legacyJSON = #"{"id":"wave","asset":"audio","startSeconds":0,"offsetFrames":2,"frameCount":3,"repeat":2}"#
let legacy=try Voice(region:JSONDecoder().decode(Region.self,from:Data(legacyJSON.utf8)),asset:asset,capacity:257,outputChannels:2)
let filled=try legacy.fill(buffer);precondition(filled);precondition(buffer.frameLength==6)
for i in 0..<6 { precondition(buffer.floatChannelData![0][i]==Float(0.25+Double(2+i%3)/32768)) }
func refuses(_ clock:CaptureAudioClock,_ offset:Int64=0,_ count:Int64=1,_ repeatCount:Int64=1) {
  do { _ = try clock.layout(rate:48000,offsetFrames:offset,frameCount:count,repetitions:repeatCount);preconditionFailure("invalid clock accepted") } catch {}
}
refuses(CaptureAudioClock(origin:"00",offset:"0",extent:"500",numer:125,denom:3,firstAudioHostTime:"0"))
refuses(CaptureAudioClock(origin:"0",offset:"1",extent:"500",numer:125,denom:3,firstAudioHostTime:"0"))
refuses(CaptureAudioClock(origin:"0",offset:"0",extent:"499",numer:125,denom:3,firstAudioHostTime:"0"))
refuses(CaptureAudioClock(origin:"0",offset:"0",extent:"340282366920938463463374607431768211455",numer:125,denom:3,firstAudioHostTime:"0"))
refuses(clock,0,4800,Int64.max)
let endpoint=try CaptureAudioClock(origin:String(UInt64.max),offset:"0",extent:"1",numer:1,denom:1,firstAudioHostTime:String(UInt64.max)).layout(rate:1_000_000_000,offsetFrames:0,frameCount:1,repetitions:1)
precondition(endpoint.totalFrames==1)
// A region may end inside its own final source frame. A 48 kHz WAV in the same
// plan neither narrows the 44.1 kHz take's bound nor widens its own.
// The plans are decoded like production input, so later Plan fields keep
// their decoded defaults instead of changing this fixture.
func mixedRates(_ duration:Double,loopStart:Double) throws -> Plan {
  let plan:[String:Any]=["schemaVersion":4,"kind":"capture-audio-arrangement","duration":duration,
    "assets":[["id":"take","path":"/take.wav","sha256":"","sampleRate":44100,"channels":1,"frames":132317],
              ["id":"loop","path":"/loop.wav","sha256":"","sampleRate":48000,"channels":1,"frames":48000]],
    "regions":[["id":"take","asset":"take","startSeconds":0,"offsetFrames":0,"frameCount":132317,"repeat":1,
                "captureClock":["origin":"1000000","offset":"0","extent":"72009252","numer":125,"denom":3,"firstAudioHostTime":"1000000"]],
               ["id":"loop","asset":"loop","startSeconds":loopStart,"offsetFrames":0,"frameCount":48000,"repeat":1]]]
  return try JSONDecoder().decode(Plan.self,from:JSONSerialization.data(withJSONObject:plan))
}
// 72009252 ticks are 3.0003855 s, 132317.00055 frames at 44.1 kHz: the take's
// final frame ends .99945 of its frame later, more than one 48 kHz frame.
try mixedRates(3.0003855,loopStart:0).validate()
// 1.02 take frames past the end; 1.056 loop frames (.97 take frames) past the end.
for (duration,loopStart) in [(3.000385,0.0),(3.999978,3.0)] {
  let plan=try mixedRates(duration,loopStart:loopStart)
  do { try plan.validate();preconditionFailure("audio past its own final frame accepted") } catch {}
}
print("CAPTURE_AUDIO_CLOCK_PASS: 28801 stereo PCM frames, delayed starts, rational cycle gaps, 8 far/edge refill positions, 2M compressed repeats, WAV continuity, overflow and UInt64+1 endpoint, per-source final-frame duration bound at 44.1/48 kHz")
}
}
`
  await writeFile(join(directory, 'Probe.swift'), swift)
  const files = ['WaveArrangement.swift','WaveLoopClock.swift','CaptureAudioClock.swift','PulseAudioClock.swift','PulseLoopClock.swift','MidiTransport.swift','UmpTransport.swift','UmpOutput.swift','UmpRegions.swift','HybridMidiTransport.swift','UmpLoopTransport.swift','UmpState.swift'].map(file=>new URL(file,import.meta.url).pathname)
  let result = spawnSync('xcrun', ['swiftc','-parse-as-library','-D','MIDI_LIBRARY','-D','ARRANGEMENT_LIBRARY',...files,join(directory,'Probe.swift'),'-o',join(directory,'probe'),'-framework','AVFoundation','-framework','CoreAudio','-framework','CoreMIDI'], { encoding:'utf8' })
  assert.equal(result.status,0,result.stderr)
  result=spawnSync(join(directory,'probe'),[join(directory,'audio.wav'),join(directory,'mono.wav')],{encoding:'utf8'})
  assert.equal(result.status,0,result.stderr)
  console.log(result.stdout.trim())
} finally { await rm(directory,{recursive:true,force:true}) }
