import { describe, it, expect } from 'vitest'

import { buildCompositeFsmMermaid } from './composite-fsm-flowchart'

describe('buildCompositeFsmMermaid', () => {
  const src = buildCompositeFsmMermaid()

  it('is a flowchart with a top-to-bottom direction', () => {
    expect(src.startsWith('flowchart TB')).toBe(true)
  })

  it('declares a subgraph per axis', () => {
    for (const axis of ['KSM', 'KTC', 'KDP', 'KCL', 'KMC']) {
      // `subgraph KSM ["..."]` etc.
      expect(src).toMatch(new RegExp(`subgraph ${axis} `))
    }
  })

  it('prefixes every state node to avoid collisions between axes', () => {
    // KTC and KCL both declare an "idle" state; the diagram must show
    // them as distinct nodes.
    expect(src).toContain('ktc_idle["idle"]')
    expect(src).toContain('kcl_idle["idle"]')
  })

  it('covers the full KSM state surface (12 phases)', () => {
    const ksm = [
      'Offline', 'Running', 'Failing', 'Overflowed', 'Compacting',
      'HandingOff', 'Draining', 'Paused', 'Stopped', 'Crashed',
      'Restarting', 'Dead',
    ]
    for (const label of ksm) {
      expect(src).toContain(`"${label}"`)
    }
  })

  it('does not emit duplicate top-level node ids (no un-prefixed collisions)', () => {
    // Heuristic: every declared `id["label"]` anchored on word chars
    // should have at most one bracket declaration when the id is
    // prefixed. We extract ids and check that each appears exactly
    // once in an initial declaration.
    const declRe = /(\b[a-z0-9_]+)\[["][^"]+["]\]/g
    const seen = new Map<string, number>()
    for (const m of src.matchAll(declRe)) {
      const id = m[1]!
      seen.set(id, (seen.get(id) ?? 0) + 1)
    }
    const duplicates = [...seen.entries()].filter(([, n]) => n > 1)
    expect(duplicates).toEqual([])
  })

  it('tags at least one terminal state', () => {
    expect(src).toMatch(/class ksm_stopped.*terminal/)
  })

  it('tags KDP gate_rejected as an error state', () => {
    expect(src).toMatch(/class .*kdp_gate_rejected.*error/)
  })
})
