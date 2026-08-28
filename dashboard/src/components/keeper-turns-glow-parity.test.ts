import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { describe, expect, it } from 'vitest'

import { FINISH_GLOW_TTL_MS } from './keeper-turns-state'

// TUI -> dashboard parity for the finish-glow contract.
//
// keeper-turns-state.ts declares itself "Same contract as the TUI's
// advance_finishes (#31208)", but nothing failed if one side changed its
// TTL: finish_glow_ttl_seconds = 60. and FINISH_GLOW_TTL_MS = 60_000 were
// two unrelated literals in two languages. The behavioral halves of the
// contract (running->idle is a finish, unavailable->idle is not, a keeper
// missing from the poll is not) are pinned by each side's own unit suite;
// the shared number is what could drift silently, and this reads it from
// the TUI source rather than a copy.
//
// vitest cwd = dashboard/, so the TUI source is one level up. A wrong path
// throws ENOENT rather than passing vacuously (same pattern as
// turn-outcome-parity.test.ts).

const TUI_ANSWERING_ML = resolve(__dirname, '../../../bin/masc_tui_answering.ml')

function tuiGlowTtlSeconds(): number {
  const source = readFileSync(TUI_ANSWERING_ML, 'utf8')
  const match = source.match(/let finish_glow_ttl_seconds = ([0-9.]+)/)
  if (!match?.[1]) {
    throw new Error(`could not find finish_glow_ttl_seconds in ${TUI_ANSWERING_ML}`)
  }
  return Number.parseFloat(match[1])
}

describe('finish-glow TTL parity', () => {
  it('agrees with the TUI TTL', () => {
    expect(FINISH_GLOW_TTL_MS).toBe(tuiGlowTtlSeconds() * 1000)
  })

  it('reads a real value from the TUI source, not a copy', () => {
    // Guards the guard: a regex that stops matching throws above, and a
    // degenerate parse cannot make the assertion vacuous.
    expect(tuiGlowTtlSeconds()).toBeGreaterThan(0)
  })
})
