import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { nativeJob, saveSelection, loadSelection, retainRender, snapshotWriter } from '../vst.mjs'
import { InstrumentPicker } from '../instruments.mjs'

const selection = { plugin_path: '/synth.vst3', plugin_name: null, preset_path: null, name: 'Synth' }

async function temporary(action) {
  const path = await mkdtemp(join(tmpdir(), 'masc-vst-test-'))
  try { await action(path) } finally { await rm(path, { recursive: true, force: true }) }
}

test('native IPC accepts only a successful process and a valid reply', async () => {
  const good = nativeJob({}, { command: process.execPath,
    args: ['-e', 'process.stdin.resume(); process.stdin.on("end",()=>console.log(JSON.stringify({ok:true,result:{frames:8}})))'] })
  assert.deepEqual(await good.promise, { frames: 8 })
  const crashed = nativeJob({}, { command: process.execPath,
    args: ['-e', 'console.log(JSON.stringify({ok:true,result:{frames:8}})); process.exit(2)'] })
  await assert.rejects(crashed.promise)
  const refused = nativeJob({}, { command: process.execPath,
    args: ['-e', 'console.log(JSON.stringify({ok:false,error:"instrument unavailable"})); process.exit(1)'] })
  await assert.rejects(refused.promise, /instrument unavailable/)
})

test('cancellation settles only after the owned native process closes', async () => {
  const job = nativeJob({}, { command: process.execPath,
    args: ['-e', 'process.stdin.resume(); setInterval(()=>{},1000)'] })
  job.cancel()
  await assert.rejects(job.promise, { code: 'ABORT_ERR' })
})

test('selection survives reopening and damaged state is not silently replaced', async () => {
  await temporary(async directory => {
    await saveSelection(directory, selection)
    assert.deepEqual(await loadSelection(directory), selection)
    const path = join(directory, 'selection.json')
    await writeFile(path, '{broken')
    await assert.rejects(loadSelection(directory))
    assert.equal(await readFile(path, 'utf8'), '{broken')
  })
})

test('picker verifies the exact instrument then commits its selected preset', async () => {
  await temporary(async directory => {
    const requests = [], chosen = [], failures = []
    let soundfonts = 0
    const picker = new InstrumentPicker({ directory, notify() {},
      selected: value => chosen.push(value), soundfont: () => soundfonts++, failed: error => failures.push(error),
      run(request) {
        requests.push(request)
        const result = request.operation === 'candidates'
          ? { candidates: [{ path: selection.plugin_path, name: selection.name }] }
          : { instrument: { name: selection.name, is_instrument: true } }
        return { promise: Promise.resolve(result), cancel() {} }
      } })
    await picker.open()
    picker.view.cursor = 1 // The VST, not the explicit SoundFont choice.
    await picker.choose()
    assert.equal(chosen.length, 0)
    assert.deepEqual(requests[1], { operation: 'inspect', plugin_path: selection.plugin_path, plugin_name: null })
    await picker.choose()
    assert.deepEqual(chosen, [selection])
    assert.deepEqual(await loadSelection(directory), selection)
    assert.equal(soundfonts, 0)
    assert.deepEqual(failures, [])
  })
})

test('failed VST load preserves the choice and never calls the SoundFont player', async () => {
  await temporary(async directory => {
    let played = 0, soundfonts = 0
    const failures = []
    const picker = new InstrumentPicker({ directory, notify() {}, selected: () => played++,
      soundfont: () => soundfonts++, failed: error => failures.push(error),
      run(request) { return { cancel() {}, promise: request.operation === 'candidates'
        ? Promise.resolve({ candidates: [{ path: selection.plugin_path, name: selection.name }] })
        : Promise.reject(new Error('license unavailable')) } } })
    await picker.open()
    picker.view.cursor = 1
    await picker.choose()
    assert.equal(picker.items()[picker.view.cursor].plugin_path, selection.plugin_path)
    assert.equal(played, 0)
    assert.equal(soundfonts, 0)
    assert.equal(failures.length, 1)
    assert.equal(await loadSelection(directory), null)
  })
})

