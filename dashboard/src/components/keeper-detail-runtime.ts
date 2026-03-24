// Keeper runtime signals, neighborhood, and tool audit panels.
// Redesigned: consistent signal row styling with inline Tailwind,
// clean tool chip badges, proper section spacing.

import { html } from 'htm/preact'
import { TimeAgo } from './common/time-ago'
import { missionSnapshot } from '../mission-store'
import type { DashboardMissionKeeperBrief, Keeper } from '../types'
import { serverStatus } from '../store'
import { operatorSnapshot } from '../operator-store'
import {
  allowlistEmptyState,
  auditMetadataState,
  linkedRecentToolsEmptyState,
  linkedRuntimeState,
  observedToolsEmptyState,
  openToolsInventory,
  toolAuditStateLabel,
} from './common/tool-audit'

// ── Utility functions ────────────────────────────────────

export function actionDescriptorLabel(actionType?: string): string {
  switch (actionType) {
    case 'keeper_message':
      return 'message'
    case 'keeper_probe':
      return 'probe'
    case 'keeper_recover':
      return 'recover'
    case 'broadcast':
      return 'broadcast'
    case 'room_pause':
      return 'pause'
    case 'room_resume':
      return 'resume'
    case 'social_sweep':
      return 'social'
    default:
      return actionType?.trim() || 'action'
  }
}

function keeperRecentTools(keeper: Keeper): string[] {
  if (keeper.recent_tool_names && keeper.recent_tool_names.length > 0) {
    return keeper.recent_tool_names
  }
  return []
}

function keeperTopTools(keeper: Keeper): string[] {
  const metrics = keeper.metrics_window
  const topTools = Array.isArray(metrics?.top_tools) ? metrics.top_tools : []
  return topTools
    .map(item => (typeof item === 'object' && item !== null && 'tool' in item && typeof item.tool === 'string' ? item.tool : null))
    .filter((item): item is string => item !== null)
}

function missionKeeperBrief(keeper: Keeper): DashboardMissionKeeperBrief | null {
  const mission = missionSnapshot.value
  if (!mission) return null
  return mission.keeper_briefs.find(brief =>
    brief.name === keeper.name
      || (brief.agent_name && keeper.agent_name && brief.agent_name === keeper.agent_name))
    ?? null
}

function formatPct(value: number | undefined): string {
  if (value == null || Number.isNaN(value)) return '-'
  return `${Math.round(value * 100)}%`
}

// ── Shared row component ─────────────────────────────────

function SignalRow({ label, value }: { label: string; value: string | number }) {
  return html`
    <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
      <span class="text-xs text-[var(--text-muted)]">${label}</span>
      <span class="text-xs font-medium text-[var(--text-strong)]">${value}</span>
    </div>
  `
}

// ── Tool chip badge ──────────────────────────────────────

function ToolChip({ name }: { name: string }) {
  return html`
    <span class="inline-flex items-center py-0.5 px-2 rounded-full text-[10px] font-medium bg-[var(--accent-12)] text-[#9ad9ff] border border-[rgba(71,184,255,0.25)]">${name}</span>
  `
}

// ── Tool list section ────────────────────────────────────

function ToolSection({ title, description, tools, fallback }: { title: string; description?: string; tools: string[]; fallback: string }) {
  return html`
    <div class="flex flex-col gap-1.5 mt-3">
      <span class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">${title}</span>
      ${description ? html`<span class="text-[11px] text-[var(--text-muted)] leading-snug">${description}</span>` : null}
      <div class="flex flex-wrap gap-1.5">
        ${tools.length > 0
          ? tools.map(tool => html`<${ToolChip} name=${tool} />`)
          : html`<span class="text-[11px] text-[var(--text-muted)] italic">${fallback}</span>`}
      </div>
    </div>
  `
}

// ── Runtime Signals ──────────────────────────────────────

export function RuntimeSignals({ keeper }: { keeper: Keeper }) {
  const mw = keeper.metrics_window

  // Quality/rate metrics only — raw counts (handoffs, compactions, k2k, etc.)
  // are authoritative in KpiGrid to avoid duplication.
  const rows: Array<{ label: string; value: string | number }> = [
    { label: 'Model fallback', value: formatPct(typeof mw?.model_fallback_rate === 'number' ? mw.model_fallback_rate : undefined) },
    { label: 'Proactive fallback', value: formatPct(typeof mw?.proactive_fallback_rate === 'number' ? mw.proactive_fallback_rate : undefined) },
    { label: 'Memory pass rate', value: formatPct(typeof mw?.memory_pass_rate === 'number' ? mw.memory_pass_rate : undefined) },
    { label: 'Preview similarity', value: typeof mw?.proactive_preview_similarity_avg === 'number' ? `${(mw.proactive_preview_similarity_avg * 100).toFixed(1)}%` : '-' },
    { label: 'Memory avg score', value: typeof mw?.memory_avg_score === 'number' ? mw.memory_avg_score.toFixed(3) : '-' },
    { label: 'Fallback rate', value: typeof mw?.fallback_rate === 'number' ? `${(mw.fallback_rate * 100).toFixed(1)}%` : '-' },
  ]

  const visibleRows = rows.filter(row =>
    !(
      row.value === '-'
      || row.value === '\u2014'
      || row.value === ''
    ))

  if (visibleRows.length === 0) return null

  return html`
    <div class="flex flex-col gap-1.5">
      ${visibleRows.map(r => html`<${SignalRow} label=${r.label} value=${r.value} />`)}
    </div>
  `
}

