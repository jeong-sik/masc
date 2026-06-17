// Keeper Workspace — context rail (right). Runtime/throughput, context-window
// occupancy, owned tasks, recent tool calls, and the "상세 보기" toggle that
// surfaces the full KeeperDetailBody. Most data comes from the live Keeper
// object + the tasks store; the recent-tool-calls section lazy-loads the rich
// per-call store (see keeper-workspace-tool-calls.ts).

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useCallback, useEffect, useState } from 'preact/hooks'
import { tasks } from '../../store'
import type { Keeper, Task } from '../../types'
import { keeperModelLabel, keeperRuntimeLabel } from './keeper-workspace-shared'
import { KeeperWorkspaceRecentTools } from './keeper-workspace-tool-calls'
import { callMcpTool } from '../../api/mcp'
import { showToast } from '../common/toast'
import { asNumber, asString, isRecord } from '../common/normalize'
import { formatDuration } from '../../lib/format-time'

const COMPACT_AT = 85 // auto-compaction threshold (%) — matches runtime default

function contextPercent(keeper: Keeper): number {
  const ratio = keeper.context_ratio ?? keeper.context?.context_ratio ?? 0
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
  if (items.length === 0 && keeper.needs_attention === true) {
    items.push({ sev: 'warn', text: '점검이 필요합니다' })
  }
  return items
}

