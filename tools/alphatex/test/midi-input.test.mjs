import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { openMidiInput } from '../midi-input.mjs'
const fixture = fileURLToPath(new URL('./fixtures/midi-input-owner.mjs', import.meta.url))
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done }); return { promise, resolve } }
function open(mode, options = {}) {
  const commands = [], childCreated = deferred()
  const input = openMidiInput({ source: '10', onPacket() {}, ...options,
    spawnProcess(executable, args, config) {
      assert.deepEqual(args, ['--source', '10'])
      const child = spawn(process.execPath, [fixture, mode, ...args], config)
      const write = child.stdin.write.bind(child.stdin)
      child.stdin.write = data => { commands.push(JSON.parse(data)); return write(data) }
      childCreated.resolve(child); return child
    } })
  return { ...input, commands, childCreated: childCreated.promise }
}
test('selected source input keeps original UMP words and integer host clock through a draining stop', async () => {
  const events = [], input = open('clean', { onPacket: event => events.push(event) })
  const admitted = await input.ready; assert.equal(admitted.source.id, '10')
  input.stop(); input.stop()
  const final = await input.completion
  assert.equal(final.admittedPackets, '2'); assert.equal(final.acknowledgedPackets, '2')
  assert.deepEqual(events.map(e => [e.ordinal, e.hostTime, e.words]), [
    ['0', '9007199254740993', [0x43953c03, 0x90012345]], ['1', '9007199254740994', [0x43953c03, 0x90012345]]])
  assert.equal(input.commands.filter(c => c.kind === 'stop').length, 1)
  assert.deepEqual(input.commands.filter(c => c.kind === 'ack').map(c => c.ordinal), ['0', '1'])
})
test('a packet decision settles before its acknowledgement; stop drains the admitted second packet', async () => {
  const entered = deferred(), decision = deferred(), events = []
  const input = open('clean', { async onPacket(event) { events.push(event.ordinal); if (event.ordinal === '0') { entered.resolve(); await decision.promise } } })
  await input.ready; await entered.promise; input.stop()
  assert.deepEqual(input.commands, [{ kind: 'stop' }]); assert.deepEqual(events, ['0'])
  decision.resolve(); await input.completion
  assert.deepEqual(events, ['0', '1']); assert.deepEqual(input.commands.slice(1), [{ kind: 'ack', ordinal: '0' }, { kind: 'ack', ordinal: '1' }])
})
test('empty input closes normally without opening a packet consumer', async () => {
  const input = open('empty', { onPacket() { assert.fail('no input was admitted') } }); await input.ready; input.stop()
  assert.equal((await input.completion).admittedPackets, '0')
})
for (const mode of ['missing-ready', 'native-error', 'wrong-source', 'duplicate-ready', 'truncated', 'word-range', 'clock-number', 'out-of-order', 'pipelined', 'false-final', 'bad-final']) {
  test(`input refuses ${mode} and joins its owned child`, async () => {
    const input = open(mode); await assert.rejects(input.completion)
    const child = await input.childCreated; assert.notEqual(child.exitCode ?? child.signalCode, null)
  })
}
test('external abort signals the consumer and joins an already admitted decision', async () => {
  const external = new AbortController(), entered = deferred(), decision = deferred(), cancelled = deferred()
  const reason = new Error('editor closing')
  const input = open('clean', { signal: external.signal, async onPacket(event, { signal }) {
    signal.addEventListener('abort', () => cancelled.resolve(signal.reason), { once: true }); entered.resolve(); await decision.promise
  } })
  await input.ready; await entered.promise; external.abort(reason)
  assert.equal(await cancelled.promise, reason)
  let settled = false; input.completion.then(() => { settled = true }, () => { settled = true })
  const child = await input.childCreated; if (child.exitCode === null && child.signalCode === null) await new Promise(resolve => child.once('close', resolve))
  await Promise.resolve(); assert.equal(settled, false)
  decision.resolve(); await assert.rejects(input.completion, error => error === reason)
  assert.equal(input.commands.some(c => c.kind === 'ack'), false)
})
test('native failure cancels the consumer and completion still joins its decision', async () => {
  const entered = deferred(), decision = deferred(), cancelled = deferred()
  const input = open('clean', { async onPacket(event, { signal }) { signal.addEventListener('abort', () => cancelled.resolve(), { once: true }); entered.resolve(); await decision.promise } })
  await input.ready; await entered.promise; (await input.childCreated).kill('SIGTERM'); await cancelled.promise
  let settled = false; input.completion.catch(() => { settled = true }); await Promise.resolve(); assert.equal(settled, false)
  decision.resolve(); await assert.rejects(input.completion, /closed without successful finalization/)
})
test('a consumer failure becomes an input failure and stops the helper', async () => {
  const input = open('clean', { async onPacket() { throw null } })
  await assert.rejects(input.completion, /null/)
})
test('bad source identity and pre-aborted admission never spawn the helper', () => {
  let spawned = false
  const spawnProcess = () => { spawned = true; assert.fail('no child may be created') }
  for (const source of [10, '', '010', '-0', '2147483648', '-2147483649']) assert.throws(() => openMidiInput({ source, onPacket() {}, spawnProcess }))
  const controller = new AbortController(); controller.abort(new Error('cancelled before admission'))
  assert.throws(() => openMidiInput({ source: '10', onPacket() {}, signal: controller.signal, spawnProcess }), /cancelled before admission/)
  assert.equal(spawned, false)
})
