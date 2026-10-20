import test from 'node:test'
import assert from 'node:assert/strict'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { promisify } from 'node:util'
import { execFile } from 'node:child_process'
import { midiSourceFromEvents, midiSourcePattern, exportMidiSource } from '../midi-source.mjs'
import { sourceMidiTimeline, sourceLoopWindow } from '../midi-source-playback.mjs'
import { projectVstMidi, renderVstPhrase } from '../sequencer-vst.mjs'
import { newEditor, editorCommand, editorAction } from '../sequencer-editor.mjs'

const execute = promisify(execFile)
const meta = (tick, type, data) => ({ tick, kind: 'meta', type, data })
const channel = (tick, bytes) => ({ tick, kind: 'channel', bytes })
const source = () => midiSourceFromEvents([meta(0, 0x51, [6,174,196]), channel(0,[0xb0,64,127]),
  channel(0,[0x90,60,100]), meta(480,0x51,[7,161,33]), channel(720,[0x80,60,47]),
  channel(800,[0xb0,64,0]), meta(960,0x2f,[])], { ppq:960, name:'Loop experiment' })
async function temporary(run) {
  const root = await mkdtemp(join(tmpdir(), 'masc-source-loop-'))
  try { return await run(root) } finally { await rm(root,{recursive:true,force:true}) }
}

test('actual Worker retains whole source history while preparing an exact loop and independent external bindings', () => temporary(async root => {
  const project = source(), before = Buffer.from(exportMidiSource(project)), options = { loop:true, sourceLoop:{start:360,end:840} }
  const worker = new Worker(new URL('../sequencer-worker.mjs',import.meta.url))
  const request = async (format,id) => {
    const pending = once(worker,'message'); worker.postMessage({id,path:join(root,String(id)),project,
      cancel:new SharedArrayBuffer(4),options:{...options,format,midiOutput:'42'}})
    const [reply]=await pending;assert.equal(reply.ok,true,reply.error);return reply.result
  }
  try {
    const midi = await request('midi',1), plan = JSON.parse(await readFile(midi.path))
    assert.equal(plan.schemaVersion,3); assert.equal(midi.format,'midi-arrangement')
    assert.deepEqual(plan.bindings,[{port:0,destination:'42'}])
    assert.deepEqual(plan.sources[0].timeline,sourceMidiTimeline(project,{midiOutput:'42'}))
    // Independent integer tempo integration: source cut crosses tick480.
    const begin=360n*437956n, finish=480n*437956n+360n*500001n
    const periodN=(finish-begin)*1000n, periodD=960n
    assert.equal(BigInt(plan.regions[0].periodNanoseconds.numerator)*periodD,
      periodN*BigInt(plan.regions[0].periodNanoseconds.denominator))
    assert.equal(plan.duration,Number((periodN+periodD-1n)/periodD)/1e9)
    const rendered = await request('vst-midi',2)
    assert.deepEqual(await readFile(rendered.path),before)
    assert.deepEqual(rendered.sourceWindow,plan.sourceWindow)
    assert.deepEqual(Buffer.from(exportMidiSource(project)),before)
  } finally { await worker.terminate() }
}))

test('source range is session-local, survives note/tempo undo, and resets for another independent pattern', () => {
  const project=source(), before=structuredClone(project)
  let editor=newEditor(project), history=editor.undo
  const result=editorCommand(editor,'loop .375 .875');editor=result.editor
  assert.equal(result.effect.kind,'source-loop');assert.equal(editor.project,project);assert.equal(editor.undo,history)
  assert.deepEqual(editor.sourceLoop,{start:360,end:840})
  editor=editorCommand(editor,'transpose 2').editor
  editor=editorCommand(editor,'tempo 100 0').editor
  editor=editorAction(editor,{kind:'undo'});editor=editorAction(editor,{kind:'undo'})
  assert.deepEqual(editor.project,before);assert.deepEqual(editor.sourceLoop,{start:360,end:840})
  for(const command of ['loop 0 0','loop 0 2','loop -1 1'])assert.throws(()=>editorCommand(editor,command))
  // Even selecting the same explicit pattern is a new audition context.
  editor=editorCommand(editor,'pattern 1').editor
  assert.deepEqual(editor.sourceLoop,{start:0,end:960});assert.deepEqual(editor.project,before)
})

