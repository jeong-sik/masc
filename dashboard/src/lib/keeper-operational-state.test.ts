import { describe, expect, it } from 'vitest'
import type { Keeper, KeeperRuntimeBlockerClass } from '../types/core'
import { KEEPER_RUNTIME_BLOCKER_CLASSES } from '../types/core'
import type { KeeperCompositeSnapshot } from '../api/schemas/keeper-composite'
import {
  compositeIsRunning,
  compositeIsTurnIdle,
  compositePhaseTone,
  derivePreferredPhase,
  deriveKeeperDisplayReason,
  deriveKeeperOperationalState,
  deriveKeeperTurnPhase,
  type KeeperAttention,
} from './keeper-operational-state'
import { toKeeperPhase } from '../keeper-store-normalize'
import type { KeeperPhase } from '../types/core'

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
    runtime: { state: 'idle' },
    compaction: { stage: 'idle' },
    measurement: {} as KeeperCompositeSnapshot['measurement'],
    invariants: {} as KeeperCompositeSnapshot['invariants'],
    fsm_guard_violations: 0,
    fsm_guard_violation_breakdown: [],
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
    expect(state).toMatchObject({
      kind: 'paused',
      attention: 'clean',
      cause: 'operator',
    })
  })

  it('paused operator cause when phase === Paused', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ phase: 'Paused' }),
      composite: null,
    })
    expect(state).toMatchObject({
      kind: 'paused',
      attention: 'clean',
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
    expect(state).toMatchObject({
      kind: 'paused',
      attention: 'clean',
      cause: 'supervisor',
    })
  })

  it('paused auto_recover cause when blocker is retryable timeout', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({
        paused: true,
        runtime_blocker_class: 'turn_timeout',
      }),
      composite: null,
    })
    expect(state).toMatchObject({
      kind: 'paused',
      attention: 'clean',
      cause: 'auto_recover',
    })
  })

  it('paused operator cause when pause_state === paused', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ pause_state: 'paused' }),
      composite: null,
    })
    expect(state).toMatchObject({
      kind: 'paused',
      attention: 'clean',
      cause: 'operator',
    })
  })

  it('paused operator cause when only status === paused', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ status: 'paused', phase: null, paused: false }),
      composite: null,
    })
    expect(state).toMatchObject({
      kind: 'paused',
      attention: 'clean',
      cause: 'operator',
    })
  })

  it('paused operator cause when only pipeline_stage === paused', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({
        status: 'active',
        phase: 'Running',
        paused: false,
        pipeline_stage: 'paused',
      }),
      composite: null,
    })
    expect(state).toMatchObject({
      kind: 'paused',
      attention: 'clean',
      cause: 'operator',
    })
  })

  it('paused operator cause when composite phase is paused', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ phase: 'Running', status: 'active', paused: false }),
      composite: makeComposite({ phase: 'paused' }),
    })
    expect(state).toMatchObject({
      kind: 'paused',
      attention: 'clean',
      cause: 'operator',
    })
  })
})

