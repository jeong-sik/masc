import { describe, expect, it } from 'vitest'
import { decodeGoalMeasure, goalMeasureEqual, goalMeasureText } from './goal-measure'
import { countMeasure, doneWhenMeasure, quantityMeasure } from './fixtures/goal-criterion'

describe('Goal measure reader', () => {
  it('reads the three shapes the server writes', () => {
    expect(decodeGoalMeasure({ kind: 'count', noun: '층', total: 14 })).toEqual({ kind: 'count', noun: '층', total: 14 })
    // Yojson writes a float target as 100.0; JSON.parse reads it as 100.
    expect(decodeGoalMeasure(JSON.parse('{"kind":"quantity","unit":"ms","direction":"at_most","target":100.0}')))
      .toEqual({ kind: 'quantity', unit: 'ms', direction: 'at_most', target: 100 })
    expect(decodeGoalMeasure({ kind: 'done_when', condition: 'TUI draws the list' }))
      .toEqual({ kind: 'done_when', condition: 'TUI draws the list' })
  })

  it.each([
    ['an unknown kind', { kind: 'percent', unit: '%', target: 90 }],
    ['an extra field', { kind: 'count', noun: '층', total: 14, baseline: 0 }],
    ['a missing field', { kind: 'quantity', unit: 'ms', target: 100 }],
    ['a blank label', { kind: 'count', noun: ' \t', total: 14 }],
    ['a label on two lines', { kind: 'done_when', condition: 'first\nsecond' }],
    ['a count out of zero', { kind: 'count', noun: '층', total: 0 }],
    ['a fractional count', { kind: 'count', noun: '층', total: 1.5 }],
    ['an unknown direction', { kind: 'quantity', unit: 'ms', direction: 'below', target: 100 }],
    ['a target that is not a number', { kind: 'quantity', unit: 'ms', direction: 'at_most', target: '100' }],
    ['the old metric fields', { metric: 'passed cases', target_value: '10' }],
  ])('refuses %s', (_case, raw) => {
    expect(decodeGoalMeasure(raw)).toBeNull()
  })

  it('compares shape and every field', () => {
    expect(goalMeasureEqual(countMeasure, { kind: 'count', noun: 'services', total: 3 })).toBe(true)
    expect(goalMeasureEqual(countMeasure, { kind: 'count', noun: 'services', total: 4 })).toBe(false)
    expect(goalMeasureEqual(quantityMeasure, { kind: 'quantity', unit: 'ms', direction: 'at_least', target: 100 })).toBe(false)
    expect(goalMeasureEqual(doneWhenMeasure, countMeasure)).toBe(false)
  })

  it('writes a target whole, not rounded to six digits', () => {
    expect(goalMeasureText({ kind: 'quantity', unit: 'bytes', direction: 'at_most', target: 1048576 })).toBe('≤ 1048576 bytes')
    expect(goalMeasureText({ kind: 'quantity', unit: 'ratio', direction: 'at_least', target: 0.1234567 })).toBe('≥ 0.1234567 ratio')
    expect(goalMeasureText(countMeasure)).toBe('3 services')
    expect(goalMeasureText(doneWhenMeasure)).toBe('the fixture ships')
  })
})
