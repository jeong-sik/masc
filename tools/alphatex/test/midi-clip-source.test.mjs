import test from 'node:test'
import assert from 'node:assert/strict'
import JZZ from 'jzz'
import midiFiles from 'jzz-midi-smf'
import { importMidiClip, readMidiClip, midiClipPerformance, midiClipClock, midiClipChunks,
  editMidiClip, midiClipNotes, editMidiClipAttack, midiClipHarmony, revoiceMidiClip, validateMidiClip } from '../midi-clip-source.mjs'
midiFiles(JZZ)
const file = messages => Buffer.concat([Buffer.from('SMF2CLIP'), ...messages.map(message => Buffer.from(message))])
const raw = words => { const bytes = Buffer.alloc(words.length * 4); words.forEach((word, index) => bytes.writeUInt32BE(word, index * 4)); return bytes }
const dc = JZZ.UMP.umpDelta, start = JZZ.UMP.umpStartClip, end = JZZ.UMP.umpEndClip
const prefix = () => [dc(0), JZZ.UMP.umpTicksPQN(1001)]
const source = () => file([...prefix(), JZZ.UMP.umpTempo(2, 0xffffffff), JZZ.UMP.umpTimeSignature(2, 4, 4),
  dc(1001), JZZ.UMP.umpProgram(2, 3, 33), dc(0), start(), dc(0), JZZ.UMP.umpTempo(2, 0x80000000),
  JZZ.UMP.umpNoteOn(2, 3, 17, 0, 3, 60 * 512 + 256),
  ...[64, 67, 71].map(key => JZZ.UMP.umpNoteOn(2, 3, key, 65535)),
  JZZ.UMP.umpPnRPN(2, 3, 17, 3, 0xffffffff),
  raw([0xb0000000, 0x12345678, 0xffffffff]), raw([0xf0000000, 1, 2, 0xffffffff]),
  dc(1001), JZZ.UMP.umpTempo(2, 1), JZZ.UMP.umpNoteOff(2, 3, 17, 65535), dc(1001), end()])
const exported = document => Buffer.concat([...midiClipChunks(document)])

test('native Clip import retains shared deltas, unsigned tempo/expression, opaque widths, setup and original bytes', () => {
  const bytes = source(), document = importMidiClip(bytes), performance = midiClipPerformance(document)
  assert.equal(performance.ppq, 1001); assert.equal(performance.ticks, '2002')
  assert.equal(performance.configurationTempo, 0xffffffff)
  assert.equal(performance.start.configurationTicks, '1001')
  assert.deepEqual(exported(document), bytes)
  assert.equal(midiClipNotes(document)[0].velocity, 0)
  assert.equal(midiClipNotes(document)[0].pitch / 512, 60.5)
  assert.deepEqual(performance.sequence.filter(row => row.words.length === 3).map(row => row.words), [[0xb0000000, 0x12345678, 0xffffffff]])
  const clock = midiClipClock(document)
  assert.equal(BigInt(clock.configuration.duration.numerator), 1001n * 0xffffffffn * 10n)
  assert.equal(BigInt(clock.sequence.duration.numerator), 1001n * (0x80000000n + 1n) * 10n)
  assert.equal(clock.sequence.duration.denominator, '1001')
  assert.deepEqual(document, JSON.parse(JSON.stringify(document)))
})

test('native pitch/velocity and voicing preserve Note Index, release/PN data, config framing and undoable originals', () => {
  const document = importMidiClip(source()), before = structuredClone(document), original = midiClipPerformance(document)
  const note = midiClipNotes(document)[0], changed = editMidiClipAttack(document, note.id, { pitch: 61 * 512, velocity: 65534 })
  assert.equal(midiClipNotes(changed)[0].index, 17); assert.equal(midiClipNotes(changed)[0].velocity, 65534)
  assert.deepEqual(midiClipPerformance(changed).sequence.filter(row => row.id !== note.id), original.sequence.filter(row => row.id !== note.id))
  assert.equal(midiClipHarmony(document, note.id).kind, 'fractional-pitch')
  const voiced = revoiceMidiClip(document, note.id, 'Cmaj7', { mode: 'drop2', octave: 4, inversion: 0 })
  assert.deepEqual(midiClipNotes(voiced).map(note => note.pitch / 512), [55, 60, 64, 71])
  assert.deepEqual(midiClipNotes(voiced).map(note => note.index), [17, 64, 67, 71])
  const bytes = exported(changed), editedOffsets = new Set(Array.from({ length: 8 }, (_, index) => Number(note.id) + index))
  for (let index = 0; index < bytes.length; index++) if (!editedOffsets.has(index)) assert.equal(bytes[index], original.bytes[index])
  const restored = editMidiClip(changed, [{ kind: 'reset-words', id: note.id }])
  assert.deepEqual(exported(restored), original.bytes); assert.deepEqual(document, before)
})

test('time edits preserve configuration word edits, stable equal-tick order, original silence and streaming long deltas', () => {
  const document = importMidiClip(source()), performance = midiClipPerformance(document)
  const notes = midiClipNotes(document), config = performance.configuration.find(row => (row.words[0] >>> 28) === 13)
  const changed = editMidiClip(document, [{ kind: 'words', id: config.id, words: [config.words[0], 60000000, 0, 0] },
    { kind: 'time', id: notes[0].id, tick: '3145730' }, { kind: 'time', id: notes[1].id, tick: '3145730' }])
  const bytes = exported(changed), reopened = midiClipPerformance(importMidiClip(bytes))
  assert.equal(reopened.configurationTempo, 60000000)
  assert.equal(reopened.ticks, '3145730')
  const moved = reopened.sequence.filter(row => row.tick === '3145730' && (row.words[0] >>> 20 & 15) === 9)
  assert.deepEqual(moved.map(row => row.words[0] >>> 8 & 127), [17, 64])
  assert.ok(reopened.sequence.some(row => row.words[0] === 0))
  assert.deepEqual(Buffer.from(changed.original.base64, 'base64'), source())
  const inward = editMidiClip(document, [{ kind: 'time', id: notes[0].id, tick: '1' }])
  assert.equal(readMidiClip(exported(inward)).end.tick, '2002')
})

