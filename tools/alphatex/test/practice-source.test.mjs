import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, readFile, writeFile, stat, chmod, rm, readdir } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { once } from 'node:events'
import { Worker } from 'node:worker_threads'
import { newProject } from '../sequencer-project.mjs'
import { phraseBacking } from '../phrase-backing.mjs'
import { nominalMidiFrame } from '../render-midi-clock.mjs'
import { newArrangement, arrangementSchedule } from '../arrangement.mjs'
import { arrangementEditor, arrangementCommand, arrangementImported } from '../arrangement-editor.mjs'
import { practicePartNames, practiceRange, practiceRegionTime } from '../practice-source.mjs'
import { readPracticeFiles } from '../practice-source-files.mjs'
import { importArrangementPractice, saveArrangement, loadArrangement, prepareArrangementPractice, verifyArrangementAssets } from '../arrangement-files.mjs'
import { arrangementRoute, selectArrangementRoute, arrangementPlaybackRequest, prepareArrangementCaptureRegions, prepareArrangementAudio } from '../arrangement-playback.mjs'
import { projectNanoseconds, fraction } from '../exact-time.mjs'

const hash = bytes => createHash('sha256').update(bytes).digest('hex')
const json = async path => JSON.parse(await readFile(path, 'utf8'))
async function fixture(run) {
  const root = await mkdtemp(join(tmpdir(), 'masc-practice-source-')), input = join(root, 'Original take')
  try {
    await mkdir(input, { mode: 0o700 })
    const preset = Buffer.from('private fixture preset'), project = { ...newProject(), sound: {
      kind: 'vst', selection: { plugin_path: '/fixture.vst3', plugin_name: null, preset_path: null, name: 'Fixture' },
      instrument: { identifier: 'fixture-id', version: '1' }, preset: { data: preset.toString('base64'), sha256: hash(preset) } } }
    const context = { schemaVersion: 1, kind: 'practice-take-context', project, track: 'track-1', backing: phraseBacking(project, 'track-1', true) }
    const renderClock = { schemaVersion: 1, kind: 'clock', device: { id: 'owned', name: 'Output' }, sampleRate: 48000,
      clock: { kind: 'mach-host-time', numer: 125, denom: 3 }, anchor: { frame: '0', hostTime: '18446744073709000000' } }
    const arm = { schemaVersion: 1, kind: 'practice-take-arm', renderClock,
      input: { schemaVersion: 1, kind: 'midi-input', protocol: 2, source: { id: '10', name: 'Keys' }, clock: renderClock.clock } }
    const rows = [[2400n, [0x43953c03, 0x90012345]], [-1n, [0x43b54a00, 0xabcdef01]], [24000n, [0x43853c00, 0x12340000]]].map(([delta, words], i) => {
      const packet = { kind: 'midi', protocol: 2, source: '10', ordinal: String(i), hostTime: String(BigInt(renderClock.anchor.hostTime) + delta), timestampOrigin: 'packet', words }
      return { packet, nominalFrame: nominalMidiFrame(packet.hostTime, arm.input.clock, renderClock) }
    })
    const receipt = { schemaVersion: 1, kind: 'practice-take', status: 'complete', error: null, packets: '3', files: {},
      inputFinal: { kind: 'stopped', source: '10', success: true, error: null, admittedPackets: '3', acknowledgedPackets: '3', discardedPackets: '0', pendingWords: 0 },
      monitorFinal: { schemaVersion: 1, kind: 'step-monitor', channel: context.backing.channel,
        sound: { identifier: 'fixture-id', version: '1', presetSHA256: project.sound.preset.sha256 },
        pcm: { clock: renderClock, device: renderClock.device, format: { sampleRate: 48000 }, nativeClosed: true, settled: true, playing: true,
          nativeError: null, receiptError: null, failure: null, sentFrames: '5824',
          final: { kind: 'stopped', success: true, admittedFrames: '5824', renderedFrames: '4800', discardedFrames: '1024', underrunFrames: '0', fault: 'none', faultFrames: '0' } },
        worker: { closed: true, terminalReceived: true, failure: null } } }
    const files = Object.fromEntries(Object.entries(practicePartNames).map(([role, name]) => [role, join(input, name)]))
    const publish = async () => {
      const bytes = { context: JSON.stringify(context), arm: JSON.stringify(arm), events: rows.map(row => JSON.stringify(row)).join('\n') + '\n' }
      for (const role of ['context', 'arm', 'events']) {
        await writeFile(files[role], bytes[role], { mode: 0o600 }); receipt.files[role] = { file: practicePartNames[role], sha256: hash(bytes[role]) }
      }
      await writeFile(files.receipt, JSON.stringify(receipt), { mode: 0o600 })
    }
    await publish()
    await run({ root, input, files, context, arm, rows, receipt, publish })
  } finally { await rm(root, { recursive: true, force: true }) }
}

