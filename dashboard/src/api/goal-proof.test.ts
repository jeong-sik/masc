import { describe, expect, it } from 'vitest'
import { decodeGoalProofCriterion } from './goal-proof'
import { countMeasure } from './fixtures/goal-criterion'

const criterion = (procedure: string) => ({ revision: 'criterion-a', title: 'Three services', measure: countMeasure, procedure })

describe('Goal proof criterion reader', () => {
  // The server keeps a procedure that OCaml String.trim leaves non-empty.
  it.each(['\u00a0', '\u3000', '\u000b'])('reads a procedure of %j, which the server stores', procedure => {
    expect(decodeGoalProofCriterion(criterion(procedure))?.procedure).toBe(procedure)
  })

  it.each([' ', '\t\n\r\f'])('refuses a procedure of %j, which the server calls blank', procedure => {
    expect(decodeGoalProofCriterion(criterion(procedure))).toBeNull()
  })

  it('refuses a fifth field', () => {
    expect(decodeGoalProofCriterion({ ...criterion('Count them.'), metric: 'services' })).toBeNull()
  })
})
