import { isRecord, asString } from '../components/common/normalize'
import type { CommandPlaneSnapshot, CommandPlaneSummarySnapshot } from '../types'
import {
  normalizeTopology,
  normalizeOperations,
  normalizeDetachments,
  normalizeAlerts,
  normalizeDecisions,
  normalizeCapacity,
  normalizeTraces,
} from '../command-normalizers'
import { normalizeSwarmStatus } from './swarm-lane'
import { normalizeSwarmProof } from './swarm-proof'

export function normalizeSnapshot(raw: unknown): CommandPlaneSnapshot {
  const root = isRecord(raw) ? raw : {}
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    topology: normalizeTopology(root.topology),
    operations: normalizeOperations(root.operations),
    detachments: normalizeDetachments(root.detachments),
    alerts: normalizeAlerts(root.alerts),
    decisions: normalizeDecisions(root.decisions),
    capacity: normalizeCapacity(root.capacity),
    traces: normalizeTraces(root.traces),
    swarm_status: normalizeSwarmStatus(root.swarm_status),
  }
}

export function normalizeSummarySnapshot(raw: unknown): CommandPlaneSummarySnapshot {
  const root = isRecord(raw) ? raw : {}
  const topology = normalizeTopology(root.topology)
  const operations = normalizeOperations(root.operations)
  const detachments = normalizeDetachments(root.detachments)
  const alerts = normalizeAlerts(root.alerts)
  const decisions = normalizeDecisions(root.decisions)
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    topology: {
      version: topology.version,
      generated_at: topology.generated_at,
      source: topology.source,
      summary: topology.summary,
    },
    operations: {
      version: operations.version,
      generated_at: operations.generated_at,
      summary: operations.summary,
      microarch: operations.microarch,
    },
    detachments: {
      version: detachments.version,
      generated_at: detachments.generated_at,
      summary: detachments.summary,
    },
    alerts: {
      version: alerts.version,
      generated_at: alerts.generated_at,
      summary: alerts.summary,
    },
    decisions: {
      version: decisions.version,
      generated_at: decisions.generated_at,
      summary: decisions.summary,
    },
    swarm_status: normalizeSwarmStatus(root.swarm_status),
    swarm_proof: normalizeSwarmProof(root.swarm_proof),
  }
}