// ── Neighborhood & Tool Audit ────────────────────────────

export function KeeperNeighborhood({ keeper }: { keeper: Keeper }) {
  const room = operatorSnapshot.value?.room ?? {}
  const actions = (operatorSnapshot.value?.available_actions ?? [])
    .filter(action => action.target_type === 'keeper' || action.target_type === 'room')
    .slice(0, 8)
  const recentTools = keeperRecentTools(keeper)
  const topTools = keeperTopTools(keeper)
  const missionBrief = missionKeeperBrief(keeper)
  const allowedTools =
    missionBrief?.allowed_tool_names && missionBrief.allowed_tool_names.length > 0
      ? missionBrief.allowed_tool_names
      : keeper.allowed_tool_names ?? []
  const observedTools =
    missionBrief?.latest_tool_names && missionBrief.latest_tool_names.length > 0
      ? missionBrief.latest_tool_names
      : keeper.latest_tool_names ?? []
  const toolCallCount = missionBrief?.latest_tool_call_count ?? keeper.latest_tool_call_count
  const auditSource = missionBrief?.tool_audit_source ?? keeper.tool_audit_source
  const auditAt = missionBrief?.tool_audit_at ?? keeper.tool_audit_at
  const capabilities = keeper.agent?.capabilities ?? []
  const roomName = room.current_room ?? room.room_id ?? serverStatus.value?.room ?? 'default'
  const project = room.project ?? serverStatus.value?.project ?? 'N/A'
  const cluster = room.cluster ?? serverStatus.value?.cluster ?? 'N/A'
  const allowlistFallback = toolAuditStateLabel(allowlistEmptyState(keeper))
  const observedFallback = toolAuditStateLabel(observedToolsEmptyState(keeper, auditSource))
  const metadataFallback = toolAuditStateLabel(auditMetadataState(keeper, auditSource))
  const linkedRecentFallback = toolAuditStateLabel(linkedRecentToolsEmptyState(keeper))
  const runtimeState = linkedRuntimeState(keeper)
  const currentTaskLabel =
    keeper.agent?.current_task
    ?? (runtimeState === 'offline' ? 'offline' : 'not_collected')
  const skillRouteLabel =
    keeper.skill_primary
    ?? (runtimeState === 'offline' ? 'offline' : 'not_collected')
  const openToolsQuery = allowedTools[0] ?? observedTools[0] ?? recentTools[0] ?? null

  return html`
    <div class="flex flex-col gap-1.5">
      <${SignalRow} label="Room" value=${roomName} />
      <${SignalRow} label="Project" value=${project} />
      <${SignalRow} label="Cluster" value=${cluster} />
      <${SignalRow} label="Current task" value=${currentTaskLabel} />
      <${SignalRow} label="Skill route" value=${skillRouteLabel} />
      <${SignalRow} label="Context source" value=${keeper.context_source ?? keeper.context?.source ?? '-'} />

      <div class="flex justify-end mt-1">
        <button type="button"
          class="py-1.5 px-3 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] text-[11px] text-[var(--text-muted)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] transition-colors cursor-pointer"
          onClick=${() => { openToolsInventory(openToolsQuery) }}
        >
          Open tools panel
        </button>
      </div>

      <${ToolSection}
        title="Allowed tools"
        description="Currently permitted tools for this keeper runtime."
        tools=${allowedTools}
        fallback=${allowlistFallback}
      />

      <${ToolSection}
        title="Observed tools"
        description="Recent execution evidence from heartbeat or runtime telemetry."
        tools=${observedTools}
        fallback=${observedFallback}
      />

      <${SignalRow} label="Tool calls" value=${typeof toolCallCount === 'number' ? toolCallCount : observedFallback === 'none_recent' ? 0 : metadataFallback} />
      <${SignalRow} label="Evidence source" value=${auditSource ?? metadataFallback} />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">Observed at</span>
        <span class="text-xs font-medium text-[var(--text-strong)]">${auditAt ? html`<${TimeAgo} timestamp=${auditAt} />` : metadataFallback}</span>
      </div>

      <${ToolSection}
        title="Keeper recent tools"
        tools=${recentTools}
        fallback=${linkedRecentFallback}
      />

      ${topTools.length > 0
        ? html`<${ToolSection} title="Window top tools" tools=${topTools} fallback="" />`
        : null}

      <${ToolSection}
        title="Capabilities"
        tools=${capabilities}
        fallback="No registered capabilities"
      />

      <${ToolSection}
        title="Available actions nearby"
        tools=${actions.map(action => actionDescriptorLabel(action.action_type))}
        fallback="No operator action advertisements"
      />
    </div>
  `
}
