// Harness health state management and data loading.

import { get } from '../api/core'
import { createAsyncResource, loaded, type AsyncResource } from '../lib/async-state'
import { lastEvent } from '../sse'
import { asNumber, asString, asStringArray, isRecord } from './common/normalize'

export type RailStatus = 'healthy' | 'warning' | 'stale' | 'idle'

export interface GateDistribution {
  [gate: string]: number
}

interface CalibrationStats {
  total_verdicts: number
  approve_count: number
  reject_count: number
  gate_distribution: GateDistribution
  labeled_count: number
  false_positive_count: number
  false_negative_count: number
  agreement_rate: number
  fallback_count?: number
  recent_fallback_reasons?: string[]
}

interface HarnessOverview {
  evaluator_status: RailStatus
  pre_compact_status: RailStatus
  handoff_status: RailStatus
  last_signal_at: number | null
  evaluator_last_event_at: number | null
  pre_compact_last_event_at: number | null
  handoff_last_event_at: number | null
  fallback_ratio: number
  // Added by lib/dashboard/dashboard_harness_health.ml as part of #6565.
  // Ratio of verdicts whose generator_cascade ≠ evaluator_cascade among
  // verdicts that carried a generator_cascade. undefined when the backend
  // had zero eligible verdicts to compute the ratio.
  cross_model_rate?: number
  latest_pre_compact_ratio: number | null
  latest_handoff_generation: number | null
}

export interface HarnessVerdictItem {
  timestamp: number
  task_id: string
  task_title: string
  agent_name: string
  gate: string
  verdict: string
  evaluator_cascade: string
  // Added by lib/tool_task.ml#build_verdict_sse_payload as part of #6565.
  generator_cascade?: string | null
  cross_model?: boolean
  fallback_reason?: string | null
}

export interface PreCompactEvent {
  timestamp: number
  keeper_name: string
  context_ratio: number
  message_count: number
  token_count: number
  strategies: string[]
  model_family: string
  trigger: string
}

export interface HandoffEvent {
  timestamp: number
  keeper_name: string
  trace_id: string
  generation: number
  next_generation: number | null
  prev_trace_id: string | null
  new_trace_id: string | null
  to_model: string | null
}

export interface HarnessSignalSection<T> {
  description: string
  recent_events: T[]
  total_recent: number
  status: RailStatus
  last_event_at: number | null
  empty_reason?: string | null
}

export interface HarnessHealthData {
  generated_at: number
  scope_note: string
  overview: HarnessOverview
  calibration: CalibrationStats
  recent_verdicts: HarnessVerdictItem[]
  pre_compact: HarnessSignalSection<PreCompactEvent>
  recent_handoffs: HarnessSignalSection<HandoffEvent>
}

const HARNESS_RELOAD_DEBOUNCE_MS = 700

export const harness: AsyncResource<HarnessHealthData> = createAsyncResource()
let reloadTimer: ReturnType<typeof setTimeout> | null = null

export function clearHarnessReloadTimer(): void {
  if (reloadTimer) {
    clearTimeout(reloadTimer)
    reloadTimer = null
  }
}

function scheduleHarnessReload(): void {
  clearHarnessReloadTimer()
  reloadTimer = setTimeout(() => {
    void loadHarnessHealth()
  }, HARNESS_RELOAD_DEBOUNCE_MS)
}

export function resetHarnessHealthState(): void {
  harness.reset()
  clearHarnessReloadTimer()
}

export function loadHarnessHealth(): Promise<void> {
  return harness.load(() => get<HarnessHealthData>('/api/v1/dashboard/harness-health'))
}

export async function refreshHarnessSurface(): Promise<void> {
  await loadHarnessHealth()
}

export function mergeRecent<T>(
  current: T[],
  nextItem: T,
  isSame: (left: T, right: T) => boolean,
  maxItems: number,
) {
  const filtered = current.filter(item => !isSame(item, nextItem))
  return [nextItem, ...filtered].slice(0, maxItems)
}

function updateHarnessData(
  update: (data: HarnessHealthData) => HarnessHealthData,
): void {
  const s = harness.state.value
  if (s.status !== 'loaded') return
  harness.state.value = loaded(update(s.data))
}

export function decodeEventPayload(event: unknown): Record<string, unknown> | null {
  if (!isRecord(event)) return null
  return isRecord(event.payload) ? event.payload : null
}