test('a missing tempo stays unresolved until explicitly supplied, without repairing the source', () => {
  const bytes = file([...prefix(), dc(0), start(), dc(0), JZZ.UMP.umpNoteOn(0, 0, 60, 0), dc(1001), end()])
  const document = importMidiClip(bytes)
  assert.throws(() => midiClipClock(document), /explicit tempo/)
  assert.equal(midiClipClock(document, { initialTempo: 50000000 }).sequence.duration.numerator, String(1001n * 500000000n))
  assert.deepEqual(exported(document), bytes)
  const empty = importMidiClip(file([...prefix(), dc(0), start(), dc(0), end()]))
  assert.equal(midiClipClock(empty).sequence.duration.numerator, '0')
})

test('edited configuration summaries, effective events and clocks agree before export, after reread and after reset', () => {
  const document = importMidiClip(source()), original = midiClipPerformance(document)
  const [tempo, meter] = original.configuration
  const edited = editMidiClip(document, [
    { kind: 'words', id: tempo.id, words: [tempo.words[0], 60000000, 0, 0] },
    { kind: 'words', id: meter.id, words: [meter.words[0], 0x03020800, 0, 0] },
  ])
  const current = midiClipPerformance(edited), reread = midiClipPerformance(importMidiClip(exported(edited)))
  assert.equal(current.configurationTempo, 60000000)
  assert.deepEqual(current.configurationMeter, { numeratorCode: 3, denominatorPower: 2, notated32nds: 8 })
  assert.deepEqual(current.events, [...current.configuration, ...current.sequence])
  assert.equal(current.configurationTempo, reread.configurationTempo)
  assert.deepEqual(current.configurationMeter, reread.configurationMeter)
  assert.deepEqual(midiClipClock(edited).configuration.duration,
    midiClipClock(importMidiClip(exported(edited))).configuration.duration)
  const reset = editMidiClip(edited, [{ kind: 'reset-words', id: tempo.id }, { kind: 'reset-words', id: meter.id }])
  assert.deepEqual(midiClipPerformance(reset).configurationMeter, original.configurationMeter)
  assert.equal(midiClipPerformance(reset).configurationTempo, original.configurationTempo)
  assert.deepEqual(exported(reset), exported(document))
})

test('opaque untimed SysEx7 setup and nonstandard meter codes stay source data', () => {
  const opaque = [0x30, 0x06, 0x7e, 0x7f, 0x0d, 0x22, 1, 0x7f]
  const bytes = file([opaque, ...prefix(), JZZ.UMP.umpTempo(0, 50000000), raw([0xd0100001, 0x00000800, 0, 0]), dc(0), start(), dc(0), end()])
  const document = importMidiClip(bytes), performance = midiClipPerformance(document)
  assert.equal(performance.prefix.length, 1)
  assert.deepEqual(performance.configurationMeter, { numeratorCode: 0, denominatorPower: 0, notated32nds: 8 })
  assert.deepEqual(exported(document), bytes)
})

test('broken envelopes, zero resolution, duplicate IDs and address changes refuse the complete source edit', () => {
  const good = source()
  const bad = [good.subarray(1), good.subarray(0, good.length - 1), Buffer.concat([good, Buffer.from(dc(0))]),
    file([dc(1), JZZ.UMP.umpTicksPQN(1001), dc(0), start(), dc(0), end()]),
    file([dc(0), raw([0x00300000]), dc(0), start(), dc(0), end()]),
    file([...prefix(), dc(0), JZZ.UMP.umpTicksPQN(1001), dc(0), start(), dc(0), end()]),
    file([...prefix(), dc(0), dc(1), start(), dc(0), end()])]
  for (const bytes of bad) assert.throws(() => importMidiClip(bytes))
  const document = importMidiClip(good), note = midiClipNotes(document)[0], before = structuredClone(document)
  const sparse = Array(2); sparse[0] = note.words[0]
  for (const changes of [[{ id: note.id, words: undefined }], [{ id: note.id, tick: undefined }],
    [{ id: note.id, words: sparse }],
    [{ id: note.id, tick: '-1' }], [{ id: note.id, tick: '01' }],
    [{ id: note.id, tick: '1' }, { id: note.id, tick: '2' }],
    [{ id: note.id, words: [note.words[0] ^ 0x100, note.words[1]] }]]) {
    assert.throws(() => validateMidiClip({ ...document, changes })); assert.deepEqual(document, before)
  }
})

test('the existing capture Clip exporter format is read without reserializing its default/header messages', () => {
  const clip = new JZZ.MIDI.Clip(); clip.ppqn = 1000
  clip.header.add(0, JZZ.UMP.umpBPM(0, 120))
  clip.add(0, JZZ.UMP.umpNoteOn(0, 0, 60, 65535)).add(1000, JZZ.UMP.umpNoteOff(0, 0, 60, 65535))
  const bytes = Buffer.from(clip.toUint8Array()), document = importMidiClip(bytes)
  assert.deepEqual(exported(document), bytes)
  assert.equal(midiClipPerformance(document).ppq, 1000)
})
