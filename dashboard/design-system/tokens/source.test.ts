import { describe, it, expect } from 'vitest'
import { source, type TokenBase, type Tier, type Kind } from './source'

// source.ts is the design-system token SSOT consumed by build.ts (codegen
// driver) to emit the 7 @generated artifacts. The codegen does no
// validation — a malformed name, unknown tier/kind, or a bonsai invariant
// pointing at a non-existent token would emit silently and surface only as
// broken CSS at runtime. These tests guard the data integrity build.ts
// relies on.

const RAW: readonly TokenBase[] = source.raw
const SEMANTIC: readonly TokenBase[] = source.semantic
const ALL: readonly TokenBase[] = [...RAW, ...SEMANTIC]

const rawNames = new Set(RAW.map((t) => t.name))
const roleNames = new Set(SEMANTIC.filter((t) => t.tier === 'role').map((t) => t.name))

const VALID_TIERS: ReadonlySet<Tier> = new Set<Tier>(['raw', 'semantic', 'role'])
const VALID_KINDS: ReadonlySet<Kind> = new Set<Kind>([
  'color', 'dimension', 'typography', 'duration', 'easing', 'shadow', 'number',
])

// Two names are emitted by both a raw literal and a role re-point: the role
// layer redirects status colors through the semantic var so theme switching
// flows through --err / --warn (raw provides the literal fallback). This is
// intentional; any OTHER duplicate is an accidental last-wins collision.
const KNOWN_ROLE_OVER_RAW = new Set(['bad-light', 'warn-bright'])

describe('design-system token SSOT (source.ts) integrity', () => {
  it('every token name is a valid CSS custom-property ident', () => {
    // codegen emits `--${name}`; a space or brace here silently breaks CSS
    const bad = ALL.filter((t) => !/^[a-z0-9_-]+$/i.test(t.name)).map((t) => t.name)
    expect(bad).toEqual([])
  })

  it('every token declares a known tier and kind', () => {
    const badTier = ALL.filter((t) => !VALID_TIERS.has(t.tier)).map((t) => `${t.name}:${t.tier}`)
    const badKind = ALL.filter((t) => !VALID_KINDS.has(t.kind)).map((t) => `${t.name}:${t.kind}`)
    expect(badTier).toEqual([])
    expect(badKind).toEqual([])
  })

  it('emits no accidental duplicate names beyond the documented role-over-raw re-points', () => {
    const counts = new Map<string, number>()
    for (const t of ALL) counts.set(t.name, (counts.get(t.name) ?? 0) + 1)
    const unexpectedDupes = [...counts.entries()]
      .filter(([name, c]) => c > 1 && !KNOWN_ROLE_OVER_RAW.has(name))
      .map(([name]) => name)
    expect(unexpectedDupes).toEqual([])
  })

  it('bonsai invariant raw names all resolve to raw tokens', () => {
    const missing = source.bonsai.invariantRawNames.filter((n) => !rawNames.has(n))
    expect(missing).toEqual([])
  })

  it('bonsai invariant role names all resolve to role-tier tokens', () => {
    const missing = source.bonsai.invariantRoleNames.filter((n) => !roleNames.has(n))
    expect(missing).toEqual([])
  })
})
