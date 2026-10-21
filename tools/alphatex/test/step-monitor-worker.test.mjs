import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, copyFile, symlink, writeFile, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, dirname, delimiter } from 'node:path'
import { pathToFileURL, fileURLToPath } from 'node:url'
import { Worker } from 'node:worker_threads'
import { createHash } from 'node:crypto'
import { newProject } from '../sequencer-project.mjs'
import { phraseBacking } from '../phrase-backing.mjs'

const bytes = Buffer.from('worker-owned preset')
const sound = { kind: 'vst', selection: { plugin_path: '/fixture.vst3', plugin_name: null, preset_path: null, name: 'Fixture' },
  instrument: { identifier: 'fixture-id', version: '1' },
  preset: { data: bytes.toString('base64'), sha256: createHash('sha256').update(bytes).digest('hex') } }
const packet = words => ({ kind: 'midi', source: '10', protocol: 2, timestampOrigin: 'packet', words })
// Real workers and protocol children, with device demand on a child event loop.
// The fixture clock is a scheduling probe, not a hardware latency measurement.
async function runtime({ pcm = 'paced', vst = 'valid' } = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'monitor-worker-'))
  const trace = join(directory, 'events.jsonl'), workers = []
  for (const file of ['synth-stream.mjs', 'soundfont-stream.mjs', 'soundfont_stream.py', 'soundfont_host.py', 'step-monitor.mjs', 'step-monitor-worker.mjs', 'step-monitor-session.mjs',
    'render-midi-clock.mjs', 'exact-time.mjs', 'phrase-backing.mjs', 'sequencer-project.mjs', 'project-sound.mjs', 'pcm-output.mjs', 'vst-stream.mjs', 'session-data.mjs', 'wave-file.mjs']) {
    await copyFile(new URL(`../${file}`, import.meta.url), join(directory, file))
  }
  await symlink(fileURLToPath(new URL('../node_modules', import.meta.url)), join(directory, 'node_modules'), 'dir')
  for (const [name, fixture, mode] of [['music-pcm-output', 'pcm-output', pcm], ['masc-vst-host', 'vst-stream', vst]]) {
    const fixtureURL = new URL(`./fixtures/${fixture}.mjs`, import.meta.url).href
    await writeFile(join(directory, name), `#!/usr/bin/env node
import { appendFileSync } from 'node:fs'
const log = row => appendFileSync(${JSON.stringify(trace)}, JSON.stringify(row) + '\\n')
log({kind:'start',name:${JSON.stringify(name)},pid:process.pid})
process.on('exit', () => log({kind:'exit',name:${JSON.stringify(name)},pid:process.pid}))
let text = ''
process.stdin.on('data', chunk => {
  text += chunk
  let end
  while ((end=text.indexOf('\\n'))>=0) {
    const line=text.slice(0,end);text=text.slice(end+1)
    const row=JSON.parse(line)
    if(row.kind==='render') log({kind:'render',pid:process.pid,messages:row.messages})
    if(row.kind==='block') { const pcm=Buffer.from(row.pcm,'base64');log({kind:'pcm',samples:[pcm.readFloatLE(0),pcm.readFloatLE(4)]}) }
  }
})
process.argv.splice(2,0,${JSON.stringify(mode)})
await import(${JSON.stringify(fixtureURL)})
`, { mode: 0o755 })
  }
  const { openStepMonitor } = await import(pathToFileURL(join(directory, 'step-monitor.mjs')))
  return { directory, trace,
    open(options = {}) {
      return openStepMonitor({ sound, output: 'owned', channel: 2, ...options,
        createWorker(url, config) {
          const worker = new Worker(url, { ...config, env: { ...process.env,
            PATH: [directory, dirname(process.execPath), process.env.PATH].join(delimiter) } })
          const record = { worker, closed: false }; workers.push(record)
          worker.once('exit', () => { record.closed = true })
          return worker
        } })
    },
    async assertClosed() {
      assert.ok(workers.every(record => record.closed))
      const rows = (await readFile(trace, 'utf8')).trim().split('\n').map(JSON.parse)
      for (const child of rows.filter(row => row.kind === 'start')) {
        assert.throws(() => process.kill(child.pid, 0), error => error.code === 'ESRCH', `child ${child.name} is reaped`)
      }
      return rows
    },
    dispose: () => rm(directory, { recursive: true, force: true }),
  }
}

