import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile, readFile, readdir, rm, chmod } from 'node:fs/promises'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { Worker } from 'node:worker_threads'
import { once } from 'node:events'
import JZZ from 'jzz'
import { newArrangement } from '../arrangement.mjs'
import { importArrangementCapture, importCaptureMidi, saveArrangement, loadArrangement } from '../arrangement-files.mjs'
import { arrangementEditor, arrangementCommand, arrangementImported, arrangementAction } from '../arrangement-editor.mjs'
import { newEditor, editorCommand, editorAction } from '../sequencer-editor.mjs'
import { midiSourcePattern, midiSourceHarmony, exportMidiSource, importMidiSource } from '../midi-source.mjs'

const origin = 10000000000000000000n
const packet = (offset, source, messages) => {
  const bytes = Buffer.from(messages.flatMap(message => [...message]))
  return { kind: 'midi', protocol: 2, source, hostTime: String(origin + offset), timestampOrigin: source === 'B' ? 'received' : 'packet',
    words: Array.from({ length: bytes.length / 4 }, (_, index) => bytes.readUInt32BE(index * 4)) }
}
const messages = () => [
  packet(-100n, 'A', [JZZ.UMP.umpProgram(3, 5, 10, 2, 3), ...[60, 64, 67, 71].map(key => JZZ.UMP.umpNoteOn(3, 5, key, 0x9001))]),
  packet(2400000n, 'B', [JZZ.UMP.noteOn(3, 5, 60, 80)]),
  packet(4800000n, 'A', [JZZ.UMP.umpPitchBend(3, 5, 0x87654321), JZZ.UMP.umpControl(3, 5, 74, 0xabcdef01), JZZ.UMP.umpPressure(3, 5, 0x87654321)]),
  packet(7200000n, 'B', [JZZ.UMP.noteOff(3, 5, 60, 45)]),
  packet(12000000n, 'A', [JZZ.UMP.umpNoteOff(3, 5, 60, 0x1234), ...[64, 67, 71].map(key => JZZ.UMP.umpNoteOff(3, 5, key, 0x1234))]),
]
async function fixture(run, rows = messages()) {
  const root = await mkdtemp(join(tmpdir(), 'masc-capture-midi-')), input = join(root, 'take'), path = join(root, 'project/song.json')
  try {
    await mkdir(input)
    const wave = Buffer.alloc(44 + 9600)
    wave.write('RIFF'); wave.writeUInt32LE(wave.length - 8, 4); wave.write('WAVEfmt ', 8); wave.writeUInt32LE(16, 16)
    wave.writeUInt16LE(1, 20); wave.writeUInt16LE(1, 22); wave.writeUInt32LE(48000, 24); wave.writeUInt32LE(96000, 28)
    wave.writeUInt16LE(2, 32); wave.writeUInt16LE(16, 34); wave.write('data', 36); wave.writeUInt32LE(9600, 40)
    const files = {
      'audio.wav': wave,
      'audio-blocks.jsonl': JSON.stringify({ kind: 'audio', hostTime: String(origin), deviceSampleTime: '0', frameOffset: '0', frameCount: 4800, peaks: [[0, 0]] }) + '\n',
      'midi.ump.jsonl': rows.map(row => JSON.stringify(row)).join('\n') + '\n',
      'session.json': JSON.stringify({ schemaVersion: 1, state: 'recorded', failure: null,
        audio: 'audio.wav', audioBlocks: 'audio-blocks.jsonl', midi: 'midi.ump.jsonl', sampleRate: 48000, channels: 1, audioFrames: '4800', midiPacketCount: String(rows.length),
        clock: { kind: 'mach-host-time', numer: 125, denom: 3, requestedStart: String(origin), firstAudioHostTime: String(origin) },
        input: { id: 'interface', name: 'Audio interface' }, midiSources: [{ id: 'A', name: 'Keys' }, { id: 'B', name: 'Pads' }] }),
    }
    for (const [name, bytes] of Object.entries(files)) await writeFile(join(input, name), bytes)
    const imported = await importArrangementCapture(newArrangement({ tempo: 137 }), input, { projectPath: path })
    await run({ root, input, path, files, rows, imported })
  } finally { await rm(root, { recursive: true, force: true }) }
}

