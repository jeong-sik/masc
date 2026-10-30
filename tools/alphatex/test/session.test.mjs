import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import JZZ from 'jzz'
import { CaptureTimeline, captureClock, exportMidiClips, unpackMidi, waveform } from '../session-data.mjs'

const origin = 9007199254740993123n
const manifest = {
  schemaVersion: 1, state: 'recorded', sampleRate: 48000, channels: 2,
  input: { id: 'loop', name: 'loop' }, midiSources: [{ id: 'A', name: 'Keyboard' }, { id: 'B', name: 'Pads' }],
  clock: { kind: 'mach-host-time', numer: 125, denom: 3, requestedStart: String(origin) },
}
const at = seconds => String(origin + BigInt(Math.round(seconds * 24000000)))
function packet(time, source, ...messages) {
  const bytes = Buffer.from(messages.flat())
  return { kind: 'midi', protocol: 2, hostTime: at(time), timestampOrigin: 'packet', source,
    words: Array.from({ length: bytes.length / 4 }, (_, i) => bytes.readUInt32BE(i * 4)) }
}

test('simultaneous multichannel audio and multiple MIDI sources retain one clock and raw UMP data', async () => {
  assert.equal(captureClock(manifest.clock)(at(0.125)), 0.125)
  const timeline = new CaptureTimeline(manifest)
  timeline.addAudio({ kind: 'audio', hostTime: at(0.05), deviceSampleTime: '0', frameOffset: '0', frameCount: 4800, peaks: [[-0.1, 0.2], [-0.7, 0.8]] })
  const note = [...JZZ.UMP.umpNoteOn(3, 5, 60, 0x9001)]
  const expressive = [...JZZ.UMP.umpPitchBend(3, 5, 0x87654321)]
  const controller = [...JZZ.UMP.umpControl(3, 5, 74, 0xabcdef01)]
  timeline.addMidi(packet(0.06, 'A', note, expressive, controller))
  timeline.addMidi(packet(0.07, 'B', [...JZZ.UMP.umpNoteOn(1, 2, 36, 0xffff)]))
  timeline.addMidi(packet(0.12, 'A', [...JZZ.UMP.umpNoteOff(3, 5, 60, 0x1234)]))
  const tracks = [...timeline.midi.values()]
  assert.equal(tracks.length, 2)
  assert.deepEqual([tracks[0].source, tracks[0].group, tracks[0].channel], ['A', 3, 5])
  assert.deepEqual(tracks[0].notes, [{ pitch: 60, start: 0.06, end: 0.12 }])
  assert.equal(tracks[1].notes[0].end, null) // No invented note-off for held notes.
  assert.deepEqual(waveform(timeline, 1, 0, 0.05, 4), [null, [-0.7, 0.8], [-0.7, 0.8], null])
  const directory = await mkdtemp(join(tmpdir(), 'masc-midi-clip-'))
  try {
    const outputs = await exportMidiClips(timeline, directory)
    assert.equal(outputs.length, 2)
    const clip = new JZZ.MIDI.Clip(await readFile(outputs[0].path))
    const events = [...clip].filter(message => message[0] >>> 4 === 4)
    assert.deepEqual(events.map(message => [...message]).slice(0, 3), [note, expressive, controller])
    assert.deepEqual(events.map(message => message.tt), [120, 120, 120, 240])
    assert.equal(clip.header.find(message => message.isTempo()).getBPM(), 120)
    await assert.rejects(exportMidiClips(timeline, directory), { code: 'EEXIST' })
  } finally { await rm(directory, { recursive: true, force: true }) }
})

test('malformed UMP and incomplete audio timing are refused instead of silently truncated', () => {
  assert.throws(() => unpackMidi({ ...packet(0, 'A', [...JZZ.UMP.umpNoteOn(0, 0, 60, 1)]), words: [0x40903c00] }), /Truncated UMP/)
  const timeline = new CaptureTimeline(manifest)
  assert.throws(() => timeline.addAudio({ kind: 'audio', hostTime: at(0), deviceSampleTime: '0', frameOffset: '4800', frameCount: 4800, peaks: [[0, 0], [0, 0]] }), /Noncontiguous/)
})

test('MIDI Clip export preserves capture time across an incoming MIDI tempo change', async () => {
  const timeline = new CaptureTimeline(manifest)
  timeline.addMidi(packet(0.5, 'A', [...JZZ.UMP.umpBPM(0, 60)]))
  timeline.addMidi(packet(1.5, 'A', [...JZZ.UMP.umpNoteOn(0, 0, 60, 0xffff)]))
  const directory = await mkdtemp(join(tmpdir(), 'masc-midi-tempo-'))
  try {
    const [output] = await exportMidiClips(timeline, directory)
    const clip = new JZZ.MIDI.Clip(await readFile(output.path))
    assert.equal(clip.find(message => message.isNoteOn()).tt, 2000)
    assert.ok(Math.abs(clip.player().durationMS() - 1500) < 1)
  } finally { await rm(directory, { recursive: true, force: true }) }
})