test('practice import owns private original bytes, exact pre-anchor/out-of-order UMP and portable clock provenance', async () => fixture(async ({ root, input, files, rows }) => {
  const path = join(root, 'project', 'song.json'), imported = await importArrangementPractice(newArrangement(), input, { projectPath: path }), asset = imported.project.assets[0]
  assert.equal(asset.kind, 'practice'); assert.equal(asset.metadata.packets, '3')
  assert.deepEqual(rows[1].nominalFrame, { numerator: '-1', denominator: '500' })
  assert.deepEqual(asset.metadata.midiTime, { first: rows[1].packet.hostTime, last: rows[2].packet.hostTime })
  const originals = {}
  for (const [role, part] of Object.entries(asset.parts)) {
    originals[role] = await readFile(files[role]); const owned = join(dirname(path), part.file), info = await stat(owned)
    assert.deepEqual(await readFile(owned), originals[role]); assert.equal(info.mode & 0o377, 0)
    assert.notEqual(info.ino, (await stat(files[role])).ino)
  }
  await saveArrangement(path, imported.project); await rm(input, { recursive: true })
  const loaded = await loadArrangement(path), target = join(root, 'moved', 'song.json')
  await saveArrangement(target, loaded.project, null, { sourceRoot: dirname(path) }); await rm(dirname(path), { recursive: true })
  const moved = await loadArrangement(target); assert.deepEqual(moved.project, imported.project)
  const snapshot = await prepareArrangementPractice(moved.project, asset.id, { sourceRoot: dirname(target), directory: root })
  for (const [role, name] of Object.entries(practicePartNames)) {
    const file = join(snapshot.directory, name)
    assert.deepEqual(await readFile(file), originals[role]); assert.equal((await stat(file)).mode & 0o377, 0)
  }
  const changed = join(dirname(target), asset.parts.events.file); await chmod(changed, 0o600); await writeFile(changed, '{}\n')
  assert.deepEqual(await readFile(join(snapshot.directory, 'events.jsonl')), originals.events)
  await assert.rejects(verifyArrangementAssets(moved.project, dirname(target)))
  await assert.rejects(prepareArrangementPractice(moved.project, asset.id, { sourceRoot: dirname(target), directory: root }))
}))

test('worker/controller import, native-tick edits and undo-retained save-as preserve a practice source', async () => fixture(async ({ root, input }) => {
  const worker = new Worker(new URL('../arrangement-worker.mjs', import.meta.url)); let id = 0
  const request = async job => {
    const response = once(worker, 'message'); worker.postMessage({ ...job, id: ++id })
    const [message] = await response; assert.equal(message.ok, true, message.error); return message.result
  }
  try {
    const path = join(root, 'old', 'song.json'), start = arrangementEditor(newArrangement({ tempo: 120 }))
    const effect = arrangementCommand(start, `import-practice ${input}`).effect
    assert.deepEqual(effect, { kind: 'import-practice', path: input })
    const imported = await request({ ...effect, project: start.project, projectPath: path })
    let editor = arrangementImported(start, imported)
    const command = line => { editor = arrangementCommand(editor, line).editor }
    command('place asset-1 4'); assert.equal(editor.project.lanes[0].kind, 'practice')
    assert.equal(editor.project.clips[0].extent, '2400001'); assert.equal(arrangementSchedule(editor.project)[0].sourceClock.origin, '18446744073708999999')
    command('trim 1 48000'); command('repeat 2000000'); command('move 8')
    assert.deepEqual(editor.project.clips.map(clip => [clip.position, clip.offset, clip.extent, clip.repeat]), [[7680, '1', '48000', 2000000]])
    const edited = editor.project; command('undo'); command('redo'); assert.deepEqual(editor.project, edited)
    for (const line of ['trim 01 2', 'trim -1 2', 'trim 0 0', 'region asset-1 0 0 2400002', 'place asset-1 0 1', 'split-take']) assert.throws(() => arrangementCommand(editor, line))
    while (editor.undo.length) command('undo')
    assert.equal(editor.project.assets.length, 0)
    const target = join(root, 'new', 'song.json')
    const revision = await request({ kind: 'save', project: editor.project, path: target, revision: null, sourceRoot: dirname(path), retainedAssets: imported.project.assets })
    await rm(input, { recursive: true }); await rm(dirname(path), { recursive: true })
    command('redo'); assert.deepEqual(editor.project.assets, imported.project.assets)
    await request({ kind: 'save', project: editor.project, path: target, revision, sourceRoot: dirname(target) })
    assert.deepEqual((await loadArrangement(target)).project, editor.project)
  } finally { await worker.terminate() }
}))

