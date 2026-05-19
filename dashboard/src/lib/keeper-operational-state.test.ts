import { describe, expect, it } from 'vitest'
import type { Keeper, KeeperRuntimeBlockerClass } from '../types/core'
import { KEEPER_RUNTIME_BLOCKER_CLASSES } from '../types/core'
import type { KeeperCompositeSnapshot } from '../api/schemas/keeper-composite'
import {
  deriveKeeperOperationalState,
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

  it('blocker AND execution_current=false ⇒ stuck (RFC §1.1)', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({ runtime_blocker_class: 'cascade_exhausted' }),
      composite: makeComposite({
        runtime_attention: attention({ execution_current: false, blocked: true }),
      }),
    })
    expect(state).toEqual<KeeperOperationalState>({
      kind: 'stuck',
      reason: 'cascade_exhausted',
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

  it('RFC §1.1 EXACT scenario: blocker set BUT execution_current=true → running, blocker is stale', () => {
    // This is the lifecycle-worker case the user reported on 2026-05-19:
    // list card showed "현재 차단 · synthetic_stall" while detail showed
    // "턴 진행 중 · executing live". The SSOT verdict must be running.
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
          execution_current: true,
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

  it('is_live=true with execution_current=false still treats blocker as stale (running, RFC §1.1 sibling)', () => {
    // Backend may briefly emit `execution_current=false` early in a
    // fresh turn — before the first receipt for it has landed — while
    // still flagging the live turn via `is_live=true`. The flat
    // `runtime_blocker_class` from the prior turn must not surface as
    // an active blocker in this window. Matches the
    // `deriveKeeperLiveTruth` fixture 2 expectation
    // (`previousExecutionReceipt` short-circuit) that this typed-sum
    // is taking over.
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({
        phase: 'Running',
        status: 'active',
        runtime_blocker_class: 'cascade_exhausted',
        runtime_blocker_summary: 'previous turn exhausted cascade',
      }),
      composite: makeComposite({
        is_live: true,
        turn_phase: 'executing',
        runtime_attention: attention({
          state: 'ok',
          execution_current: false,
          stale_execution_receipt: true,
          blocked: false,
        }),
      }),
    })
    expect(state).toEqual<KeeperOperationalState>({
      kind: 'running',
      turnPhase: 'executing',
      staleBlocker: 'cascade_exhausted',
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

  it('stuck beats running (when execution not fresh)', () => {
    const state = deriveKeeperOperationalState({
      keeper: makeKeeper({
        phase: 'Running',
        runtime_blocker_class: 'turn_timeout',
      }),
      composite: makeComposite({
        runtime_attention: attention({ execution_current: false }),
      }),
    })
    expect(state.kind).toBe('stuck')
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
