// Contract: one keeper state renders as one word, everywhere.
//
// The dashboard shows keeper status on four independent surfaces, each
// reached through a different call chain. Before 2026-07-27 all twelve
// `KeeperPhase` values rendered 2–4 different words depending on which
// surface you were looking at — `Offline` was 미기동 / 정지 / 확인 필요 /
// 오프라인 at the same moment. Each surface was internally consistent, so
// the compiler saw nothing wrong: every table was total over its own union.
//
// This test is the thing the type system cannot express — that four
// separately-typed lookups agree. It fails if any one of them is edited
// alone.
import { describe, it, expect } from 'vitest'
import { keeperDisplayStatus } from './keeper-runtime-display'
import { PHASE_TONE, PHASE_LABEL_KO, PHASE_DESCRIPTION_KO, toKeeperPhaseToken, type KeeperPhaseToken } from './fleet-tone'
import { resolveUnifiedStatus } from './unified-status'
import { keeperPhaseLabel } from '../components/keeper-workspace/keeper-workspace-shared'
import { PHASE_STYLES, getPhaseStyle } from '../components/keeper-phase-indicator'
import type { Keeper, KeeperPhase } from '../types/core'

const ALL_PHASES: KeeperPhase[] = [
  'Offline', 'Running', 'Failing', 'Compacting',
  'HandingOff', 'Draining', 'Paused', 'Stopped', 'Crashed', 'Restarting',
]

function keeperInPhase(phase: KeeperPhase): Keeper {
  return { name: 'contract', lifecycle_phase: phase, phase } as Keeper
}

/** The four places an operator can read this keeper's state. Each entry is
 *  the expression the corresponding component renders — keep them in step
 *  with the call sites named in the comments. */
function renderedWords(phase: KeeperPhase): Record<string, string> {
  const keeper = keeperInPhase(phase)
  return {
    // keepers page: workspace roster row + chat header pill
    //   keeper-workspace-roster.ts, keeper-workspace-chat.ts
    workspaceRoster: keeperPhaseLabel(keeper),
    // monitoring page: roster aside "selected keeper runtime" state line
    //   agent-roster.ts, keeper branch
    rosterAside: PHASE_LABEL_KO[keeperDisplayStatus(keeper)],
    // agent detail header: <StatusBadge label=${unified.label}>
    //   agent-detail.ts
    agentDetailBadge: resolveUnifiedStatus(keeperDisplayStatus(keeper), null, null).label,
    // agent detail header: <KeeperPhaseBadge>, rendered on the same line
    //   agent-detail.ts -> keeper-phase-indicator.ts
    phaseBadge: PHASE_STYLES[phase].label,
  }
}

describe('keeper status vocabulary is single-valued across surfaces', () => {
  it.each(ALL_PHASES)('%s renders as one word everywhere', phase => {
    const words = renderedWords(phase)
    const distinct = [...new Set(Object.values(words))]
    expect(distinct, `surfaces disagree for ${phase}: ${JSON.stringify(words)}`).toHaveLength(1)
  })

  it('covers every KeeperPhase, so a new phase cannot skip this test', () => {
    // Guards against the list above drifting from the type. `PHASE_STYLES`
    // is `Record<KeeperPhase, …>`, so its keys are exactly the union.
    expect([...ALL_PHASES].sort()).toEqual(Object.keys(PHASE_STYLES).sort())
  })
})

describe('keeperDisplayStatus stays inside the token union', () => {
  // The union is the function's declared return type, so a producer arm
  // that invents a value is a compile error. These cases pin the inputs
  // that used to escape it at runtime and surface as `확인 필요`.
  const escapees: Array<[string, Keeper, KeeperPhaseToken]> = [
    [
      'heartbeat alive with no lifecycle phase',
      { name: 'k', status: 'offline', last_heartbeat: new Date().toISOString() } as Keeper,
      'idle',
    ],
    [
      'HandingOff via keeper.phase — PascalCase lowercases to handingoff, not handoff',
      { name: 'k', status: 'offline', phase: 'HandingOff', last_heartbeat: new Date().toISOString() } as Keeper,
      'handoff',
    ],
    ['backend status idle', { name: 'k', status: 'idle' } as Keeper, 'idle'],
    ['backend status listening', { name: 'k', status: 'listening' } as Keeper, 'listening'],
    [
      'offline residual: no recorded activity renders unbooted',
      { name: 'k', status: 'offline' } as Keeper,
      'unbooted',
    ],
  ]

  it.each(escapees)('%s', (_name, keeper, expected) => {
    const token = keeperDisplayStatus(keeper)
    expect(token).toBe(expected)
    expect(PHASE_LABEL_KO[token]).not.toBe(PHASE_LABEL_KO.unknown)
  })

  it('does not leak an unmodelled backend status', () => {
    expect(keeperDisplayStatus({ name: 'k', status: 'no-such-status' } as Keeper)).toBe('unknown')
  })
})

describe('the three token-keyed tables cover the same keys', () => {
  it('tone, label and description agree on the keyspace', () => {
    const tone = Object.keys(PHASE_TONE).sort()
    expect(Object.keys(PHASE_LABEL_KO).sort()).toEqual(tone)
    expect(Object.keys(PHASE_DESCRIPTION_KO).sort()).toEqual(tone)
  })

  it('every token round-trips through the boundary parser', () => {
    for (const token of Object.keys(PHASE_TONE) as KeeperPhaseToken[]) {
      expect(toKeeperPhaseToken(token)).toBe(token)
    }
  })

  it('no two tokens share a label, so a word identifies a state', () => {
    const labels = Object.values(PHASE_LABEL_KO)
    expect(new Set(labels).size).toBe(labels.length)
  })
})

describe('the unknown fallback does not assert a state', () => {
  it('an unrecognized phase does not claim the keeper never booted', () => {
    // `PHASE_STYLES.Offline` carries `미기동`, which is a claim. Reusing it
    // as the fallback would make "we have no phase" read as "never booted".
    expect(getPhaseStyle('NoSuchPhase').label).toBe(PHASE_LABEL_KO.unknown)
    expect(getPhaseStyle(null).label).toBe(PHASE_LABEL_KO.unknown)
    expect(PHASE_STYLES.Offline.label).toBe(PHASE_LABEL_KO.unbooted)
  })
})
