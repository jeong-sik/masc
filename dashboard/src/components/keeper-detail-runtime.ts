// Keeper runtime signals, neighborhood, and tool audit panels.
// Extracted from keeper-detail-panels.ts for maintainability.

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
    case 'lodge_tick':
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

// ── Runtime Signals ──────────────────────────────────────

export function RuntimeSignals({ keeper }: { keeper: Keeper }) {
  const mw = keeper.metrics_window

  const rows: Array<{ label: string; value: string | number }> = [
    { label: 'Model fallback', value: formatPct(typeof mw?.model_fallback_rate === 'number' ? mw.model_fallback_rate : undefined) },
    { label: '선제적 폴백', value: formatPct(typeof mw?.proactive_fallback_rate === 'number' ? mw.proactive_fallback_rate : undefined) },
    { label: '메모리 통과율', value: formatPct(typeof mw?.memory_pass_rate === 'number' ? mw.memory_pass_rate : undefined) },
    { label: '핸드오프', value: typeof mw?.handoff_count === 'number' ? mw.handoff_count : keeper.handoff_count_total ?? '-' },
    { label: '컴팩션', value: typeof mw?.compaction_events === 'number' ? mw.compaction_events : keeper.compaction_count ?? '-' },
    { label: '절약 토큰', value: typeof mw?.compaction_saved_tokens === 'number' ? mw.compaction_saved_tokens : keeper.last_compaction_saved_tokens ?? '-' },
    { label: 'K2K 이벤트', value: keeper.k2k_count ?? '-' },
    { label: '대화 꼬리', value: keeper.conversation_tail_count ?? '-' },
    { label: '도구 호출', value: typeof mw?.tool_call_count === 'number' ? mw.tool_call_count : '-' },
    { label: '미리보기 유사도', value: typeof mw?.proactive_preview_similarity_avg === 'number' ? `${(mw.proactive_preview_similarity_avg * 100).toFixed(1)}%` : '-' },
    { label: '메모리 평균 점수', value: typeof mw?.memory_avg_score === 'number' ? mw.memory_avg_score.toFixed(3) : '-' },
    { label: '폴백 비율', value: typeof mw?.fallback_rate === 'number' ? `${(mw.fallback_rate * 100).toFixed(1)}%` : '-' },
  ]

  const visibleRows = rows.filter(row =>
    !(
      row.value === '-'
      || row.value === '—'
      || row.value === ''
    ))

  if (visibleRows.length === 0) return null

  return html`
    <div class="keeper-signal-list">
      ${visibleRows.map(r => html`
        <div class="keeper-signal-row">
          <span>${r.label}</span>
          <strong>${r.value}</strong>
        </div>
      `)}
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
  const project = room.project ?? serverStatus.value?.project ?? '확인 없음'
  const cluster = room.cluster ?? serverStatus.value?.cluster ?? '확인 없음'
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
    <div class="keeper-signal-list">
      <div class="keeper-signal-row">
        <span>Room</span>
        <strong>${roomName}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Project</span>
        <strong>${project}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Cluster</span>
        <strong>${cluster}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Current task</span>
        <strong>${currentTaskLabel}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Skill route</span>
        <strong>${skillRouteLabel}</strong>
      </div>
      <div style="display:flex; justify-content:flex-end; margin-top:4px;">
        <button class="control-btn ghost" onClick=${() => { openToolsInventory(openToolsQuery) }}>
          Open tools panel
        </button>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Allowed tools</span>
        <span style="font-size:11px; color:#64748b;">Currently permitted tools for this keeper runtime.</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${allowedTools.length > 0
            ? allowedTools.map(tool => html`<span class="pill">${tool}</span>`)
            : html`<span style="font-size:12px; color:#888;">${allowlistFallback}</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Observed tools</span>
        <span style="font-size:11px; color:#64748b;">Recent execution evidence from heartbeat or runtime telemetry.</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${observedTools.length > 0
            ? observedTools.map(tool => html`<span class="pill">${tool}</span>`)
            : html`<span style="font-size:12px; color:#888;">${observedFallback}</span>`}
        </div>
      </div>
      <div class="keeper-signal-row">
        <span>Tool calls</span>
        <strong>${typeof toolCallCount === 'number' ? toolCallCount : observedFallback === 'none_recent' ? 0 : metadataFallback}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Evidence source</span>
        <strong>${auditSource ?? metadataFallback}</strong>
      </div>
      <div class="keeper-signal-row">
        <span>Observed at</span>
        <strong>${auditAt ? html`<${TimeAgo} timestamp=${auditAt} />` : metadataFallback}</strong>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Keeper recent tools</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${recentTools.length > 0
            ? recentTools.map(tool => html`<span class="pill">${tool}</span>`)
            : html`<span style="font-size:12px; color:#888;">${linkedRecentFallback}</span>`}
        </div>
      </div>
      ${topTools.length > 0
        ? html`
            <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
              <span style="font-size:12px; color:#888;">Window top tools</span>
              <div style="display:flex; flex-wrap:wrap; gap:6px;">
                ${topTools.map(tool => html`<span class="pill">${tool}</span>`)}
              </div>
            </div>
          `
        : null}
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Capabilities</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${capabilities.length > 0
            ? capabilities.map(capability => html`<span class="pill">${capability}</span>`)
            : html`<span style="font-size:12px; color:#888;">등록된 capability 없음</span>`}
        </div>
      </div>
      <div style="display:flex; flex-direction:column; gap:8px; margin-top:8px;">
        <span style="font-size:12px; color:#888;">Available actions nearby</span>
        <div style="display:flex; flex-wrap:wrap; gap:6px;">
          ${actions.length > 0
            ? actions.map(action => html`<span class="pill">${actionDescriptorLabel(action.action_type)}</span>`)
            : html`<span style="font-size:12px; color:#888;">operator action 광고 없음</span>`}
        </div>
      </div>
    </div>
  `
}
