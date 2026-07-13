import { existsSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, it, expect } from 'vitest'

import {
  COMPOSITE_FSM_TLA_SPEC_PATHS,
  buildCompositeFsmMermaid,
} from './composite-fsm-flowchart'

function repoRoot(): string {
  const cwd = process.cwd()
  return cwd.endsWith('/dashboard') ? resolve(cwd, '..') : cwd
}

describe('buildCompositeFsmMermaid', () => {
  const src = buildCompositeFsmMermaid()

  it('pins every documented TLA+ source to an existing spec file', () => {
    for (const specPath of COMPOSITE_FSM_TLA_SPEC_PATHS) {
      expect(existsSync(resolve(repoRoot(), specPath)), specPath).toBe(true)
    }
  })

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

  it('covers the full KSM state surface (13 phases)', () => {
    const ksm = [
      'Offline', 'Running', 'Failing', 'Overflowed', 'Compacting',
      'HandingOff', 'Draining', 'Paused', 'Stopped', 'Crashed',
      'Restarting', 'Dead',
    ]
    for (const label of ksm) {
      expect(src).toContain(`"${label}"`)
    }
  })

  it('tags Stopped and Dead as terminal states', () => {
    expect(src).toMatch(/class .*ksm_stopped.*ksm_dead.*terminal/)
  })

  it('does not emit duplicate top-level node ids (no un-prefixed collisions)', () => {
    // Inference: every declared `id["label"]` anchored on word chars
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