describe('deriveKeeperOperationalState — offline branch', () => {
  it.each<[Keeper['phase'], 'crashed' | 'dead' | 'shutdown' | 'unbooted']>([
    ['Crashed', 'crashed'],
    ['Dead', 'dead'],
    ['Stopped', 'shutdown'],
    ['Offline', 'unbooted'],
  ])('phase=%s → cause=%s', (phase, cause) => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ phase, status: 'offline' }),
      composite: null,
    })
    expect(state).toMatchObject({ kind: 'offline', attention: 'clean', cause })
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
  it('synthetic_stall without composite ⇒ running because it is diagnostic-only', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({
        runtime_blocker_class: 'synthetic_stall',
      }),
      composite: null,
    })
    expect(state).toMatchObject({
      kind: 'running',
      attention: 'clean',
      staleBlocker: null,
    })
  })

  it('synthetic_stall with blocked runtime_attention ⇒ stuck', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({
        runtime_blocker_class: 'synthetic_stall',
      }),
      composite: makeComposite({
        runtime_attention: attention({ execution_current: true, blocked: true }),
      }),
    })
    expect(state).toMatchObject({
      kind: 'stuck',
      attention: 'blocked',
      reason: 'synthetic_stall',
    })
  })

  it('blocker AND execution_current=true ⇒ stuck (receipt is current)', () => {
    // execution_current=true means the receipt matches the *current* live
    // turn (server_dashboard_http.ml:1061-1074) — the blocker is meaningful.
    // attention=blocked here because runtime_attention.blocked=true (kind/
    // attention orthogonality covered in the §13 axis-extension suite).
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ runtime_blocker_class: 'runtime_exhausted' }),
      composite: makeComposite({
        runtime_attention: attention({ execution_current: true, blocked: true }),
      }),
    })
    expect(state).toMatchObject({
      kind: 'stuck',
      attention: 'blocked',
      reason: 'runtime_exhausted',
    })
  })

  it('blocker without explicit stale marker ⇒ stuck (fail-closed default)', () => {
    // attention present but execution_current undefined → no explicit
    // stale marker → blocker stays meaningful (fail-closed). Mirrors the
    // older-backend case where runtime_attention may omit the field.
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ runtime_blocker_class: 'turn_timeout' }),
      composite: makeComposite({
        runtime_attention: attention({ execution_current: undefined }),
      }),
    })
    expect(state).toMatchObject({
      kind: 'stuck',
      attention: 'clean',
      reason: 'turn_timeout',
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
    expect(state).toMatchObject({
      kind: 'stuck',
      attention: 'clean',
      reason: 'fiber_dead',
    })
  })

  it('every KEEPER_RUNTIME_BLOCKER_CLASSES value is a valid StuckReason', () => {
    for (const cls of KEEPER_RUNTIME_BLOCKER_CLASSES) {
      const state = deriveKeeperOperationalState({
        keeper: makeKeeper({ runtime_blocker_class: cls as KeeperRuntimeBlockerClass }),
        composite: cls === 'synthetic_stall'
          ? makeComposite({ runtime_attention: attention({ execution_current: true, blocked: true }) })
          : null,
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
    expect(state).toMatchObject({
      kind: 'running',
      attention: 'clean',
      turnPhase: 'unknown',
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
    expect(state).toMatchObject({
      kind: 'running',
      attention: 'clean',
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
    expect(state).toMatchObject({
      kind: 'running',
      attention: 'clean',
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
        runtime_blocker_class: 'runtime_exhausted',
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
    expect(state).toMatchObject({
      kind: 'running',
      attention: 'clean',
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

describe('toKeeperPhase — wire-boundary narrow (lowercase + PascalCase)', () => {
  it.each<KeeperPhase>([
    'Offline', 'Running', 'Failing', 'Overflowed', 'Compacting',
    'HandingOff', 'Draining', 'Paused', 'Stopped', 'Crashed',
    'Restarting', 'Dead',
  ])('accepts PascalCase KeeperPhase %s', (phase) => {
    expect(toKeeperPhase(phase)).toBe(phase)
  })
  it.each([
    ['offline', 'Offline'],
    ['running', 'Running'],
    ['failing', 'Failing'],
    ['handing_off', 'HandingOff'],
    ['dead', 'Dead'],
  ])('accepts lowercase wire format %s → %s', (input, expected) => {
    expect(toKeeperPhase(input)).toBe(expected)
  })
  it('returns null on unknown string', () => {
    expect(toKeeperPhase('plotting_revenge')).toBeNull()
  })
  it('returns null on null/undefined', () => {
    expect(toKeeperPhase(null)).toBeNull()
    expect(toKeeperPhase(undefined)).toBeNull()
  })
  it('returns null on empty string', () => {
    expect(toKeeperPhase('')).toBeNull()
  })
})

describe('compositePhaseTone — exhaustive switch over KeeperPhase', () => {
  it.each<KeeperPhase>(['Offline', 'Running'])('phase %s ⇒ active', (phase) => {
    expect(compositePhaseTone(phase)).toBe('active')
  })
  it.each<KeeperPhase>([
    'Overflowed', 'Compacting', 'HandingOff', 'Draining', 'Paused', 'Restarting',
  ])('phase %s ⇒ warn', (phase) => {
    expect(compositePhaseTone(phase)).toBe('warn')
  })
  it.each<KeeperPhase>([
    'Failing', 'Stopped', 'Crashed', 'Dead',
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

describe('KeeperOperationalState.attention axis — RFC-0135 §13 Goal-2 (2026-05-20)', () => {
  // The standalone `deriveKeeperAttention` was retired in favour of
  // a per-variant `attention` axis on `KeeperOperationalState`. The
  // priority rule (blocked > needs_attention > clean) is unchanged;
  // the migration moved derivation into `deriveKeeperOperationalState`
  // so external callers can no longer OR-merge an off-SSOT attention
  // axis with kind (audit B3 root pattern).

  it('blocked=true ⇒ attention=blocked', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper(),
      composite: makeComposite({ runtime_attention: attention({ blocked: true }) }),
    })
    expect(state.attention).toBe<KeeperAttention>('blocked')
  })

  it('needs_attention=true ⇒ attention=needs_attention', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper(),
      composite: makeComposite({ runtime_attention: attention({ needs_attention: true }) }),
    })
    expect(state.attention).toBe<KeeperAttention>('needs_attention')
  })

  it('blocked beats needs_attention when both set', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper(),
      composite: makeComposite({
        runtime_attention: attention({ blocked: true, needs_attention: true }),
      }),
    })
    expect(state.attention).toBe<KeeperAttention>('blocked')
  })

  it('neither flag set ⇒ attention=clean', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper(),
      composite: makeComposite({ runtime_attention: attention({}) }),
    })
    expect(state.attention).toBe<KeeperAttention>('clean')
  })

  it('null composite ⇒ attention=clean (no backend attestation)', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper(),
      composite: null,
    })
    expect(state.attention).toBe<KeeperAttention>('clean')
  })

  // §13 axis × kind orthogonality matrix — attention is computed
  // independently of which `kind` variant the keeper resolves into.
  it.each<[
    'offline' | 'paused' | 'stuck' | 'running',
    Partial<Keeper>,
    Partial<KeeperCompositeSnapshot> | null,
    KeeperAttention,
  ]>([
    // kind=paused × attention=blocked
    ['paused', { paused: true }, { runtime_attention: attention({ blocked: true }) }, 'blocked'],
    // kind=offline × attention=needs_attention
    ['offline', { phase: 'Offline' }, { runtime_attention: attention({ needs_attention: true }) }, 'needs_attention'],
    // kind=stuck × attention=blocked
    ['stuck', { runtime_blocker_class: 'turn_timeout' as KeeperRuntimeBlockerClass }, { runtime_attention: attention({ blocked: true }) }, 'blocked'],
    // kind=running × attention=clean
    ['running', {}, { runtime_attention: attention({}) }, 'clean'],
  ])('kind=%s × attention=%s — axes orthogonal', (kind, keeperOverrides, compositeOverrides, expectedAttention) => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper(keeperOverrides),
      composite: compositeOverrides === null ? null : makeComposite(compositeOverrides),
    })
    expect(state.kind).toBe(kind)
    expect(state.attention).toBe<KeeperAttention>(expectedAttention)
  })
})

