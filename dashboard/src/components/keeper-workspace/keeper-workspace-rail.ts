// Keeper Workspace — context rail (right). Runtime/throughput, context-window
// occupancy, owned tasks, recent tool calls, and the "운영 상세" toggle that
// surfaces the full KeeperDetailBody. Most data comes from the live Keeper
// object + the tasks store; the recent-tool-calls section lazy-loads the rich
// per-call store (see keeper-workspace-tool-calls.ts).

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { tasks } from '../../store'
import type { Keeper, Task } from '../../types'
import { navigate } from '../../router'
import { keeperModelLabel, keeperRuntimeLabel } from './keeper-workspace-shared'
import { KeeperWorkspaceRecentTools } from './keeper-workspace-tool-calls'
import { formatDuration } from '../../lib/format-time'

const COMPACT_AT = 85 // auto-compaction threshold (%) — matches runtime default

function contextRatio(keeper: Keeper): number | null {
  const ratio = keeper.context_ratio ?? keeper.context?.context_ratio
  if (typeof ratio !== 'number' || !Number.isFinite(ratio)) return null
  return Math.max(0, Math.min(1, ratio))
}

function contextPercent(keeper: Keeper): number | null {
  const ratio = contextRatio(keeper)
  if (ratio === null) return null
  return Math.max(0, Math.min(100, Math.round(ratio * 100)))
}

function contextMax(keeper: Keeper): number | null {
  return keeper.context_max ?? keeper.context?.context_max ?? null
}

function formatK(n: number | null | undefined): string | null {
  if (typeof n !== 'number') return null
  return n >= 1000 ? `${(n / 1000).toFixed(1)}k` : `${n}`
}

/** Newest-last per-turn throughput series for the rail sparkline. */
function tpsSeries(keeper: Keeper): number[] {
  return (keeper.metrics_series ?? [])
    .map(p => (typeof p.wall_tokens_per_second === 'number' ? Math.max(0, p.wall_tokens_per_second) : 0))
    .slice(-24)
}

function ownedTasks(keeper: Keeper): Task[] {
  return tasks.value.filter(t => t.assignee === keeper.name || (keeper.agent_name != null && t.assignee === keeper.agent_name))
}

function taskStateClass(status: Task['status']): string {
  if (status === 'awaiting_verification') return 'review'
  return ''
}

function nonEmpty(value: string | null | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}

function attentionFallback(keeper: Keeper): string | null {
  if (keeper.needs_attention !== true) return null
  const summary = nonEmpty(keeper.runtime_blocker_summary)
  if (summary) return summary
  const reason = nonEmpty(keeper.attention_reason)
  const action = nonEmpty(keeper.next_human_action)
  if (reason && action) return `${reason} · ${action}`
  if (reason) return `주의 원인: ${reason}`
  if (action) return `다음 조치: ${action}`
  return 'runtime_attention.needs_attention=true · 원인/조치 미수신'
}

type AttentionItem = { sev: 'bad' | 'warn'; text: string }

/** Attention items from the same live signals the roster badge counts
 *  (blocked tasks + explicit flag). No fabricated severities — the section
 *  is omitted entirely when there is nothing to surface. */
function attentionItems(keeper: Keeper): AttentionItem[] {
  const items: AttentionItem[] = []
  const blocked = keeper.blocked_task_count ?? 0
  if (blocked > 0) items.push({ sev: 'bad', text: `차단된 태스크 ${blocked}건` })
  const awaiting = ownedTasks(keeper).filter(t => t.status === 'awaiting_verification')
  if (awaiting.length > 0) items.push({ sev: 'warn', text: `검증 대기 ${awaiting.length}건` })
  const fallback = items.length === 0 ? attentionFallback(keeper) : null
  if (fallback) items.push({ sev: 'warn', text: fallback })
  return items
}

function AttentionSection({ keeper }: { keeper: Keeper }): VNode | null {
  const items = attentionItems(keeper)
  if (items.length === 0) return null
  return html`
    <div class="kw-sec v2-monitoring-panel">
      <h4>주의 <span class="kw-kp-att">${items.length}</span></h4>
      <div class="kw-att-list v2-monitoring-row">
        ${items.map((it, i) => html`
          <div class=${`kw-att-item ${it.sev} v2-monitoring-row`} key=${`${it.text}-${i}`}>
            <span class="kw-att-dot" aria-hidden="true"></span>
            <span class="kw-att-text" title=${it.text}>${it.text}</span>
          </div>
        `)}
      </div>
    </div>
  `
}

