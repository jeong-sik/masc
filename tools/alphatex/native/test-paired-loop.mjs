// Validate the real paired plan and retained owner admission without opening
// audio/MIDI devices. Exact source/placement authority survives the short loop.
import assert from 'node:assert/strict'
import {mkdtemp,writeFile,rm} from 'node:fs/promises'
import {join} from 'node:path'
import {tmpdir} from 'node:os'
import {spawnSync} from 'node:child_process'
const root=await mkdtemp(join(tmpdir(),'masc-paired-loop-plan-'))
try {
 const swift=`import Foundation
func refuses(_ f:()throws->Void){do{try f();preconditionFailure("invalid paired plan admitted")}catch{}}
@main enum Probe {static func main()throws {
 let packets:[[String:Any]]=[
  ["kind":"midi","protocol":2,"hostTime":"200000000","source":"A","timestampOrigin":"packet","words":[UInt32(0x43953c00),UInt32(0x90010000)]],
  ["kind":"midi","protocol":2,"hostTime":"300000000","source":"A","timestampOrigin":"packet","words":[UInt32(0x43853c00),UInt32(0x12340000)]],
  ["kind":"midi","protocol":2,"hostTime":"900000000","source":"A","timestampOrigin":"packet","words":[UInt32(0x30010000),UInt32(0)]]]
 let clock:[String:Any]=["origin":"0","offset":"0","extent":"1000000000","numer":1,"denom":1,"firstAudioHostTime":"0"]
 let ump:[String:Any]=["schemaVersion":1,"duration":1,"sources":[["id":"take","extent":"1000000000","timeline":["schemaVersion":4,"duration":1,"clock":["origin":"0","numer":1,"denom":1],"bindings":[["source":"A","destination":"42"]],"packets":packets]]],"regions":[["id":"clip","source":"take","startSeconds":0,"offset":"0","extent":"1000000000","repeatCount":1,"startNanoseconds":["numerator":"0","denominator":"1"]]]]
 var json:[String:Any]=["schemaVersion":5,"kind":"capture-arrangement","duration":0.5,"loop":["start":480,"end":1440,"ppq":960,"tempo":120],"assets":[["id":"take","path":"unused.wav","sha256":"unused","sampleRate":48000,"channels":1,"frames":48000]],"regions":[["id":"clip","asset":"take","startSeconds":0,"offsetFrames":0,"frameCount":48000,"repeat":1,"captureClock":clock,"startNanoseconds":["numerator":"0","denominator":"1"]]],"umpRegions":ump]
 func decode(_ data:[String:Any])throws->Plan {try JSONDecoder().decode(Plan.self,from:JSONSerialization.data(withJSONObject:data))}
 let plan=try decode(json);try plan.validate()
 let owner=try UmpLoopTransport(timeline:plan.umpRegions!,cycle:plan.loop!.midiCycle())
 precondition(owner.plan.bindings.count==1 && owner.plan.clips[0].events.count==3)
 refuses{_ = try UmpRegionTransport(timeline:plan.umpRegions!)} // unreachable opaque suffix stays excluded only in the selected cycle
 for field in ["source","offset","extent","repeatCount"] {
  var bad=json,notes=ump,regions=ump["regions"] as! [[String:Any]]
  regions[0][field] = field=="repeatCount" ? 2 : field=="source" ? "missing" : "1"
  notes["regions"]=regions;bad["umpRegions"]=notes
  refuses{try decode(bad).validate()}
 }
 // Two fractions can display as the same binary64 placement. Pairing still
 // requires their exact original nanosecond positions to agree.
 var shifted=ump,notes=ump["regions"] as! [[String:Any]],audio=json["regions"] as! [[String:Any]]
 notes[0]["startSeconds"]=0.25;audio[0]["startSeconds"]=0.25
 notes[0]["startNanoseconds"]=["numerator":"250000000000000001","denominator":"1000000000"]
 audio[0]["startNanoseconds"]=["numerator":"250000000","denominator":"1"]
 shifted["regions"]=notes;json["regions"]=audio;json["umpRegions"]=shifted
 refuses{try decode(json).validate()}
 notes[0]["startNanoseconds"]=["numerator":"250000000","denominator":"1"]
 shifted["regions"]=notes;json["umpRegions"]=shifted;try decode(json).validate()
 print("PAIRED_LOOP_PLAN_PASS original source/clock/cut/repeat/packet preservation, exact shared placement, retained window admission and unreachable suffix exclusion; no devices")
}}
`
 await writeFile(join(root,'Probe.swift'),swift)
 const names=['WaveArrangement','WaveLoopClock','CaptureAudioClock','PulseAudioClock','MidiTransport','UmpTransport','UmpOutput','UmpRegions','UmpLoopTransport','HybridMidiTransport','UmpState']
 let r=spawnSync('xcrun',['swiftc','-parse-as-library','-D','MIDI_LIBRARY','-D','ARRANGEMENT_LIBRARY',...names.map(n=>new URL(n+'.swift',import.meta.url).pathname),join(root,'Probe.swift'),'-o',join(root,'probe'),'-framework','AVFoundation','-framework','CoreAudio','-framework','CoreMIDI'],{encoding:'utf8'})
 assert.equal(r.status,0,r.stderr)
 r=spawnSync(join(root,'probe'),[],{encoding:'utf8'});assert.equal(r.status,0,r.stdout+r.stderr);process.stdout.write(r.stdout)
}finally{await rm(root,{recursive:true,force:true})}
