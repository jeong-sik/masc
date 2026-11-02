import { isRecord } from '../components/common/normalize'
import { get, type GetOptions } from './core'
import { isActivationGap } from './dashboard-skills'
import {
  decodeSkillActivationObservation, decodeSkillTurnRef, validateAsyncOccurrenceFacts,
  type SkillActivationObservation,
} from './dashboard-tools-prompts'

type SkillScanScope = 'complete_retained_trace_snapshot' | 'incomplete_retained_trace_snapshot' | 'trace_store_unavailable'

export interface PhysicalSkillOrigin extends SkillActivationObservation {
  traceId: string
  ledgerRevision: string
}

export interface PhysicalSkillEvidence {
  turnRef: string
  origins: PhysicalSkillOrigin[]
  coverage: {
    scope: SkillScanScope
    sessionsInspected: number
    ledgersLoaded: number
    gaps: Record<string, unknown>[]
  }
}

function object(value: unknown, keys: readonly string[], label: string): Record<string, unknown> {
  if (!isRecord(value) || Object.keys(value).length !== keys.length
    || !keys.every(key => Object.hasOwn(value, key))) throw new Error(`${label}: invalid fields`)
  return value
}

function text(value: unknown, label: string): string {
  if (typeof value !== 'string' || value.trim() === '') throw new Error(`${label}: missing string`)
  return value
}

function count(value: unknown, label: string): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) throw new Error(`${label}: invalid count`)
  return value
}

function scope(value: unknown): SkillScanScope {
  switch (value) {
    case 'complete_retained_trace_snapshot':
    case 'incomplete_retained_trace_snapshot':
    case 'trace_store_unavailable': return value
    default: throw new Error('Skill scan: unknown coverage scope')
  }
}

function origin(value: unknown, turnRef: string): PhysicalSkillOrigin {
  const raw = object(value, ['trace_id', 'ledger_revision', 'activations', 'async_result_deliveries', 'async_actions'], 'Skill origin')
  const traceId = text(raw.trace_id, 'trace_id')
  const ledgerRevision = text(raw.ledger_revision, 'ledger_revision')
  if (!/^[0-9a-f]{64}$/.test(ledgerRevision)) throw new Error('Skill origin: invalid ledger revision')
  const facts = decodeSkillActivationObservation({ activations: raw.activations,
    async_result_deliveries: raw.async_result_deliveries, async_actions: raw.async_actions })
  const childIds = new Set(facts.async_result_deliveries.flatMap(delivery =>
    delivery.child_activations.map(child => child.skill_tool_use_id)))
  for (const activation of facts.activations) {
    const reference = decodeSkillTurnRef(activation.turn_ref, 'activation.turn_ref')
    if (reference.slice(0, reference.lastIndexOf('#')) !== traceId
      || (reference !== turnRef && !childIds.has(activation.skill_tool_use_id))) {
      throw new Error('Skill origin: activation is outside the requested provenance')
    }
  }
  for (const delivery of facts.async_result_deliveries) {
    if (delivery.physical_turn_ref !== turnRef) throw new Error('Skill result belongs to another receiving turn')
  }
  for (const action of facts.async_actions) {
    if (action.physical_turn_ref !== turnRef) throw new Error('Skill action belongs to another receiving turn')
  }
  if (facts.activations.length === 0 && facts.async_result_deliveries.length === 0 && facts.async_actions.length === 0) {
    throw new Error('Skill origin has no matching facts')
  }
  return { traceId, ledgerRevision, ...facts }
}

export function decodePhysicalSkillEvidence(value: unknown, requestedTurnRef: string): PhysicalSkillEvidence {
  const expected = decodeSkillTurnRef(requestedTurnRef, 'requested turn_ref')
  const raw = object(value, ['schema', 'turn_ref', 'origins', 'coverage'], 'Physical Skill evidence')
  if (raw.schema !== 'masc.dashboard.skill-physical-turn/v1'
    || raw.turn_ref !== expected || !Array.isArray(raw.origins)) {
    throw new Error('Skill evidence does not match the requested physical turn')
  }
  const origins = raw.origins.map(value => origin(value, expected))
  if (new Set(origins.map(value => value.traceId)).size !== origins.length) throw new Error('Skill origins are repeated')
  validateAsyncOccurrenceFacts(origins.flatMap(value => value.async_actions))
  const coverage = object(raw.coverage, ['scope', 'sessions_inspected', 'ledgers_loaded', 'gaps'], 'Skill coverage')
  if (!Array.isArray(coverage.gaps)) throw new Error('Skill coverage: missing gaps')
  const gaps = coverage.gaps.map(gap => {
    if (!isRecord(gap) || !isActivationGap(gap)) throw new Error('Skill coverage: invalid gap')
    return gap
  })
  const scanScope = scope(coverage.scope)
  const sessionsInspected = count(coverage.sessions_inspected, 'sessions_inspected')
  const ledgersLoaded = count(coverage.ledgers_loaded, 'ledgers_loaded')
  if (ledgersLoaded > sessionsInspected || origins.length > ledgersLoaded
    || (scanScope === 'complete_retained_trace_snapshot' ? gaps.length !== 0 : gaps.length === 0)
    || (scanScope === 'trace_store_unavailable' && origins.length !== 0)
    || (gaps.some(gap => gap.code === 'trace_root_changed_during_discovery') && origins.length !== 0)) {
    throw new Error('Skill coverage disagrees with its observations')
  }
  return { turnRef: expected, origins, coverage: { scope: scanScope, sessionsInspected, ledgersLoaded, gaps } }
}

export async function fetchPhysicalSkillEvidence(turnRef: string, opts: GetOptions = {}): Promise<PhysicalSkillEvidence> {
  const canonical = decodeSkillTurnRef(turnRef, 'turn_ref')
  const params = new URLSearchParams({ turn_ref: canonical })
  const raw = await get<unknown>(`/api/v1/dashboard/skill-activations/physical-turn?${params}`, opts)
  return decodePhysicalSkillEvidence(raw, canonical)
}