test('worker sustains demand during a blocked terminal and retains MIDI order and final joins', async () => {
  const fixture = await runtime(), owner = fixture.open()
  try {
    await owner.ready
    const clock = await owner.clock
    assert.equal(clock.anchor.hostTime, '9007199254740997')
    const sent = owner.send(owner.prepare(packet([0x40903c00, 0xa0000000])))
    await assert.rejects(owner.send(owner.prepare(packet([0x40904000, 0xa0000000]))), /pending monitor packet/)
    await sent
    const before = await owner.inspect()
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100)
    const a = owner.inspect(), b = owner.inspect()
    assert.equal(a, b) // one diagnostic request, not an unbounded query queue
    const after = await a
    assert.ok(BigInt(after.pcm.requestedBlocks) > BigInt(before.pcm.requestedBlocks))
    assert.equal(after.pcm.final, null)
    await owner.send(owner.prepare(packet([0x40803c00, 0])))
    owner.stop(); await owner.completion
    const report = owner.diagnostics()
    assert.equal(report.worker.closed, true); assert.equal(report.worker.terminalReceived, true)
    assert.equal(report.pcm.nativeClosed, true); assert.equal(report.pcm.settled, true)
    assert.equal(report.pcm.final.success, true)
    const rows = await fixture.assertClosed()
    assert.deepEqual(rows.filter(row => row.kind === 'render').flatMap(row => row.messages).map(row => row.bytes),
      [[0x92, 60, 80], [0x82, 60, 0]])
    report.pcm.device.id = 'caller mutation'
    assert.equal((await owner.inspect()).pcm.device.id, 'owned')
  } finally { owner.stop(); await owner.completion.catch(() => {}); await fixture.dispose() }
})

test('worker stop before ready joins children and cancellation preserves uncloneable caller causes', async () => {
  for (const reason of [null, false, 0, '', () => {}]) {
    const fixture = await runtime({ vst: 'wait-block' }), owner = fixture.open()
    try {
      // The PCM prepared observation proves child startup without requiring a
      // completed synth block or an audio-ready acknowledgement.
      while (!(await owner.inspect()).pcm?.device) await new Promise(resolve => setImmediate(resolve))
      owner.stop(); owner.cancel(reason)
      await assert.rejects(owner.completion, error => error.cause === reason)
      await assert.rejects(owner.ready)
      await fixture.assertClosed()
    } finally { owner.stop(); await owner.completion.catch(() => {}); await fixture.dispose() }
  }
})

test('one device worker combines live notes with absolute-frame backing across fractional loop boundaries', async () => {
  const project = newProject()
  project.tempo = 600000; project.length = 960; project.loop = { start: 0, end: 960 }
  project.tracks[0].channel = 2
  project.tracks[0].notes = [{ id: 'excluded', pitch: 99, start: 0, duration: 960, velocity: 100 }]
  project.tracks.push({ ...project.tracks[0], id: 'backing', channel: 1,
    notes: [{ id: 'bass', pitch: 48, start: 0, duration: 960, velocity: 80 }] })
  const fixture = await runtime(), owner = fixture.open({ backing: phraseBacking(project, 'track-1', true) })
  try {
    await owner.ready
    await owner.send(owner.prepare(packet([0x40903c00, 0xa0000000])))
    while (BigInt((await owner.inspect()).pcm.requestedBlocks) < 5n) await new Promise(resolve => setImmediate(resolve))
    await owner.send(owner.prepare(packet([0x40803c00, 0])))
    owner.stop(); await owner.completion
    const rows = await fixture.assertClosed(), renders = rows.filter(row => row.kind === 'render')
    const frames = new Map()
    const notes = renders.flatMap(row => {
      const start = frames.get(row.pid) ?? 0; frames.set(row.pid, start + 8)
      return row.messages.map(message => ({ ...message, pid: row.pid, at: start + message.frame }))
    })
    assert.deepEqual(notes.filter(row => row.bytes[0] === 0x91).slice(0, 7).map(row => row.at), [0, 5, 10, 14, 19, 24, 29])
    const boundary = notes.filter(row => row.at === 5 && (row.bytes[0] & 15) === 1 && row.bytes[1] === 48)
    assert.deepEqual(boundary.map(row => row.bytes[0]), [0x81, 0x91])
    assert.ok(notes.some(row => row.bytes[0] === 0x92 && row.bytes[1] === 60))
    assert.ok(notes.some(row => row.bytes[0] === 0x82 && row.bytes[1] === 60))
    assert.ok(notes.every(row => row.bytes[1] !== 99))
    assert.equal(owner.diagnostics().backing.channel, 2)
    assert.equal(owner.diagnostics().backing.instances, 2)
    assert.equal(owner.diagnostics().backing.peak, .5)
    assert.equal(owner.diagnostics().backing.clippedSamples, '0')
    assert.ok(rows.filter(row => row.kind === 'pcm').every(row => row.samples[0] === .5 && row.samples[1] === -.25))
    const live = notes.find(row => row.bytes[0] === 0x92 && row.bytes[1] === 60)
    const backing = notes.find(row => row.bytes[0] === 0x91 && row.bytes[1] === 48)
    assert.notEqual(live.pid, backing.pid)
    assert.equal(new Set(rows.filter(row => row.kind === 'start' && row.name === 'music-pcm-output').map(row => row.pid)).size, 1)
  } finally { owner.stop(); await owner.completion.catch(() => {}); await fixture.dispose() }
})