function formatAgo(seconds: number | null | undefined): string | null {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds < 0) return null
  return `${formatDuration(seconds)} 전`
}

function ContextSection({ keeper }: { keeper: Keeper }): VNode {
  const pct = contextPercent(keeper)
  const hot = pct !== null && pct >= COMPACT_AT
  const max = contextMax(keeper)
  const baseTokens = keeper.context_tokens ?? keeper.context?.context_tokens ?? null
  const tokens = formatK(baseTokens)
  const maxLabel = formatK(max)
  const msgCount = keeper.context?.message_count ?? null
  const hasCheckpoint = keeper.context?.has_checkpoint ?? null
  const contextSource = nonEmpty(keeper.context_source ?? keeper.context?.source)
  const compactionCount = keeper.compaction_count ?? null
  const hasCompactionHistory = typeof compactionCount === 'number' && compactionCount > 0
  const lastCompactionAgo = hasCompactionHistory ? formatAgo(keeper.last_compaction_ago_s) : null
  const lastCompactionSaved = hasCompactionHistory ? formatK(keeper.last_compaction_saved_tokens) : null
  const hasUsageBreakdown = baseTokens !== null || max !== null || msgCount !== null || hasCheckpoint !== null || contextSource != null
  const hasMeterData = pct !== null && (pct > 0 || max !== null)
  const contextMeta = html`
    <div class="kw-ctx-meta">
      ${msgCount !== null ? html`<span>메시지 ${msgCount}개</span>` : null}
      ${hasCheckpoint === true ? html`<span>체크포인트 보유</span>` : null}
      ${contextSource ? html`<span>출처 ${contextSource}</span>` : null}
    </div>
  `
  let usageBody: VNode
  if (hasMeterData) {
    usageBody = html`
      <div class="flex items-baseline justify-between">
        <span class="text-xs text-[var(--color-fg-secondary)]">윈도우 사용량</span>
        <span class=${`font-mono text-sm ${hot ? 'text-[var(--color-status-err)]' : 'text-[var(--color-accent-fg)]'}`}>${pct ?? 0}%</span>
      </div>
      <div class="kw-meter-wrap">
        <div class=${`kw-meter${hot ? ' hot' : ''}`}><span style=${{ width: `${pct ?? 0}%` }}></span></div>
        <span class="kw-meter-mark" style=${{ left: `${COMPACT_AT}%` }} title=${`자동 compact 임계치 ${COMPACT_AT}%`}>
          <i class="kw-meter-mark-lbl">compact ${COMPACT_AT}%</i>
        </span>
      </div>
      ${tokens || maxLabel
        ? html`<div class="kw-ctx-tok">
            <span class="mono">${tokens ?? '—'}</span>
            <span aria-hidden="true">/</span>
            <span class="mono">${maxLabel ?? '—'}</span>
            <span class="lbl">사용 / 전체 윈도우</span>
          </div>`
        : null}
      ${contextMeta}
    `
  } else if (hasUsageBreakdown) {
    usageBody = html`
      <div class="kw-context-empty">
        <strong>윈도우 사용률 미수신</strong>
        <span>전체 윈도우 총량이 없어 비율과 compact 임계치를 숨깁니다.</span>
      </div>
      ${tokens || maxLabel
        ? html`<div class="kw-ctx-tok">
            <span class="mono">${tokens ?? '—'}</span>
            <span aria-hidden="true">/</span>
            <span class="mono">${maxLabel ?? '—'}</span>
            <span class="lbl">사용 / 전체 윈도우</span>
          </div>`
        : null}
      ${contextMeta}
    `
  } else {
    usageBody = html`
      <div class="kw-context-empty">
        <strong>컨텍스트 사용량 미수신</strong>
        <span>런타임이 토큰/윈도우 메트릭을 아직 보내지 않았습니다.</span>
      </div>
    `
  }

  return html`
    <div class="kw-sec v2-monitoring-panel">
      <h4>컨텍스트 점유</h4>
      <div class="kw-card v2-monitoring-card">
        ${usageBody}
        <div class="kw-cmp-readonly">
          ${hasCompactionHistory
            ? html`
                <span>누적 컴팩트 ${compactionCount}회</span>
                ${lastCompactionAgo ? html`<span>마지막 ${lastCompactionAgo}</span>` : null}
                ${lastCompactionSaved ? html`<span>절약 ${lastCompactionSaved} tok</span>` : null}
              `
            : html`<span>컴팩트 기록 없음</span>`}
        </div>
      </div>
    </div>
  `
}

