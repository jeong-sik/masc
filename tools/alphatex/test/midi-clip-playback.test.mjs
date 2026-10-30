import test from 'node:test'
import assert from 'node:assert/strict'
import JZZ from 'jzz'
import { importMidiClip, midiClipPerformance, midiClipNotes, editMidiClipAttack } from '../midi-clip-source.mjs'
import { midiClipPlaybackPlan, clipRoundedNanoseconds, midiClipEventNanoseconds } from '../midi-clip-playback.mjs'

const clip = (messages, ppq = 1001) => Buffer.concat([Buffer.from('SMF2CLIP'), Buffer.from(JZZ.UMP.umpDelta(0)),
  Buffer.from(JZZ.UMP.umpTicksPQN(ppq)), ...messages.map(Buffer.from)])
const dc = JZZ.UMP.umpDelta, start = JZZ.UMP.umpStartClip, end = JZZ.UMP.umpEndClip
const document = () => importMidiClip(clip([JZZ.UMP.umpTempo(0, 50000000), dc(1001), JZZ.UMP.umpProgram(3, 4, 12),
  dc(0), start(), dc(0), JZZ.UMP.umpTempo(0, 60000000), JZZ.UMP.umpNoteOn(3, 4, 17, 0, 3, 60 * 512 + 256),
  JZZ.UMP.umpPnRPN(3, 4, 17, 3, 0xffffffff), dc(1001), JZZ.UMP.umpNoteOff(3, 4, 17, 65535), dc(1001), end()]))

test('native playback plan retains source identities, words, setup delay and exact source tempo changes', () => {
  const source = document(), before = structuredClone(source), plan = midiClipPlaybackPlan(source, { destination: '-42' })
  assert.equal(plan.source.ppq, 1001); assert.equal(plan.destination, '-42')
  assert.deepEqual(plan.events.map(row => row.words), midiClipPerformance(source).events.map(row => row.words))
  assert.equal(clipRoundedNanoseconds(plan.setupNanoseconds), 500000000n)
  assert.equal(clipRoundedNanoseconds(plan.durationNanoseconds), 1700000000n)
  const note = midiClipNotes(source)[0]
  assert.equal(midiClipEventNanoseconds(plan, note.id), '500000000')
  assert.deepEqual(plan.events.find(row => row.id === note.id).words, note.words)
  assert.equal(plan.events.find(row => row.id === note.id).tick, '0')
  assert.deepEqual(source, before)
  const edited = editMidiClipAttack(source, note.id, { velocity: 65534 }), next = midiClipPlaybackPlan(edited, { destination: '-42' })
  assert.equal(next.source.originalSha256, plan.source.originalSha256)
  assert.notEqual(next.source.documentSha256, plan.source.documentSha256)
  assert.throws(() => midiClipEventNanoseconds(next, 'missing'))
})

test('configuration and sequence fractions are added before one final deadline rounding', () => {
  const source = importMidiClip(clip([JZZ.UMP.umpTempo(0, 1), dc(1), start(), dc(1),
    JZZ.UMP.umpNoteOn(0, 0, 60, 65535), dc(1), end()], 3))
  const plan = midiClipPlaybackPlan(source, { destination: '42' }), note = midiClipNotes(source)[0]
  assert.deepEqual(plan.events.find(row => row.id === note.id).nanoseconds, { numerator: '20', denominator: '3' })
  assert.equal(midiClipEventNanoseconds(plan, note.id), '7')
  assert.equal(clipRoundedNanoseconds(plan.durationNanoseconds), 10n)
})

test('profile negotiation, embedded clocks, missing tempo and invalid output identities are explicit refusals', () => {
  const plain = document(), source = Buffer.from(plain.original.base64, 'base64')
  const profile = importMidiClip(Buffer.concat([source.subarray(0, 8), Buffer.from([0x30, 6, 0x7e, 0x7f, 0x0d, 0x22, 1, 0x7f]), source.subarray(8)]))
  assert.throws(() => midiClipPlaybackPlan(profile, { destination: '42' }), { kind: 'profile-negotiation-required' })
  const jr = importMidiClip(clip([JZZ.UMP.umpTempo(0, 50000000), dc(0), start(), dc(0),
    [0x00, 0x20, 0, 1], dc(1001), end()]))
  assert.throws(() => midiClipPlaybackPlan(jr, { destination: '42' }), { kind: 'embedded-clock' })
  const unresolved = importMidiClip(clip([dc(0), start(), dc(1001), end()]))
  assert.throws(() => midiClipPlaybackPlan(unresolved, { destination: '42' }), /explicit tempo/)
  assert.equal(clipRoundedNanoseconds(midiClipPlaybackPlan(unresolved, { destination: '42', initialTempo: 50000000 }).durationNanoseconds), 500000000n)
  for (const destination of [undefined, 'device', '042', '-0', '2147483648']) assert.throws(() => midiClipPlaybackPlan(plain, { destination }))
  assert.equal(midiClipPlaybackPlan(importMidiClip(clip([dc(0), start(), dc(0), end()])), { destination: '42' }).events.length, 0)
})
