import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { PassThrough, Writable } from 'node:stream'
import { openPlayback, arrangementTransportPath } from '../playback.mjs'

function fixture(options = {}) {
  const child = new EventEmitter(), commands = [], signals = []
  child.stdout = new PassThrough(); child.stderr = new PassThrough()
  child.stdin = new Writable({ write(data, _, done) { commands.push(JSON.parse(data)); done() } })
  child.kill = name => { signals.push(name); return true }
  let args, executable
  const playback = openPlayback({ path: '/synthetic/phrase.wav', output: 'test-output', ...options,
    spawnProcess(file, arguments_) { executable = file; args = arguments_; return child } })
  const event = (kind, values = {}) => child.stdout.write(JSON.stringify({ kind, currentTime: 0.2, duration: 2,
    loop: options.loop ?? false, device: { id: 'test-output', name: 'Test output', outputs: 2 }, ...values }) + '\n')
  const close = (code = 0) => { child.stdout.end(); child.stderr.end(); child.emit('close', code, null) }
  return { child, playback, commands, signals, args, executable, event, close }
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
test('seek forwards the inclusive WAV endpoint and refuses positions beyond it', async () => {
  for (const loop of [false, true]) {
    const f = fixture({ loop })
    f.event('playing'); await f.playback.ready
    f.playback.seek(2)
    assert.deepEqual(f.commands, [{ kind: 'seek', seconds: 2 }])
    for (const seconds of [2.001, -1, Infinity, NaN]) assert.throws(() => f.playback.seek(seconds), /Seek/)
    assert.equal(f.commands.length, 1)
    if (loop) { f.event('playing', { currentTime: 0 }); f.playback.stop() }
    f.event('stopped', { currentTime: loop ? 0 : 2 }); f.close()
    assert.equal((await f.playback.completion).currentTime, loop ? 0 : 2)
  }
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

test('MIDI destination playback pins its identity and retains the same owned transport controls', async () => {
  const f = fixture({ output: undefined, midiOutput: '-120', loop: true })
  const device = { kind: 'midi', id: '-120', name: 'Owned virtual output', protocol: 1 }
  assert.deepEqual(f.args, ['play', '--file', '/synthetic/phrase.wav', '--destination', '-120', '--loop'])
  f.event('playing', { device }); await f.playback.ready
  f.playback.pause(); f.event('paused', { device })
  f.playback.seek(2); f.playback.resume(); f.playback.stop()
  f.event('stopped', { device }); f.close()
  await f.playback.completion
  assert.deepEqual(f.commands, [{ kind: 'pause' }, { kind: 'seek', seconds: 2 }, { kind: 'resume' }, { kind: 'stop' }])
  const bad = fixture({ output: undefined, midiOutput: '-120' })
  bad.event('playing', { device: { ...device, id: '121' } }); bad.close(1)
  await assert.rejects(bad.playback.ready, /selected device/)
  await assert.rejects(bad.playback.completion, /selected device/)
  assert.throws(() => openPlayback({ path: 'x', output: 'audio', midiOutput: '-120' }), /Choose/)
})

test('terminal termination gives the MIDI owner a chance to release keys and waits for close', async () => {
  const f = fixture({ output: undefined, midiOutput: '-120' })
  const device = { kind: 'midi', id: '-120', name: 'Owned output', protocol: 1 }
  f.event('playing', { device }); await f.playback.ready
  let done = false
  f.playback.completion.then(() => { done = true })
  f.playback.terminate()
  assert.deepEqual(f.signals, ['SIGTERM'])
  await Promise.resolve(); assert.equal(done, false)
  f.event('stopped', { device }); f.close(); await f.playback.completion
})


test('source playback pins every port binding and admits a zero-duration source through child completion', async () => {
  const device = { kind: 'midi', id: '-120', name: 'Source one', protocol: 1 }
  const second = { ...device, id: '122', name: 'Source two' }
  const bindings = [{ port: 2, destination: '-120' }, { port: 7, destination: '122' }]
  const f = fixture({ output: undefined, midiOutput: '-120', midiBindings: bindings })
  bindings[1].destination = 'substituted after admission'
  const state = { currentTime: 0, duration: 0, device,
    bindings: [{ port: 2, device }, { port: 7, device: second }] }
  f.event('playing', state); await f.playback.ready
  f.event('stopped', state); f.close()
  assert.equal((await f.playback.completion).duration, 0)
  const g = fixture({ output: undefined, midiOutput: '-120', midiBindings: [{ port: 2, destination: '-120' }, { port: 7, destination: '122' }] })
  g.event('playing', { ...state, bindings: [{ port: 2, device }, { port: 7, device: { ...second, id: '123' } }] }); g.close(1)
  await assert.rejects(g.playback.ready, /source ports/)
  await assert.rejects(g.playback.completion, /source ports/)
  assert.throws(() => openPlayback({ path: 'source', midiOutput: '-120', midiBindings: [{ port: 2, destination: '123' }] }), /bindings/)
})


test('WAV arrangement route uses its native helper and refuses unsupported MIDI or whole-project looping',async()=>{
  const f=fixture({format:'wave-arrangement'})
  assert.equal(f.executable,arrangementTransportPath)
  assert.deepEqual(f.args,['play','--file','/synthetic/phrase.wav','--output','test-output'])
  f.event('playing');await f.playback.ready;f.playback.stop();f.event('stopped');f.close();await f.playback.completion
  for(const options of [{format:'unknown'},{format:'wave-arrangement',loop:true},{format:'wave-arrangement',midiOutput:'midi'}]){
    assert.throws(()=>fixture(options))
  }
})

test('combined playback pins its audio device and every MIDI binding in one native owner', async () => {
  const bindings = [{ port: 0, destination: '-120' }, { port: 1, destination: '122' }]
  const options = { format: 'mixed-arrangement', midiOutput: '-120', midiBindings: bindings }
  const f = fixture(options)
  assert.equal(f.executable, arrangementTransportPath)
  assert.deepEqual(f.args, ['play', '--file', '/synthetic/phrase.wav', '--output', 'test-output'])
  const state = { format: 'mixed-arrangement', clock: { kind: 'mach-host-time' }, bindings: bindings.map(({ port, destination }) => ({ port,
    device: { id: destination, kind: 'midi', protocol: 1, name: 'Selected destination' } })) }
  f.event('playing', state); await f.playback.ready
  f.playback.pause(); f.event('paused', state); f.playback.seek(.4); f.playback.resume(); f.event('playing', state)
  f.playback.stop(); f.event('stopped', state); f.close(); await f.playback.completion
  assert.deepEqual(f.commands, [{ kind: 'pause' }, { kind: 'seek', seconds: .4 }, { kind: 'resume' }, { kind: 'stop' }])
  for (const change of [{ device: { id: 'other', name: 'Wrong audio', outputs: 2 } }, { bindings: [] }, { clock: undefined }, { format: 'wave-arrangement' }]) {
    const bad = fixture(options); bad.event('playing', { ...state, ...change }); bad.close(1)
    await assert.rejects(bad.playback.ready); await assert.rejects(bad.playback.completion)
  }
  assert.throws(() => fixture({ ...options, output: undefined }))
  assert.throws(() => fixture({ ...options, loop: true }))
})

test('captured audio-only playback owns the native arrangement clock and refuses MIDI or whole-song loop selection', async () => {
  const format = 'capture-audio-arrangement'
  const f = fixture({ format })
  assert.equal(f.executable, arrangementTransportPath)
  const clock = { kind: 'mach-host-time' }
  f.event('playing', { format, clock }); await f.playback.ready
  f.playback.pause(); f.event('paused', { format, clock }); f.playback.seek(.5); f.playback.resume()
  f.event('playing', { format, clock }); f.playback.stop(); f.event('stopped', { format, clock }); f.close()
  await f.playback.completion
  assert.deepEqual(f.commands.map(command => command.kind), ['pause', 'seek', 'resume', 'stop'])
  for (const options of [{ loop: true }, { midiOutput: '12' }]) assert.throws(() => fixture({ format, ...options }), /Invalid arrangement/)
  const invalid = fixture({ format }); invalid.event('playing'); invalid.close(1)
  await assert.rejects(invalid.playback.completion, /captured audio arrangement clock/)
})