function ThroughputSection({ keeper }: { keeper: Keeper }): VNode {
  const model = keeperModelLabel(keeper)
  const runtime = keeperRuntimeLabel(keeper)
  // scope (skill_primary) used to live in the chat header sub-row; folded here
  // so the slim single-row header loses no information.
  const scope = keeper.skill_primary ?? null
  const series = tpsSeries(keeper)
  const peak = Math.max(1, ...series)
  const latest = series.length ? series[series.length - 1] : 0
  return html`
    <div class="kw-sec v2-monitoring-panel">
      <h4>런타임 · 처리량</h4>
      <div class=${`kw-vitals ${model ? '' : 'single'} v2-monitoring-row`}>
        <div class=${`kw-vital ${runtime ? '' : 'muted'}`}><div class="vk">런타임</div><div class="vv" title=${runtime ?? ''}>${runtime ?? '런타임 미수신'}</div></div>
        ${model ? html`<div class="kw-vital"><div class="vk">모델</div><div class="vv" title=${model}>${model}</div></div>` : null}
        ${scope ? html`<div class="kw-vital" style=${{ gridColumn: '1 / -1' }}><div class="vk">scope</div><div class="vv" title=${scope}>${scope}</div></div>` : null}
      </div>
      ${series.length >= 2
        ? html`<div class="kw-card mt-2 v2-monitoring-card">
            <div class="flex items-baseline justify-between">
              <span class="font-mono text-base text-[var(--color-status-ok)]">${latest}</span>
              <span class="text-2xs text-[var(--color-fg-muted)]">tok/s</span>
            </div>
            <div class="mt-2 flex h-7 items-end gap-0.5" aria-hidden="true">
              ${series.map(v => html`<span class="flex-1 rounded-[1px] bg-[var(--color-status-ok)]" style=${{ height: `${Math.max(6, (v / peak) * 100)}%`, opacity: 0.35 + 0.65 * (v / peak) }}></span>`)}
            </div>
          </div>`
        : null}
    </div>
  `
}

function OwnedTasksSection({ keeper }: { keeper: Keeper }): VNode {
  const owned = ownedTasks(keeper)
  const openTask = (task: Task) => {
    navigate('workspace', { section: 'planning', task: task.id })
  }
  return html`
    <div class="kw-sec v2-monitoring-panel">
      <h4>소유 태스크</h4>
      <div class="kw-list v2-monitoring-row">
        ${owned.length
          ? owned.map(t => html`
              <button
                type="button"
                class="kw-tasktag v2-monitoring-row"
                key=${t.id}
                title=${`${t.id} · ${t.title}`}
                aria-label=${`태스크 열기: ${t.id} ${t.title}`}
                onClick=${() => openTask(t)}
              >
                <span class="tid">${t.id}</span>
                <span class="ttl">${t.title}</span>
                ${t.status ? html`<span class=${`tstate ${taskStateClass(t.status)}`}>${t.status}</span>` : null}
              </button>
            `)
          : html`<div class="kw-list-empty v2-monitoring-row">할당된 태스크 없음</div>`}
      </div>
    </div>
  `
}

export function KeeperWorkspaceRail({
  keeper,
  onToggleDetail,
}: {
  keeper: Keeper
  onToggleDetail: () => void
}): VNode {
  return html`
    <aside class="kw-rail v2-monitoring-surface" aria-label="키퍼 컨텍스트">
      <div class="kw-rail-scroll v2-monitoring-panel">
        <${AttentionSection} keeper=${keeper} />
        <${ThroughputSection} keeper=${keeper} />
        <${ContextSection} keeper=${keeper} />
        <${OwnedTasksSection} keeper=${keeper} />
        <${KeeperWorkspaceRecentTools} keeperName=${keeper.name} />
        <div class="kw-sec v2-monitoring-toolbar">
          <button type="button" class="kw-detail-btn v2-monitoring-action" onClick=${onToggleDetail}>
            <span>운영 상세</span>
            <span class="sub">FSM · 진단 · 정체성 · 설정 →</span>
          </button>
        </div>
      </div>
    </aside>
  `
}
