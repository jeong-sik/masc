// Keeper runtime signals, neighborhood, and tool audit panels.
// Redesigned: consistent signal row styling with inline Tailwind,
// clean tool chip badges, proper section spacing.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { TimeAgo } from './common/time-ago'
import { missionSnapshot } from '../mission-store'
import { formatPct } from '../lib/format-number'
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
import { ToolAllowlistEditor } from './tools/tool-allowlist-editor'
import { toolsData, loadTools } from './tools/tool-state'

const showAllowlistEditor = signal(false)

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
    <button type="button"
      class="inline-flex items-center py-0.5 px-2 rounded-full text-[10px] font-medium bg-[var(--accent-12)] text-[#9ad9ff] border border-[rgba(71,184,255,0.25)] hover:bg-[rgba(71,184,255,0.18)] cursor-pointer transition-colors"
      title="클릭하여 도구 상세 보기"
      onClick=${() => openToolsInventory(name)}
    >${name}</button>
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
    { label: '자율 턴', value: keeper.autonomous_turn_count ?? '-' },
    { label: '도구 턴', value: keeper.autonomous_tool_turn_count ?? '-' },
    { label: '텍스트 턴', value: keeper.autonomous_text_turn_count ?? '-' },
    { label: '게시판 반응', value: keeper.board_reactive_turn_count ?? '-' },
    { label: '멘션 반응', value: keeper.mention_reactive_turn_count ?? '-' },
    { label: 'No-op 턴', value: keeper.noop_turn_count ?? '-' },
    { label: '모델 폴백', value: formatPct(typeof mw?.model_fallback_rate === 'number' ? mw.model_fallback_rate : undefined) },
    { label: '프로액티브 폴백', value: formatPct(typeof mw?.proactive_fallback_rate === 'number' ? mw.proactive_fallback_rate : undefined) },
    { label: '메모리 통과율', value: formatPct(typeof mw?.memory_pass_rate === 'number' ? mw.memory_pass_rate : undefined) },
    { label: '프리뷰 유사도', value: typeof mw?.proactive_preview_similarity_avg === 'number' ? `${(mw.proactive_preview_similarity_avg * 100).toFixed(1)}%` : '-' },
    { label: '메모리 평균 점수', value: typeof mw?.memory_avg_score === 'number' ? mw.memory_avg_score.toFixed(3) : '-' },
    { label: '폴백 비율', value: typeof mw?.fallback_rate === 'number' ? `${(mw.fallback_rate * 100).toFixed(1)}%` : '-' },
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
  const clusterRaw = room.cluster ?? serverStatus.value?.cluster ?? null
  const clusterVisible = clusterRaw && clusterRaw !== 'unknown' && clusterRaw !== 'default' && clusterRaw !== 'N/A'
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
  const allowedToolCountLabel =
    allowedTools.length > 0 ? String(allowedTools.length) : allowlistFallback
  const openToolsQuery = allowedTools[0] ?? observedTools[0] ?? recentTools[0] ?? null

  return html`
    <div class="flex flex-col gap-1.5">
      <${SignalRow} label="룸" value=${roomName} />
      <${SignalRow} label="프로젝트" value=${project} />
      ${clusterVisible ? html`<${SignalRow} label="클러스터" value=${clusterRaw} />` : null}
      <${SignalRow} label="현재 태스크" value=${currentTaskLabel} />
      <${SignalRow} label="스킬 경로" value=${skillRouteLabel} />
      <${SignalRow} label="컨텍스트 출처" value=${keeper.context_source ?? keeper.context?.source ?? '-'} />
      <${SignalRow} label="허용 도구 수" value=${allowedToolCountLabel} />

      <div class="flex justify-end mt-1">
        <button type="button"
          class="py-1.5 px-3 rounded-lg border border-[var(--card-border)] bg-[var(--white-3)] text-[11px] text-[var(--text-muted)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)] transition-colors cursor-pointer"
          onClick=${() => { openToolsInventory(openToolsQuery) }}
        >
          도구 패널 열기
        </button>
      </div>

      <div class="flex items-center justify-between mt-3">
        <span class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)]">허용된 도구</span>
        <button type="button"
          class="text-[10px] text-[var(--text-muted)] hover:text-[var(--text-body)] cursor-pointer transition-colors"
          onClick=${() => {
            showAllowlistEditor.value = !showAllowlistEditor.value
            if (showAllowlistEditor.value && !toolsData.value) loadTools()
          }}
        >${showAllowlistEditor.value ? '닫기' : '편집'}</button>
      </div>

      ${showAllowlistEditor.value
        ? html`<${ToolAllowlistEditor}
            keeperName=${keeper.name}
            currentAllowlist=${allowedTools}
            allToolNames=${(toolsData.value?.tool_inventory?.tools ?? []).map((t: { name: string }) => t.name)}
            onUpdated=${() => { showAllowlistEditor.value = false }}
          />`
        : html`
          <span class="text-[11px] text-[var(--text-muted)] leading-snug">이 키퍼 런타임에 현재 허용된 도구.</span>
          <div class="flex flex-wrap gap-1.5">
            ${allowedTools.length > 0
              ? allowedTools.map((tool: string) => html`<${ToolChip} name=${tool} />`)
              : html`<span class="text-[11px] text-[var(--text-muted)] italic">${allowlistFallback}</span>`}
          </div>
        `}

      <${ToolSection}
        title="관측된 도구"
        description="하트비트 또는 런타임 텔레메트리의 최근 실행 근거."
        tools=${observedTools}
        fallback=${observedFallback}
      />

      <${SignalRow} label="도구 호출" value=${typeof toolCallCount === 'number' ? toolCallCount : observedFallback === 'none_recent' ? 0 : metadataFallback} />
      <${SignalRow} label="근거 출처" value=${auditSource ?? metadataFallback} />
      <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-[var(--white-3)]">
        <span class="text-xs text-[var(--text-muted)]">관측 시점</span>
        <span class="text-xs font-medium text-[var(--text-strong)]">${auditAt ? html`<${TimeAgo} timestamp=${auditAt} />` : metadataFallback}</span>
      </div>

      <${ToolSection}
        title="키퍼 최근 도구"
        tools=${recentTools}
        fallback=${linkedRecentFallback}
      />

      ${topTools.length > 0
        ? html`<${ToolSection} title="윈도우 상위 도구" tools=${topTools} fallback="" />`
        : null}

      <${ToolSection}
        title="등록된 기능"
        tools=${capabilities}
        fallback="등록된 기능 없음"
      />

      <${ToolSection}
        title="사용 가능한 인근 액션"
        tools=${actions.map(action => actionDescriptorLabel(action.action_type))}
        fallback="운영자 액션 광고 없음"
      />
    </div>
  `
}