test('closing a pending catalog retires its late reply', async () => {
  await temporary(async directory => {
    let finish, started
    const running = new Promise(resolve => { started = resolve })
    let cancelled = false
    const picker = new InstrumentPicker({ directory, notify() {}, selected() { assert.fail('unexpected playback') },
      soundfont() { assert.fail('unexpected fallback') }, failed() { assert.fail('retired load failed visibly') },
      run() {
        started()
        return { promise: new Promise(resolve => { finish = resolve }), cancel() { cancelled = true } }
      } })
    const opening = picker.open()
    await running
    picker.close()
    finish({ candidates: [{ path: selection.plugin_path, name: selection.name }] })
    await opening
    assert.equal(cancelled, true)
    assert.equal(picker.view, null)
  })
})

test('retained render and Lane snapshot outlive temporary playback files', async () => {
  await temporary(async directory => {
    const wav = join(directory, 'temporary.wav'), midi = join(directory, 'temporary.mid')
    await writeFile(wav, Buffer.from([1, 2, 3]))
    await writeFile(midi, Buffer.from([4, 5, 6]))
    const render = { output_path: wav, wav_sha256: 'a'.repeat(64), midi_sha256: 'b'.repeat(64) }
    const saved = await retainRender(join(directory, 'state'), render, midi)
    await rm(wav)
    await rm(midi)
    assert.deepEqual([...await readFile(saved.result.output_path)], [1, 2, 3])
    assert.deepEqual([...await readFile(saved.result.midi_path)], [4, 5, 6])
    const record = snapshotWriter(join(directory, 'state'))
    await Promise.all([record({ state: 'rendered', render: saved.result }), record({ state: 'player_started', render: saved.result })])
    const snapshot = JSON.parse(await readFile(join(directory, 'state', 'snapshot.json'), 'utf8'))
    assert.equal(snapshot.cursor, '2')
    assert.equal(snapshot.observations[0].fields.state, 'player_started')
    assert.equal(snapshot.observations[0].evidence.length, 2)
    assert.equal(snapshot.observations[0].evidence[0].sha256, render.wav_sha256)
  })
})

test('rapid editor requests launch once and closing waits for that child', async () => {
  await temporary(async directory => {
    let started, rejectJob, edits = 0, cancelled = 0
    const running = new Promise(resolve => { started = resolve })
    const picker = new InstrumentPicker({ directory, notify() {}, selected() {}, soundfont() {},
      failed() { assert.fail('cancelled editor must not report a load failure') },
      run(request) {
        assert.equal(request.operation, 'edit')
        edits++
        started()
        return { promise: new Promise((_, reject) => { rejectJob = reject }),
          cancel() { cancelled++; rejectJob(new Error('cancelled')) } }
      } })
    picker.view = { kind: 'presets', instrument: selection,
      items: [{ name: 'Default', preset_path: null }], cursor: 0, query: '' }
    const first = picker.edit(), second = picker.edit()
    await running
    assert.equal(edits, 1)
    picker.close()
    await Promise.all([first, second, picker.settled()])
    assert.equal(cancelled, 1)
    assert.equal(picker.view, null)
  })
})

test('a bundle restores the exact recent sub-instrument and preset', async () => {
  await temporary(async directory => {
    const recent = { ...selection, plugin_name: 'Second', name: 'Second', preset_path: '/chosen.vstpreset' }
    await saveSelection(directory, recent)
    const chosen = []
    const picker = new InstrumentPicker({ directory, notify() {}, selected: value => chosen.push(value),
      soundfont() { assert.fail('unexpected substitution') }, failed(error) { assert.fail(error.message) },
      run(request) { return { cancel() {}, promise: Promise.resolve(request.operation === 'candidates'
        ? { candidates: [{ path: selection.plugin_path, name: 'Bundle' }] }
        : request.plugin_name === null ? { plugin_names: ['First', 'Second'] }
          : { instrument: { name: request.plugin_name, is_instrument: true } }) } } })
    await picker.open()
    await picker.choose()
    assert.equal(picker.items()[picker.view.cursor].plugin_name, 'Second')
    await picker.choose()
    assert.equal(picker.items()[picker.view.cursor].preset_path, recent.preset_path)
    await picker.choose()
    assert.deepEqual(chosen, [recent])
  })
})
