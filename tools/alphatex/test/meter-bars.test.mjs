import { test } from 'node:test'
import assert from 'node:assert/strict'
import { meterSegments, barAt, isBarStart } from '../meter-bars.mjs'

const per = 960

test('a single 4/4 signature counts bars of four quarter notes', () => {
  const segments = meterSegments([{ tick: 0, numerator: 4, denominator: 4 }])
  assert.deepEqual(barAt(0, segments, per), { bar: 1, beat: 1 })
  assert.deepEqual(barAt(4 * per + per / 2, segments, per), { bar: 2, beat: 1.5 })
  assert.equal(isBarStart(8 * per, segments, per), true)
  assert.equal(isBarStart(9 * per, segments, per), false)
})

test('a later signature starts a new bar at its own tick and keeps counting', () => {
  // Two bars of 4/4, then 6/8: a bar of six eighth notes, beats are eighths.
  const segments = meterSegments([{ tick: 0, numerator: 4, denominator: 4 }, { tick: 8 * per, numerator: 6, denominator: 8 }])
  assert.deepEqual(barAt(8 * per, segments, per), { bar: 3, beat: 1 })
  assert.deepEqual(barAt(8 * per + 3 * per, segments, per), { bar: 4, beat: 1 })
  assert.deepEqual(barAt(8 * per + per / 2, segments, per), { bar: 3, beat: 2 })
  assert.equal(isBarStart(11 * per, segments, per), true)
})

test('a signature written inside a bar ends that bar early', () => {
  const segments = meterSegments([{ tick: 0, numerator: 4, denominator: 4 }, { tick: 6 * per, numerator: 3, denominator: 4 }])
  assert.deepEqual(barAt(5 * per, segments, per), { bar: 2, beat: 2 })
  assert.deepEqual(barAt(6 * per, segments, per), { bar: 3, beat: 1 })
})

test('without a signature at tick 0 the SMF default 4/4 applies first', () => {
  const segments = meterSegments([{ tick: 4 * per, numerator: 3, denominator: 4 }])
  assert.deepEqual(barAt(2 * per, segments, per), { bar: 1, beat: 3 })
  assert.deepEqual(barAt(7 * per, segments, per), { bar: 3, beat: 1 })
  assert.deepEqual(meterSegments([]), [{ tick: 0, numerator: 4, denominator: 4 }])
})

test('signatures out of order or with invalid values are refused', () => {
  assert.throws(() => meterSegments([{ tick: 8, numerator: 4, denominator: 4 }, { tick: 4, numerator: 3, denominator: 4 }]), /tick order/)
  assert.throws(() => meterSegments([{ tick: 0, numerator: 0, denominator: 4 }]), /Invalid/)
})
