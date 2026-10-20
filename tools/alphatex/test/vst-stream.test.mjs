import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { openVstStream } from '../vst-stream.mjs'

const data = Buffer.from('owned sound')
const sound = () => ({ kind: 'vst', selection: { plugin_path: '/fixture.vst3', plugin_name: null, preset_path: '/label-only', name: 'Fixture' },
  instrument: { identifier: 'fixture-id', version: '1' },
  preset: { data: data.toString('base64'), sha256: createHash('sha256').update(data).digest('hex') } })
const options = mode => ({ command: process.execPath, args: [fileURLToPath(new URL('./fixtures/vst-stream.mjs', import.meta.url)), mode] })

test('real child returns ordered stereo PCM, admits one block, drains before completion', async () => {
  const selected = sound(), owner = openVstStream(selected, options('valid'))
  selected.instrument.identifier = 'caller-mutated'
  try {
    await owner.ready
    const first = owner.render(7, [{ frame: 0, bytes: [0x90, 60, 90] }])
    await assert.rejects(owner.render(8), /pending/)
    const pcm = await first
    assert.equal(pcm.length, 56)
    assert.equal(pcm.readFloatLE(0), .25); assert.equal(pcm.readFloatLE(4), -.125)
    const last = owner.render(13, [{ frame: 12, bytes: [0x80, 60, 0] }])
    owner.stop()
    assert.equal((await last).length, 104)
    assert.deepEqual(await owner.completion, { kind: 'stopped', frames: '20' })
    await assert.rejects(owner.render(1), /not accepting/)
  } finally { owner.cancel(); await owner.completion.catch(() => {}) }
})

test('bad sound, block identity, PCM and missing finalization reject through actual child closure', async () => {
  for (const mode of ['identity', 'sequence', 'truncated', 'nan', 'crash', 'unfinalized']) {
    let closed = false
    const owner = openVstStream(sound(), { ...options(mode), spawnProcess(...args) {
      const child = spawn(...args); child.once('close', () => { closed = true }); return child
    } })
    try {
      if (mode === 'identity') await assert.rejects(owner.ready, /mismatch/)
      else {
        await owner.ready
        if (mode !== 'unfinalized') await assert.rejects(owner.render(7))
        else owner.stop()
      }
      await assert.rejects(owner.completion)
      assert.equal(closed, true)
    } finally { owner.cancel(); await owner.completion.catch(() => {}) }
  }
})

test('preabort spawns nothing; pending admission abort joins actual process close', async () => {
  const cancellation = new AbortController(); cancellation.abort(new Error('retired'))
  assert.throws(() => openVstStream(sound(), { signal: cancellation.signal, spawnProcess() { assert.fail('spawned') } }), /retired/)
  const pending = new AbortController()
  let closed = false
  const owner = openVstStream(sound(), { ...options('wait'), signal: pending.signal, spawnProcess(...args) {
    const child = spawn(...args); child.once('close', () => { closed = true }); return child
  } })
  pending.abort(new Error('retired'))
  await assert.rejects(owner.ready, /retired/)
  await assert.rejects(owner.completion, /retired/)
  assert.equal(closed, true)
})

test('retiring an in-flight block rejects its PCM and joins closure; early stop drains zero frames', async () => {
  const cancellation = new AbortController()
  const owner = openVstStream(sound(), { ...options('wait-block'), signal: cancellation.signal })
  await owner.ready
  const block = owner.render(7)
  cancellation.abort(new Error('input retired'))
  await assert.rejects(block, /input retired/)
  await assert.rejects(owner.completion, /input retired/)
  const early = openVstStream(sound(), options('valid'))
  early.stop()
  await early.ready
  assert.deepEqual(await early.completion, { kind: 'stopped', frames: '0' })
  const unavailable = openVstStream(sound(), { command: '/no-such-owned-vst-host' })
  await assert.rejects(unavailable.ready, { code: 'ENOENT' })
  await assert.rejects(unavailable.completion, { code: 'ENOENT' })
})
