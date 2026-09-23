import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { describe, expect, it } from 'vitest'

import { LANE_IDS } from './dashboard-standalone-lanes'

// OCaml -> dashboard parity for the standalone-lane wire vocabulary.
//
// Standalone_lane.to_id spells every lane id; the TUI decoder consumes it
// directly, but this bundle can only carry a copy. This test reads the OCaml
// source rather than trusting the copy, so renaming or adding a lane turns
// exactly this file red (same pattern as turn-outcome-parity.test.ts and
// keeper-turns-glow-parity.test.ts).
//
// vitest cwd = dashboard/, so the source is one level up. A wrong path
// throws ENOENT rather than passing vacuously.

const STANDALONE_LANE_ML = resolve(__dirname, '../../../lib/runtime/standalone_lane.ml')

function laneIds(): string[] {
  const source = readFileSync(STANDALONE_LANE_ML, 'utf8')
  const match = source.match(/let to_id = function\n((?:\s*\|[^\n]*\n)+)/)
  const arms = match?.[1]
  if (!arms) throw new Error(`could not find to_id in ${STANDALONE_LANE_ML}`)
  const ids = [...arms.matchAll(/->\s*"([^"]+)"/g)]
    .map(arm => arm[1])
    .filter((id): id is string => id !== undefined)
  if (ids.length === 0) throw new Error(`to_id in ${STANDALONE_LANE_ML} yielded no ids`)
  return ids
}

describe('standalone lane id parity', () => {
  it('carries exactly the ids the OCaml source defines', () => {
    expect([...LANE_IDS].sort()).toEqual(laneIds().sort())
  })

  it('reads real values from the source, not a copy', () => {
    // Guards the guard: a regex that stops matching throws above; a
    // degenerate parse cannot shrink the vocabulary unnoticed.
    expect(laneIds().length).toBeGreaterThanOrEqual(3)
  })
})
