import test from 'node:test'
import assert from 'node:assert/strict'
import { recordingEpoch, recordedRegion, attachRecordedTake } from '../arrangement-recording.mjs'
import { newArrangement } from '../arrangement.mjs'
import { arrangementEditor, arrangementImported, arrangementAction } from '../arrangement-editor.mjs'

const origin = 9007199254740993123n
function source(start = origin) {
  return { kind: 'capture', id: 'asset-1', name: 'Recorded input',
    parts: Object.fromEntries(['manifest', 'audio', 'audioBlocks', 'midi'].map(role => [role, { sha256: 'a'.repeat(64), file: `assets/${'a'.repeat(64)}.${role === 'audio' ? 'wav' : 'capture'}` }])),
    manifest: { schemaVersion: 1, state: 'recorded', failure: null, audio: 'audio.wav', audioBlocks: 'audio-blocks.jsonl', midi: 'midi.ump.jsonl',
      clock: { kind: 'mach-host-time', numer: 125, denom: 3, requestedStart: String(start), firstAudioHostTime: String(start + 2400000n) },
      sampleRate: 48000, channels: 1, audioFrames: '48000', midiPacketCount: '2',
      input: { id: 'input', name: 'Interface' }, midiSources: [{ id: 'source', name: 'Keys' }] },
    midiTime: { first: String(start + 1200000n), last: String(start + 12000000n) } }
}
const epoch = (anchor, position = 0, duration = 20) => ({ duration, clock: { kind: 'mach-host-time', anchor: String(anchor), position, numer: 125, denom: 3 } })
test('record against backing with exact large clocks, inward sub-tick placement and original source retention', () => {
  const project = newArrangement({ tempo: 120 }), asset = source()
  const aligned = recordedRegion(project, asset, epoch(origin - 1n))
  assert.equal(aligned.position, 1)
  assert.equal(aligned.offset, '12499')
  assert.equal(aligned.extent, '26387501')
  assert.equal(BigInt(aligned.alignment.roundingHostTicks.numerator), 0n)
  const attached = attachRecordedTake(project, { project: { ...project, assets: [asset] }, asset: asset.id }, epoch(origin - 1n))
  const editor = arrangementImported(arrangementEditor(project), attached)
  assert.equal(editor.project.clips.length, 1); assert.deepEqual(editor.project.assets[0].manifest, asset.manifest)
  assert.equal(editor.project.assets[0].recording.sourceOrigin, String(origin))
  const undone = arrangementAction(editor, { kind: 'undo' })
  assert.equal(undone.project, project)
  assert.deepEqual(arrangementAction(undone, { kind: 'redo' }).project, editor.project)
})
test('startup pre-roll and end fence select only the original interval inside backing time', () => {
  const asset = source(), project = newArrangement({ tempo: 120 })
  const region = recordedRegion(project, asset, epoch(origin + 4800000n, 0, .5))
  assert.equal(region.position, 0); assert.equal(region.offset, '4800000'); assert.equal(region.extent, '12000000')
  assert.throws(() => recordedRegion(project, source(origin + 48000000n), epoch(origin, 0, 1)))
})
test('recording after seek uses the actual offset and nanosecond MIDI epoch without Number absolute clocks', () => {
  const project = newArrangement({ tempo: 120 }), asset = source(240000000000000n)
  const clock = { kind: 'mach-nanoseconds', anchor: '9999999500000000', position: 2.25 }
  const region = recordedRegion(project, asset, { clock, duration: 10 })
  assert.equal(region.position, 5280); assert.equal(region.offset, '0')
  const fractional = recordedRegion(newArrangement({ tempo: 123.45 }), source(), epoch(origin - 13579n, .123))
  assert.ok(BigInt(fractional.alignment.roundingHostTicks.numerator) >= 0n)
  assert.ok(BigInt(fractional.alignment.roundingHostTicks.numerator) < BigInt(fractional.alignment.roundingHostTicks.denominator))
})
test('no floating or mismatched clock can admit arrangement recording', () => {
  for (const event of [{ kind: 'paused' }, { kind: 'playing', clock: { kind: 'mach-host-time', anchor: Number(origin), position: 0, numer: 125, denom: 3 } },
    { kind: 'playing', loop: true, ...epoch(origin) }, { kind: 'playing', ...epoch(origin), clock: { ...epoch(origin).clock, denom: 0 } }]) assert.throws(() => recordingEpoch(event))
  assert.throws(() => recordedRegion(newArrangement(), source(), { ...epoch(origin), clock: { ...epoch(origin).clock, numer: 1 } }), /timebases/)
})