function AttentionSection({ keeper }: { keeper: Keeper }): VNode | null {
  const items = attentionItems(keeper)
  if (items.length === 0) return null
  return html`
    <div class="ss-card bg-card rounded-2xl shadow-card kw-sec v2-monitoring-panel">
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

type CompactionSnapshot = {
  id: string
  at: string
  trigger: string
  phase: string | null
  beforeTokens: number
  afterTokens: number
  savedTokens: number
}

function nowHM(): string {
  return new Date().toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false })
}

function formatAgo(seconds: number | null | undefined): string | null {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds < 0) return null
  return `${formatDuration(seconds)} 전`
}

type CompactButtonState = 'idle' | 'busy' | 'done'

function CompactButton({ state, onClick }: { state: CompactButtonState; onClick: () => void }): VNode {
  const label = state === 'idle' ? '지금 컴팩트' : state === 'busy' ? '압축 중…' : '완료'
  const icon = state === 'done' ? '✓ ' : ''
  return html`
    <button type="button" class=${`kw-compact-btn ${state}`} disabled=${state === 'busy'} onClick=${onClick}>
      ${icon}${label}
    </button>
  `
}

function SnapshotList({ snapshots }: { snapshots: CompactionSnapshot[] }): VNode | null {
  if (snapshots.length === 0) return null
  return html`
    <div class="kw-cmp-list">
      <h5>컴팩션 스냅샷</h5>
      ${snapshots.map(s => {
        const reduction = s.beforeTokens > 0
          ? Math.round((1 - s.afterTokens / s.beforeTokens) * 100)
          : 0
        return html`
          <div class="kw-cmp-snap" key=${s.id}>
            <div class="kw-cmp-snap-h">
              <span class="kw-cmp-snap-id">${s.at}</span>
              ${s.phase ? html`<span class="kw-cmp-snap-phase">${s.phase}</span>` : null}
              <span class="kw-cmp-snap-reduction">-${reduction}%</span>
            </div>
            <div class="kw-cmp-snap-stats">
              <span>${formatK(s.beforeTokens) ?? '—'} → ${formatK(s.afterTokens) ?? '—'} tok</span>
              <span>절약 ${formatK(s.savedTokens) ?? '—'} tok</span>
            </div>
            <div class="kw-cmp-snap-trigger text-2xs text-[var(--color-fg-muted)]">${s.trigger}</div>
          </div>
        `
      })}
    </div>
  `
}

function ContextSection({ keeper }: { keeper: Keeper }): VNode {
  const [snapshots, setSnapshots] = useState<CompactionSnapshot[]>([])
  const [compactState, setCompactState] = useState<CompactButtonState>('idle')

  useEffect(() => {
    setSnapshots([])
    setCompactState('idle')
  }, [keeper.name])

  const pct = contextPercent(keeper)
  const hot = pct >= COMPACT_AT
  const max = contextMax(keeper)
  const baseTokens = keeper.context_tokens ?? keeper.context?.context_tokens ?? null
  const tokens = formatK(baseTokens)
  const maxLabel = formatK(max)
  const msgCount = keeper.context?.message_count ?? null
  const hasCheckpoint = keeper.context?.has_checkpoint ?? null
  const contextSource = keeper.context_source ?? keeper.context?.source ?? null
  const compactionCount = keeper.compaction_count ?? null
  const lastCompactionAgo = formatAgo(keeper.last_compaction_ago_s)
  const lastCompactionSaved = formatK(keeper.last_compaction_saved_tokens)

  const runCompact = useCallback(async () => {
    if (compactState === 'busy') return
    setCompactState('busy')
    try {
      const text = await callMcpTool('masc_keeper_compact', { name: keeper.name })
      let parsed: unknown = null
      try {
        parsed = JSON.parse(text)
      } catch {
        parsed = null
      }
      const record = isRecord(parsed) ? parsed : null
      const beforeTokens = asNumber(record?.before_tokens) ?? 0
      const afterTokens = asNumber(record?.after_tokens) ?? 0
      const savedTokens = asNumber(record?.saved_tokens) ?? Math.max(0, beforeTokens - afterTokens)
      const snapshot: CompactionSnapshot = {
        id: `cmp-${Date.now()}`,
        at: nowHM(),
        trigger: asString(record?.trigger) ?? '수동 컴팩트',
        phase: asString(record?.phase) ?? null,
        beforeTokens,
        afterTokens,
        savedTokens,
      }
      setSnapshots(prev => [snapshot, ...prev])
      setCompactState('done')
      window.setTimeout(() => setCompactState('idle'), 2600)
    } catch (err) {
      const message = err instanceof Error ? err.message : '컴팩트 요청 실패'
      showToast(message, 'error')
      setCompactState('idle')
    }
  }, [compactState, keeper.name])

  return html`
    <div class="ss-card bg-card rounded-2xl shadow-card kw-sec v2-monitoring-panel">
      <h4>컨텍스트 점유</h4>
      <div class="kw-card v2-monitoring-card">
        <div class="flex items-baseline justify-between">
          <span class="text-xs text-[var(--color-fg-secondary)]">윈도우 사용량</span>
          <span class=${`font-mono text-sm ${hot ? 'text-[var(--color-status-err)]' : 'text-[var(--color-accent-fg)]'}`}>${pct}%</span>
        </div>
        <div class="kw-meter-wrap">
          <div class=${`kw-meter${hot ? ' hot' : ''}`}><span style=${{ width: `${pct}%` }}></span></div>
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
        <div class="mt-2 grid grid-cols-2 gap-2 text-2xs text-[var(--color-fg-secondary)]">
          ${msgCount !== null ? html`<span>메시지 ${msgCount}개</span>` : null}
          ${hasCheckpoint === true ? html`<span>체크포인트 보유</span>` : null}
          ${contextSource ? html`<span>출처 ${contextSource}</span>` : null}
          ${compactionCount !== null ? html`<span>누적 컴팩트 ${compactionCount}회</span>` : null}
          ${lastCompactionAgo ? html`<span>마지막 컴팩트 ${lastCompactionAgo}</span>` : null}
          ${lastCompactionSaved ? html`<span>절약 ${lastCompactionSaved} tok</span>` : null}
        </div>
        <div class="kw-cmp-actions">
          <${CompactButton} state=${compactState} onClick=${() => { void runCompact() }} />
        </div>
        <${SnapshotList} snapshots=${snapshots} />
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
    <div class="ss-card bg-card rounded-2xl shadow-card kw-sec v2-monitoring-panel">
      <h4>런타임 · 처리량</h4>
      <div class="kw-vitals v2-monitoring-row">
        <div class="kw-vital"><div class="vk">모델</div><div class="vv" title=${model ?? ''}>${model ?? '—'}</div></div>
        <div class="kw-vital"><div class="vk">런타임</div><div class="vv" title=${runtime ?? ''}>${runtime ?? '—'}</div></div>
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
  return html`
    <div class="ss-card bg-card rounded-2xl shadow-card kw-sec v2-monitoring-panel">
      <h4>소유 태스크</h4>
      <div class="kw-list v2-monitoring-row">
        ${owned.length
          ? owned.map(t => html`
              <div class="kw-tasktag v2-monitoring-row" key=${t.id}>
                <span class="tid">${t.id}</span>
                <span class="ttl" title=${t.title}>${t.title}</span>
                ${t.status ? html`<span class=${`tstate ${taskStateClass(t.status)}`}>${t.status}</span>` : null}
              </div>
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
    <aside class="ss-surface bg-surface-page styleseed-scope kw-rail v2-monitoring-surface" aria-label="키퍼 컨텍스트">
      <div class="kw-rail-scroll v2-monitoring-panel">
        <${AttentionSection} keeper=${keeper} />
        <${ThroughputSection} keeper=${keeper} />
        <${ContextSection} keeper=${keeper} />
        <${OwnedTasksSection} keeper=${keeper} />
        <${KeeperWorkspaceRecentTools} keeperName=${keeper.name} />
        <div class="kw-sec v2-monitoring-toolbar">
          <button type="button" class="kw-detail-btn v2-monitoring-action" onClick=${onToggleDetail}>
            <span>상세 보기</span>
            <span class="sub">상태 · 진단 · 정체성 · 설정 →</span>
          </button>
        </div>
      </div>
    </aside>
  `
}
