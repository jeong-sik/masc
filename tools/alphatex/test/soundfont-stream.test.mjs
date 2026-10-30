import test, { before } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readdir, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawn } from 'node:child_process'
import { captureFluidSound } from '../soundfont.mjs'
import { openFluidStream } from '../soundfont-stream.mjs'

let sound
before(async () => { sound = await captureFluidSound().promise })
async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), 'fluid-stream-test-')), children = []
  return { directory, children, open(selected = sound, options = {}) {
    return openFluidStream(selected, { directory, sampleRate: 48000, ...options, spawnProcess(...args) {
      const child = spawn(...args); children.push(child); return child
    } })
  }, async clean() {
    assert.ok(children.every(child => child.exitCode !== null || child.signalCode !== null))
    for (const child of children) assert.throws(() => process.kill(child.pid, 0), { code: 'ESRCH' })
    assert.deepEqual(await readdir(directory), [])
    await rm(directory, { recursive: true })
  } }
}
async function render(frames, events, splits = [frames]) {
  const owned = await fixture(), owner = owned.open(), pcm = []
  try {
    const ready = await owner.ready
    assert.equal(ready.fontSha256, sound.font.sha256)
    assert.deepEqual(ready.engine, sound.engine)
    let cursor = 0
    for (const count of splits) {
      pcm.push(await owner.render(count, events.filter(e => e.frame >= cursor && e.frame < cursor + count)
        .map(e => ({ ...e, frame: e.frame - cursor }))))
      cursor += count
    }
    assert.equal(cursor, frames)
    owner.stop()
    assert.deepEqual(await owner.completion, { kind: 'stopped', frames: String(frames) })
    return Buffer.concat(pcm)
  } finally { owner.cancel(); await owner.completion.catch(() => {}); await owned.clean() }
}
const event = (frame, bytes) => ({ frame, bytes })

test('actual FluidSynth retains absolute quantum order across arbitrary device cuts', async () => {
  const events = [event(0,[0xc0,33]), event(0,[0xb0,7,100]), event(1,[0x90,60,100]),
    event(63,[0xb0,74,80]), event(64,[0xb0,10,20]), event(257,[0x80,60,9]), event(514,[0x90,64,96]), event(1000,[0x80,64,0])]
  const whole = await render(2048, events)
  const cuts = [1,62,1,1,7,57,128,1,1,255,1,485,1,1047]
  assert.equal(cuts.reduce((a,b)=>a+b,0),2048)
  const split = await render(2048,events,cuts)
  assert.deepEqual(split,whole)
  assert.ok(whole.some(byte=>byte!==0))
  for(let i=0;i<whole.length;i+=4) assert.ok(Number.isFinite(whole.readFloatLE(i)))
})

test('actual continuous stream responds to sustain while retaining finite requested output', async () => {
  const notes = [event(0,[0xb0,64,127]),event(0,[0x90,60,100]),event(12000,[0x80,60,0]),event(36000,[0xb0,64,0])]
  const wet = await render(48000,notes), dry = await render(48000,notes.map(e=>e.frame===0&&e.bytes[0]===0xb0?event(0,[0xb0,64,0]):e))
  const power = b => { let n=0;for(let frame=16800;frame<31200;frame++)for(let ch=0;ch<2;ch++)n+=b.readFloatLE(frame*8+ch*4)**2;return n }
  assert.equal(wet.length,48000*8)
  assert.notDeepEqual(wet,dry)
  assert.ok(power(wet)>power(dry))
})

test('engine mismatch and distinct note boundaries collapsed across blocks reject and reap child/font', async () => {
  for(const mismatch of [true,false]) {
    const owned=await fixture(), selected=structuredClone(sound)
    if(mismatch) selected.engine.version+='-unavailable'
    const owner=owned.open(selected)
    try {
      if(mismatch) await assert.rejects(owner.ready,/version/)
      else {
        await owner.ready
        await owner.render(8,[event(1,[0x90,60,100])])
        await assert.rejects(owner.render(1,[event(0,[0x80,60,0])]),/collapses/)
      }
      await assert.rejects(owner.completion)
    } finally { owner.cancel();await owner.completion.catch(()=>{});await owned.clean() }
  }
})

test('cancel during font preparation opens no child; in-flight PCM cancel waits child close and font removal', async () => {
  for(const pending of [false,true]) {
    const owned=await fixture(), owner=owned.open()
    let block
    if(pending) { await owner.ready; block=owner.render(2**20,[event(0,[0x90,60,100])]);block.catch(()=>{}) }
    owner.cancel(new Error('retired input'))
    if(block) await assert.rejects(block,/retired input/)
    await assert.rejects(owner.completion,/retired input/)
    if(!pending) { await assert.rejects(owner.ready,/retired input/);assert.equal(owned.children.length,0) }
    await owned.clean()
  }
})

test('unsupported/unordered wire rejects rather than returning replacement PCM', async () => {
  for(const messages of [[event(0,[0xf0,1,0xf7])],[event(2,[0x90,60,100]),event(1,[0x80,60,0])]]) {
    const owned=await fixture(),owner=owned.open()
    try { await owner.ready;await assert.rejects(owner.render(128,messages));await assert.rejects(owner.completion) }
    finally { owner.cancel();await owner.completion.catch(()=>{});await owned.clean() }
  }
})

test('early normal stop drains zero frames; pre-ready cancellation retains falsy failure causes',async()=>{
  const normal=await fixture(),owner=normal.open()
  owner.stop()
  await assert.rejects(owner.ready,/stopped before opening/)
  assert.deepEqual(await owner.completion,{kind:'stopped',frames:'0'})
  assert.equal(normal.children.length,0);await normal.clean()
  for(const cause of [null,false,0,'']) {
    const owned=await fixture(),stream=owned.open()
    stream.cancel(cause)
    await assert.rejects(stream.ready,e=>e instanceof Error&&e.cause===cause)
    await assert.rejects(stream.completion,e=>e instanceof Error&&e.cause===cause)
    await owned.clean()
  }
})

test('cancellation after native close but before lease cleanup remains failure',async()=>{
  const owned=await fixture(),owner=owned.open()
  let settled=false,cancelBeforeCompletion=false
  owner.completion.then(()=>{settled=true},()=>{settled=true})
  await owner.ready;await owner.render(64,[event(0,[0x90,60,100])])
  owned.children[0].once('close',()=>queueMicrotask(()=>{
    cancelBeforeCompletion=!settled
    owner.cancel(new Error('cancel before lease completion'))
  }))
  owner.stop()
  try {
    await assert.rejects(owner.completion,/cancel before lease completion/)
    assert.equal(cancelBeforeCompletion,true)
  }finally{owner.cancel();await owner.completion.catch(()=>{});await owned.clean()}
})