function processHarnessEvent(evt: unknown): void {
  if (!evt) return
  const event = evt as Record<string, unknown>
  const type = typeof event.type === 'string' ? event.type : ''
  const payload = decodeEventPayload(evt)

  if (type === 'oas:masc:harness:verdict_recorded') {
    if (!payload) return
    const nextItem: HarnessVerdictItem = {
      timestamp: asNumber(payload.timestamp) ?? Date.now() / 1000,
      task_id: asString(payload.task_id, ''),
      task_title: asString(payload.task_title, 'task'),
      agent_name: asString(payload.agent_name, ''),
      gate: asString(payload.gate, ''),
      verdict: asString(payload.verdict, ''),
      evaluator_cascade: asString(payload.evaluator_cascade, ''),
      fallback_reason: asString(payload.fallback_reason) ?? null,
    }
    updateHarnessData(data => ({
      ...data,
      recent_verdicts: mergeRecent(
        data.recent_verdicts,
        nextItem,
        (left, right) =>
          left.timestamp === right.timestamp
          && left.task_id === right.task_id
          && left.verdict === right.verdict,
        8,
      ),
      overview: {
        ...data.overview,
        last_signal_at: nextItem.timestamp,
        evaluator_last_event_at: nextItem.timestamp,
      },
    }))
    scheduleHarnessReload()
  }

  if (type === 'oas:masc:harness:pre_compact') {
    if (!payload) return
    const nextItem: PreCompactEvent = {
      timestamp: asNumber(payload.timestamp) ?? Date.now() / 1000,
      keeper_name: asString(payload.keeper_name, ''),
      context_ratio: asNumber(payload.context_ratio, 0),
      message_count: asNumber(payload.message_count, 0),
      token_count: asNumber(payload.token_count, 0),
      strategies: asStringArray(payload.strategies),
      model_family: asString(payload.model_family, ''),
      trigger: asString(payload.trigger, ''),
    }
    updateHarnessData(data => ({
      ...data,
      pre_compact: {
        ...data.pre_compact,
        recent_events: mergeRecent(
          data.pre_compact.recent_events,
          nextItem,
          (left, right) =>
            left.timestamp === right.timestamp
            && left.keeper_name === right.keeper_name
            && left.trigger === right.trigger,
          8,
        ),
        total_recent: data.pre_compact.total_recent + 1,
        last_event_at: nextItem.timestamp,
        empty_reason: null,
      },
      overview: {
        ...data.overview,
        last_signal_at: nextItem.timestamp,
        pre_compact_last_event_at: nextItem.timestamp,
        latest_pre_compact_ratio: nextItem.context_ratio,
      },
    }))
    scheduleHarnessReload()
  }

  if (
    type === 'oas:masc:harness:handoff'
    || type === 'keeper_handoff'
    || type === 'masc/keeper_handoff'
  ) {
    const handoffPayload: Record<string, unknown> = payload ?? event
    const hasTimestamp =
      handoffPayload.timestamp != null || handoffPayload.ts_unix != null
    const hasKeeperIdentity =
      handoffPayload.keeper_name != null || handoffPayload.name != null
    const hasGeneration =
      handoffPayload.generation != null
      || handoffPayload.from_generation != null
      || handoffPayload.next_generation != null
      || handoffPayload.to_generation != null
    if (!(hasTimestamp && hasKeeperIdentity && hasGeneration)) {
      console.warn('[harness-health] ignoring malformed handoff event', {
        type,
        candidate: handoffPayload,
      })
      return
    }
    const nextGeneration = asNumber(handoffPayload.next_generation)
    const toGeneration = asNumber(handoffPayload.to_generation)
    const nextItem: HandoffEvent = {
      timestamp: asNumber(handoffPayload.timestamp) ?? asNumber(handoffPayload.ts_unix) ?? Date.now() / 1000,
      keeper_name: asString(handoffPayload.keeper_name) ?? asString(handoffPayload.name, ''),
      trace_id: asString(handoffPayload.trace_id) ?? asString(handoffPayload.new_trace_id, ''),
      generation: asNumber(handoffPayload.generation) ?? asNumber(handoffPayload.from_generation, 0),
      next_generation: nextGeneration ?? toGeneration ?? null,
      prev_trace_id: asString(handoffPayload.prev_trace_id) ?? null,
      new_trace_id: asString(handoffPayload.new_trace_id) ?? null,
      to_model: asString(handoffPayload.to_model) ?? null,
    }
    updateHarnessData(data => ({
      ...data,
      recent_handoffs: {
        ...data.recent_handoffs,
        recent_events: mergeRecent(
          data.recent_handoffs.recent_events,
          nextItem,
          (left, right) =>
            left.timestamp === right.timestamp
            && left.trace_id === right.trace_id,
          8,
        ),
        total_recent: data.recent_handoffs.total_recent + 1,
        last_event_at: nextItem.timestamp,
        empty_reason: null,
      },
      overview: {
        ...data.overview,
        last_signal_at: nextItem.timestamp,
        handoff_last_event_at: nextItem.timestamp,
        latest_handoff_generation: nextItem.next_generation ?? nextItem.generation,
      },
    }))
    scheduleHarnessReload()
  }
}

export function handleHarnessSSE(): () => void {
  return lastEvent.subscribe((event) => {
    processHarnessEvent(event)
  })
}
