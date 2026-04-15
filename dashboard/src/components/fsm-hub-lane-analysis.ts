import type { KeeperCompositeSnapshot } from '../api/keeper'

import {
  type CompositeObservation,
  type InsightTone,
  type LaneKey,
  type ObservedLaneSummary,
  LANE_LABELS,
  TRANSITION_FIELDS,
  extractLaneValue,
} from './fsm-hub-types'
import { laneChangedAt, laneTransitionCount } from './fsm-hub-derivations'

export function isObservedStall(
  key: LaneKey,
  value: string,
  observedForSec: number,
): boolean {
  if (key === 'phase') {
    if (value === 'Failing') return observedForSec >= 90
    if (value === 'Overflowed') return observedForSec >= 60
    if (value === 'Compacting') return observedForSec >= 90
    if (value === 'HandingOff' || value === 'Draining') return observedForSec >= 60
    return false
  }
  if (key === 'turn') {
    if (value === 'prompting' || value === 'executing') return observedForSec >= 45
    if (value === 'compacting') return observedForSec >= 60
    if (value === 'finalizing') return observedForSec >= 30
    return false
  }
  if (key === 'cascade') {
    if (value === 'selecting') return observedForSec >= 30
    if (value === 'trying') return observedForSec >= 45
    return false
  }
  if (key === 'compaction') {
    return value === 'compacting' && observedForSec >= 60
  }
  return false
}

function laneMeaning(
  key: LaneKey,
  snapshot: KeeperCompositeSnapshot,
  observedForSec: number,
): { tone: InsightTone; meaning: string } {
  const value = extractLaneValue(snapshot, key)

  const base: { tone: InsightTone; meaning: string } = (() => {
    switch (key) {
    case 'phase':
      switch (value) {
        case 'Running':
          return snapshot.is_live
            ? { tone: 'info', meaning: 'parent lifecycle is healthy while the live turn advances' }
            : { tone: 'ok', meaning: 'no live turn; waiting for the next observation cycle' }
        case 'Failing':
          return { tone: 'error', meaning: 'recovery owns the keeper lifecycle until reconcile clears' }
        case 'Overflowed':
          return { tone: 'warn', meaning: 'context overflow has been latched and must resolve before healthy turns resume' }
        case 'Compacting':
          return { tone: 'warn', meaning: 'post-turn compaction currently owns the lifecycle' }
        case 'HandingOff':
          return { tone: 'warn', meaning: 'handoff is draining this keeper toward stop' }
        case 'Draining':
          return { tone: 'warn', meaning: 'the keeper is draining in-flight work before stop' }
        case 'Stable':
          return { tone: 'info', meaning: 'no lifecycle activity is currently expected' }
        default:
          return { tone: 'info', meaning: 'lifecycle state observed' }
      }
    case 'turn':
      switch (value) {
        case 'idle':
          return { tone: snapshot.is_live ? 'info' : 'ok', meaning: snapshot.is_live ? 'turn context exists but work has not advanced yet' : 'no in-flight turn is being observed' }
        case 'prompting':
          return { tone: 'info', meaning: 'prompt assembly is still preparing the turn inputs' }
        case 'executing':
          return { tone: 'info', meaning: 'the turn is inside model/tool execution work' }
        case 'compacting':
          return { tone: 'warn', meaning: 'turn finalization is blocked on compaction finishing' }
        case 'finalizing':
          return { tone: 'info', meaning: 'the turn is sealing results and preparing the next idle snapshot' }
        default:
          return { tone: 'info', meaning: 'turn-cycle state observed' }
      }
    case 'decision':
      switch (value) {
        case 'undecided':
          return { tone: snapshot.is_live ? 'info' : 'ok', meaning: snapshot.is_live ? 'decision work has not committed yet' : 'idle snapshots intentionally clear decision state' }
        case 'guard_ok':
          return { tone: 'info', meaning: 'guardrails allowed the turn to continue' }
        case 'gate_rejected':
          return { tone: 'warn', meaning: 'guardrails blocked the turn before tool/model work' }
        case 'tool_policy_selected':
          return { tone: 'info', meaning: 'tool policy selection has committed and execution can advance' }
        default:
          return { tone: 'info', meaning: 'decision state observed' }
      }
    case 'cascade':
      switch (value) {
        case 'idle':
          return { tone: 'ok', meaning: 'no provider failover work is active' }
        case 'selecting':
          return { tone: 'info', meaning: 'provider routing is selecting the next execution path' }
        case 'trying':
          return { tone: 'info', meaning: 'provider execution is in flight' }
        case 'done':
          return { tone: 'ok', meaning: 'cascade accepted a provider result for this turn' }
        case 'exhausted':
          return { tone: 'error', meaning: 'all cascade options were consumed without a usable path' }
        default:
          return { tone: 'info', meaning: 'cascade state observed' }
      }
    case 'compaction':
      switch (value) {
        case 'accumulating':
          return { tone: 'ok', meaning: 'memory is collecting compaction candidates, not executing yet' }
        case 'compacting':
          return { tone: 'warn', meaning: 'memory compaction is actively rewriting context state' }
        case 'done':
          return { tone: 'ok', meaning: 'compaction finished for the observed turn' }
        default:
          return { tone: 'info', meaning: 'compaction state observed' }
      }
    }
  })()

  if (base.tone !== 'error' && isObservedStall(key, value, observedForSec)) {
    return { tone: 'warn', meaning: 'state movement looks stalled on this screen' }
  }
  return base
}

export function deriveObservedLaneSummaries(
  snapshot: KeeperCompositeSnapshot,
  observations: CompositeObservation[],
  now: number,
): ObservedLaneSummary[] {
  return TRANSITION_FIELDS.map(({ field, key }) => {
    const changedAt = laneChangedAt(observations, key)
    const observedForSec = changedAt > 0 ? Math.max(0, now - changedAt) : 0
    const transitionCount = laneTransitionCount(observations, key)
    const meaning = laneMeaning(key, snapshot, observedForSec)
    const value = extractLaneValue(snapshot, key)
    const stalled = isObservedStall(key, value, observedForSec)

    return {
      field,
      label: LANE_LABELS[key],
      value,
      tone: stalled && meaning.tone !== 'error' ? 'warn' : meaning.tone,
      stalled,
      meaning: meaning.meaning,
      observedForSec,
      transitionCount,
    }
  })
}
