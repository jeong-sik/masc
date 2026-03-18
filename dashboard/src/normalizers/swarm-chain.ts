import { isRecord, asString, asNumber, asBoolean } from '../components/common/normalize'
import type {
  ChainHistoryEventSummary,
  ChainRuntimeStatus,
  CommandPlaneChainConnection,
  CommandPlaneChainOverlay,
  CommandPlaneChainRun,
  CommandPlaneChainRunNode,
  CommandPlaneChainRunResponse,
  CommandPlaneChainSummary,
} from '../types'
import { normalizeOperationRecord } from '../command-normalizers'

function normalizeChainRuntime(raw: unknown): ChainRuntimeStatus | null {
  if (!isRecord(raw)) return null
  return {
    chain_id: asString(raw.chain_id) ?? null,
    started_at: asNumber(raw.started_at) ?? null,
    progress: asNumber(raw.progress) ?? null,
    elapsed_sec: asNumber(raw.elapsed_sec) ?? null,
  }
}

function normalizeChainHistoryEvent(raw: unknown): ChainHistoryEventSummary | null {
  if (!isRecord(raw)) return null
  const event = asString(raw.event)
  if (!event) return null
  return {
    event,
    chain_id: asString(raw.chain_id) ?? null,
    timestamp: asString(raw.timestamp) ?? null,
    duration_ms: asNumber(raw.duration_ms) ?? null,
    message: asString(raw.message) ?? null,
    tokens: asNumber(raw.tokens) ?? null,
  }
}

function normalizeChainRunNode(raw: unknown): CommandPlaneChainRunNode | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  if (!id) return null
  return {
    id,
    type: asString(raw.type),
    status: asString(raw.status),
    duration_ms: asNumber(raw.duration_ms) ?? null,
    error: asString(raw.error) ?? null,
  }
}

export function normalizeChainRun(raw: unknown): CommandPlaneChainRun | null {
  if (!isRecord(raw)) return null
  const runId = asString(raw.run_id)
  const chainId = asString(raw.chain_id)
  if (!chainId) return null
  return {
    run_id: runId ?? null,
    chain_id: chainId,
    duration_ms: asNumber(raw.duration_ms),
    success: asBoolean(raw.success),
    mermaid: asString(raw.mermaid),
    nodes: Array.isArray(raw.nodes)
      ? raw.nodes
          .map(normalizeChainRunNode)
          .filter((item): item is CommandPlaneChainRunNode => item !== null)
      : [],
  }
}

function normalizeChainOverlay(raw: unknown): CommandPlaneChainOverlay | null {
  if (!isRecord(raw)) return null
  const operation = normalizeOperationRecord(raw.operation)
  if (!operation) return null
  return {
    operation,
    runtime: normalizeChainRuntime(raw.runtime),
    history: normalizeChainHistoryEvent(raw.history),
    mermaid: asString(raw.mermaid) ?? null,
    preview_run: normalizeChainRun(raw.preview_run),
  }
}

function normalizeChainConnection(raw: unknown): CommandPlaneChainConnection {
  const root = isRecord(raw) ? raw : {}
  return {
    status: asString(root.status) ?? 'disconnected',
    base_url: asString(root.base_url) ?? null,
    message: asString(root.message) ?? null,
  }
}

export function normalizeChainSummary(raw: unknown): CommandPlaneChainSummary {
  const root = isRecord(raw) ? raw : {}
  const summary = isRecord(root.summary) ? root.summary : undefined
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    connection: normalizeChainConnection(root.connection),
    summary: summary
      ? {
          linked_operations: asNumber(summary.linked_operations),
          active_chains: asNumber(summary.active_chains),
          running_operations: asNumber(summary.running_operations),
          recent_failures: asNumber(summary.recent_failures),
          last_history_event_at: asString(summary.last_history_event_at) ?? null,
        }
      : undefined,
    operations: Array.isArray(root.operations)
      ? root.operations
          .map(normalizeChainOverlay)
          .filter((item): item is CommandPlaneChainOverlay => item !== null)
      : [],
    recent_history: Array.isArray(root.recent_history)
      ? root.recent_history
          .map(normalizeChainHistoryEvent)
          .filter((item): item is ChainHistoryEventSummary => item !== null)
      : [],
  }
}

export function normalizeChainRunResponse(raw: unknown): CommandPlaneChainRunResponse {
  const root = isRecord(raw) ? raw : {}
  return {
    run: normalizeChainRun(root.run),
  }
}
