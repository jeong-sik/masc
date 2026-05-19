import { describe, expect, it } from 'vitest'
import type { Keeper, KeeperRuntimeBlockerClass } from '../types/core'
import { KEEPER_RUNTIME_BLOCKER_CLASSES } from '../types/core'
import type { KeeperCompositeSnapshot } from '../api/schemas/keeper-composite'
import {
  compositeIsRunning,
  compositeIsTurnIdle,
  compositePhaseTone,
  deriveKeeperAttention,
  deriveKeeperDisplayReason,
  deriveKeeperOperationalState,
  toKsmPhase,
  type KeeperAttention,
  type KeeperKsmPhase,
  type KeeperOperationalState,
} from './keeper-operational-state'

function makeKeeper(overrides: Partial<Keeper> = {}): Keeper {
  return {
    name: 'test-keeper',
    status: 'active',
    ...overrides,
  } as Keeper
}

function makeComposite(
  overrides: Partial<KeeperCompositeSnapshot> = {},
): KeeperCompositeSnapshot {
  return {
    correlation_id: 'corr',
    run_id: 'run',
    ts: 0,
    phase: 'Stable',
    turn_phase: 'idle',
    decision: { stage: 'idle' },
    cascade: { state: 'idle' },
    compaction: { stage: 'idle' },
    measurement: {} as KeeperCompositeSnapshot['measurement'],
    invariants: {} as KeeperCompositeSnapshot['invariants'],
    fsm_guard_violations: 0,
    is_live: false,
    last_outcome: null,
    recommended_actions: [],
    ...overrides,
  } as KeeperCompositeSnapshot
}

function attention(
  overrides: Partial<NonNullable<KeeperCompositeSnapshot['runtime_attention']>> = {},
): NonNullable<KeeperCompositeSnapshot['runtime_attention']> {
  return {
    state: 'active',
    needs_attention: false,
    blocked: false,
    reason: null,
    raw_phase: null,
    is_live: true,
    source: 'test',
    ...overrides,
  }
}

describe('deriveKeeperOperationalState — paused branch', () => {
  it('paused when keeper.paused === true', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ paused: true }),
      composite: null,
    })
    expect(state).toEqual<KeeperOperationalState>({
      kind: 'paused',
      cause: 'unknown',
    })
  })

  it('paused operator cause when phase === Paused', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ phase: 'Paused' }),
      composite: null,
    })
    expect(state).toEqual<KeeperOperationalState>({
      kind: 'paused',
      cause: 'operator',
    })
  })

  it('paused supervisor cause when blocker is supervisor_paused', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({
        paused: true,
        runtime_blocker_class: 'supervisor_paused',
      }),
      composite: null,
    })
    expect(state).toEqual<KeeperOperationalState>({
      kind: 'paused',
      cause: 'supervisor',
    })
  })

  it('paused operator cause when pause_state === paused', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ pause_state: 'paused' }),
      composite: null,
    })
    expect(state).toEqual<KeeperOperationalState>({
      kind: 'paused',
      cause: 'operator',
    })
  })
})

describe('deriveKeeperOperationalState — offline branch', () => {
  it.each<[Keeper['phase'], 'crashed' | 'dead' | 'shutdown' | 'unbooted']>([
    ['Crashed', 'crashed'],
    ['Dead', 'dead'],
    ['Zombie', 'dead'],
    ['Stopped', 'shutdown'],
    ['Offline', 'unbooted'],
  ])('phase=%s → cause=%s', (phase, cause) => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ phase, status: 'offline' }),
      composite: null,
    })
    expect(state).toEqual<KeeperOperationalState>({ kind: 'offline', cause })
  })

  it.each<['offline' | 'inactive' | 'unbooted']>([
    ['offline'],
    ['inactive'],
    ['unbooted'],
  ])('status=%s without phase → offline', (status) => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ status }),
      composite: null,
    })
    expect(state.kind).toBe('offline')
  })

  it('composite phase Stopped overrides keeper.phase', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ phase: 'Running', status: 'active' }),
      composite: makeComposite({ phase: 'Stopped' }),
    })
    expect(state.kind).toBe('offline')
  })
})

