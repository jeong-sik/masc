import { describe, it, expect } from 'vitest'
import { compositeSnapshotForKeeper } from './keeper-composite-lookup'
import { buildCompositeByKeeperKey } from '../composite-signals'
import type { Keeper } from '../types'
import type {
  FleetCompositeSnapshot,
  KeeperCompositeSnapshot,
} from '../api/schemas/keeper-composite'

function snapshot(overrides: Partial<KeeperCompositeSnapshot> = {}): KeeperCompositeSnapshot {
  return {
    correlation_id: 'corr-1',
    run_id: 'run-1',
    ts: 1_000_000,
    phase: 'running',
    turn_phase: 'idle',
    decision: { stage: 'undecided' },
    runtime: { state: 'idle' },
    compaction: { stage: 'accumulating' },
    measurement: { captured: false },
    invariants: {
      phase_turn_alignment: true,
      no_runtime_before_measurement: true,
      compaction_atomicity: true,
      event_priority_monotone: true,
      phase_derivation_agreement: true,
    },
    fsm_guard_violations: 0,
    fsm_guard_violation_breakdown: [],
    is_live: true,
    last_outcome: null,
    recommended_actions: [],
    ...overrides,
  }
}

function keeper(overrides: Partial<Keeper> = {}): Keeper {
  return {
    name: 'sangsu',
    keeper_id: 'keeper-id-sangsu',
    agent_name: 'keeper-sangsu-agent',
    status: 'running',
    ...overrides,
  } as Keeper
}

function fleet(snapshots: KeeperCompositeSnapshot[]): FleetCompositeSnapshot {
  return { generated_at: 1_000_000, count: snapshots.length, snapshots }
}

describe('compositeSnapshotForKeeper', () => {
  it('resolves the snapshot by keeper name', () => {
    const snap = snapshot({ keeper: 'sangsu', correlation_id: 'corr-sangsu' })
    const byKey = buildCompositeByKeeperKey(fleet([snap]))
    expect(compositeSnapshotForKeeper(keeper(), byKey)).toBe(snap)
  })

  it('falls back to keeper_id when the name key is absent', () => {
    // Snapshot keyed only by correlation_id equal to the keeper_id.
    const snap = snapshot({ correlation_id: 'keeper-id-sangsu' })
    const byKey = buildCompositeByKeeperKey(fleet([snap]))
    expect(compositeSnapshotForKeeper(keeper(), byKey)).toBe(snap)
  })

  it('returns null when no key matches the keeper', () => {
    const snap = snapshot({ keeper: 'someone-else', correlation_id: 'corr-else' })
    const byKey = buildCompositeByKeeperKey(fleet([snap]))
    expect(compositeSnapshotForKeeper(keeper(), byKey)).toBeNull()
  })

  it('returns null for a null keeper or null map', () => {
    const byKey = buildCompositeByKeeperKey(fleet([snapshot({ keeper: 'sangsu' })]))
    expect(compositeSnapshotForKeeper(null, byKey)).toBeNull()
    expect(compositeSnapshotForKeeper(keeper(), null)).toBeNull()
  })
})
