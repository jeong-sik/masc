import test from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { openMonitorSession as openStepMonitor, monitorPacket } from '../step-monitor-session.mjs'
import { openStepInput } from '../step-input.mjs'
import { openMidiInput } from '../midi-input.mjs'
import { openPcmOutput } from '../pcm-output.mjs'
import { openVstStream } from '../vst-stream.mjs'
import { newEditor, editorCommand } from '../sequencer-editor.mjs'
import { phraseBacking } from '../phrase-backing.mjs'

const data = Buffer.from('owned monitor preset')
const sound = { kind: 'vst', selection: { plugin_path: '/fixture.vst3', plugin_name: null, preset_path: null, name: 'Fixture' },
  instrument: { identifier: 'fixture-id', version: '1' },
  preset: { data: data.toString('base64'), sha256: createHash('sha256').update(data).digest('hex') } }
const packet = words => ({ kind: 'midi', source: '10', protocol: 2, timestampOrigin: 'packet', words })
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done }); return { promise, resolve } }
const fixture = name => fileURLToPath(new URL(`./fixtures/${name}.mjs`, import.meta.url))
function io({ pcmMode = 'valid', vstMode = 'valid' } = {}) {
  const children = [], blocks = []
  const spawnOwned = (...args) => { const child = spawn(...args); children.push(child); return child }
  return { children, blocks,
    openOutput: options => openPcmOutput({ ...options, spawnProcess(_exe, args, config) {
      return spawnOwned(process.execPath, [fixture('pcm-output'), pcmMode, ...args], config)
    } }),
    openSynth: (selected, options) => {
      const owner = openVstStream(selected, { ...options, command: process.execPath,
        args: [fixture('vst-stream'), vstMode], spawnProcess: spawnOwned })
      return { ...owner, render(frames, messages) { blocks.push(structuredClone(messages)); return owner.render(frames, messages) } }
    },
    openInput: options => openMidiInput({ ...options, spawnProcess(_exe, args, config) {
      return spawnOwned(process.execPath, [fixture('midi-input-owner'), 'step-chord', ...args], config)
    } }),
    assertClosed() { for (const child of children) assert.notEqual(child.exitCode ?? child.signalCode, null) },
  }
}

test('one input drives selected-channel audition and one undoable chord; all three children join', async () => {
  const owned = io(), adopted = deferred(), sounded = deferred()
  let editor = newEditor(), queue = Promise.resolve(), owner, sent = 0
  owner = openStepInput({ source: '10', audio: { sound, output: 'owned' }, getEditor: () => editor,
    adoptEditor(next) { editor = next; adopted.resolve() },
    enqueue(action) { const decision = queue.then(action); queue = decision.catch(() => {}); return decision },
    openInput: owned.openInput,
    openMonitor(options) {
      const monitor = openStepMonitor({ ...options, ...owned })
      return { ...monitor, async send(prepared) { await monitor.send(prepared); if (++sent === 3) sounded.resolve() } }
    } })
  try {
    assert.equal((await owner.ready).monitoring, true)
    await adopted.promise; await sounded.promise
    owner.stop(); await owner.completion
    assert.equal(owned.children.length, 3); owned.assertClosed()
    assert.deepEqual(owned.blocks.flat().map(row => row.bytes), [[0x90, 60, 72], [0x90, 64, 127], [0x80, 60, 8], [0x80, 64, 16]])
    assert.deepEqual(editor.project.tracks[0].notes.map(note => [note.pitch, note.velocity, note.start]), [[60, 72, 0], [64, 127, 0]])
    assert.equal(editor.tick, 960)
    assert.equal(editorCommand(editor, 'undo').editor.project.tracks[0].notes.length, 0)
  } finally { owner.cancel(); await owner.completion.catch(() => {}) }
})

test('practice input sounds the same source without changing notes, cursor or undo history', async () => {
  const owned = io(), sounded = deferred(), editor = newEditor(), states = []
  let sent = 0
  const owner = openStepInput({ source: '10', practice: true,
    audio: { sound, output: 'owned', backing: phraseBacking(editor.project, 'track-1') },
    getEditor: () => editor, adoptEditor() { assert.fail('practice edited the phrase') },
    enqueue: action => Promise.resolve().then(action), onState: state => states.push(state.held),
    openInput: owned.openInput, openMonitor(options) {
      const monitor = openStepMonitor({ ...options, ...owned })
      return { ...monitor, async send(prepared) { await monitor.send(prepared); if (++sent === 3) sounded.resolve() } }
    } })
  try {
    assert.equal((await owner.ready).practice, true)
    await sounded.promise
    assert.throws(() => owner.control({ kind: 'step-rest' }), /Stop practice/)
    owner.stop(); await owner.completion; owned.assertClosed()
    assert.deepEqual(states, [2, 1, 0]); assert.deepEqual(editor, newEditor())
    assert.ok(owned.blocks.flat().some(row => row.bytes[0] === 0x90 && row.bytes[1] === 60))
    assert.equal(owner.diagnostics().backing.track, 'track-1')
  } finally { owner.cancel(); await owner.completion.catch(() => {}) }
})

