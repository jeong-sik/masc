import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { PassThrough, Writable } from 'node:stream'
import { mkdtemp, readdir, rm, access } from 'node:fs/promises'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { openPlayback, midiClipTransportPath } from '../playback.mjs'
import { MidiClipPlayer } from '../midi-clip-player.mjs'
import { importMidiClip, editMidiClipAttack, midiClipNotes } from '../midi-clip-source.mjs'

const source = { originalSha256: 'a'.repeat(64), documentSha256: 'b'.repeat(64), ppq: 1001 }
const deferred = () => { let resolve, reject; const promise = new Promise((ok, fail) => { resolve = ok; reject = fail }); return { promise, resolve, reject } }
function protocol({ duration = '2000000000', setup = '500000000' } = {}) {
  const child = new EventEmitter(), commands = [], signals = []
  child.stdout = new PassThrough(); child.stderr = new PassThrough()
  child.stdin = new Writable({ write(bytes, _, done) { commands.push(JSON.parse(bytes)); done() } })
  child.kill = signal => signals.push(signal)
  let program
  const fraction = value => ({ numerator: String(BigInt(value) * 1001n), denominator: '1001' })
  const plan = { schemaVersion: 1, kind: 'midi-clip-playback', source, destination: '-42', durationNanoseconds: fraction(duration), setupNanoseconds: fraction(setup) }
  const player = openPlayback({ path: '/private/clip-plan.json', format: 'midi-clip', midiOutput: '-42', midiClipPlan: plan,
    spawnProcess(executable) { program = executable; return child } })
  const event = (kind, values = {}) => child.stdout.write(JSON.stringify({ kind, format: 'midi-clip', loop: false,
    currentTime: 0, duration: 2, currentNanoseconds: '0', durationNanoseconds: '2000000000', setupNanoseconds: '500000000',
    source: { ...source }, device: { kind: 'midi', id: '-42', name: 'Owned native2', protocol: 2, nativeProtocol: 2 },
    clock: { kind: 'monotonic-nanoseconds' }, ...values }) + '\n')
  const close = (code = 0) => { child.stdout.end(); child.stderr.end(); child.emit('close', code, null) }
  return { player, event, close, commands, signals, program }
}
test('native readiness pins the source before start and Playing admits exact seek, pause and resume', async () => {
  const fixture = protocol(); let ready = false
  fixture.player.ready.then(() => { ready = true })
  fixture.event('ready'); await Promise.resolve(); assert.equal(ready, false)
  assert.equal(fixture.program, midiClipTransportPath); assert.deepEqual(fixture.commands, [{ kind: 'start' }])
  assert.throws(() => fixture.player.pause(), /not ready/)
  fixture.event('playing'); await fixture.player.ready
  fixture.player.seekNanoseconds('1000000001'); fixture.player.pause(); fixture.event('paused')
  fixture.player.resume(); fixture.player.stop(); fixture.event('stopped'); fixture.close()
  await fixture.player.completion
  assert.deepEqual(fixture.commands, [{ kind: 'start' }, { kind: 'seek', nanoseconds: '1000000001' }, { kind: 'pause' }, { kind: 'resume' }, { kind: 'stop' }])
  assert.throws(() => fixture.player.seek(1), /exact nanoseconds/)
})
test('pre-ready stop never admits Start, while an empty admitted Clip completes normally', async () => {
  const early = protocol(); early.player.stop(); early.event('ready'); early.event('stopped'); early.close()
  assert.deepEqual(early.commands, [{ kind: 'stop' }]); await early.player.completion
  await assert.rejects(early.player.ready, /before starting/)
  const empty = protocol({ duration: '0', setup: '0' }), zero = { duration: 0, durationNanoseconds: '0', setupNanoseconds: '0' }
  empty.event('ready', zero); empty.event('playing', zero); empty.event('stopped', zero); empty.close()
  assert.equal((await empty.player.ready).duration, 0); assert.equal((await empty.player.completion).duration, 0)
})
test('native clock/source/protocol substitution fails before source admission or any further command', async () => {
  for (const replacement of [
    { source: { ...source, documentSha256: 'c'.repeat(64) } },
    { device: { kind: 'midi', id: '-42', name: 'Wrong protocol', protocol: 2, nativeProtocol: 1 } },
    { currentNanoseconds: '01' }, { durationNanoseconds: '2000000001' },
  ]) {
    const fixture = protocol(); fixture.event('ready', replacement); fixture.close(1)
    await assert.rejects(fixture.player.ready); await assert.rejects(fixture.player.completion)
    assert.deepEqual(fixture.commands, []); assert.deepEqual(fixture.signals, ['SIGTERM'])
  }
  const drift = protocol(); drift.event('ready'); drift.event('playing'); await drift.player.ready
  drift.event('paused', { durationNanoseconds: '3000000000', duration: 3 }); drift.close(1)
  await assert.rejects(drift.player.completion, /admitted clock/)
  const missing = protocol(); missing.event('playing'); missing.close(1)
  await assert.rejects(missing.player.ready, /prepare before starting/)
})