test('recorded WAV/UMP → actual worker MIDI variant → harmony/revoice → arrangement/save/export retains the original take', () => fixture(async ({ root, path, files, imported, rows }) => {
  const worker = new Worker(new URL('../arrangement-worker.mjs', import.meta.url)); let id = 0
  const request = async value => {
    const pending = once(worker, 'message'); worker.postMessage({ ...value, id: ++id })
    const [reply] = await pending; assert.equal(reply.ok, true, reply.error); return reply.result
  }
  try {
    let editor = arrangementEditor(imported.project)
    editor = arrangementCommand(editor, `place ${imported.asset} 0`).editor
    const original = structuredClone(editor.project), rawClip = original.clips[0]
    const effect = arrangementCommand(editor, 'capture-midi').effect
    assert.deepEqual(effect, { kind: 'capture-midi', asset: imported.asset })
    const result = await request({ ...effect, project: editor.project, sourceRoot: dirname(path) })
    editor = arrangementImported(editor, result)
    const variant = editor.project.assets.at(-1), performance = midiSourcePattern(variant.source)
    assert.equal(variant.kind, 'midi'); assert.equal(performance.format, 1)
    assert.deepEqual(performance.timing, { kind: 'ppq', ppq: 960 })
    assert.deepEqual(performance.diagnostics, []); assert.equal(performance.notes.length, 5)
    assert.deepEqual([...new Set(performance.notes.map(note => [note.track, note.port, note.channel].join(':')))].sort(), ['1:0:5', '2:1:5'])
    const micros = 437956n, first = BigInt(rows[0].hostTime)
    const at = host => Number(((BigInt(host) - first) * 125n * 960n * 2n + 3n * micros * 1000n) / (6n * micros * 1000n))
    const notes = performance.notes.filter(note => note.track === 1)
    assert.deepEqual(notes.map(note => [note.start, note.duration, note.velocity]), Array.from({ length: 4 }, () => [0, at(rows.at(-1).hostTime), 72]))
    const wire = performance.events.filter(event => event.track === 1 && event.kind === 'channel')
    assert.deepEqual(wire.slice(0, 3).map(event => event.bytes), [[0xb5, 0, 2], [0xb5, 32, 3], [0xc5, 10]])
    assert.deepEqual(wire.slice(7, 10).map(event => event.bytes), [[0xe5, 89, 67], [0xb5, 74, 85], [0xd5, 67]])
    const provenance = JSON.parse(Buffer.from(performance.events.find(event => event.kind === 'meta' && event.type === 0x7f).data).toString('utf8'))
    assert.equal(provenance.origin, String(first)); assert.deepEqual(provenance.parts, original.assets[0].parts)
    assert.deepEqual(provenance.routes.map(route => [route.port, route.source, route.group]), [[0, 'A', 3], [1, 'B', 3]])
    let child = newEditor(variant.source)
    assert.ok(midiSourceHarmony(child.project, 0.001).candidates.includes('Cmaj7'))
    child = editorCommand(child, 'channel 6').editor
    child = editorCommand(child, 'revoice Cmaj7 drop2').editor
    assert.deepEqual(midiSourcePattern(child.project).notes.filter(note => note.track === 1).map(note => note.pitch).sort((a, b) => a - b), [55, 60, 64, 71])
    child = editorAction(child, { kind: 'undo' }); assert.deepEqual(child.project, variant.source)
    child = editorAction(child, { kind: 'redo' })
    const edited = await request({ kind: 'import-phrase', project: editor.project, document: child.project })
    editor = arrangementImported(editor, edited)
    editor = arrangementCommand(editor, 'cursor 4').editor; editor = arrangementAction(editor, { kind: 'place' })
    assert.equal(editor.project.clips.at(-1).position, 3840)
    assert.deepEqual(editor.project.clips[0], rawClip); assert.deepEqual(editor.project.assets[0], original.assets[0])
    const saved = join(root, 'portable/song.json'); await saveArrangement(saved, editor.project, null, { sourceRoot: dirname(path) })
    const loaded = await loadArrangement(saved); assert.deepEqual(loaded.project, editor.project)
    const reopened = importMidiSource(exportMidiSource(loaded.project.assets.at(-1).source))
    assert.deepEqual(midiSourcePattern(reopened).notes.map(note => [note.port, note.channel, note.pitch, note.start, note.duration]),
      midiSourcePattern(child.project).notes.map(note => [note.port, note.channel, note.pitch, note.start, note.duration]))
    for (const [role, part] of Object.entries(original.assets[0].parts)) {
      const name = { manifest: 'session.json', audio: 'audio.wav', audioBlocks: 'audio-blocks.jsonl', midi: 'midi.ump.jsonl' }[role]
      assert.deepEqual(await readFile(join(dirname(saved), part.file)), Buffer.from(files[name]))
    }
    assert.deepEqual(imported.project.assets, original.assets)
  } finally { await worker.terminate() }
}))

test('MIDI2 zero-velocity attacks survive and same-time program/expression order is retained', () => fixture(async ({ imported, path }) => {
  const result = await importCaptureMidi(imported.project, imported.asset, { sourceRoot: dirname(path) })
  const performance = midiSourcePattern(result.project.assets.at(-1).source)
  assert.equal(performance.notes[0].velocity, 1)
  assert.deepEqual(performance.events.filter(event => event.kind === 'channel').map(event => event.bytes), [[0xc0, 12], [0x90, 60, 1], [0xa0, 60, 64], [0x80, 60, 0]])
}, [packet(0n, 'A', [JZZ.UMP.umpProgram(0, 0, 12), JZZ.UMP.umpNoteOn(0, 0, 60, 0), JZZ.UMP.umpAftertouch(0, 0, 60, 0x80000000)]), packet(2400000n, 'A', [JZZ.UMP.umpNoteOff(0, 0, 60, 0)])]))