describe('deriveKeeperOperationalState — stuck branch (RFC-0135 §1.1 root)', () => {
  it('blocker without composite ⇒ stuck reason=blocker_class', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({
        runtime_blocker_class: 'synthetic_stall',
      }),
      composite: null,
    })
    expect(state).toEqual<KeeperOperationalState>({
      kind: 'stuck',
      reason: 'synthetic_stall',
    })
  })

  it('blocker AND execution_current=true ⇒ stuck (receipt is current)', () => {
    // execution_current=true means the receipt matches the *current* live
    // turn (server_dashboard_http.ml:1061-1074) — the blocker is meaningful.
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ runtime_blocker_class: 'cascade_exhausted' }),
      composite: makeComposite({
        runtime_attention: attention({ execution_current: true, blocked: true }),
      }),
    })
    expect(state).toEqual<KeeperOperationalState>({
      kind: 'stuck',
      reason: 'cascade_exhausted',
    })
  })

  it('blocker without explicit stale marker ⇒ stuck (fail-closed default)', () => {
    // attention present but execution_current undefined → no explicit
    // stale marker → blocker stays meaningful (fail-closed). Mirrors the
    // older-backend case where runtime_attention may omit the field.
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ runtime_blocker_class: 'oas_timeout_budget' }),
      composite: makeComposite({
        runtime_attention: attention({ execution_current: undefined }),
      }),
    })
    expect(state).toEqual<KeeperOperationalState>({
      kind: 'stuck',
      reason: 'oas_timeout_budget',
    })
  })

  it('fiber_alive=false ⇒ stuck reason=fiber_dead even without blocker', () => {
    const composite = makeComposite()
    ;(composite as unknown as { phase_diagnosis: unknown }).phase_diagnosis = {
      conditions: { fiber_alive: false },
    }
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper(),
      composite,
    })
    expect(state).toEqual<KeeperOperationalState>({
      kind: 'stuck',
      reason: 'fiber_dead',
    })
  })

  it('every KEEPER_RUNTIME_BLOCKER_CLASSES value is a valid StuckReason', () => {
    for (const cls of KEEPER_RUNTIME_BLOCKER_CLASSES) {
      const state = deriveKeeperOperationalState({
        keeper: makeKeeper({ runtime_blocker_class: cls as KeeperRuntimeBlockerClass }),
        composite: null,
      })
      expect(state.kind === 'stuck' && state.reason === cls).toBe(true)
    }
  })
})

describe('deriveKeeperOperationalState — running branch with conditioning', () => {
  it('plain running, no composite, no blocker', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ phase: 'Running', status: 'active' }),
      composite: null,
    })
    expect(state).toEqual<KeeperOperationalState>({
      kind: 'running',
      turnPhase: 'idle',
      staleBlocker: null,
    })
  })

  it('RFC §1.1 EXACT scenario: blocker set BUT execution_current=false → running, blocker is stale', () => {
    // This is the lifecycle-worker case the user reported on 2026-05-19:
    // list card showed "현재 차단 · synthetic_stall" while detail showed
    // "턴 진행 중 · executing live". The detail panel's pre-RFC logic
    // demoted the blocker when execution_current=false (receipt is from
    // a prior turn). The typed SSOT mirrors that, producing
    // `running { staleBlocker: synthetic_stall }`.
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({
        phase: 'Running',
        status: 'active',
        runtime_blocker_class: 'synthetic_stall',
      }),
      composite: makeComposite({
        phase: 'Stable',
        turn_phase: 'executing',
        is_live: true,
        runtime_attention: attention({
          state: 'active',
          execution_current: false,
          stale_execution_receipt: true,
          blocked: false,
        }),
      }),
    })
    expect(state).toEqual<KeeperOperationalState>({
      kind: 'running',
      turnPhase: 'executing',
      staleBlocker: 'synthetic_stall',
    })
  })

  it('stale_execution_receipt=true with no blocker still surfaces as running (staleBlocker null)', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ phase: 'Running', status: 'active' }),
      composite: makeComposite({
        runtime_attention: attention({
          execution_current: true,
          stale_execution_receipt: true,
        }),
      }),
    })
    expect(state).toEqual<KeeperOperationalState>({
      kind: 'running',
      turnPhase: 'idle',
      staleBlocker: null,
    })
  })

  it('turn_phase from composite takes precedence over keeper.pipeline_stage', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({
        phase: 'Running',
        status: 'active',
        pipeline_stage: 'idle',
      }),
      composite: makeComposite({ turn_phase: 'compacting' }),
    })
    expect(state.kind === 'running' && state.turnPhase === 'compacting').toBe(true)
  })
})

