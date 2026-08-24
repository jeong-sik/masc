// MASC Dashboard — durable Keeper persistence proof projection.
//
// Backend: GET /api/v1/dashboard/keeper-feature-proof
//
// The endpoint carries several feature proofs. This decoder deliberately
// projects only the persistence feature and rejects internally inconsistent
// tier evidence instead of rendering plausible-looking counters.

import { isRecord } from '../components/common/normalize'
import { get, type AbortableRequestOptions } from './core'

export type KeeperFeatureProofStatus = 'pass' | 'warn' | 'fail'
export type KeeperPersistenceTierId = '1h' | '2h' | '4h' | '24h'
export type KeeperPersistenceEvidenceKind = 'durable_turn_span'

export interface KeeperPersistenceTierProof {
  id: KeeperPersistenceTierId
  requiredSpanHours: number
  status: KeeperFeatureProofStatus
  evidenceKind: KeeperPersistenceEvidenceKind
  keeperCount: number
  observedCount: number
  missingCount: number
  undeterminedCount: number
  observedKeepers: string[]
  missingKeepers: string[]
  // Keepers whose earliest turn row the backend never reached: the segment
  // head budget ran out first. They did not fail the span - the reader
  // stopped before it could tell - so they are neither observed nor missing.
  undeterminedKeepers: string[]
}

export interface DashboardKeeperPersistenceProofResponse {
  generatedAt: string
  status: KeeperFeatureProofStatus
  summary: string
  tiers: KeeperPersistenceTierProof[]
}

const EXPECTED_TIERS = [
  { id: '1h', requiredSpanHours: 1 },
  { id: '2h', requiredSpanHours: 2 },
  { id: '4h', requiredSpanHours: 4 },
  { id: '24h', requiredSpanHours: 24 },
] as const

function protocolError(message: string): never {
  throw new Error(`Invalid Keeper persistence proof response: ${message}`)
}

function nonEmptyString(value: unknown, context: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    protocolError(`${context} must be a non-empty string`)
  }
  return value
}

function isoTimestamp(value: unknown, context: string): string {
  const timestamp = nonEmptyString(value, context)
  if (!Number.isFinite(Date.parse(timestamp))) {
    protocolError(`${context} must be a valid timestamp`)
  }
  return timestamp
}

function nonNegativeInteger(value: unknown, context: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) {
    protocolError(`${context} must be a non-negative safe integer`)
  }
  return value as number
}

function proofStatus(value: unknown, context: string): KeeperFeatureProofStatus {
  if (value !== 'pass' && value !== 'warn' && value !== 'fail') {
    protocolError(`${context} has unknown status ${JSON.stringify(value)}`)
  }
  return value
}

function keeperNames(value: unknown, context: string): string[] {
  if (!Array.isArray(value)) protocolError(`${context} must be an array`)
  const names = value.map((name, index) => nonEmptyString(name, `${context}[${index}]`))
  if (new Set(names).size !== names.length) {
    protocolError(`${context} must not contain duplicate keepers`)
  }
  return names
}

function expectedStatus(
  keeperCount: number,
  observedCount: number,
  undeterminedCount: number,
): KeeperFeatureProofStatus {
  if (keeperCount === 0) return 'fail'
  if (observedCount === keeperCount) return 'pass'
  // 'fail' asserts that no Keeper met the span. That is only sayable once
  // every Keeper produced an answer; with an unread history in the mix the
  // backend does not know, and neither does this decoder.
  if (observedCount === 0 && undeterminedCount === 0) return 'fail'
  return 'warn'
}

function sameNames(left: ReadonlySet<string>, right: ReadonlySet<string>): boolean {
  return left.size === right.size && [...left].every(name => right.has(name))
}

