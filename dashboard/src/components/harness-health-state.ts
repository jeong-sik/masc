// Harness health state management and data loading.

import { get } from '../api/core'
import { createAsyncResource, loaded, type AsyncResource } from '../lib/async-state'
import { lastEvent } from '../sse'
import { asNumber, asString, isRecord } from './common/normalize'

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
  last_signal_at: number | null
  evaluator_last_event_at: number | null
  fallback_ratio: number
  // Added by lib/dashboard/dashboard_harness_health.ml as part of #6565.
  // Ratio of verdicts whose generator_runtime ≠ evaluator_runtime among
  // verdicts that carried a generator_runtime. undefined when the backend
  // had zero eligible verdicts to compute the ratio.
  cross_model_rate?: number
}

export interface HarnessVerdictItem {
  timestamp: number
  task_id: string
  task_title: string
  agent_name: string
  gate: string
  verdict: string
  evaluator_runtime: string
  // Added by lib/tool_task.ml#build_verdict_sse_payload as part of #6565.
  generator_runtime?: string | null
  cross_runtime?: boolean
  fallback_reason?: string | null
}

export interface HarnessHealthData {
  generated_at: number
  scope_note: string
  overview: HarnessOverview
  calibration: CalibrationStats
  recent_verdicts: HarnessVerdictItem[]
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

  if (type === 'agent_core:masc:harness:verdict_recorded') {
    if (!payload) return
    const nextItem: HarnessVerdictItem = {
      timestamp: asNumber(payload.timestamp) ?? Date.now() / 1000,
      task_id: asString(payload.task_id, ''),
      task_title: asString(payload.task_title, 'task'),
      agent_name: asString(payload.agent_name, ''),
      gate: asString(payload.gate, ''),
      verdict: asString(payload.verdict, ''),
      evaluator_runtime: asString(payload.evaluator_runtime, ''),
      generator_runtime: asString(payload.generator_runtime) ?? null,
      cross_runtime: payload.cross_runtime === true,
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
}

export function handleHarnessSSE(): () => void {
  return lastEvent.subscribe((event) => {
    processHarnessEvent(event)
  })
}
