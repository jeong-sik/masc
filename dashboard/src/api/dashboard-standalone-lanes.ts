import { isRecord } from '../components/common/normalize'
import { get, type AbortableRequestOptions } from './core'

export type StandaloneLaneId =
  | 'board_attention_exact'
  | 'hitl_auto_judge'
  | 'librarian_exact'
  | 'verifier_exact'

export type StandaloneLaneStatus =
  | 'running'
  | 'idle'
  | 'degraded'
  | 'no_retained_observation'
  | 'unavailable'

export type StandaloneLaneConfigurationState =
  | 'ready'
  | 'degraded'
  | 'unconfigured'
  | 'unavailable'

export interface StandaloneLaneSlotCount {
  slotId: string
  count: number
}

export interface StandaloneLaneSnapshotRow {
  laneId: StandaloneLaneId
  label: string
  required: boolean
  observationOnly: true
  configured: boolean | null
  configurationState: StandaloneLaneConfigurationState
  admittedSlots: string[]
  cliSlots: string[]
  droppedSlots: string[]
  admissionError: string | null
  status: StandaloneLaneStatus
  retainedRunCount: number
  runningCount: number
  succeededCount: number
  failedCount: number
  cancelledCount: number
  lastStartedAt: number | null
  lastTerminalAt: number | null
  lastOutcome: 'succeeded' | 'failed' | 'cancelled' | null
  p50ElapsedSeconds: number | null
  selectedSlots: StandaloneLaneSlotCount[]
}

export interface StandaloneLanesSnapshot {
  schema: 'masc.standalone_llm_lanes.v1'
  generatedAt: string
  observedAtUnix: number
  observationOnly: true
  exactRunProjectionCount: number
  exactRunSourceTotal: number
  exactRunProjectionTruncated: boolean
  lanes: StandaloneLaneSnapshotRow[]
}

// The registry spellings come from Exact_lane_run_registry.lane_key and the
// verifier from Runtime.verifier_exact_lane_id — the language-boundary copy,
// pinned to those sources by standalone-lanes-parity.test.ts. `satisfies`
// keeps this list and the StandaloneLaneId union from drifting apart.
export const LANE_IDS = [
  'board_attention_exact',
  'hitl_auto_judge',
  'librarian_exact',
  'verifier_exact',
] as const satisfies readonly StandaloneLaneId[]
const STATUSES: readonly string[] = ['running', 'idle', 'degraded', 'no_retained_observation', 'unavailable']
const CONFIGURATION_STATES: readonly string[] = ['ready', 'degraded', 'unconfigured', 'unavailable']
const OUTCOMES: readonly string[] = ['succeeded', 'failed', 'cancelled']

function fail(message: string): never {
  throw new Error(`Invalid standalone lanes response: ${message}`)
}

function string(value: unknown, context: string): string {
  if (typeof value !== 'string' || value.trim() === '') fail(`${context} must be a non-empty string`)
  return value
}

function number(value: unknown, context: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
    fail(`${context} must be a non-negative finite number`)
  }
  return value
}

function count(value: unknown, context: string): number {
  const parsed = number(value, context)
  if (!Number.isSafeInteger(parsed)) fail(`${context} must be a safe integer`)
  return parsed
}

function nullableNumber(value: unknown, context: string): number | null {
  return value === null ? null : number(value, context)
}

function nullableString(value: unknown, context: string): string | null {
  return value === null ? null : string(value, context)
}

