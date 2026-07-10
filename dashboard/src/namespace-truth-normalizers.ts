import { asBoolean, asNumber, asString, asStringArray, isRecord, extractArray } from './components/common/normalize'
import {
  normalizeServerStatus,
  normalizeExecutionSummary,
  normalizeExecutionQueueItem,
} from './store-normalizers'
import { normalizePendingConfirmSummary } from './pending-confirm'
import type {
  DashboardAttentionEvent,
  DashboardNamespaceTruthFocus,
  DashboardReadinessPillar,
  DashboardReadinessSummary,
  DashboardNamespaceTruthResponse,
  DashboardRuntimeCountAuthority,
} from './types'

// normalizePendingConfirmSummary imported from pending-confirm.ts (SSOT)

function normalizeFocus(raw: unknown): DashboardNamespaceTruthFocus | null {
  if (!isRecord(raw)) return null
  const label = asString(raw.label)
  const reason = asString(raw.reason)
  const source = asString(raw.source)
  const provenance = asString(raw.provenance)
  if (!label || !reason || !source || !provenance) return null
  return {
    label,
    reason,
    source,
    provenance,
    target_kind: asString(raw.target_kind) ?? null,
    target_id: asString(raw.target_id) ?? null,
    suggested_tab: asString(raw.suggested_tab) ?? null,
    suggested_surface: asString(raw.suggested_surface) ?? null,
    suggested_params: isRecord(raw.suggested_params)
      ? Object.fromEntries(
          Object.entries(raw.suggested_params)
            .map(([key, value]) => {
              const text = asString(value)
              return text ? [key, text] : null
            })
            .filter((entry): entry is [string, string] => entry !== null),
        )
      : {},
  }
}

function normalizeReadinessPillar(raw: unknown): DashboardReadinessPillar | null {
  if (!isRecord(raw)) return null
  const key = asString(raw.key)
  const label = asString(raw.label)
  const status = asString(raw.status)
  const summary = asString(raw.summary)
  const score = asNumber(raw.score)
  if (!key || !label || !status || !summary || score == null) return null
  return {
    key,
    label,
    status,
    score,
    summary,
    blocking_reasons: asStringArray(raw.blocking_reasons),
    metrics: isRecord(raw.metrics)
      ? Object.fromEntries(
          Object.entries(raw.metrics)
            .map(([metricKey, value]) => {
              const numeric = asNumber(value)
              return numeric == null ? null : [metricKey, numeric]
            })
            .filter((entry): entry is [string, number] => entry !== null),
        )
      : {},
  }
}

function normalizeReadiness(raw: unknown): DashboardReadinessSummary | null {
  if (!isRecord(raw)) return null
  const status = asString(raw.status)
  const score = asNumber(raw.score)
  if (!status || score == null) return null
  return {
    status,
    score,
    decision_required_count: asNumber(raw.decision_required_count) ?? 0,
    blocking_count: asNumber(raw.blocking_count) ?? 0,
    pillars: extractArray(raw.pillars)
      .map(normalizeReadinessPillar)
      .filter((pillar): pillar is DashboardReadinessPillar => pillar !== null),
  }
}

function normalizeRuntimeCountAuthority(raw: unknown): DashboardRuntimeCountAuthority | undefined {
  if (!isRecord(raw)) return undefined
  const countRoles = isRecord(raw.count_roles)
    ? Object.fromEntries(
        Object.entries(raw.count_roles)
          .map(([key, value]) => {
            const text = asString(value)
            return text ? [key, text] : null
          })
          .filter((entry): entry is [string, string] => entry !== null),
      )
    : undefined
  return {
    source: asString(raw.source),
    authority: asString(raw.authority),
    configured_authority: asString(raw.configured_authority),
    fallback_policy: asString(raw.fallback_policy),
    shell_arbitration_allowed: asBoolean(raw.shell_arbitration_allowed),
    live_total_runtimes: asNumber(raw.live_total_runtimes),
    live_keepers: asNumber(raw.live_keepers),
    configured_keepers: asNumber(raw.configured_keepers),
    configured_minus_live_keepers: asNumber(raw.configured_minus_live_keepers),
    count_roles: countRoles,
  }
}