test('SysEx7 fragment timestamps, system escape data and independent source groups survive MIDI export', () => fixture(async ({ imported, path }) => {
  const result = await importCaptureMidi(imported.project, imported.asset, { sourceRoot: dirname(path) })
  const source = result.project.assets.at(-1).source, performance = midiSourcePattern(importMidiSource(exportMidiSource(source)))
  const sx = performance.events.filter(event => event.kind === 'sysex')
  assert.deepEqual(sx.map(event => [event.port, event.status, event.data]), [[0, 0xf0, [1, 2]], [1, 0xf0, [3, 4]], [0, 0xf7, [5, 0xf7]], [1, 0xf7, [6, 0xf7]], [0, 0xf7, [0xf8]]])
  assert.ok(sx[2].tick > sx[0].tick); assert.ok(sx[3].tick > sx[1].tick)
}, [
  packet(0n, 'A', [JZZ.UMP([0x30, 0x12, 1, 2, 0, 0, 0, 0])]),
  packet(100000n, 'B', [JZZ.UMP([0x30, 0x12, 3, 4, 0, 0, 0, 0])]),
  packet(200000n, 'A', [JZZ.UMP([0x30, 0x31, 5, 0, 0, 0, 0, 0])]),
  packet(300000n, 'B', [JZZ.UMP([0x30, 0x31, 6, 0, 0, 0, 0, 0])]),
  packet(400000n, 'A', [JZZ.UMP([0x10, 0xf8, 0, 0]), JZZ.UMP.noteOn(0, 0, 60, 80)]),
  packet(500000n, 'A', [JZZ.UMP.noteOff(0, 0, 60, 0)]),
]))

test('out-of-order arrival preserves original host ordering and MIDI1 bank/RPN bytes', () => fixture(async ({ imported, path }) => {
  const result = await importCaptureMidi(imported.project, imported.asset, { sourceRoot: dirname(path) })
  const performance = midiSourcePattern(result.project.assets.at(-1).source)
  assert.deepEqual(performance.diagnostics, [])
  assert.deepEqual(performance.events.filter(event => event.kind === 'channel').map(event => event.bytes),
    [[0xb0, 0, 3], [0xb0, 32, 2], [0xc0, 12], [0xb0, 101, 0], [0xb0, 100, 0], [0xb0, 6, 2], [0x90, 60, 80], [0x90, 60, 0]])
}, [packet(2400000n, 'A', [JZZ.UMP.noteOn(0, 0, 60, 0)]),
  packet(0n, 'A', [JZZ.UMP.control(0, 0, 0, 3), JZZ.UMP.control(0, 0, 32, 2), JZZ.UMP.program(0, 0, 12),
    JZZ.UMP.control(0, 0, 101, 0), JZZ.UMP.control(0, 0, 100, 0), JZZ.UMP.control(0, 0, 6, 2), JZZ.UMP.noteOn(0, 0, 60, 80)])]))

for (const [name, extra] of [
  ['reserved utility', JZZ.UMP([0, 0xf0, 0, 0])],
  ['per-note expression', JZZ.UMP([0x40, 0x60, 60, 0, 0x80, 0, 0, 0])],
  ['note attribute', JZZ.UMP([0x43, 0x95, 62, 1, 0x90, 0, 0, 0])],
  ['reserved program flags', JZZ.UMP([0x43, 0xc5, 0, 2, 1, 0, 0, 0])],
  ['compound controller', JZZ.UMP([0x43, 0xb5, 6, 0, 0x80, 0, 0, 0])],
  ['unclosed note', JZZ.UMP.umpNoteOn(3, 5, 62, 0x9000)],
  ['unclosed exclusive', JZZ.UMP([0x33, 0x11, 1, 0, 0, 0, 0, 0])],
]) test(`unsupported or ambiguous ${name} cannot partly publish a MIDI variant`, () => fixture(async ({ imported, path, root }) => {
  const before = structuredClone(imported.project), scratch = join(root, 'scratch'); await mkdir(scratch)
  await assert.rejects(importCaptureMidi(imported.project, imported.asset, { sourceRoot: dirname(path), directory: scratch }))
  assert.deepEqual(imported.project, before); assert.deepEqual(await readdir(scratch), [])
}, [...messages(), packet(13000000n, 'A', [extra])]))

test('tampered raw parts and cancellation refuse derivation without changing the musical document', () => fixture(async ({ imported, path, root }) => {
  const before = structuredClone(imported.project), scratch = join(root, 'scratch'); await mkdir(scratch)
  const cancellation = new AbortController(); cancellation.abort()
  await assert.rejects(importCaptureMidi(imported.project, imported.asset, { sourceRoot: dirname(path), directory: scratch, signal: cancellation.signal }), { name: 'AbortError' })
  const file = join(dirname(path), imported.project.assets[0].parts.midi.file)
  await chmod(file, 0o600); await writeFile(file, '{}\n')
  await assert.rejects(importCaptureMidi(imported.project, imported.asset, { sourceRoot: dirname(path), directory: scratch }), /content changed/)
  assert.deepEqual(imported.project, before); assert.deepEqual(await readdir(scratch), [])
}))
