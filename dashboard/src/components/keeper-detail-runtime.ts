// Keeper runtime signals, neighborhood, and tool audit panels.
// Redesigned: consistent signal row styling with inline Tailwind,
// clean tool chip badges, proper section spacing.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
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
import { ToolAllowlistEditor } from './tools/tool-allowlist-editor'
import { loadTools } from './tools/tool-state'

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

// Helper: format a 0–1 ratio as percentage or '-'
function fmtRate(v: number | undefined): string {
  return v != null ? `${(v * 100).toFixed(1)}%` : '-'
}

// Helper: format a float with fixed decimals or '-'
function fmtFixed(v: number | undefined, digits = 3): string {
  return v != null ? v.toFixed(digits) : '-'
}

// Helper: format an integer count or '-'
function fmtCount(v: number | undefined): string | number {
  return v != null ? v : '-'
}

interface SignalGroup {
  title: string
  rows: Array<{ label: string; value: string | number }>
}

export function RuntimeSignals({ keeper }: { keeper: Keeper }) {
  const mw = keeper.metrics_window

  // Quality/rate metrics only — raw counts (handoffs, compactions, turns)
  // are authoritative in KpiGrid to avoid duplication.
  const groups: SignalGroup[] = [
    {
      title: '폴백',
      rows: [
        { label: '전체 폴백', value: fmtRate(mw?.fallback_rate) },
        { label: '모델 폴백', value: fmtRate(mw?.model_fallback_rate) },
        { label: '프로액티브 폴백', value: fmtRate(mw?.proactive_fallback_rate) },
      ],
    },
    {
      title: '정렬 품질',
      rows: [
        { label: '목표 정렬', value: fmtFixed(mw?.goal_alignment_avg) },
        { label: '응답 정렬', value: fmtFixed(mw?.response_alignment_avg) },
        { label: '목표 드리프트', value: fmtFixed(mw?.goal_drift_avg) },
        { label: '반복 위험', value: fmtFixed(mw?.repetition_risk_avg) },
      ],
    },
    {
      title: '자율 행동',
      rows: [
        { label: '자동 성찰 비율', value: fmtRate(mw?.auto_reflect_rate) },
        { label: '자동 계획 비율', value: fmtRate(mw?.auto_plan_rate) },
        { label: '자동 컴팩션 비율', value: fmtRate(mw?.auto_compact_rate) },
        { label: '자동 핸드오프 비율', value: fmtRate(mw?.auto_handoff_rate) },
        { label: '가드레일 정지', value: fmtCount(mw?.guardrail_stop_count) },
        { label: '가드레일 비율', value: fmtRate(mw?.guardrail_stop_rate) },
      ],
    },
    {
      title: '드리프트 보정',
      rows: [
        { label: '보정 횟수', value: fmtCount(mw?.drift_applied_count) },
        { label: '보정 비율', value: fmtRate(mw?.drift_applied_rate) },
        { label: '개입 비중', value: fmtRate(mw?.intervention_share) },
        { label: '턴당 개입', value: fmtFixed(mw?.intervention_per_turn, 2) },
      ],
    },
    {
      title: '메모리',
      rows: [
        { label: '메모리 통과율', value: fmtRate(mw?.memory_pass_rate) },
        { label: '메모리 평균 점수', value: fmtFixed(mw?.memory_avg_score) },
        { label: '메모리 교정', value: fmtCount(mw?.memory_corrections) },
        { label: '교정 성공', value: fmtCount(mw?.memory_correction_success) },
        { label: '날씨 통과율', value: fmtRate(mw?.memory_weather_pass_rate) },
      ],
    },
    {
      title: '메모리 컴팩션',
      rows: [
        { label: '드롭 비율', value: fmtRate(mw?.memory_compaction_drop_ratio) },
        { label: '평균 드롭', value: fmtFixed(mw?.memory_compaction_drop_avg, 1) },
        { label: '컴팩션 절감', value: fmtRate(mw?.compaction_saved_ratio) },
        { label: '평균 절감 토큰', value: fmtFixed(mw?.avg_compaction_saved_tokens, 0) },
      ],
    },
    {
      title: '프리뷰 유사도',
      rows: [
        { label: '평균', value: fmtRate(mw?.proactive_preview_similarity_avg) },
        { label: '최대', value: fmtRate(mw?.proactive_preview_similarity_max) },
        { label: '경고', value: typeof mw?.proactive_preview_similarity_warn === 'boolean' ? (mw.proactive_preview_similarity_warn ? 'Y' : 'N') : '-' },
      ],
    },
    {
      title: '반응',
      rows: [
        { label: '멘션 반응', value: fmtCount(keeper.mention_reactive_turn_count) },
      ],
    },
  ]

  // Filter out groups where all rows are '-'
  const visibleGroups = groups
    .map(g => ({
      ...g,
      rows: g.rows.filter(r => r.value !== '-' && r.value !== '\u2014' && r.value !== ''),
    }))
    .filter(g => g.rows.length > 0)

  if (visibleGroups.length === 0) return null

  return html`
    <div class="flex flex-col gap-3">
      ${visibleGroups.map(g => html`
        <div class="flex flex-col gap-1">
          <span class="text-[10px] font-semibold uppercase tracking-wider text-[var(--text-muted)] px-1">${g.title}</span>
          <div class="flex flex-col gap-1">
            ${g.rows.map(r => html`<${SignalRow} label=${r.label} value=${r.value} />`)}
          </div>
        </div>
      `)}
    </div>
  `
}

// ── Neighborhood & Tool Audit ────────────────────────────

export function KeeperNeighborhood({ keeper }: { keeper: Keeper }) {
  useEffect(() => { showAllowlistEditor.value = false }, [keeper.name])

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
            if (showAllowlistEditor.value) loadTools()
          }}
        >${showAllowlistEditor.value ? '닫기' : '편집'}</button>
      </div>

      ${showAllowlistEditor.value
        ? html`<${ToolAllowlistEditor}
            keeperName=${keeper.name}
            currentMode=${keeper.tool_policy_mode ?? 'preset'}
            currentPreset=${keeper.tool_preset ?? 'full'}
            currentAlsoAllow=${keeper.tool_also_allow ?? []}
            currentCustomAllowlist=${keeper.tool_custom_allowlist ?? []}
            currentDenylist=${keeper.tool_denylist ?? []}
            resolvedAllowlist=${allowedTools}
            onUpdated=${() => { showAllowlistEditor.value = false; loadTools() }}
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
