// Exercise production rational pulse streaming after far seeks and through
// source-sample rounding; no terminal text or layout expectations.
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'
const directory = await mkdtemp(join(tmpdir(), 'masc-practice-clock-'))
try {
  const main = join(directory, 'main.swift'), binary = join(directory, 'probe')
  await writeFile(main, `import Foundation
let pulse = PulseAudioClock(period:.init(numerator:"60000000000",denominator:"137"),beatsPerBar:7,duration:1_000_000)
let layout = try pulse.layout(rate:48000,frameCount:576)
for copy in [Int64(0),1,6,7,1_000_000,2_000_000] {
 let at=layout.clock.start(copy)
 let exact=UInt128(copy)*60_000_000_000*48000
 let divisor:UInt128=137*1_000_000_000
 precondition(UInt128(at)==exact/divisor+(exact%divisor==0 ? 0:1))
 let value=layout.span(at:at,maximum:100)
 precondition(value.source==0 && value.count==100 && value.gain==(copy%7==0 ? 1:0.5))
 if copy>0 {precondition(layout.span(at:at-1,maximum:100).source==nil)}
}
var frame:Int64=0, sounded:[Int64]=[], gains:[Float]=[]
while frame<100_000 {
 let span=layout.span(at:frame,maximum:113)
 precondition(span.count>0 && span.count<=113)
 if span.source==0 {sounded.append(frame);gains.append(span.gain)}
 frame+=span.count
}
precondition(sounded.prefix(4)==[0,21022,42044,63066] && gains.prefix(4)==[1,0.5,0.5,0.5])
let fast=try PulseAudioClock(period:.init(numerator:"1000000",denominator:"1"),beatsPerBar:4,duration:0.01).layout(rate:48000,frameCount:576)
precondition(fast.clock.frameCount==48 && fast.span(at:48,maximum:100).source==0)
let last=layout.span(at:layout.totalFrames-1,maximum:100)
precondition(last.count==1)
// Count-in has an exact authored number of beats, even when a nearby Double
// horizon would round above the last source sample. It never adds another tick.
let counted=try PulseAudioClock(period:.init(numerator:"1000000000",denominator:"3"),beatsPerBar:3,duration:1.0000000000000002,beatCount:"3").layout(rate:48000,frameCount:576)
precondition(counted.totalFrames==48000 && counted.clock.repetitions==3)
let finalCount=counted.span(at:47999,maximum:113)
precondition(finalCount.source==nil && finalCount.count==1)
for fraction in [("0","1"),("01","1"),("2","2"),("1","1000000000"),(String(UInt128.max),"1")] {
 do {_ = try PulseAudioClock(period:.init(numerator:fraction.0,denominator:fraction.1),beatsPerBar:4,duration:1).layout(rate:48000,frameCount:576);preconditionFailure("invalid or unrepresentable pulse admitted")}catch{}
}
print("PRACTICE_CLOCK_PASS absolute rational beats, bar accents, partial buffers, far seek, final sample, sample-resolution and overflow rejection")
`)
  const sources = ['CaptureAudioClock.swift', 'PulseAudioClock.swift'].map(file => new URL(file, import.meta.url).pathname)
  let result = spawnSync('xcrun', ['swiftc', main, ...sources, '-module-cache-path', join(directory, 'modules'), '-o', binary], { encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  result = spawnSync(binary, [], { encoding: 'utf8' }); assert.equal(result.status, 0, result.stderr)
  console.log(result.stdout.trim())
} finally { await rm(directory, { recursive: true, force: true }) }
