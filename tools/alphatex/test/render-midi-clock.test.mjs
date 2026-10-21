import test from 'node:test'
import assert from 'node:assert/strict'
import { nominalMidiFrame } from '../render-midi-clock.mjs'

const clock = { kind: 'clock', schemaVersion: 1, device: { id: 'output', name: 'Output' }, sampleRate: 48000,
  clock: { kind: 'mach-host-time', numer: 125, denom: 3 }, anchor: { frame: '1024', hostTime: '18446744073709000000' } }
test('MIDI host ticks map to signed nominal frame fractions without UInt64 or sub-frame precision loss', () => {
  assert.deepEqual(nominalMidiFrame(clock.anchor.hostTime, clock.clock, clock), {numerator:'1024',denominator:'1'})
  assert.deepEqual(nominalMidiFrame('18446744073709000001', clock.clock, clock), {numerator:'512001',denominator:'500'})
  assert.deepEqual(nominalMidiFrame('18446744073708500000', clock.clock, clock), {numerator:'24',denominator:'1'})
  assert.deepEqual(nominalMidiFrame('18446744073708000000', clock.clock, clock), {numerator:'-976',denominator:'1'})
  assert.deepEqual(nominalMidiFrame(clock.anchor.hostTime, {...clock.clock,numer:250,denom:6}, clock), {numerator:'1024',denominator:'1'})
})
test('clock identity/format and unequal timebases refuse nominal placement instead of guessing', () => {
  assert.throws(() => nominalMidiFrame('1', {...clock.clock,numer:1}, clock), /timebases disagree/)
  for (const value of ['-1','01','18446744073709551616',9007199254740992]) assert.throws(() => nominalMidiFrame(value, clock.clock, clock))
  assert.throws(() => nominalMidiFrame('1',clock.clock,{...clock,anchor:{frame:'0',hostTime:'0'}}), /Missing/)
})
