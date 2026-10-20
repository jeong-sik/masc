import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { openPcmOutput } from '../pcm-output.mjs'

function options(mode) {
  return { output: 'owned', spawnProcess(exe, args, opts) {
    return spawn(process.execPath, [fileURLToPath(new URL('./fixtures/pcm-output.mjs', import.meta.url)), mode, ...args], opts)
  } }
}
test('device demand supplies PCM exactly once; stop joins an owned producer after actual child closure', async () => {
  let requested, complete, childClosed, resolveBlock
  const demand = new Promise(resolve => { requested = resolve })
  const close = new Promise(resolve => { childClosed = resolve })
  const base = options('valid')
  const owner = openPcmOutput({ ...base, spawnProcess(...args) {
    const child = base.spawnProcess(...args); child.once('close', childClosed); return child
  }, provideBlock(request) {
    assert.equal(request.sampleRate, 48000); assert.equal(request.frames, 8)
    requested(request)
    return new Promise(resolve => { resolveBlock = resolve })
  } })
  const info = await owner.ready; info.blockFrames = 999 // must not change owned validation
  const request = await demand
  owner.completion.finally(() => { complete = true }).catch(() => {})
  owner.stop()
  assert.equal(request.signal.aborted, true)
  await close
  assert.equal(complete, undefined)
  resolveBlock(Buffer.alloc(64))
  assert.equal((await owner.completion).admittedFrames, '0')
})
test('prefill and playing acknowledgements may already be queued when stop is requested', async () => {
  const requests = []
  let owner
  owner = openPcmOutput({ ...options('valid'), provideBlock(row) {
    requests.push([row.id, row.startFrame]); return Buffer.alloc(row.frames * 8)
  }, onEvent(event) { if (event.kind === 'playing') owner.stop() } })
  await owner.ready
  const final = await owner.completion
  assert.deepEqual(requests.slice(0, 2), [['1', '0'], ['2', '8']])
  assert.equal(final.admittedFrames, '16')
})
test('identity, demand, PCM, underrun and finalization errors reject after closure', async () => {
  for (const mode of ['identity', 'demand', 'underrun', 'total', 'unfinalized', 'exit', 'bad-pcm', 'nan']) {
    let owner, closed = false
    const base = options(mode)
    owner = openPcmOutput({ ...base, spawnProcess(...args) {
      const child = base.spawnProcess(...args); child.once('close', () => { closed = true }); return child
    }, provideBlock(row) {
      const pcm = Buffer.alloc(mode === 'bad-pcm' ? 1 : row.frames * 8)
      if (mode === 'nan') pcm.writeFloatLE(NaN)
      return pcm
    }, onEvent(row) { if (row.kind === 'playing' && ['total', 'unfinalized', 'exit'].includes(mode)) owner.stop() } })
    if (mode === 'identity') await assert.rejects(owner.ready)
    else await owner.ready
    await assert.rejects(owner.completion)
    assert.equal(closed, true)
  }
})
test('preabort spawns nothing and every falsy cancellation cause remains failure', async () => {
  const pre = new AbortController(); pre.abort()
  assert.throws(() => openPcmOutput({ signal: pre.signal, provideBlock() {}, spawnProcess() { assert.fail('spawned') } }))
  for (const reason of [null, false, 0, '']) for (const kind of ['cancel', 'signal']) {
    const cancellation = new AbortController()
    let requested
    const demand = new Promise(resolve => { requested = resolve })
    const owner = openPcmOutput({ ...options('cancel-race'), signal: cancellation.signal, provideBlock(row) {
      requested(); return new Promise((resolve, reject) => row.signal.addEventListener('abort', () => reject(row.signal.reason), { once: true }))
    } })
    await demand
    owner.stop()
    if (kind === 'cancel') owner.cancel(reason); else cancellation.abort(reason)
    await assert.rejects(owner.completion, error => error.cause === reason)
  }
})

test('cancellation after native close still owns an unsettled producer', async () => {
  for (const kind of ['cancel', 'signal']) {
    let requested, childClosed, resolveBlock
    const demand = new Promise(resolve => { requested = resolve })
    const close = new Promise(resolve => { childClosed = resolve })
    const cancellation = new AbortController(), base = options('valid')
    const owner = openPcmOutput({ ...base, signal: cancellation.signal, spawnProcess(...args) {
      const child = base.spawnProcess(...args); child.once('close', childClosed); return child
    }, provideBlock() { requested(); return new Promise(resolve => { resolveBlock = resolve }) } })
    await demand
    owner.stop()
    await close
    if (kind === 'cancel') owner.cancel(null); else cancellation.abort(null)
    resolveBlock(Buffer.alloc(64))
    await assert.rejects(owner.completion, error => error.cause === null)
  }
})

test('native error retains the final classified fault and immutable counters after child closure', async () => {
  for (const [mode, fault, missing] of [['fault-final', 'underrun', '8'], ['format-final', 'render-format', '0']]) {
    const events = []
    let child, closed = false
    const base = options(mode)
    const owner = openPcmOutput({ ...base, spawnProcess(...args) {
      child = base.spawnProcess(...args); child.once('close', () => { closed = true }); return child
    }, onEvent: row => events.push(row), provideBlock: row => Buffer.alloc(row.frames * 8) })
    await owner.ready
    await assert.rejects(owner.completion)
    assert.equal(closed, true)
    const report = owner.diagnostics()
    assert.equal(report.settled, true); assert.equal(report.nativeClosed, true)
    assert.equal(report.nativeError.message, fault); assert.equal(report.receiptError, null)
    assert.equal(report.final.success, false); assert.equal(report.final.fault, fault)
    assert.equal(report.final.underrunFrames, missing); assert.equal(report.final.renderedFrames, '16')
    assert.equal(report.final.demand.completedBlocks, '2')
    assert.equal(events.at(-1).kind, 'stopped')
    report.final.fault = 'caller mutation'; report.device.id = 'other'
    assert.equal(owner.diagnostics().final.fault, fault); assert.equal(owner.diagnostics().device.id, 'owned')
  }
})