describe('deriveKeeperOperationalState — priority invariants', () => {
  it('paused beats offline (paused supersedes status=offline)', () => {
    // A paused keeper with offline status must still derive paused, not
    // offline — paused is the more actionable operator signal.
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ paused: true, status: 'offline' }),
      composite: null,
    })
    expect(state.kind).toBe('paused')
  })

  it('paused beats stuck (paused supersedes blocker_class)', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({
        paused: true,
        runtime_blocker_class: 'synthetic_stall',
      }),
      composite: null,
    })
    expect(state.kind).toBe('paused')
  })

  it('offline beats stuck (offline supersedes blocker_class)', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({
        phase: 'Crashed',
        runtime_blocker_class: 'cascade_exhausted',
      }),
      composite: null,
    })
    expect(state.kind).toBe('offline')
  })

  it('stuck beats running (when receipt is current — execution_current=true)', () => {
    // Mirror of the pre-RFC detail-panel logic: the blocker drives the
    // headline iff the receipt is from the current live turn.
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({
        phase: 'Running',
        runtime_blocker_class: 'turn_timeout',
      }),
      composite: makeComposite({
        runtime_attention: attention({ execution_current: true }),
      }),
    })
    expect(state.kind).toBe('stuck')
  })

  it('running with staleBlocker beats stuck (when receipt is from prior turn)', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({
        phase: 'Running',
        runtime_blocker_class: 'turn_timeout',
      }),
      composite: makeComposite({
        runtime_attention: attention({
          execution_current: false,
          stale_execution_receipt: true,
        }),
      }),
    })
    expect(state).toEqual<KeeperOperationalState>({
      kind: 'running',
      turnPhase: 'idle',
      staleBlocker: 'turn_timeout',
    })
  })
})

describe('deriveKeeperOperationalState — exhaustive kind union', () => {
  it('every returned state has a discriminant kind ∈ {offline, paused, stuck, running}', () => {
    const samples: Array<DeriveInputsLite> = [
      { keeper: makeKeeper(), composite: null },
      { keeper: makeKeeper({ paused: true }), composite: null },
      { keeper: makeKeeper({ phase: 'Crashed' }), composite: null },
      {
        keeper: makeKeeper({ runtime_blocker_class: 'exception' }),
        composite: null,
      },
      {
        keeper: makeKeeper(),
        composite: makeComposite({
          runtime_attention: attention({ execution_current: true }),
        }),
      },
    ]
    const validKinds = new Set(['offline', 'paused', 'stuck', 'running'])
    for (const input of samples) {
      const result = deriveKeeperOperationalState(input)
      expect(validKinds.has(result.kind)).toBe(true)
    }
  })
})

interface DeriveInputsLite {
  keeper: Keeper
  composite: KeeperCompositeSnapshot | null
}

describe('toKsmPhase — RFC-0135 PR-11 wire-boundary narrow', () => {
  it.each<KeeperKsmPhase>([
    'offline', 'running', 'failing', 'overflowed', 'compacting',
    'handing_off', 'draining', 'paused', 'stopped', 'crashed',
    'restarting', 'dead', 'zombie',
  ])('accepts canonical KSM phase %s', (phase) => {
    expect(toKsmPhase(phase)).toBe(phase)
  })
  it('returns null on unknown string', () => {
    expect(toKsmPhase('plotting_revenge')).toBeNull()
  })
  it('returns null on null/undefined', () => {
    expect(toKsmPhase(null)).toBeNull()
    expect(toKsmPhase(undefined)).toBeNull()
  })
  it('returns null on empty string', () => {
    expect(toKsmPhase('')).toBeNull()
  })
})

