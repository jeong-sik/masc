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
let voice = try Voice(region:region,asset:asset,capacity:257)
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
let grain=CaptureAudioClock(origin:"0",offset:"0",extent:"751",numer:125,denom:3,firstAudioHostTime:"1")
let large=try grain.layout(rate:48000,offsetFrames:0,frameCount:1,repetitions:2_000_000)
precondition(large.totalFrames==3_004_000 && large.start(1_999_999)==3_003_999)
precondition(large.span(at:3_003_999,maximum:100).source==0)
let legacyJSON = #"{"id":"wave","asset":"audio","startSeconds":0,"offsetFrames":2,"frameCount":3,"repeat":2}"#
let legacy=try Voice(region:JSONDecoder().decode(Region.self,from:Data(legacyJSON.utf8)),asset:asset,capacity:257)
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
  const files = ['WaveArrangement.swift','CaptureAudioClock.swift','MidiTransport.swift','UmpTransport.swift','UmpOutput.swift','UmpRegions.swift','UmpState.swift'].map(file=>new URL(file,import.meta.url).pathname)
  let result = spawnSync('xcrun', ['swiftc','-parse-as-library','-D','MIDI_LIBRARY','-D','ARRANGEMENT_LIBRARY',...files,join(directory,'Probe.swift'),'-o',join(directory,'probe'),'-framework','AVFoundation','-framework','CoreAudio','-framework','CoreMIDI'], { encoding:'utf8' })
  assert.equal(result.status,0,result.stderr)
  result=spawnSync(join(directory,'probe'),[join(directory,'audio.wav')],{encoding:'utf8'})
  assert.equal(result.status,0,result.stderr)
  console.log(result.stdout.trim())
} finally { await rm(directory,{recursive:true,force:true}) }
