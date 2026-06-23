// Keeper Workspace — context rail (right). Ported to the keeper-v2 prototype DOM
// (rails.jsx ContextRail): `.ctx` → `.ctx-scroll` → `.ctx-sec` sections (주의 /
// 런타임 `.rtc-card` / 처리량 `.tps-card` / 컨텍스트 `.ctx-card` / 소유 태스크
// `.ctx-list`), styled by the vendored SSOT CSS. Live wiring (Keeper object +
// tasks store + masc_keeper_compact) is unchanged; only the DOM/classes changed.
// Data gaps (runtime capability flags, effort segments, compaction/memory
// inspectors) are MARKED, never faked.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type { VNode } from 'preact'
import { shellAuthSummary, tasks } from '../../store'
import type { Keeper, Task } from '../../types'
import { navigate } from '../../router'
import { keeperModelLabel, keeperRuntimeLabel } from './keeper-workspace-shared'
import { CountBadge } from '../v2/primitives-v2'
import { callMcpTool } from '../../api/mcp'
import { showToast } from '../common/toast'
import { requestConfirm } from '../common/confirm-dialog'
import { dashboardAuthAccess } from '../../lib/dashboard-auth-access'
import { errorToString } from '../../lib/format-string'
import { refreshAfterRuntimeAction } from '../keeper-detail-helpers'
import { contextThresholds } from '../../config/context-thresholds'

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
  const max = keeper.context_max ?? keeper.context?.context_max ?? null
  if (typeof max !== 'number' || !Number.isFinite(max) || max <= 0) return null
  return max
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
    <div class="ctx-sec">
      <h4 style=${{ display: 'flex', alignItems: 'center', gap: '7px' }}>주의 <${CountBadge}>${items.length}</${CountBadge}></h4>
      <div class="att-list">
        ${items.map((it, i) => html`
          <div class=${`att-item ${it.sev}`} key=${`${it.text}-${i}`}>
            <span class="att-dot" aria-hidden="true"></span>
            <span class="att-text" title=${it.text}>${it.text}</span>
          </div>
        `)}
      </div>
    </div>
  `
}

function RuntimeSection({ keeper }: { keeper: Keeper }): VNode {
  const model = keeperModelLabel(keeper)
  const runtime = keeperRuntimeLabel(keeper)
  const max = contextMax(keeper)
  const ctxK = max ? formatK(max) : null
  return html`
    <div class="ctx-sec">
      <h4>런타임</h4>
      <div class="rtc-card">
        <div class="rtc-id mono">${runtime ?? '런타임 미수신'}</div>
        ${model
          ? html`<div class="rtc-model mono">${model}${ctxK ? ` · ${ctxK} ctx` : ''}</div>`
          : null}
        ${/* Live execution snapshot carries no capability flags / effort segments
             (multimodal/json/tool-choice, low/medium/high). Marked, not faked. */ ''}
        <div class="rtc-na" data-stub="runtime-capabilities">능력·effort 정보 미수신</div>
      </div>
    </div>
  `
}

function ThroughputSection({ keeper }: { keeper: Keeper }): VNode {
  const series = tpsSeries(keeper)
  const peak = Math.max(1, ...series)
  const latest = series.at(-1) ?? 0
  const live = keeper.status.toLowerCase() === 'running' || keeper.status.toLowerCase() === 'active'
  // Prototype hides the throughput card by default behind a collapsible header
  // with an inline summary (keeper-v2/rails.jsx:422,477-482). .ctx-h-toggle /
  // .ctx-h-caret carry no CSS in any stylesheet — they are inline-styled in the
  // prototype, so they are inline-styled here too.
  const [tpsOpen, setTpsOpen] = useState(false)
  return html`
    <div class="ctx-sec">
      <h4
        class="ctx-h-toggle"
        onClick=${() => setTpsOpen((v) => !v)}
        style=${{ cursor: 'pointer', display: 'flex', alignItems: 'center', gap: '6px' }}
      >
        <span class="ctx-h-caret" style=${{ fontSize: '9px', color: 'var(--text-dim)' }}>${tpsOpen ? '▾' : '▸'}</span>
        처리량
        ${!tpsOpen
          ? html`<span class="mono" style=${{ marginLeft: 'auto', fontSize: '11px', color: 'var(--text-dim)' }}>${live && latest > 0 ? `${latest} tok/s` : '유휴'}</span>`
          : null}
      </h4>
      ${tpsOpen
        ? html`<div class="tps-card">
            <div class="tps-now">
              <span class=${`tps-val${latest > 0 ? '' : ' idle'}`}>${latest > 0 ? latest : '—'}</span>
              <span class="tps-unit">tok/s</span>
              ${live && latest > 0 ? html`<span class="tps-flag"><span class="tps-dot"></span>live</span>` : null}
            </div>
            ${series.length >= 2
              ? html`<div class="tps-spark" aria-hidden="true">
                  ${series.map((v) => html`<span style=${{ height: `${Math.max(6, (v / peak) * 100)}%`, opacity: 0.35 + 0.65 * (v / peak) }}></span>`)}
                </div>`
              : null}
          </div>`
        : null}
    </div>
  `
}

function compactionGatePct(keeper: Keeper): number {
  const raw = keeper.compaction_ratio_gate
  const ratio = typeof raw === 'number' && Number.isFinite(raw) && raw > 0
    ? raw
    : contextThresholds.value.compacting
  return Math.max(1, Math.min(99, Math.round(ratio * 100)))
}

function compactRequiresForce(keeper: Keeper): boolean {
  const phase = (keeper.phase ?? keeper.lifecycle_phase ?? '').toLowerCase()
  if (phase === 'overflowed' || phase === 'paused' || phase === 'compacting') return false
  if (phase === 'running' || phase === 'failing') return true
  const status = keeper.status.toLowerCase()
  return status === 'running' || status === 'active' || status === 'busy' || status === 'failing'
}

function ContextSection({ keeper, onToggleDetail }: { keeper: Keeper; onToggleDetail: () => void }): VNode {
  const [compacting, setCompacting] = useState(false)
  const pct = contextPercent(keeper)
  const compactAt = compactionGatePct(keeper)
  const hot = pct !== null && pct >= compactAt
  const max = contextMax(keeper)
  const baseTokens = keeper.context_tokens ?? keeper.context?.context_tokens ?? null
  const tokens = formatK(baseTokens)
  const maxLabel = formatK(max)
  const compactionCount = keeper.compaction_count ?? null
  const hasCompactionHistory = typeof compactionCount === 'number' && compactionCount > 0
  const hasMeterData = pct !== null && (pct > 0 || max !== null)
  const compactAccess = dashboardAuthAccess(shellAuthSummary.value, 'worker')
  const canCompact = compactAccess.allowed && !compacting
  const compactReason = compactAccess.reason ?? '컴팩션 실행 권한이 필요합니다.'
  const runCompact = () => {
    if (!compactAccess.allowed) {
      showToast(compactReason, 'error', 6000)
      return
    }
    void (async () => {
      const force = compactRequiresForce(keeper)
      if (force) {
        const confirmed = await requestConfirm({
          title: 'Force keeper compact',
          message: `${keeper.name} is not in an explicit overflow/paused compaction phase. Run masc_keeper_compact with force=true?`,
          confirmText: 'Force compact',
          tone: 'warning',
        })
        if (!confirmed) return
      }
      setCompacting(true)
      try {
        const raw = await callMcpTool('masc_keeper_compact', { name: keeper.name, force })
        const parsed = JSON.parse(raw) as { before_tokens?: number; after_tokens?: number; phase_after?: string }
        const before = formatK(parsed.before_tokens)
        const after = formatK(parsed.after_tokens)
        showToast(
          before && after ? `${keeper.name} compact 완료: ${before} -> ${after}` : `${keeper.name} compact 완료`,
          'success',
        )
        await refreshAfterRuntimeAction()
      } catch (err) {
        showToast(`compact 실패: ${errorToString(err)}`, 'error', 8000)
      } finally {
        setCompacting(false)
      }
    })()
  }

  const usageHeader = html`
    <div style=${{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
      <span style=${{ fontSize: '12px', color: 'var(--text-mid)' }}>윈도우 사용량</span>
      <span class="mono" style=${{ fontSize: '14px', color: hot ? 'var(--status-bad)' : 'var(--volt-strong)' }}>${pct ?? 0}%</span>
    </div>
  `

  return html`
    <div class="ctx-sec">
      <h4>컨텍스트</h4>
      <div class="ctx-card">
        ${hasMeterData
          ? html`
              ${usageHeader}
              <div class="meter-wrap">
                <div class=${`meter${hot ? ' hot' : ''}`}><span style=${{ width: `${pct ?? 0}%` }}></span></div>
                <span class=${`meter-mark${hot ? ' hot' : ''}`} style=${{ left: `${compactAt}%` }}>
                  <i class="meter-mark-lbl">compact ${compactAt}%</i>
                </span>
              </div>
            `
          : html`<div class="ctx-empty" data-stub="context-window"><strong>윈도우 사용률 미수신</strong><span>런타임이 전체 윈도우 총량을 아직 보내지 않았습니다. ratio_gate ${compactAt}%.</span></div>`}
        <div class="ctx-tok">
          <span class="mono">${tokens ?? '—'}</span>
          <span class="ctx-tok-sep">/</span>
          <span class="mono ctx-tok-full">${maxLabel ?? '—'}</span>
          <span class="ctx-tok-lbl">사용 / 전체 윈도우</span>
        </div>
        <div class="cmp-actions">
          <button
            type="button"
            class=${`cmp-run${compacting ? ' busy' : ''}`}
            disabled=${!canCompact}
            title=${compactAccess.allowed ? 'masc_keeper_compact 실행' : compactReason}
            onClick=${runCompact}
          >${compacting ? html`<span class="cmp-spin"></span> 컴팩트 실행 중…` : '◉ 지금 컴팩트'}</button>
        </div>
        ${/* The prototype opens dedicated compaction-snapshot / memory inspectors;
             those live overlays do not exist yet, so both route to the operational
             detail body (FSM · 진단 · 정체성 · memory). Marked as a deferred wiring. */ ''}
        <button type="button" class="cmp-open" data-stub="compaction-inspector" onClick=${onToggleDetail}>
          ◉ 컴팩션 스냅샷${hasCompactionHistory ? ` · ${compactionCount}` : ''} <span class="cmp-open-sub">운영 상세에서 보기</span>
        </button>
        <button type="button" class="cmp-open" data-stub="memory-inspector" onClick=${onToggleDetail}>
          ◈ 메모리 보기 <span class="cmp-open-sub">FSM · 진단 · 정체성</span>
        </button>
      </div>
    </div>
  `
}

function OwnedTasksSection({ keeper }: { keeper: Keeper }): VNode {
  const owned = ownedTasks(keeper)
  const openTask = (task: Task) => {
    navigate('workspace', { section: 'planning', task: task.id })
  }
  return html`
    <div class="ctx-sec">
      <h4>소유 태스크</h4>
      <div class="ctx-list">
        ${owned.length
          ? owned.map(t => html`
              <button
                type="button"
                class="tasktag"
                key=${t.id}
                title=${`작업으로 이동 · ${t.id} · ${t.title}`}
                aria-label=${`태스크 열기: ${t.id} ${t.title}`}
                onClick=${() => openTask(t)}
              >
                <div class="tasktag-top">
                  <span class="tid">${t.id}</span>
                  ${t.status ? html`<span class=${`tasktag-state ${taskStateClass(t.status)}`}>${t.status}</span>` : null}
                </div>
                <span class="ttl">${t.title}</span>
              </button>
            `)
          : html`<div style=${{ fontSize: '12px', color: 'var(--text-dim)' }}>할당된 태스크 없음</div>`}
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
    <aside class="ctx" aria-label="키퍼 컨텍스트">
      <div class="ctx-scroll">
        <${AttentionSection} keeper=${keeper} />
        <${ThroughputSection} keeper=${keeper} />
        <${RuntimeSection} keeper=${keeper} />
        <${ContextSection} keeper=${keeper} onToggleDetail=${onToggleDetail} />
        <${OwnedTasksSection} keeper=${keeper} />
      </div>
    </aside>
  `
}