test('SMPTE drop-frame loop clock and distinct ports remain original routing/time rather than phrase defaults', () => {
  const bytes=Buffer.from(exportMidiSource(source()));bytes.writeUInt16BE(0xe350,12)
  // Import through the real source parser to bind its original digest.
  return import('../midi-source.mjs').then(({importMidiSource})=>{
    const document=importMidiSource(bytes),performance=midiSourcePattern(document)
    const window=sourceLoopWindow(performance,{start:1,end:959})
    assert.deepEqual(window.clock,{start:'1001',end:String(959n*1001n),denominator:'2400000'})
    const multi=midiSourceFromEvents([meta(0,0x21,[7]),channel(0,[0x90,60,100]),channel(960,[0x80,60,40]),
      meta(960,0x21,[2]),channel(960,[0x91,64,90]),channel(1920,[0x81,64,20]),meta(1920,0x2f,[])],{ppq:960})
    const plan=sourceMidiTimeline(multi,{loop:true,portBindings:[{port:7,destination:'42'},{port:2,destination:'-3'}]})
    assert.deepEqual(plan.bindings,[{port:0,destination:'-3'},{port:1,destination:'42'}])
    assert.deepEqual(plan.sources[0].timeline.bindings,[{port:2,destination:'-3'},{port:7,destination:'42'}])
    assert.throws(()=>projectVstMidi(multi,{loop:true}),/separate instrument instances/)
  })
})

test('VST loops a selected PCM window of a retained full render and retains the original MIDI/preset evidence', () => temporary(async root => {
  const project=source(),prepared=projectVstMidi(project,{loop:true,sourceLoop:{start:360,end:840}})
  const midi=join(root,'source.mid'),output=join(root,'source.wav');await writeFile(midi,prepared.bytes)
  const selection={plugin_path:'/fixture.vst3',plugin_name:null,preset_path:null,name:'Chosen'}
  const job=renderVstPhrase({preparation:{promise:Promise.resolve({...prepared,path:midi}),cancel:new Int32Array(new SharedArrayBuffer(4))},
    selection,outputPath:output,stateDirectory:join(root,'state'),loop:true,run(request){
      assert.equal(request.tail_seconds,0)
      return {cancel(){},promise:writeFile(output,'synthetic full render').then(()=>({output_path:output,duration_ms:469,
        frames:20683,sample_rate:44100,midi_sha256:'a'.repeat(64),wav_sha256:'b'.repeat(64)}))}
    }})
  const result=await job.promise
  const ceil=(n,d)=>(n+d-1n)/d,begin=360n*437956n,finish=480n*437956n+360n*500001n,d=960000000n
  const offset=Number(ceil(begin*44100n,d)),end=Number(ceil(finish*44100n,d))
  assert.deepEqual(result.frameRange,{offsetFrames:offset,frameCount:end-offset})
  assert.equal(result.duration,(end-offset)/44100)
  assert.deepEqual(await readFile(result.vst.midi_path),Buffer.from(exportMidiSource(project)))
  assert.equal(await readFile(result.path,'utf8'),'synthetic full render')
}))

test('native audio decoder reads only the requested frames and refuses out-of-file/empty windows without opening a device', () => temporary(async root => {
  const production=await readFile(new URL('../native/MusicTransport.swift',import.meta.url),'utf8')
  const prefix=production.slice(0,production.indexOf('final class Transport {'))
  const wav=Buffer.alloc(44+8*2*4);wav.write('RIFF');wav.writeUInt32LE(wav.length-8,4);wav.write('WAVEfmt ',8)
  wav.writeUInt32LE(16,16);wav.writeUInt16LE(3,20);wav.writeUInt16LE(2,22);wav.writeUInt32LE(48000,24)
  wav.writeUInt32LE(48000*8,28);wav.writeUInt16LE(8,32);wav.writeUInt16LE(32,34);wav.write('data',36);wav.writeUInt32LE(64,40)
  for(let i=0;i<16;i++)wav.writeFloatLE(i/16,44+i*4)
  const path=join(root,'source.wav');await writeFile(path,wav)
  const main=prefix+`\nlet audio = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]), commonFormat: .pcmFormatFloat32, interleaved: false)
let buffer = try readAudioWindow(audio, offsetFrames: 2, frameCount: 3)
precondition(buffer.frameLength == 3)
precondition(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 3)) == [0.25,0.375,0.5])
precondition(Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: 3)) == [0.3125,0.4375,0.5625])
for (offset,count): (Int64,Int64) in [(0,0),(-1,1),(8,1),(7,2),(Int64.max,1)] {
 do { _ = try readAudioWindow(audio, offsetFrames: offset, frameCount: count); fatalError("invalid source window admitted") } catch {}
}
print("NATIVE_PCM_WINDOW_PASS")\n`
  await writeFile(join(root,'main.swift'),main)
  const binary=join(root,'read-window')
  await execute('xcrun',['swiftc',join(root,'main.swift'),'-o',binary,'-framework','AVFoundation','-framework','CoreAudio'])
  assert.equal((await execute(binary,[path])).stdout.trim(),'NATIVE_PCM_WINDOW_PASS')
}))
