// Keeper fleet overview — compact comparison grid showing all keepers
// at a glance: pipeline stage, context ratio, tool calls, generation,
// and activity recency. Designed for the Agents tab header.

import { html } from 'htm/preact'
import { navigate } from '../router'
import type { Keeper, PipelineStage } from '../types/core'
import { CONTEXT_RATIO_CRITICAL, CONTEXT_RATIO_FLEET_WARN } from '../config/constants'
import { KeeperPhaseBadge } from './keeper-phase-indicator'

// ── Pipeline stage styling ────────────────────────────

interface StageStyle {
  label: string
  color: string
  bg: string
  pulse: boolean
}

const STAGE_STYLES: Record<string, StageStyle> = {
  thinking:             { label: '사고',    color: 'var(--accent)',  bg: 'rgba(71,184,255,0.12)', pulse: true },
  tool_use:             { label: '도구',    color: 'var(--ok)',      bg: 'rgba(52,211,153,0.12)', pulse: true },
  compacting:           { label: '압축',    color: '#a855f7',        bg: 'rgba(168,85,247,0.12)', pulse: true },
  handoff:              { label: '승계',    color: '#ef4444',        bg: 'rgba(239,68,68,0.12)',  pulse: true },
  scheduled_autonomous: { label: '자율',    color: 'var(--accent)',  bg: 'rgba(71,184,255,0.08)', pulse: true },
  failing:              { label: '오류',    color: 'var(--bad)',     bg: 'rgba(239,68,68,0.12)',  pulse: true },
  crashed:              { label: '중단',    color: '#ef4444',        bg: 'rgba(239,68,68,0.15)',  pulse: false },
  restarting:           { label: '재시작',  color: '#38bdf8',        bg: 'rgba(56,189,248,0.12)', pulse: true },
  draining:             { label: '종료중',  color: '#fb923c',        bg: 'rgba(251,146,60,0.12)', pulse: true },
  paused:               { label: '일시정지', color: '#a78bfa',       bg: 'rgba(167,139,250,0.12)', pulse: false },
  idle:                 { label: '대기',    color: 'var(--text-dim)', bg: 'var(--white-5)',        pulse: false },
  offline:              { label: '오프',    color: 'var(--text-dim)', bg: 'var(--white-3)',        pulse: false },
}

const ACTIVE_STAGES = new Set<string>(['thinking', 'tool_use', 'compacting', 'handoff', 'scheduled_autonomous', 'failing', 'restarting', 'draining'])

function stageStyle(stage?: PipelineStage): StageStyle {
  if (!stage) return STAGE_STYLES['offline']!
  return STAGE_STYLES[stage] ?? STAGE_STYLES['offline']!
}

// ── Context bar ───────────────────────────────────────

function ContextBar({ ratio }: { ratio: number | undefined }) {
  const pct = (ratio ?? 0) * 100
  const color = pct > 85 ? 'var(--bad)' : pct > 60 ? 'var(--warn)' : 'var(--ok)'
  return html`
    <div class="flex items-center gap-1.5">
      <div class="flex-1 h-1.5 rounded-full bg-[var(--white-6)] overflow-hidden">
        <div class="h-full rounded-full transition-all duration-500"
          style="width: ${pct.toFixed(0)}%; background: ${color}"></div>
      </div>
      <span class="text-[10px] font-mono w-8 text-right" style="color: ${color}">
        ${pct > 0 ? `${pct.toFixed(0)}%` : '-'}
      </span>
    </div>
  `
}

// ── Activity recency ──────────────────────────────────

function formatRecency(agoS: number | undefined): string {
  if (agoS == null) return '-'
  if (agoS < 60) return `${Math.round(agoS)}초`
  if (agoS < 3600) return `${Math.floor(agoS / 60)}분`
  if (agoS < 86400) return `${Math.floor(agoS / 3600)}시간`
  return `${Math.floor(agoS / 86400)}일`
}

// ── Keeper row ────────────────────────────────────────

function KeeperRow({ keeper }: { keeper: Keeper }) {
  const stage = stageStyle(keeper.pipeline_stage)
  const isActive = ACTIVE_STAGES.has(keeper.pipeline_stage ?? '')
  const toolCount = keeper.latest_tool_call_count ?? keeper.metrics_window?.tool_call_count ?? 0

  return html`
    <div
      class="flex items-center gap-3 py-2 px-3 rounded-lg cursor-pointer hover:bg-[var(--white-5)] transition-colors ${isActive ? 'ring-1 ring-[var(--accent-30)]' : ''}"
      onClick=${() => navigate('monitoring', { section: 'agents', agent: keeper.name })}
    >
      ${'' /* Phase badge (lifecycle) + Stage badge (activity) */}
      <div class="flex-shrink-0">
        <${KeeperPhaseBadge} phase=${keeper.phase} compact />
      </div>
      <div
        class="flex-shrink-0 px-2 py-0.5 rounded text-[10px] font-bold uppercase tracking-wider text-center w-12"
        style="color: ${stage.color}; background: ${stage.bg}; ${stage.pulse ? 'animation: loadingPulse 2s ease-in-out infinite;' : ''}"
      >
        ${stage.label}
      </div>

      ${'' /* Name */}
      <div class="w-28 flex-shrink-0 truncate">
        <span class="text-[12px] font-mono font-medium text-[var(--text-strong)]">${keeper.name}</span>
      </div>

      ${'' /* Context bar */}
      <div class="flex-1 min-w-20 max-w-40">
        <${ContextBar} ratio=${keeper.context_ratio} />
      </div>

      ${'' /* Stats */}
      <div class="flex items-center gap-4 flex-shrink-0 text-[10px] font-mono text-[var(--text-muted)]">
        <span title="세대">G${keeper.generation ?? 0}</span>
        <span title="턴">${keeper.turn_count ?? 0}t</span>
        <span title="도구 호출">${toolCount > 0 ? `${toolCount}c` : '-'}</span>
        <span title="마지막 활동" class="${(keeper.last_activity_ago_s ?? 999) < 120 ? 'text-[var(--ok)]' : ''}">
          ${formatRecency(keeper.last_activity_ago_s)}
        </span>
      </div>
    </div>
  `
}