test('raw native plan retains UInt64 timestamps, packet order, high-resolution words and private source snapshots', async () => fixture(async ({ root, input, rows }) => {
  const path = join(root, 'project', 'song.json'), imported = await importArrangementPractice(newArrangement(), input, { projectPath: path })
  const editor = arrangementCommand(arrangementEditor(imported.project), 'place asset-1 0').editor, project = editor.project
  let route = selectArrangementRoute(arrangementRoute(), arrangementCommand(editor, 'mixed-output owned').effect)
  const effect = arrangementCommand(editor, 'midi-source asset-1 10 42').effect
  route = selectArrangementRoute(route, effect)
  const request = arrangementPlaybackRequest(project, route)
  assert.deepEqual(request, { kind: 'prepare-capture', output: 'owned', midiOutput: undefined, sourceBindings: [{ asset: 'asset-1', source: '10', destination: '42' }] })
  assert.throws(() => arrangementPlaybackRequest(project, arrangementRoute()))
  await assert.rejects(prepareArrangementAudio(project, { sourceRoot: dirname(path), directory: root }), /MIDI/)
  await assert.rejects(prepareArrangementCaptureRegions(project, { sourceRoot: dirname(path), directory: root }), /destination/)
  const prepared = await prepareArrangementCaptureRegions(project, { ...request, sourceRoot: dirname(path), directory: root }), plan = await json(prepared.path)
  assert.equal(prepared.format, 'capture-arrangement'); assert.equal(plan.schemaVersion, 5)
  assert.deepEqual(plan.assets, []); assert.deepEqual(plan.regions, [])
  assert.deepEqual(plan.umpRegions.sources[0].timeline.packets, rows.map(row => row.packet))
  assert.equal(plan.umpRegions.sources[0].timeline.clock.origin, rows[1].packet.hostTime)
  assert.equal(plan.umpRegions.regions[0].extent, '2400001'); assert.deepEqual(prepared.bindings, [{ port: 0, destination: '42' }])
  assert.deepEqual(project, editor.project)
}))

test('internally inconsistent, incomplete, corrupt and failed receipts cannot be imported even with freshly matching hashes', async () => fixture(async ({ root, input, files, receipt, rows, arm, context, publish }) => {
  const path = join(root, 'project', 'song.json'), baseline = structuredClone({ receipt, rows, arm, context })
  const mutations = [
    () => { receipt.status = 'failed' }, () => { receipt.error = 'late failure' }, () => { receipt.packets = '2' },
    () => { receipt.inputFinal.acknowledgedPackets = '2' }, () => { receipt.inputFinal.pendingWords = 1 },
    () => { receipt.monitorFinal.worker.closed = false }, () => { receipt.monitorFinal.pcm.final.underrunFrames = '1' },
    () => { receipt.monitorFinal.pcm.final.renderedFrames = '4799' }, () => { receipt.monitorFinal.sound.version = '2' },
    () => { rows[0].packet.hostTime = '18446744073709551616' }, () => { rows[0].packet.ordinal = '1' },
    () => { rows[0].packet.source = '11' }, () => { rows[0].packet.words = [] },
    () => { rows[1].nominalFrame.numerator = '0' }, () => { arm.input.protocol = 1 },
    () => { context.backing.channel = 15 }, () => { receipt.files.extra = {} },
  ]
  for (const mutate of mutations) {
    Object.assign(receipt, structuredClone(baseline.receipt)); rows.splice(0, rows.length, ...structuredClone(baseline.rows))
    Object.assign(arm, structuredClone(baseline.arm)); Object.assign(context, structuredClone(baseline.context))
    mutate(); await publish()
    await assert.rejects(importArrangementPractice(newArrangement(), input, { projectPath: path }))
    assert.ok((await readdir(join(dirname(path), 'assets'))).every(file => !file.startsWith('.import-')))
  }
  Object.assign(receipt, structuredClone(baseline.receipt)); rows.splice(0, rows.length, ...structuredClone(baseline.rows)); Object.assign(arm, structuredClone(baseline.arm)); Object.assign(context, structuredClone(baseline.context))
  await publish(); await writeFile(files.events, '{}\n')
  await assert.rejects(readPracticeFiles(files))
  await rm(files.receipt); await assert.rejects(importArrangementPractice(newArrangement(), input, { projectPath: path }), { code: 'ENOENT' })
  const controller = new AbortController(); controller.abort()
  await assert.rejects(importArrangementPractice(newArrangement(), input, { projectPath: path, signal: controller.signal }), { name: 'AbortError' })
}))