describe('KeeperOperationalState remaining Goal-2 axes — RFC-0135 strict closeout', () => {
  it('turnPhase is present on non-running variants and uses composite before flat fallback', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ paused: true, pipeline_stage: 'idle' }),
      composite: makeComposite({ turn_phase: 'executing' }),
    })
    expect(state.kind).toBe('paused')
    expect(state.turnPhase).toBe('executing')
  })

  it('turnPhase falls back to flat pipeline_stage on every variant', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ phase: 'Crashed', pipeline_stage: 'failing' }),
      composite: null,
    })
    expect(state.kind).toBe('offline')
    expect(state.turnPhase).toBe('failing')
  })

  it('turnPhase uses explicit unknown marker when neither source is present', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper(),
      composite: null,
    })
    expect(state.turnPhase).toBe('unknown')
  })

  it('displaySummary is present on the state and keeps composite-preferred precedence', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({
        runtime_blocker_class: 'turn_timeout',
        runtime_blocker_summary: 'flat summary',
        attention_reason: 'attention memo',
      }),
      composite: makeComposite({
        runtime_attention: attention({ reason: 'live reason' }),
      }),
    })
    expect(state.kind).toBe('stuck')
    expect(state.displaySummary).toBe('live reason')
  })

  it('phase is present on the state and uses composite-preferred phase when lifecycle is not terminal', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ phase: 'Running', status: 'active' }),
      composite: makeComposite({ phase: 'compacting' }),
    })
    expect(state.phase).toBe('Compacting')
  })

  it('phase keeps terminal lifecycle status authoritative over a stale composite phase', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ phase: 'Paused', status: 'active', paused: true }),
      composite: makeComposite({ phase: 'running' }),
    })
    expect(state.kind).toBe('paused')
    expect(state.phase).toBe('Paused')
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

describe('deriveKeeperTurnPhase — RFC-0135 PR-14b', () => {
  it('composite turn_phase wins over flat pipeline_stage', () => {
    expect(
      deriveKeeperTurnPhase(
        { pipeline_stage: 'idle' } as Keeper,
        { turn_phase: 'executing' } as unknown as KeeperCompositeSnapshot,
      ),
    ).toBe('executing')
  })
  it('falls back to pipeline_stage when composite null', () => {
    expect(deriveKeeperTurnPhase({ pipeline_stage: 'compacting' } as Keeper, null)).toBe('compacting')
  })
  it('falls back to pipeline_stage when composite turn_phase empty string', () => {
    expect(
      deriveKeeperTurnPhase(
        { pipeline_stage: 'handoff' } as Keeper,
        { turn_phase: '' } as unknown as KeeperCompositeSnapshot,
      ),
    ).toBe('handoff')
  })
  it('returns null when both sources empty', () => {
    expect(deriveKeeperTurnPhase({} as Keeper, null)).toBeNull()
  })
})

describe('derivePreferredPhase — RFC-0135 PR-14d', () => {
  it('composite wire phase wins over flat keeper.phase', () => {
    expect(
      derivePreferredPhase(
        { phase: 'Running' } as Keeper,
        { phase: 'compacting' } as unknown as KeeperCompositeSnapshot,
      ),
    ).toBe('Compacting')
  })
  it('falls back to keeper.phase when composite empty', () => {
    expect(
      derivePreferredPhase({ phase: 'HandingOff' } as Keeper, null),
    ).toBe('HandingOff')
  })
  it('falls back to keeper.phase when composite has unknown wire value', () => {
    expect(
      derivePreferredPhase(
        { phase: 'Running' } as Keeper,
        { phase: 'inventing_new_state' } as unknown as KeeperCompositeSnapshot,
      ),
    ).toBe('Running')
  })
  it('returns null when neither source has a known phase', () => {
    expect(derivePreferredPhase({} as Keeper, null)).toBeNull()
  })
})