function parseLane(raw: unknown, index: number): StandaloneLaneSnapshotRow {
  const context = `lanes[${index}]`
  if (!isRecord(raw)) fail(`${context} must be an object`)
  const laneId = string(raw.lane_id, `${context}.lane_id`)
  const status = string(raw.status, `${context}.status`)
  const configurationState = string(raw.configuration_state, `${context}.configuration_state`)
  if (!(LANE_IDS as readonly string[]).includes(laneId)) fail(`${context}.lane_id is unknown`)
  if (!STATUSES.includes(status)) fail(`${context}.status is unknown`)
  if (!CONFIGURATION_STATES.includes(configurationState)) {
    fail(`${context}.configuration_state is unknown`)
  }
  if (!Array.isArray(raw.admitted_slots)) fail(`${context}.admitted_slots must be an array`)
  if (!Array.isArray(raw.cli_slots)) fail(`${context}.cli_slots must be an array`)
  if (!Array.isArray(raw.dropped_slots)) fail(`${context}.dropped_slots must be an array`)
  if (!Array.isArray(raw.selected_slots)) fail(`${context}.selected_slots must be an array`)
  if (typeof raw.required !== 'boolean') fail(`${context}.required must be a boolean`)
  if (raw.observation_only !== true) fail(`${context}.observation_only must be true`)
  if (raw.configured !== null && typeof raw.configured !== 'boolean') {
    fail(`${context}.configured must be a boolean or null`)
  }
  const lastOutcome = raw.last_outcome === null ? null : string(raw.last_outcome, `${context}.last_outcome`)
  if (lastOutcome !== null && !OUTCOMES.includes(lastOutcome)) fail(`${context}.last_outcome is unknown`)
  return {
    laneId: laneId as StandaloneLaneId,
    label: string(raw.label, `${context}.label`),
    required: raw.required,
    observationOnly: true,
    configured: raw.configured as boolean | null,
    configurationState: configurationState as StandaloneLaneConfigurationState,
    admittedSlots: raw.admitted_slots.map((slot, slotIndex) => string(slot, `${context}.admitted_slots[${slotIndex}]`)),
    cliSlots: raw.cli_slots.map((slot, slotIndex) => string(slot, `${context}.cli_slots[${slotIndex}]`)),
    droppedSlots: raw.dropped_slots.map((slot, slotIndex) => string(slot, `${context}.dropped_slots[${slotIndex}]`)),
    admissionError: nullableString(raw.admission_error, `${context}.admission_error`),
    status: status as StandaloneLaneStatus,
    retainedRunCount: count(raw.retained_run_count, `${context}.retained_run_count`),
    runningCount: count(raw.running_count, `${context}.running_count`),
    succeededCount: count(raw.succeeded_count, `${context}.succeeded_count`),
    failedCount: count(raw.failed_count, `${context}.failed_count`),
    cancelledCount: count(raw.cancelled_count, `${context}.cancelled_count`),
    lastStartedAt: nullableNumber(raw.last_started_at, `${context}.last_started_at`),
    lastTerminalAt: nullableNumber(raw.last_terminal_at, `${context}.last_terminal_at`),
    lastOutcome: lastOutcome as StandaloneLaneSnapshotRow['lastOutcome'],
    p50ElapsedSeconds: nullableNumber(raw.p50_elapsed_s, `${context}.p50_elapsed_s`),
    selectedSlots: raw.selected_slots.map((slot, slotIndex) => {
      if (!isRecord(slot)) fail(`${context}.selected_slots[${slotIndex}] must be an object`)
      return {
        slotId: string(slot.slot_id, `${context}.selected_slots[${slotIndex}].slot_id`),
        count: count(slot.count, `${context}.selected_slots[${slotIndex}].count`),
      }
    }),
  }
}

export function parseStandaloneLanesSnapshot(raw: unknown): StandaloneLanesSnapshot {
  if (!isRecord(raw)) fail('root must be an object')
  if (raw.schema !== 'masc.standalone_llm_lanes.v1') fail('root.schema is unknown')
  if (raw.observation_only !== true) fail('root.observation_only must be true')
  if (typeof raw.exact_run_projection_truncated !== 'boolean') {
    fail('root.exact_run_projection_truncated must be a boolean')
  }
  const exactRunProjectionCount = count(raw.exact_run_projection_count, 'root.exact_run_projection_count')
  const exactRunSourceTotal = count(raw.exact_run_source_total, 'root.exact_run_source_total')
  if (exactRunProjectionCount > exactRunSourceTotal) fail('root exact run projection exceeds source total')
  if (raw.exact_run_projection_truncated !== (exactRunProjectionCount < exactRunSourceTotal)) {
    fail('root.exact_run_projection_truncated does not match counts')
  }
  if (!Array.isArray(raw.lanes)) fail('root.lanes must be an array')
  const lanes = raw.lanes.map(parseLane)
  if (lanes.length !== LANE_IDS.length || new Set(lanes.map(lane => lane.laneId)).size !== LANE_IDS.length) {
    fail('root.lanes must contain each standalone lane exactly once')
  }
  return {
    schema: raw.schema,
    generatedAt: string(raw.generated_at, 'root.generated_at'),
    observedAtUnix: number(raw.observed_at_unix, 'root.observed_at_unix'),
    observationOnly: true,
    exactRunProjectionCount,
    exactRunSourceTotal,
    exactRunProjectionTruncated: raw.exact_run_projection_truncated,
    lanes,
  }
}

export async function fetchStandaloneLanes(
  opts?: AbortableRequestOptions,
): Promise<StandaloneLanesSnapshot> {
  const raw = await get<unknown>('/api/v1/dashboard/standalone-lanes', { signal: opts?.signal })
  return parseStandaloneLanesSnapshot(raw)
}
