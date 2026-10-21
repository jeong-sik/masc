import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import JZZ from 'jzz'
import { newArrangement } from '../../arrangement.mjs'
import { importArrangementCapture } from '../../arrangement-files.mjs'

const origin = 10000000000000000000n
export const packet = (offset, source, messages) => {
  const bytes = Buffer.from(messages.flatMap(message => [...message]))
  return { kind: 'midi', protocol: 2, source, hostTime: String(origin + offset), timestampOrigin: source === 'B' ? 'received' : 'packet',
    words: Array.from({ length: bytes.length / 4 }, (_, index) => bytes.readUInt32BE(index * 4)) }
}
export const captureMessages = () => [
  packet(-100n, 'A', [JZZ.UMP.umpProgram(3, 5, 10, 2, 3), ...[60, 64, 67, 71].map(key => JZZ.UMP.umpNoteOn(3, 5, key, 0x9001))]),
  packet(2400000n, 'B', [JZZ.UMP.noteOn(3, 5, 60, 80)]),
  packet(4800000n, 'A', [JZZ.UMP.umpPitchBend(3, 5, 0x87654321), JZZ.UMP.umpControl(3, 5, 74, 0xabcdef01), JZZ.UMP.umpPressure(3, 5, 0x87654321)]),
  packet(7200000n, 'B', [JZZ.UMP.noteOff(3, 5, 60, 45)]),
  packet(12000000n, 'A', [JZZ.UMP.umpNoteOff(3, 5, 60, 0x1234), ...[64, 67, 71].map(key => JZZ.UMP.umpNoteOff(3, 5, key, 0x1234))]),
]
export async function capturedMidiFixture(run, rows = captureMessages()) {
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