test('monitoring preserves MIDI message order and projection, refusing opaque data and key collisions atomically', () => {
  const held = monitorPacket(packet([0x43953c00, 0x80000000]), 2)
  assert.deepEqual(held.messages, [{ frame: 0, bytes: [0x92, 60, 64] }])
  const expressions = monitorPacket(packet([0x43b54000, 0xffffffff, 0x43d50000, 0x80000000, 0x43e50000, 0xffffffff,
    0x43a53c00, 0x40000000, 0x23c52000, 0x23b5007f]), 2, held.held)
  assert.deepEqual(expressions.messages.map(row => row.bytes), [[0xb2,64,127], [0xd2,64], [0xe2,127,127], [0xa2,60,32]])
  assert.deepEqual(monitorPacket(packet([0x43813c00, 0]), 2, held.held).messages, [])
  assert.deepEqual(monitorPacket(packet([0x43853c00, 0x80000000]), 2, held.held).messages, [{ frame: 0, bytes: [0x82,60,64] }])
  for (const words of [[0x44913c00, 0xffff0000], [0x43953c03, 0xffff0001], [0x30000000,0], [0x43f00000,0]]) {
    assert.throws(() => monitorPacket(packet(words), 2, held.held))
    assert.equal(held.held.size, 1)
  }
})

test('output or synth failure cancels the whole route before completion, never substituting sound/output', async () => {
  for (const mode of [{pcmMode:'identity'}, {pcmMode:'underrun'}, {vstMode:'identity'}, {vstMode:'crash'}]) {
    const owned = io(mode), owner = openStepMonitor({ sound, output: 'owned', channel: 0, ...owned })
    await owner.ready.catch(() => {})
    await assert.rejects(owner.completion)
    owned.assertClosed()
    assert.ok(owned.children.length <= 2)
  }
})

test('stop interrupts an in-flight synth block and joins actual synth/output closure', async () => {
  const owned = io({ vstMode: 'wait-block' }), rendering = deferred()
  const owner = openStepMonitor({ sound, output: 'owned', channel: 0, ...owned,
    openSynth(selected, options) {
      const synth = owned.openSynth(selected, options)
      return { ...synth, render(...args) { rendering.resolve(); return synth.render(...args) } }
    } })
  await rendering.promise
  owner.stop(); await owner.completion
  await assert.rejects(owner.ready)
  owned.assertClosed()
})

test('view close before monitor readiness never opens MIDI; admitted controls still drain', async () => {
  const owned = io({ vstMode: 'wait-block' }), rendering = deferred()
  let editor = newEditor(), opened = false
  const owner = openStepInput({ source: '10', audio: { sound, output: 'owned' }, getEditor: () => editor,
    adoptEditor(next) { editor = next }, enqueue: action => action(),
    openInput() { opened = true; assert.fail('MIDI opened before audio was ready') },
    openMonitor: options => openStepMonitor({ ...options, ...owned, openSynth(selected, config) {
      const synth = owned.openSynth(selected, config)
      return { ...synth, render(...args) { rendering.resolve(); return synth.render(...args) } }
    } }) })
  await rendering.promise
  owner.stop({ admittedControls: true })
  editor = owner.control({ kind: 'step-length', value: '1/3' })
  await owner.completion
  assert.equal(editor.duration, 320); assert.equal(opened, false); owned.assertClosed()
})

test('cancellation preserves even falsy causes and joins children while audio is opening', async () => {
  for (const reason of [null, false, 0, '']) {
    const owned = io({ vstMode: 'wait-block' }), rendering = deferred()
    const owner = openStepMonitor({ sound, output: 'owned', channel: 0, ...owned, openSynth(selected, config) {
      const synth = owned.openSynth(selected, config)
      return { ...synth, render(...args) { rendering.resolve(); return synth.render(...args) } }
    } })
    await rendering.promise; owner.cancel(reason)
    await assert.rejects(owner.completion, error => error.cause === reason)
    owned.assertClosed()
  }
})
