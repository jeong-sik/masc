import { describe, it, expect } from 'vitest'

import { buildCompositeFsmMermaid } from './composite-fsm-flowchart'

describe('buildCompositeFsmMermaid', () => {
  const src = buildCompositeFsmMermaid()

  it('is a flowchart with a top-to-bottom direction', () => {
    expect(src.startsWith('flowchart TB')).toBe(true)
  })

  it('declares a subgraph per axis (6 including KCB)', () => {
    for (const axis of ['KSM', 'KTC', 'KDP', 'KCL', 'KMC', 'KCB']) {
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

  it('covers the full KSM state surface (13 phases)', () => {
    const ksm = [
      'Offline', 'Running', 'Failing', 'Overflowed', 'Compacting',
      'HandingOff', 'Draining', 'Paused', 'Stopped', 'Crashed',
      'Restarting', 'Dead', 'Zombie',
    ]
    for (const label of ksm) {
      expect(src).toContain(`"${label}"`)
    }
  })

  it('tags Zombie as a terminal state alongside Stopped and Dead', () => {
    // Zombie is a terminal phase reached when terminal_failure_latched
    // is asserted (KeeperStateMachine.tla:77 TerminalPhases).
    expect(src).toContain('ksm_zombie["Zombie"]')
    expect(src).toMatch(/class .*ksm_zombie.*terminal/)
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

  it('renders the 3 observable KCB states and omits tripped', () => {
    // The unobservable-by-design "tripped" state must not appear as a
    // node — the mutator resets consecutive_count before any snapshot
    // can see it. See display_state.mli.
    expect(src).toContain('kcb_clean["clean"]')
    expect(src).toContain('kcb_warning["warning"]')
    expect(src).toContain('kcb_cooling["cooling"]')
    // Bracket-declaration check: no node named tripped at all.
    expect(src).not.toMatch(/kcb_tripped\[/)
  })

  it('uses a dashed edge for warning → cooling (acknowledging the transient Trip)', () => {
    // Dashed arrow is a visual note that the transition exists inside
    // the mutator's read-modify-write but is not directly renderable.
    expect(src).toMatch(/kcb_warning\s*-\.->\s*kcb_cooling/)
  })

  it('uses literal hex colors in classDef (no CSS var()), since values are emitted as raw SVG attrs', () => {
    // Mermaid writes classDef color/fill/stroke verbatim into SVG
    // attributes. CSS custom properties don't resolve on attr paths
    // Mermaid uses during layout/text measurement, and a mixed classDef
    // has caused parse failures that leaked the library's "Syntax error"
    // bomb SVG into document.body (related: PR #8843).
    const classDefLines = src.split('\n').filter(l => /^\s*classDef\s+/.test(l))
    expect(classDefLines.length).toBeGreaterThan(0)
    for (const line of classDefLines) {
      expect(line).not.toMatch(/var\(--/)
    }
  })
})
