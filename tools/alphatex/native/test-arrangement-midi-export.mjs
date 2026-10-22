// End-to-end file decisions through the production native source-state projector.
// No MIDI device, plug-in or terminal layout is involved.
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { mkdtemp, readFile, writeFile, readdir, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createHash } from 'node:crypto'
import JZZ from 'jzz'
import SMF from 'jzz-midi-smf'
import { newArrangement, editArrangement } from '../arrangement.mjs'
import { encodeMidiFile, importMidiSource, midiSourcePattern, exportMidiSource } from '../midi-source.mjs'
import { exportArrangementMidi } from '../arrangement-midi-export.mjs'
import { prepareArrangementMidiParts } from '../arrangement-vst.mjs'

SMF(JZZ)
const exec = promisify(execFile), native = dirname(fileURLToPath(import.meta.url))
const owned = !process.argv[2], root = owned ? await mkdtemp(join(tmpdir(), 'masc-midi-export-')) : process.argv[2]
const executable = join(root, 'music-midi'), observations = []
try {
  await exec('xcrun', ['swiftc', '-parse-as-library', '-O', join(native, 'MidiTransport.swift'),
    join(native, 'MidiRenderProjection.swift'), '-o', executable, '-framework', 'CoreMIDI'])
  const channel = (tick, bytes) => ({ tick, kind: 'channel', bytes })
  const meta = (tick, type, data) => ({ tick, kind: 'meta', type, data })
  const original = await encodeMidiFile({ division: 1001, tracks: [[
    meta(0, 0x51, [7, 0xa1, 0x20]), meta(0, 0x21, [3]),
    channel(0, [0xb0, 7, 90]), channel(0, [0xe0, 0, 65]), channel(0, [0xd0, 0]),
    channel(20, [0x90, 60, 90]), channel(30, [0xb0, 64, 127]),
    meta(100, 5, [...Buffer.from('한글 lyric')]),
    channel(100, [0x80, 60, 45]), channel(100, [0x90, 62, 80]), channel(100, [0x80, 62, 31]),
    channel(100, [0xd0, 5]), meta(101, 0x7f, [0, 255, 127]),
    channel(200, [0x90, 64, 70]), channel(400, [0x80, 64, 99]), meta(500, 0x2f, [])
  ]] })
  const source = importMidiSource(original), before = Buffer.from(exportMidiSource(source))
  let project = editArrangement(newArrangement({ title: 'Export proof', tempo: 123 }), { kind: 'asset-add', asset: { id: 'source', kind: 'midi', name: 'Expressive', source } })
  project = editArrangement(project, { kind: 'lane-add', name: 'Keys', sourceKind: 'midi' })
  project = editArrangement(project, { kind: 'region-add', lane: 'lane-1', asset: 'source', name: 'Trim/repeat', position: 960, offset: 100, extent: 300, repeat: 3 })
  project = editArrangement(project, { kind: 'region-add', lane: 'lane-1', asset: 'source', name: 'Overlap', position: 1200, offset: 100, extent: 300, repeat: 1 })
  const authored = structuredClone(project), target = join(root, 'song.mid')
  const receipt = await exportArrangementMidi(project, target, { directory: root, executable })
  const bytes = await readFile(target), parsed = new JZZ.MIDI.SMF(bytes)
  const performance = midiSourcePattern(importMidiSource(bytes))
  assert.equal(parsed.type, 1); assert.equal(parsed.ppqn, 32767)
  assert.equal(parsed.ntrk, 3)
  assert.deepEqual(receipt.ports.map(port => [port.sourcePort, port.exportPort]), [[3, 0], [3, 1]])
  assert.ok(receipt.maxTimingErrorNanoseconds <= receipt.microseconds * 1000 / 32767 / 2)
  const tolerance = receipt.microseconds / 32767 / 2e6 + 1e-9
  assert.ok(Math.abs(performance.seconds - (60 / 123 + 450 / 1001)) <= tolerance)
  const firstNote = performance.events.find(event => event.kind === 'channel' && event.bytes[0] === 0x90)
  assert.ok(Math.abs(firstNote.seconds - 60 / 123) <= tolerance)
  for (const [port, copies] of [[0, 3], [1, 1]]) {
    const events = performance.events.filter(event => event.kind === 'channel' && event.port === port)
    for (const message of [[0xb0,7,90], [0xe0,0,65], [0xb0,64,127], [0x90,60,90], [0x80,60,45], [0x90,62,80], [0x80,62,31]]) {
      assert.equal(events.filter(event => JSON.stringify(event.bytes) === JSON.stringify(message)).length, copies)
    }
    const short = events.filter(event => event.bytes[1] === 62)
    for (let copy = 0; copy < copies; copy++) assert.deepEqual(short.slice(copy * 2, copy * 2 + 2).map(event => event.bytes), [[0x90,62,80],[0x80,62,31]])
    assert.equal(events.filter(event => JSON.stringify(event.bytes) === JSON.stringify([0x80,64,0])).length, copies)
    assert.equal(events.filter(event => JSON.stringify(event.bytes) === JSON.stringify([0xb0,64,0])).length, copies)
    assert.ok(!events.some(event => event.bytes[0] === 0x80 && event.bytes[1] === 64 && event.bytes[2] === 99))
  }
  assert.equal(performance.events.filter(event => event.kind === 'meta' && event.type === 5).length, 4)
  const provenance = parsed.find(chunk => chunk.type === 'MASC')
  const retained = JSON.parse(Buffer.from(provenance.data, 'latin1').toString('utf8'))
  assert.deepEqual(retained.project, project)
  assert.deepEqual(Buffer.from(exportMidiSource(retained.project.assets[0].source)), original)
  assert.deepEqual(Buffer.from(exportMidiSource(source)), before); assert.deepEqual(project, authored)
  assert.equal((await stat(target)).mode & 0o777, 0o600)
  observations.push({ case: 'trim-repeat-overlap-expression-provenance', receipt, sha256: createHash('sha256').update(bytes).digest('hex') })

  // Loop/practice are audition choices; the exported document is linear.
  const audition = editArrangement(editArrangement(project, { kind: 'loop', range: { start: 960, end: 1920 } }),
    { kind: 'practice', practice: { countInBars: 1, metronome: true } })
  await exportArrangementMidi(audition, join(root, 'linear.mid'), { directory: root, executable })
  assert.deepEqual(await readFile(join(root, 'linear.mid')), bytes)
  observations.push({ case: 'loop-and-practice-independent' })

  // Existing targets are never replaced and cancellation drains preparation.
  await assert.rejects(exportArrangementMidi(project, target, { directory: root, executable }), { code: 'EEXIST' })
  assert.deepEqual(await readFile(target), bytes)
  const controller = new AbortController()
  await assert.rejects(exportArrangementMidi(project, join(root, 'cancel.mid'), { directory: root, executable,
    signal: controller.signal, async prepare(value, options) {
      const result = await prepareArrangementMidiParts(value, options)
      controller.abort(); return result
    } }), { name: 'AbortError' })
  assert.ok(!(await readdir(root)).some(name => name.startsWith('midi-export-') || name.startsWith('.masc-midi-export-') || name === 'cancel.mid'))
  observations.push({ case: 'existing-file-and-cancel-cleanup' })

  const make = (bytes, extent, pattern) => {
    let value = editArrangement(newArrangement({ tempo: 111 }), { kind: 'asset-add', asset: { id: 'original', kind: 'midi', name: 'Original', source: importMidiSource(bytes) } })
    value = editArrangement(value, { kind: 'lane-add', sourceKind: 'midi', name: 'Imported' })
    return editArrangement(value, { kind: 'region-add', lane: 'lane-1', asset: 'original', name: 'Pattern', position: 0, offset: 0, extent, repeat: 1, ...(pattern === undefined ? {} : { pattern }) })
  }
  // Real native system messages must survive SMF's F7 escape encoding.
  const systems = await encodeMidiFile({ division: 1001, tracks: [[
    { tick: 0, kind: 'sysex', status: 0xf0, data: [1, 2, 0xf7] },
    channel(0, [0x90, 60, 90]), { tick: 100, kind: 'sysex', status: 0xf7, data: [0xf8] },
    meta(200, 0x51, [15, 0x42, 0x40]), channel(500, [0x80, 60, 47]), meta(1001, 0x2f, [])
  ]] })
  const systemsProject = make(systems, 1001)
  await exportArrangementMidi(systemsProject, join(root, 'system.mid'), { directory: root, executable })
  const systemPerformance = midiSourcePattern(importMidiSource(await readFile(join(root, 'system.mid'))))
  assert.deepEqual(systemPerformance.events.filter(event => event.kind === 'sysex').map(event => [event.status, event.data]), [[0xf0,[1,2,0xf7]],[0xf7,[0xf8]]])
  const release = systemPerformance.events.find(event => event.kind === 'channel' && event.bytes[0] === 0x80)
  assert.ok(Math.abs(release.seconds - (200 * .5 + 300) / 1001) < 1 / 32767)
  observations.push({ case: 'sysex-realtime-tempo-map', noteOffSeconds: release.seconds })

  const patterns = await encodeMidiFile({ division: 480, tracks: [[channel(0,[0x90,60,90]),channel(480,[0x80,60,0]),meta(480,0x2f,[])],
    [channel(0,[0x91,67,90]),channel(480,[0x81,67,55]),meta(480,0x2f,[])]] })
  patterns.writeUInt16BE(2, 8); patterns.writeUInt16BE(0xe350, 12) // 29.97 drop-frame, 80 ticks/frame
  const independent = make(patterns, 480, 1)
  await exportArrangementMidi(independent, join(root, 'smpte.mid'), { directory: root, executable })
  const smpte = midiSourcePattern(importMidiSource(await readFile(join(root, 'smpte.mid'))))
  assert.ok(Math.abs(smpte.seconds - 480 * 1001 / (30000 * 80)) < 1 / 32767)
  assert.deepEqual(smpte.notes.map(note => note.pitch), [67])
  observations.push({ case: 'explicit-smf2-drop-frame-pattern', seconds: smpte.seconds })

  const longRest = editArrangement(independent, { kind: 'region-change', id: 'region-1', position: 10_000_000 })
  await exportArrangementMidi(longRest, join(root, 'rest.mid'), { directory: root, executable })
  const rest = midiSourcePattern(importMidiSource(await readFile(join(root, 'rest.mid'))))
  assert.ok(rest.notes[0].start > 0x0fffffff)
  assert.ok(Math.abs(rest.notes[0].seconds - 10_000_000 / 960 * 60 / 111) < 1 / 32767)
  observations.push({ case: 'rest-beyond-four-byte-delta', ticks: rest.notes[0].start })

  let withAudio = editArrangement(project, { kind: 'asset-add', asset: { id: 'wave', kind: 'wave', name: 'Audio',
    file: `assets/${'a'.repeat(64)}.wav`, sha256: 'a'.repeat(64),
    metadata: { encoding: 'pcm', channels: 1, sampleRate: 48000, bitsPerSample: 16, validBits: 16, blockAlign: 2, frames: 48000 } } })
  withAudio = editArrangement(withAudio, { kind: 'lane-add', name: 'Audio', sourceKind: 'wave' })
  withAudio = editArrangement(withAudio, { kind: 'region-add', lane: 'lane-2', asset: 'wave', name: 'Backing', position: 0, offset: 0, extent: 48000, repeat: 1 })
  const audioReceipt = await exportArrangementMidi(withAudio, join(root, 'with-audio.mid'), { directory: root, executable })
  assert.deepEqual(audioReceipt.excludedAudioRegions, ['region-3'])
  assert.equal(audioReceipt.tracks, 2)
  assert.ok(Math.abs(midiSourcePattern(importMidiSource(await readFile(join(root, 'with-audio.mid')))).seconds - 1) < 1 / 32767)
  const solo = editArrangement(withAudio, { kind: 'lane-solo', id: 'lane-2' })
  await assert.rejects(exportArrangementMidi(solo, join(root, 'solo.mid'), { directory: root, executable }))
  assert.ok(!(await readdir(root)).includes('solo.mid'))
  observations.push({ case: 'audio-exclusion-horizon-and-audible-solo-selection' })

  await assert.rejects(exportArrangementMidi(project, join(root, 'changed.mid'), { directory: root, executable,
    async prepare(value, options) {
      const result = await prepareArrangementMidiParts(value, options)
      await writeFile(result.parts[0].path, 'changed projection')
      return result
    } }))
  assert.ok(!(await readdir(root)).some(name => name.startsWith('midi-export-') || name.startsWith('.masc-midi-export-') || name === 'changed.mid'))
  observations.push({ case: 'projection-hash-refusal-cleanup' })
  await writeFile(join(root, 'project.json'), JSON.stringify(project))
  await writeFile(join(root, 'verification.json'), JSON.stringify({ passed: observations.length, observations }, null, 2))
  console.log(JSON.stringify({ passed: observations.length, root }))
} finally { if (owned) await rm(root, { recursive: true, force: true }) }