test('normal stop while the synth is opening retires children without requiring ready', async () => {
  const project = newProject()
  project.tracks[0].channel = 2
  project.tracks.push({ ...project.tracks[0], id: 'backing', channel: 1,
    notes: [{ id: 'bass', pitch: 48, start: 0, duration: 960, velocity: 80 }] })
  const fixture = await runtime({ vst: 'wait-block' }), owner = fixture.open({ backing: phraseBacking(project, 'track-1') })
  try {
    while ((await owner.inspect()).backing?.instances !== 2) await new Promise(resolve => setImmediate(resolve))
    owner.stop(); await owner.completion
    await assert.rejects(owner.ready)
    await fixture.assertClosed()
    assert.equal(owner.diagnostics().worker.terminalReceived, true)
    assert.equal(owner.diagnostics().backing.instances, 2)
  } finally { owner.stop(); await owner.completion.catch(() => {}); await fixture.dispose() }
})

test('practice synth failure joins every independent instance and its one output', async () => {
  const project = newProject()
  project.tracks[0].channel = 2
  project.tracks.push({ ...project.tracks[0], id: 'backing', channel: 1,
    notes: [{ id: 'bass', pitch: 48, start: 0, duration: 960, velocity: 80 }] })
  const fixture = await runtime({ vst: 'identity' }), owner = fixture.open({ backing: phraseBacking(project, 'track-1') })
  try {
    await assert.rejects(owner.ready); await assert.rejects(owner.completion)
    await fixture.assertClosed()
    assert.equal(owner.diagnostics().backing.instances, 2)
    assert.equal(owner.diagnostics().pcm.nativeClosed, true)
    assert.equal(owner.diagnostics().worker.terminalReceived, true)
  } finally { owner.stop(); await owner.completion.catch(() => {}); await fixture.dispose() }
})

test('unexpected worker exit is failure with unconfirmed native cleanup, never an invented final', async () => {
  const { openStepMonitor } = await import('../step-monitor.mjs')
  const owner = openStepMonitor({ sound, output: 'owned', channel: 0,
    createWorker() { return new Worker('process.exit(3)', { eval: true }) } })
  const inspected = owner.inspect()
  await assert.rejects(owner.completion, /without confirmed cleanup/)
  await assert.rejects(owner.ready)
  await assert.rejects(owner.clock)
  assert.equal((await inspected).worker.closed, true)
  assert.equal(owner.diagnostics().worker.terminalReceived, false)
  assert.equal(owner.diagnostics().pcm, null)
})

test('worker relays output/synth faults and closed child receipts', async () => {
  for (const mode of [{ pcm: 'identity' }, { pcm: 'fault-final' }, { vst: 'identity' }, { vst: 'crash' }]) {
    const fixture = await runtime(mode), owner = fixture.open()
    try {
      await owner.ready.catch(() => {})
      await assert.rejects(owner.completion)
      assert.equal(owner.diagnostics().worker.closed, true)
      assert.equal(owner.diagnostics().worker.terminalReceived, true)
      assert.equal(owner.diagnostics().pcm.nativeClosed, true)
      if (mode.pcm === 'fault-final') assert.equal(owner.diagnostics().pcm.final.fault, 'underrun')
      await fixture.assertClosed()
    } finally { owner.stop(); await owner.completion.catch(() => {}); await fixture.dispose() }
  }
})

test('actual FluidSynth runs inside the demand worker with independent live/backing voices', async () => {
  const { captureFluidSound } = await import('../soundfont.mjs')
  const selected = await captureFluidSound().promise, fixture = await runtime({ pcm: 'fluid' })
  const project = newProject()
  project.tracks.push({ ...structuredClone(project.tracks[0]), id: 'bass', name: 'Backing', channel: 1, program: 33,
    notes: [{ id: 'bass-1', pitch: 48, start: 0, duration: 960, velocity: 100 }] })
  const owner = fixture.open({ sound: selected, channel: 0, backing: phraseBacking(project, 'track-1', true),
    initial: [[0xc0,0],[0xb0,7,100],[0xb0,10,64],[0xc1,33],[0xb1,7,100],[0xb1,10,64]] })
  try {
    await owner.ready
    await owner.send(owner.prepare(packet([0x40903c00,0xa0000000])))
    await owner.send(owner.prepare(packet([0x40803c00,0])))
    const report = await owner.inspect()
    assert.equal(report.sound.kind,'soundfont')
    assert.equal(report.sound.fontSHA256,selected.font.sha256)
    assert.equal(report.sound.engine.controlFrames,selected.engine.controlFrames)
    assert.equal(report.backing.instances,2)
    owner.stop();await owner.completion
    const rows=await fixture.assertClosed()
    assert.ok(rows.some(row=>row.kind==='pcm'&&row.samples.some(value=>value!==0)))
    assert.equal(rows.filter(row=>row.kind==='start'&&row.name==='masc-vst-host').length,0)
    assert.equal(owner.diagnostics().worker.closed,true)
  } finally { owner.stop();await owner.completion.catch(()=>{});await fixture.dispose() }
})