describe('compositePhaseTone — RFC-0135 PR-11 exhaustive switch', () => {
  it.each<KeeperKsmPhase>(['offline', 'running'])('phase %s ⇒ active', (phase) => {
    expect(compositePhaseTone(phase)).toBe('active')
  })
  it.each<KeeperKsmPhase>([
    'overflowed', 'compacting', 'handing_off', 'draining', 'paused', 'restarting',
  ])('phase %s ⇒ warn', (phase) => {
    expect(compositePhaseTone(phase)).toBe('warn')
  })
  it.each<KeeperKsmPhase>([
    'failing', 'stopped', 'crashed', 'dead', 'zombie',
  ])('phase %s ⇒ err', (phase) => {
    expect(compositePhaseTone(phase)).toBe('err')
  })
})

describe('compositeIsRunning / compositeIsTurnIdle — wire-format helpers', () => {
  it('phase=running ⇒ true', () => {
    expect(compositeIsRunning({ phase: 'running' })).toBe(true)
  })
  it('phase=paused ⇒ false', () => {
    expect(compositeIsRunning({ phase: 'paused' })).toBe(false)
  })
  it('turn_phase=idle ⇒ true', () => {
    expect(compositeIsTurnIdle({ turn_phase: 'idle' })).toBe(true)
  })
  it('turn_phase=executing ⇒ false', () => {
    expect(compositeIsTurnIdle({ turn_phase: 'executing' })).toBe(false)
  })
})

describe('deriveKeeperAttention — RFC-0135 PR-14a', () => {
  const makeComposite = (
    attentionOverrides: Partial<{ blocked: boolean; needs_attention: boolean }>,
  ): KeeperCompositeSnapshot =>
    ({
      keeper: 'test',
      runtime_attention: {
        blocked: false,
        needs_attention: false,
        ...attentionOverrides,
      },
    } as unknown as KeeperCompositeSnapshot)

  it('blocked=true ⇒ blocked', () => {
    expect(deriveKeeperAttention(makeComposite({ blocked: true }))).toBe<KeeperAttention>('blocked')
  })
  it('needs_attention=true ⇒ needs_attention', () => {
    expect(deriveKeeperAttention(makeComposite({ needs_attention: true }))).toBe<KeeperAttention>('needs_attention')
  })
  it('blocked beats needs_attention when both set', () => {
    expect(
      deriveKeeperAttention(makeComposite({ blocked: true, needs_attention: true })),
    ).toBe<KeeperAttention>('blocked')
  })
  it('neither flag set ⇒ clean', () => {
    expect(deriveKeeperAttention(makeComposite({}))).toBe<KeeperAttention>('clean')
  })
  it('null composite ⇒ clean (no backend attestation)', () => {
    expect(deriveKeeperAttention(null)).toBe<KeeperAttention>('clean')
  })
})

describe('deriveKeeperDisplayReason — RFC-0135 PR-14c', () => {
  const composite = (reason: string | undefined): KeeperCompositeSnapshot =>
    ({
      keeper: 'test',
      runtime_attention: reason !== undefined ? { reason } : {},
    } as unknown as KeeperCompositeSnapshot)

  it('composite reason wins over flat summary', () => {
    expect(
      deriveKeeperDisplayReason(
        { runtime_blocker_summary: 'flat summary', attention_reason: 'pinned' } as Keeper,
        composite('live reason'),
      ),
    ).toBe('live reason')
  })
  it('falls back to runtime_blocker_summary when composite empty', () => {
    expect(
      deriveKeeperDisplayReason(
        { runtime_blocker_summary: 'flat summary', attention_reason: 'pinned' } as Keeper,
        composite(undefined),
      ),
    ).toBe('flat summary')
  })
  it('falls back to attention_reason when summary missing', () => {
    expect(
      deriveKeeperDisplayReason(
        { attention_reason: 'pinned' } as Keeper,
        null,
      ),
    ).toBe('pinned')
  })
  it('filters whitespace-only reason', () => {
    expect(
      deriveKeeperDisplayReason(
        { runtime_blocker_summary: 'real value' } as Keeper,
        composite('   '),
      ),
    ).toBe('real value')
  })
  it('returns null when no source has a non-empty value', () => {
    expect(deriveKeeperDisplayReason({} as Keeper, null)).toBeNull()
  })
})
