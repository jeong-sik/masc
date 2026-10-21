import test from 'node:test'
import assert from 'node:assert/strict'
import { importMidiSource, midiSourcePattern, exportMidiSource } from '../midi-source.mjs'
import { sourceAudioClock, sourceAudioFrames } from '../source-audio-clock.mjs'
const chunk=(name,data)=>{const h=Buffer.alloc(8);h.write(name);h.writeUInt32BE(data.length,4);return Buffer.concat([h,Buffer.from(data)])}
const tempo=value=>[0xff,0x51,3,value>>16,value>>8&255,value&255]
function source(tracks,{format=1,division=960}={}) {
 const h=Buffer.alloc(6);h.writeUInt16BE(format);h.writeUInt16BE(tracks.length,2);h.writeUInt16BE(division,4)
 return importMidiSource(Buffer.concat([chunk('MThd',h),...tracks.map(t=>chunk('MTrk',t))]))
}
test('original tempo map selects exact cut timestamps across tempo edits without PCM period rounding',()=>{
 const document=source([[0,...tempo(437956),0x83,0x60,...tempo(500001),0x83,0x60,0xff,0x2f,0],
  [0,0x90,60,100,0x87,0x40,0x80,60,0,0,0xff,0x2f,0]])
 const before=Buffer.from(exportMidiSource(document)),performance=midiSourcePattern(document)
 assert.deepEqual(sourceAudioClock(performance,360,480),{start:String(360n*437956n),end:String(480n*437956n+360n*500001n),denominator:'960000000'})
 const quarter=sourceAudioClock(performance,0,480)
 assert.deepEqual(sourceAudioFrames(quarter,44100),{offsetFrames:0,frameCount:9657})
 assert.notEqual((BigInt(quarter.end)-BigInt(quarter.start))*44100n,9657n*BigInt(quarter.denominator))
 assert.deepEqual(Buffer.from(exportMidiSource(document)),before)
})
test('independent SMF2 and SMPTE drop-frame source clocks retain selected original timing',()=>{
 const track=value=>[0,...tempo(value),0,0x90,60,100,0x87,0x40,0x80,60,0,0,0xff,0x2f,0]
 const document=source([track(437956),track(500001)],{format:2}),before=structuredClone(document)
 assert.throws(()=>midiSourcePattern(document),/pattern/)
 for(const [pattern,micros]of [[0,437956n],[1,500001n]]) {
  const clock=sourceAudioClock(midiSourcePattern(document,{pattern}),1,959)
  assert.deepEqual(clock,{start:String(micros),end:String(micros*960n),denominator:'960000000'})
 }
 const smpte=source([track(1)],{format:0,division:(256-29)*256+80})
 assert.deepEqual(sourceAudioClock(midiSourcePattern(smpte),1,959),{start:'1001',end:String(960n*1001n),denominator:'2400000'})
 assert.deepEqual(document,before)
})
test('subframe cuts retain silent clock horizons without manufacturing a source sample',()=>{
 assert.deepEqual(sourceAudioFrames({start:'1',end:'2',denominator:'1000000000'},44100),{offsetFrames:1,frameCount:0})
 assert.deepEqual(sourceAudioFrames({start:'0',end:'1',denominator:'1000000000'},44100),{offsetFrames:0,frameCount:1})
})
