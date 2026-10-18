import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { PassThrough, Writable } from 'node:stream'
import { openPlayback } from '../playback.mjs'

function fixture(options = {}) {
  const child = new EventEmitter(), commands = [], signals = []
  child.stdout = new PassThrough(); child.stderr = new PassThrough()
  child.stdin = new Writable({ write(data, _, done) { commands.push(JSON.parse(data)); done() } })
  child.kill = name => { signals.push(name); return true }
  let args
  const playback = openPlayback({ path: '/synthetic/phrase.wav', output: 'test-output', ...options,
    spawnProcess(_, arguments_) { args = arguments_; return child } })
  const event = (kind, values = {}) => child.stdout.write(JSON.stringify({ kind, currentTime: 0.2, duration: 2,
    loop: options.loop ?? false, device: { id: 'test-output', name: 'Test output', outputs: 2 }, ...values }) + '\n')
  const close = (code = 0) => { child.stdout.end(); child.stderr.end(); child.emit('close', code, null) }
  return { child, playback, commands, signals, args, event, close }
}
test('one native transport owns pause, seek, resume and loop state until child close', async () => {
  const seen = [], f = fixture({ loop: true, onEvent: event => seen.push(event.kind) })
  assert.ok(f.args.includes('--loop'))
  f.event('playing'); await f.playback.ready
  f.playback.pause(); f.event('paused')
  f.playback.seek(1); f.playback.resume(); f.event('playing', { currentTime: 1 })
  f.playback.stop(); f.event('stopped', { currentTime: 1.1 })
  let completed = false; f.playback.completion.then(() => { completed = true })
  await Promise.resolve(); assert.equal(completed, false)
  f.close(); assert.equal((await f.playback.completion).currentTime, 1.1)
  assert.deepEqual(f.commands, [{ kind: 'pause' }, { kind: 'seek', seconds: 1 }, { kind: 'resume' }, { kind: 'stop' }])
  assert.deepEqual(seen, ['playing', 'paused', 'playing', 'stopped'])
})
test('substituted output or malformed protocol fails and waits for the owned child', async () => {
  const f = fixture()
  f.event('playing', { device: { id: 'another-output', name: 'Other', outputs: 2 } })
  assert.deepEqual(f.signals, ['SIGTERM'])
  f.close(1)
  await assert.rejects(f.playback.ready, /selected device/)
  await assert.rejects(f.playback.completion, /selected device/)
  const g = fixture(); g.child.stdout.write('not JSON\n'); g.close(1)
  await assert.rejects(g.playback.completion, /JSON/)
})
test('a protocol failure rejects readiness and refuses buffered states and commands until child close', async () => {
  const seen = [], f = fixture({ onEvent: event => seen.push(event.kind) })
  let readiness = 'pending', completed = false
  f.playback.ready.then(() => { readiness = 'resolved' }, () => { readiness = 'rejected' })
  f.playback.completion.then(() => { completed = true }, () => { completed = true })
  const playing = { kind: 'playing', currentTime: 0.2, duration: 2, loop: false,
    device: { id: 'test-output', name: 'Test output', outputs: 2 } }
  f.child.stdout.write(`not JSON\n${JSON.stringify(playing)}\n`)
  await Promise.resolve()
  assert.equal(readiness, 'rejected')
  assert.equal(completed, false)
  assert.deepEqual(seen, [])
  assert.deepEqual(f.signals, ['SIGTERM'])
  for (const command of ['pause', 'resume', 'status']) assert.throws(() => f.playback[command](), /JSON/)
  assert.throws(() => f.playback.seek(1))
  f.playback.stop()
  assert.deepEqual(f.commands, [])
  f.event('stopped')
  f.close(0)
  await assert.rejects(f.playback.ready, /JSON/)
  await assert.rejects(f.playback.completion, /JSON/)
})
test('native failure after readiness closes state admission without replacing orderly stop semantics', async () => {
  const seen = [], f = fixture({ onEvent: event => seen.push(event.kind) })
  f.event('playing'); await f.playback.ready
  f.event('error', { message: 'Device disappeared' })
  f.event('playing'); f.event('paused'); f.event('stopped')
  assert.deepEqual(seen, ['playing', 'error'])
  assert.throws(() => f.playback.pause(), /Device disappeared/)
  f.playback.stop()
  assert.deepEqual(f.commands, [])
  f.close(0)
  await assert.rejects(f.playback.completion, /Device disappeared/)
})
test('early stop, cancellation and native failure do not become successful playback', async () => {
  const f = fixture(); f.playback.stop(); assert.deepEqual(f.commands, [{ kind: 'stop' }]); f.close(0)
  await assert.rejects(f.playback.completion, /without finalization/)
  const signal = new AbortController(), g = fixture({ signal: signal.signal })
  signal.abort(); assert.deepEqual(g.signals, ['SIGTERM']); g.close(1)
  await assert.rejects(g.playback.completion)
  const h = fixture(); h.event('error', { message: 'Device disappeared' }); h.close(1)
  await assert.rejects(h.playback.completion, /Device disappeared/)
  const preAborted = new AbortController(); preAborted.abort()
  assert.throws(() => openPlayback({ path: 'x', signal: preAborted.signal }), /abort/i)
})