function document(withTempo = true) {
  const words = [0x00400000, 0x003003e8, 0xd0100000, 50000000, 0, 0,
    0x00400000, 0xf0200000, 0, 0, 0, 0x00400000, 0x40903c00, 0xffff0000,
    0x004003e8, 0x40803c00, 0xffff0000, 0x00400000, 0xf0210000, 0, 0, 0]
  if (!withTempo) words.splice(2, 4)
  const bytes = Buffer.alloc(8 + words.length * 4); bytes.write('SMF2CLIP')
  words.forEach((word, index) => bytes.writeUInt32BE(word, 8 + index * 4))
  return importMidiClip(bytes)
}
function fakeOpen() {
  const calls = [], waiting = []
  const open = options => {
    const done = deferred(), plan = JSON.parse(readFileSync(options.path)), commands = []
    const value = { options, plan, commands, close: () => done.resolve(), fail: error => done.reject(error),
      event: event => options.onEvent(event) }
    calls.push(value)
    for (const waiter of [...waiting]) if (calls.length >= waiter.index) {
      waiting.splice(waiting.indexOf(waiter), 1); waiter.resolve(calls[waiter.index - 1])
    }
    return { completion: done.promise, stop: () => commands.push('stop'), pause: () => commands.push('pause'),
      resume: () => commands.push('resume'), status: () => commands.push('status'), seekNanoseconds: value => commands.push(['seek', value]) }
  }
  return { open, calls, next: (index = 1) => calls.length >= index ? Promise.resolve(calls[index - 1]) : new Promise(resolve => waiting.push({ index, resolve })) }
}
test('early restart keeps its admitted plan and stop retains files until the native child closes', async () => {
  const root = await mkdtemp(join(tmpdir(), 'masc-clip-player-')), fake = fakeOpen()
  try {
    const player = new MidiClipPlayer({ destination: '42', open: fake.open, temporaryRoot: root }), original = document()
    const first = player.play(original), changed = editMidiClipAttack(original, midiClipNotes(original)[0].id, { velocity: 2 })
    const second = player.restart(changed), child = await fake.next()
    assert.deepEqual(child.plan, first.plan); assert.notEqual(child.plan.source.documentSha256,
      (await import('../midi-clip-playback.mjs')).midiClipPlaybackPlan(changed, { destination: '42' }).source.documentSha256)
    assert.equal(fake.calls.length, 1)
    child.event({ kind: 'playing' }); player.stop(); assert.deepEqual(child.commands, ['stop'])
    await access(child.options.path)
    let settled = false; const closing = player.close().then(() => { settled = true })
    await Promise.resolve(); assert.equal(settled, false)
    child.close(); await closing; await second.completion
    assert.deepEqual(await readdir(root), []); assert.equal(player.state.kind, 'stopped')
  } finally { await rm(root, { recursive: true, force: true }) }
})
test('route changes retire old callbacks; a save-conflict drain permits later playback and close blocks new work', async () => {
  const root = await mkdtemp(join(tmpdir(), 'masc-clip-route-')), fake = fakeOpen()
  try {
    const player = new MidiClipPlayer({ destination: '42', open: fake.open, temporaryRoot: root })
    const original = player.play(document()); const first = await fake.next(); first.event({ kind: 'playing' })
    assert.throws(() => player.setOutput('another device')); assert.deepEqual(first.commands, [])
    player.setOutput('43'); const next = player.restart(document())
    first.event({ kind: 'playing' }); assert.equal(player.state.kind, 'preparing')
    assert.equal(fake.calls.length, 1); first.close(); await original.completion
    const second = await fake.next(2); assert.equal(second.options.midiOutput, '43')
    second.event({ kind: 'playing' }); const settling = player.settle(); second.close(); await settling; await next.completion
    assert.equal(player.closed, false)
    const final = player.play(document())
    const third = await fake.next(3); third.close(); await final.completion; await player.close()
    assert.throws(() => player.play(document()), /closed/); assert.deepEqual(await readdir(root), [])
  } finally { await rm(root, { recursive: true, force: true }) }
})

