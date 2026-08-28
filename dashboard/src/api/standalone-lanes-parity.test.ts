import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { describe, expect, it } from 'vitest'

import { LANE_IDS } from './dashboard-standalone-lanes'

// OCaml -> dashboard parity for the standalone-lane wire vocabulary.
//
// Exact_lane_run_registry.lane_key owns the registry spellings and
// Runtime.verifier_exact_lane_id owns the verifier spelling; the TUI decoder consumes both
// directly, but this bundle can only carry a copy. This test reads the two
// OCaml sources rather than trusting the copy, so renaming or adding a lane
// turns exactly this file red (same pattern as turn-outcome-parity.test.ts
// and keeper-turns-glow-parity.test.ts).
//
// vitest cwd = dashboard/, so the sources are one level up. A wrong path
// throws ENOENT rather than passing vacuously.

const REGISTRY_ML = resolve(__dirname, '../../../lib/exact_lane_run_registry.ml')
const RUNTIME_ML = resolve(__dirname, '../../../lib/runtime/runtime.ml')

function registryLaneKeys(): string[] {
  const source = readFileSync(REGISTRY_ML, 'utf8')
  const match = source.match(/let lane_key = function\n((?:\s*\|[^\n]*\n)+)/)
  const arms = match?.[1]
  if (!arms) throw new Error(`could not find lane_key in ${REGISTRY_ML}`)
  const keys = [...arms.matchAll(/->\s*"([^"]+)"/g)]
    .map(arm => arm[1])
    .filter((key): key is string => key !== undefined)
  if (keys.length === 0) throw new Error(`lane_key in ${REGISTRY_ML} yielded no keys`)
  return keys
}

function verifierLaneId(): string {
  const source = readFileSync(RUNTIME_ML, 'utf8')
  const match = source.match(/let verifier_exact_lane_id = "([^"]+)"/)
  if (!match?.[1]) {
    throw new Error(`could not find verifier_exact_lane_id in ${RUNTIME_ML}`)
  }
  return match[1]
}

describe('standalone lane id parity', () => {
  it('carries exactly the ids the OCaml sources define', () => {
    const backend = [...registryLaneKeys(), verifierLaneId()].sort()
    expect([...LANE_IDS].sort()).toEqual(backend)
  })

  it('reads real values from the sources, not a copy', () => {
    // Guards the guard: a regex that stops matching throws above; a
    // degenerate parse cannot shrink the vocabulary unnoticed.
    expect(registryLaneKeys().length).toBeGreaterThanOrEqual(4)
    expect(verifierLaneId()).not.toBe('')
  })
})