test('native region span may exceed UInt64 without converting absolute hosts to Number', async () => fixture(async ({ files }) => {
  const { metadata } = await readPracticeFiles(files)
  metadata.renderClock.anchor.hostTime = '1'; metadata.renderedFrames = '18446744073709551615'
  metadata.renderClock.sampleRate = 1; metadata.renderClock.clock = { kind: 'mach-host-time', numer: 1, denom: 1 }; metadata.input.clock = metadata.renderClock.clock
  const asset = { metadata }, range = practiceRange(asset)
  assert.ok(BigInt(range.extent) > 0xffffffffffffffffn)
  assert.equal(practiceRegionTime(asset, { offset: '0', extent: range.extent }).sourceClock.extent, range.extent)
}))

test('empty takes, changed receipt bytes, stale hashes and public preset copies cannot enter an arrangement', async () => fixture(async ({ root, input, files, rows, receipt, publish }) => {
  const path = join(root, 'project', 'song.json')
  await writeFile(files.context, '{}')
  await assert.rejects(importArrangementPractice(newArrangement(), input, { projectPath: path }))
  await publish()
  const imported = await importArrangementPractice(newArrangement(), input, { projectPath: path }), asset = imported.project.assets[0]
  const owned = join(dirname(path), asset.parts.context.file)
  await chmod(owned, 0o444)
  await assert.rejects(verifyArrangementAssets(imported.project, dirname(path)), /private/)
  await chmod(owned, 0o400)
  const receiptFile = join(dirname(path), asset.parts.receipt.file)
  await chmod(receiptFile, 0o600); await writeFile(receiptFile, JSON.stringify({ ...receipt, added: 'changed receipt' }))
  await assert.rejects(verifyArrangementAssets(imported.project, dirname(path)), /changed/)
  rows.splice(0); receipt.packets = '0'; receipt.inputFinal.admittedPackets = '0'; receipt.inputFinal.acknowledgedPackets = '0'
  await publish()
  // A zero-packet recording is a valid retained take, but has no region to play.
  await writeFile(files.events, '')
  receipt.files.events.sha256 = hash(''); await writeFile(files.receipt, JSON.stringify(receipt))
  assert.equal((await readPracticeFiles(files)).metadata.packets, '0')
  await assert.rejects(importArrangementPractice(newArrangement(), input, { projectPath: join(root, 'empty', 'song.json') }), /no MIDI packets/)
}))

test('fractional-tempo practice placement preserves the native exact loop entry and outward final horizon', async () => fixture(async ({ root, input, rows, publish }) => {
  // A same-tick On/Off pair must be delivered, not reconstructed as empty
  // history when a binary64 placement falls just before the loop origin.
  rows[1].packet.words = [0x43953c00, 0x80000000, 0x43853c00, 0]
  await publish()
  const path = join(root, 'project', 'song.json'), imported = await importArrangementPractice(newArrangement({ tempo: 120.1 }), input, { projectPath: path })
  let editor = arrangementCommand(arrangementEditor(imported.project), 'region asset-1 .5 0 48000 3').editor
  editor = arrangementCommand(editor, 'loop .5 1.5').editor
  const prepared = await prepareArrangementCaptureRegions(editor.project, { sourceRoot: dirname(path), directory: root, midiOutput: '42' }), plan = await json(prepared.path)
  const region = plan.umpRegions.regions[0], start = fraction(...projectNanoseconds(editor.project, 480))
  assert.deepEqual(region.startNanoseconds, start)
  assert.equal(region.offset, '0'); assert.equal(region.extent, '48000'); assert.equal(region.repeatCount, 3)
  assert.deepEqual(plan.umpRegions.sources[0].timeline.packets, rows.map(row => row.packet))
  // The one-shot source horizon must enclose the exact final native boundary.
  const n = BigInt(start.numerator) + 3n * 48000n * 125n * BigInt(start.denominator) / 3n, d = BigInt(start.denominator)
  const horizon = BigInt(Math.round(plan.umpRegions.duration * 1e9))
  assert.ok(horizon * d >= n); assert.ok((horizon - 1n) * d < n)
}))