test('an explicit initial tempo resolves only the session plan; invalid values keep an admitted owner intact', async () => {
  const root = await mkdtemp(join(tmpdir(), 'masc-clip-tempo-')), fake = fakeOpen()
  try {
    const player = new MidiClipPlayer({ destination: '42', open: fake.open, temporaryRoot: root }), original = document(false)
    const before = structuredClone(original)
    assert.throws(() => player.play(original), /explicit tempo/)
    player.setInitialTempo(50000000); const owner = player.play(original), child = await fake.next()
    assert.equal(BigInt(child.plan.durationNanoseconds.numerator) / BigInt(child.plan.durationNanoseconds.denominator), 500000000n)
    assert.throws(() => player.setInitialTempo(0), /UInt32/); assert.deepEqual(child.commands, [])
    assert.deepEqual(original, before)
    player.setInitialTempo(undefined); assert.deepEqual(child.commands, ['stop'])
    assert.throws(() => player.restart(original), /explicit tempo/)
    child.close(); await owner.completion; await player.close(); assert.deepEqual(await readdir(root), [])
  } finally { await rm(root, { recursive: true, force: true }) }
})

test('the native controller preserves exact seek values beyond binary64 nanosecond precision', async () => {
  const fixture = protocol({ duration: '9007199254740995' }), clock = { durationNanoseconds: '9007199254740995', duration: Number('9007199254740995') / 1e9 }
  fixture.event('ready', clock); fixture.event('playing', clock); await fixture.player.ready
  fixture.player.seekNanoseconds('9007199254740993')
  assert.deepEqual(fixture.commands.at(-1), { kind: 'seek', nanoseconds: '9007199254740993' })
  for (const bad of ['9007199254740996', '01', '-1', '1.5']) assert.throws(() => fixture.player.seekNanoseconds(bad))
  fixture.player.stop(); fixture.event('stopped', clock); fixture.close(); await fixture.player.completion
})

test('a different initial-tempo plan cannot supply the first clock or admit Start for the same source identity', async () => {
  for (const wrong of [
    { durationNanoseconds: '1000000000', duration: 1 },
    { setupNanoseconds: '250000000' },
  ]) {
    const fixture = protocol(); fixture.event('ready', wrong); fixture.close(1)
    await assert.rejects(fixture.player.ready, /admitted clock/)
    await assert.rejects(fixture.player.completion, /admitted clock/)
    assert.deepEqual(fixture.commands, []); assert.deepEqual(fixture.signals, ['SIGTERM'])
  }
})