// ── Fleet summary bar ─────────────────────────────────

function FleetSummary({ keepers }: { keepers: Keeper[] }) {
  const active = keepers.filter(k => ACTIVE_STAGES.has(k.pipeline_stage ?? '')).length
  const idle = keepers.filter(k => k.pipeline_stage === 'idle').length
  const offline = keepers.length - active - idle
  const avgCtx = keepers.reduce((s, k) => s + (k.context_ratio ?? 0), 0) / (keepers.length || 1)
  const totalTools = keepers.reduce((s, k) => s + (k.latest_tool_call_count ?? k.metrics_window?.tool_call_count ?? 0), 0)
  const totalCompactions = keepers.reduce((s, k) => s + (k.compaction_count ?? 0), 0)
  const compactKeepers = keepers.filter(k => k.metrics_window?.compaction_saved_ratio != null)
  const avgSavedRatio = compactKeepers.length > 0
    ? compactKeepers.reduce((s, k) => s + (k.metrics_window?.compaction_saved_ratio ?? 0), 0) / compactKeepers.length
    : null

  return html`
    <div class="flex gap-3 flex-wrap text-[11px] mb-3">
      <span class="inline-flex items-center gap-1 px-2 py-1 rounded-md bg-[var(--white-4)] border border-[var(--white-6)]">
        <span class="font-mono font-medium text-[var(--ok)]">${active}</span>
        <span class="text-[var(--text-dim)]">활성</span>
      </span>
      <span class="inline-flex items-center gap-1 px-2 py-1 rounded-md bg-[var(--white-4)] border border-[var(--white-6)]">
        <span class="font-mono font-medium text-[var(--text-muted)]">${idle}</span>
        <span class="text-[var(--text-dim)]">대기</span>
      </span>
      ${offline > 0 ? html`
        <span class="inline-flex items-center gap-1 px-2 py-1 rounded-md bg-[var(--white-4)] border border-[var(--white-6)]">
          <span class="font-mono font-medium text-[var(--text-dim)]">${offline}</span>
          <span class="text-[var(--text-dim)]">오프</span>
        </span>
      ` : null}
      <span class="inline-flex items-center gap-1 px-2 py-1 rounded-md bg-[var(--white-4)] border border-[var(--white-6)]">
        <span class="text-[var(--text-dim)]">평균 컨텍스트</span>
        <span class="font-mono font-medium ${avgCtx > CONTEXT_RATIO_CRITICAL ? 'text-[var(--bad)]' : avgCtx > CONTEXT_RATIO_FLEET_WARN ? 'text-[var(--warn)]' : 'text-[var(--text-strong)]'}">${(avgCtx * 100).toFixed(0)}%</span>
      </span>
      ${totalTools > 0 ? html`
        <span class="inline-flex items-center gap-1 px-2 py-1 rounded-md bg-[var(--white-4)] border border-[var(--white-6)]">
          <span class="font-mono font-medium text-[var(--text-strong)]">${totalTools}</span>
          <span class="text-[var(--text-dim)]">총 도구 호출</span>
        </span>
      ` : null}
      ${totalCompactions > 0 ? html`
        <span class="inline-flex items-center gap-1 px-2 py-1 rounded-md bg-[var(--white-4)] border border-[var(--white-6)]">
          <span class="font-mono font-medium text-[#a855f7]">${totalCompactions}</span>
          <span class="text-[var(--text-dim)]">압축</span>
          ${avgSavedRatio != null ? html`
            <span class="font-mono font-medium ${avgSavedRatio >= 0.4 ? 'text-[var(--ok)]' : avgSavedRatio >= 0.2 ? 'text-[var(--warn)]' : 'text-[var(--bad)]'}">${(avgSavedRatio * 100).toFixed(0)}%</span>
            <span class="text-[var(--text-dim)]">절감</span>
          ` : null}
        </span>
      ` : null}
    </div>
  `
}

// ── Main component ────────────────────────────────────

export function KeeperFleetOverview({ keepers: allKeepers }: { keepers: Keeper[] }) {
  if (allKeepers.length === 0) return null

  // Sort: active first, then by recency
  const sorted = [...allKeepers].sort((a, b) => {
    const aActive = ACTIVE_STAGES.has(a.pipeline_stage ?? '') ? 1 : 0
    const bActive = ACTIVE_STAGES.has(b.pipeline_stage ?? '') ? 1 : 0
    if (aActive !== bActive) return bActive - aActive
    return (a.last_activity_ago_s ?? 9999) - (b.last_activity_ago_s ?? 9999)
  })

  return html`
    <div class="mb-6">
      <${FleetSummary} keepers=${allKeepers} />
      <div class="flex flex-col gap-0.5 rounded-xl border border-[var(--card-border)] bg-[var(--white-2)] p-2">
        ${sorted.map(k => html`<${KeeperRow} key=${k.name} keeper=${k} />`)}
      </div>
    </div>
  `
}
