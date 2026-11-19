// Goal criteria in the shape the server writes them
// (Goal_document.criterion_to_yojson, lib/goal/goal_document.ml):
// { revision, title, measure, procedure }, where measure is one of the three
// Goal_measure.to_yojson shapes. Tests build criteria here so that a change
// of the server shape is fixed in one place.

import type { GoalMeasure } from '../goal-measure'
import type { GoalProofCriterion } from '../../types/core'

export const countMeasure: GoalMeasure = { kind: 'count', noun: 'services', total: 3 }
export const quantityMeasure: GoalMeasure = { kind: 'quantity', unit: 'ms', direction: 'at_most', target: 100 }
export const doneWhenMeasure: GoalMeasure = { kind: 'done_when', condition: 'the fixture ships' }

export function goalCriterion(overrides: Partial<GoalProofCriterion> = {}): GoalProofCriterion {
  return {
    revision: 'criterion-a',
    title: 'Three services',
    measure: countMeasure,
    procedure: 'Count the services that answer the health probe.',
    ...overrides,
  }
}