function normalizeAttentionEvent(raw: unknown): DashboardAttentionEvent | null {
  if (!isRecord(raw)) return null
  const severity = asString(raw.severity)
  const kind = asString(raw.kind)
  const summary = asString(raw.summary)
  if (!severity || !kind || !summary) return null
  return {
    severity,
    kind,
    summary,
    requires_decision: asBoolean(raw.requires_decision) ?? false,
    keeper_name: asString(raw.keeper_name) ?? null,
    target_type: asString(raw.target_type) ?? null,
    target_id: asString(raw.target_id) ?? null,
    recommended_action: asString(raw.recommended_action) ?? null,
    provenance: asString(raw.provenance) ?? null,
  }
}

export function normalizeNamespaceTruth(raw: unknown): DashboardNamespaceTruthResponse {
  const root = isRecord(raw) ? raw : {}
  const namespaceBlock = isRecord(root.root) ? root.root : {}
  const executionBlock = isRecord(root.execution) ? root.execution : {}
  const commandBlock = isRecord(root.command) ? root.command : {}
  const operatorBlock = isRecord(root.operator) ? root.operator : {}
  const retentionBlock = isRecord(root.retention) ? root.retention : null
  return {
    generated_at: asString(root.generated_at),
    generated_at_iso: asString(root.generated_at_iso),
    dashboard_surface: asString(root.dashboard_surface),
    dashboard_aliases: asStringArray(root.dashboard_aliases),
    source: asString(root.source),
    retention: retentionBlock
      ? {
          scope: asString(retentionBlock.scope),
          workspace_root: asString(retentionBlock.workspace_root),
          workspace_path: asString(retentionBlock.workspace_path),
          shell_input: asString(retentionBlock.shell_input),
          execution_input: asString(retentionBlock.execution_input),
          command_input: asString(retentionBlock.command_input),
          cache_policy: asString(retentionBlock.cache_policy),
        }
      : undefined,
    root: {
      status: normalizeServerStatus(namespaceBlock.status),
      counts: isRecord(namespaceBlock.counts)
        ? {
            agents: asNumber(namespaceBlock.counts.agents),
            tasks: asNumber(namespaceBlock.counts.tasks),
            keepers: asNumber(namespaceBlock.counts.keepers),
            total_runtimes: asNumber(namespaceBlock.counts.total_runtimes),
          }
        : undefined,
      configured_keepers: asNumber(namespaceBlock.configured_keepers),
      runtime_count_authority: normalizeRuntimeCountAuthority(namespaceBlock.runtime_count_authority),
      provenance: asString(namespaceBlock.provenance) ?? null,
    },
    execution: {
      summary: normalizeExecutionSummary(executionBlock.summary),
      top_queue: normalizeExecutionQueueItem(executionBlock.top_queue),
      provenance: asString(executionBlock.provenance) ?? null,
    },
    command: {
      active_operations: asNumber(commandBlock.active_operations),
      active_detachments: asNumber(commandBlock.active_detachments),
      pending_approvals: asNumber(commandBlock.pending_approvals),
      bad_alerts: asNumber(commandBlock.bad_alerts),
      warn_alerts: asNumber(commandBlock.warn_alerts),
      provenance: asString(commandBlock.provenance) ?? null,
    },
    operator: {
      pending_confirm_summary: normalizePendingConfirmSummary(operatorBlock.pending_confirm_summary),
      provenance: asString(operatorBlock.provenance) ?? null,
    },
    readiness: normalizeReadiness(root.readiness),
    attention_events: extractArray(root.attention_events)
      .map(normalizeAttentionEvent)
      .filter((event): event is DashboardAttentionEvent => event !== null),
    focus: normalizeFocus(root.focus),
  }
}