function parseTier(
  raw: unknown,
  index: number,
): KeeperPersistenceTierProof {
  const context = `persistence.duration_tiers[${index}]`
  if (!isRecord(raw)) protocolError(`${context} must be an object`)
  const expected = EXPECTED_TIERS[index]
  if (expected == null) protocolError('persistence.duration_tiers contains an unexpected tier')
  if (raw.id !== expected.id) {
    protocolError(`${context}.id must be ${expected.id}`)
  }
  if (raw.required_span_hours !== expected.requiredSpanHours) {
    protocolError(`${context}.required_span_hours must be ${expected.requiredSpanHours}`)
  }
  if (raw.evidence_kind !== 'durable_turn_span') {
    protocolError(`${context}.evidence_kind must be durable_turn_span`)
  }
  const keeperCount = nonNegativeInteger(raw.keeper_count, `${context}.keeper_count`)
  const observedCount = nonNegativeInteger(raw.observed_count, `${context}.observed_count`)
  const missingCount = nonNegativeInteger(raw.missing_count, `${context}.missing_count`)
  const undeterminedCount = nonNegativeInteger(
    raw.undetermined_count,
    `${context}.undetermined_count`,
  )
  const observedKeepers = keeperNames(raw.observed_keepers, `${context}.observed_keepers`)
  const missingKeepers = keeperNames(raw.missing_keepers, `${context}.missing_keepers`)
  const undeterminedKeepers = keeperNames(
    raw.undetermined_keepers,
    `${context}.undetermined_keepers`,
  )
  if (observedCount !== observedKeepers.length
    || missingCount !== missingKeepers.length
    || undeterminedCount !== undeterminedKeepers.length) {
    protocolError(`${context} counts must match keeper arrays`)
  }
  if (observedCount + missingCount + undeterminedCount !== keeperCount) {
    protocolError(
      `${context} observed_count + missing_count + undetermined_count must equal keeper_count`,
    )
  }
  const observed = new Set(observedKeepers)
  const missing = new Set(missingKeepers)
  if (missingKeepers.some(name => observed.has(name))
    || undeterminedKeepers.some(name => observed.has(name) || missing.has(name))) {
    protocolError(`${context} observed, missing and undetermined keepers must not overlap`)
  }
  const status = proofStatus(raw.status, `${context}.status`)
  const derivedStatus = expectedStatus(keeperCount, observedCount, undeterminedCount)
  if (status !== derivedStatus) {
    protocolError(`${context}.status=${status} does not match derived status=${derivedStatus}`)
  }
  return {
    id: expected.id,
    requiredSpanHours: expected.requiredSpanHours,
    status,
    evidenceKind: 'durable_turn_span',
    keeperCount,
    observedCount,
    missingCount,
    undeterminedCount,
    observedKeepers,
    missingKeepers,
    undeterminedKeepers,
  }
}

export function parseKeeperPersistenceProofResponse(
  raw: unknown,
): DashboardKeeperPersistenceProofResponse {
  if (!isRecord(raw)) protocolError('root must be an object')
  const generatedAt = isoTimestamp(raw.generated_at, 'root.generated_at')
  if (!Array.isArray(raw.features)) protocolError('root.features must be an array')
  const matches = raw.features.filter(
    feature => isRecord(feature) && feature.id === 'persistent_24h_turn_exchange',
  )
  if (matches.length !== 1) {
    protocolError(`expected exactly one persistent_24h_turn_exchange feature, found ${matches.length}`)
  }
  const feature = matches[0]
  if (!isRecord(feature)) protocolError('persistence feature must be an object')
  if (!Array.isArray(feature.duration_tiers)) {
    protocolError('persistence.duration_tiers must be an array')
  }
  if (feature.duration_tiers.length !== EXPECTED_TIERS.length) {
    protocolError(`persistence.duration_tiers must contain ${EXPECTED_TIERS.length} tiers`)
  }
  const tiers = feature.duration_tiers.map(parseTier)
  const firstTier = tiers[0]
  if (firstTier == null) protocolError('persistence.duration_tiers must not be empty')
  const fleet = new Set([
    ...firstTier.observedKeepers,
    ...firstTier.missingKeepers,
    ...firstTier.undeterminedKeepers,
  ])
  for (let index = 1; index < tiers.length; index += 1) {
    const previous = tiers[index - 1]
    const current = tiers[index]
    if (previous == null || current == null) {
      protocolError(`persistence.duration_tiers[${index}] is absent`)
    }
    const currentFleet = new Set([
      ...current.observedKeepers,
      ...current.missingKeepers,
      ...current.undeterminedKeepers,
    ])
    if (current.keeperCount !== firstTier.keeperCount || !sameNames(fleet, currentFleet)) {
      protocolError(`persistence.duration_tiers[${index}] must describe the same Keeper fleet`)
    }
    // Being unread does not depend on how long a span the tier asks for, so
    // the undetermined set is the same at every tier. A tier that moves a
    // Keeper in or out of it is reporting a read that changed mid-report.
    if (!sameNames(new Set(previous.undeterminedKeepers), new Set(current.undeterminedKeepers))) {
      protocolError(
        `persistence.duration_tiers[${index}] must report the same unread Keepers as every tier`,
      )
    }
    const previousObserved = new Set(previous.observedKeepers)
    const currentMissing = new Set(current.missingKeepers)
    if (current.observedKeepers.some(name => !previousObserved.has(name))
      || previous.missingKeepers.some(name => !currentMissing.has(name))) {
      protocolError(`persistence.duration_tiers[${index}] violates duration monotonicity`)
    }
  }
  const status = proofStatus(feature.status, 'persistence.status')
  const tier24h = tiers[tiers.length - 1]
  if (tier24h == null || status !== tier24h.status) {
    protocolError('persistence.status must match the 24h tier status')
  }
  return {
    generatedAt,
    status,
    summary: nonEmptyString(feature.summary, 'persistence.summary'),
    tiers,
  }
}

export async function fetchKeeperPersistenceProof(
  opts?: AbortableRequestOptions,
): Promise<DashboardKeeperPersistenceProofResponse> {
  const raw = await get<unknown>('/api/v1/dashboard/keeper-feature-proof', { signal: opts?.signal })
  return parseKeeperPersistenceProofResponse(raw)
}
