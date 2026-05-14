import { html } from 'htm/preact'
import { formatPct1, formatTokens } from '../lib/format-number'
import { Eyebrow } from './common/eyebrow'
import { StatTile } from './common/stat-tile'
import type { Keeper, KeeperMetricPoint } from '../types'
import {
  formatDuration,
  CTX_CRITICAL_PCT,
  CTX_WARN_PCT,
} from './keeper-detail-ctx-utils'
import { OutcomesLedger } from './keeper-detail-outcomes'

export function MutedSpan({ children }: { children: unknown }) {
  return html`<span class="text-3xs text-[var(--color-fg-disabled)]">${children}</span>`
}

export function DetailRow({ children }: { children: unknown }) {
  return html`<div class="flex items-center justify-between mb-1.5">${children}</div>`
}

// ── KPI Card ─────────────────────────────────────────────

type KpiTone = 'default' | 'ok' | 'warn' | 'bad'

function kpiToneToStatus(tone: KpiTone): 'ok' | 'warn' | 'crit' | undefined {
  if (tone === 'default') return undefined
  if (tone === 'bad') return 'crit'
  return tone
}

// KpiTone + KPI_TONE/KPI_VALUE_TONE retained: used by inline heartbeat/compression/drop elements.

const KPI_TONE: Record<KpiTone, string> = {
  default: 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)]',
  ok: 'border-[var(--ok-20)] bg-[var(--ok-6)]',
  warn: 'border-[var(--warn-20)] bg-[var(--warn-8)]',
  bad: 'border-[var(--bad-20)] bg-[var(--bad-6)]',
}

const KPI_VALUE_TONE: Record<KpiTone, string> = {
  default: 'text-[var(--color-fg-secondary)]',
  ok: 'text-[var(--color-status-ok)]',
  warn: 'text-[var(--color-status-warn)]',
  bad: 'text-[var(--color-status-err)]',
}

// ── Detail Card (shared container) ───────────────────────

export function DetailCard({ class: cx, children }: {
  class?: string
  children: unknown
}) {
  return html`
    <div class="p-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] ${cx ?? ''}">${children}</div>
  `
}

// ── Operational Health ───────────────────────────────────

export function OperationalHealth({ keeper }: { keeper: Keeper }) {
  const mw = keeper.metrics_window
  const hb = keeper.last_heartbeat
  const compSavedRatio = mw?.compaction_saved_ratio
  const avgSaved = mw?.avg_compaction_saved_tokens
  const dropRatio = mw?.memory_compaction_drop_ratio
  const lastCompAgo = keeper.last_compaction_ago_s

  const hbTone: KpiTone = !hb ? 'default' : 'ok'
  const compTone: KpiTone = compSavedRatio == null ? 'default'
    : compSavedRatio >= 0.4 ? 'ok' : compSavedRatio >= 0.2 ? 'warn' : 'bad'
  const dropTone: KpiTone = dropRatio == null ? 'default'
    : dropRatio <= 0.1 ? 'ok' : dropRatio <= 0.3 ? 'warn' : 'bad'

  const hasAny = hb || compSavedRatio != null || dropRatio != null || lastCompAgo != null
  if (!hasAny) return null

  return html`
    <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
      <div class="mb-2 text-3xs font-semibold tracking-[var(--track-caps)] uppercase text-[var(--color-fg-muted)]">운영 건강도</div>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
        ${hb ? html`
          <div class="p-2 rounded-[var(--r-1)] border ${KPI_TONE[hbTone]} flex flex-col gap-0.5">
            <${Eyebrow}>하트비트</${Eyebrow}>
            <span class="text-xs font-mono ${KPI_VALUE_TONE[hbTone]}">${hb.replace('T', ' ').slice(0, 19)}</span>
          </div>
        ` : null}
        ${compSavedRatio != null ? html`
          <div class="p-2 rounded-[var(--r-1)] border ${KPI_TONE[compTone]} flex flex-col gap-0.5">
            <${Eyebrow}>압축 절감률</${Eyebrow}>
            <span class="text-sm font-mono tabular-nums ${KPI_VALUE_TONE[compTone]}">${formatPct1(compSavedRatio)}</span>
            ${avgSaved != null ? html`<${MutedSpan}>avg ${formatTokens(avgSaved)} saved</${MutedSpan}>` : null}
          </div>
        ` : null}
        ${dropRatio != null ? html`
          <div class="p-2 rounded-[var(--r-1)] border ${KPI_TONE[dropTone]} flex flex-col gap-0.5">
            <${Eyebrow}>메모리 손실률</${Eyebrow}>
            <span class="text-sm font-mono tabular-nums ${KPI_VALUE_TONE[dropTone]}">${formatPct1(dropRatio)}</span>
          </div>
        ` : null}
        ${lastCompAgo != null ? html`
          <div class="p-2 rounded-[var(--r-1)] border ${KPI_TONE['default']} flex flex-col gap-0.5">
            <${Eyebrow}>마지막 압축</${Eyebrow}>
            <span class="text-xs font-mono text-[var(--color-fg-secondary)]">${formatDuration(lastCompAgo)} 전</span>
          </div>
        ` : null}
      </div>
    </div>
  `
}

// ── KPI Grid ─────────────────────────────────────────────
// 4-section layout mirrors the keeper's 3-layer state model
// (Events -> Phase+Conditions -> Counters): identity / memory / autonomy / outcomes.

export function KpiSection({ title, children }: {
  title: string
  children: unknown
}) {
  return html`
    <section class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3" aria-label=${title}>
      <header class="mb-2">
        <h3 class="text-2xs font-semibold tracking-[var(--track-caps)] uppercase text-[var(--color-fg-muted)]">${title}</h3>
      </header>
      ${children}
    </section>
  `
}

export function KpiGrid({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  const lastPt = series[series.length - 1] as KeeperMetricPoint | undefined
  const latestCost =
    lastPt && Number.isFinite(lastPt.cost_usd)
      ? `$${lastPt.cost_usd.toFixed(4)}`
      : null

  const ctxPct = keeper.context_ratio != null ? Math.round(keeper.context_ratio * 100) : null
  const ctxTone: KpiTone = ctxPct == null ? 'default' : ctxPct > CTX_CRITICAL_PCT ? 'bad' : ctxPct > CTX_WARN_PCT ? 'warn' : ctxPct > 0 ? 'ok' : 'default'
  const ctxHint = ctxPct != null && ctxPct > CTX_WARN_PCT ? '한계 접근 중' : undefined

  const outcomes = keeper.outcomes

  return html`
    <div class="flex flex-col gap-3 mb-5">
      <${KpiSection} title="정체성">
        <div class="grid grid-cols-3 gap-2">
          <${StatTile}
            label="세대"
            value=${String(keeper.generation ?? '-')}
          />
          <${StatTile}
            label="턴"
            value=${String(keeper.turn_count ?? '-')}
          />
          <${StatTile}
            label="인계"
            value=${String(keeper.handoff_count_total ?? '-')}
          />
        </div>
      <//>

      <${KpiSection} title="메모리 압력">
        <div class="flex flex-col gap-3">
          <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
            <${StatTile}
              label="컨텍스트"
              value=${ctxPct != null ? `${ctxPct}%` : '-'}
              status=${kpiToneToStatus(ctxTone)}
              delta=${ctxHint ? { direction: ctxPct != null && ctxPct > CTX_WARN_PCT ? 'down' as const : 'flat' as const, text: ctxHint } : undefined}
            />
            <${StatTile}
              label="토큰"
              value=${formatTokens(keeper.context_tokens)}
            />
            <${StatTile}
              label="압축"
              value=${String(keeper.compaction_count ?? '-')}
            />
            ${latestCost
              ? html`<${StatTile} label="비용 (USD)" value=${latestCost} />`
              : null}
          </div>
          <${OperationalHealth} keeper=${keeper} />
        </div>
      <//>

      <${KpiSection} title="자율성 패턴">
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
          <${StatTile}
            label="자율 턴"
            value=${String(keeper.autonomous_turn_count ?? 0)}
          />
          <${StatTile}
            label="자율 행동"
            value=${String(keeper.autonomous_action_count ?? 0)}
          />
          <${StatTile}
            label="보드 반응"
            value=${String(keeper.board_reactive_turn_count ?? 0)}
          />
          <${StatTile}
            label="비활동"
            value=${String(keeper.noop_turn_count ?? 0)}
          />
        </div>
      <//>

      <${KpiSection} title="결과">
        ${outcomes ? html`<${OutcomesLedger} keeper=${keeper} outcomes=${outcomes} />` : html`
          <div class="text-2xs text-[var(--color-fg-disabled)] leading-snug">
            outcomes 집계를 불러오는 중이거나, 이 키퍼는 아직 관찰된 전이가 없습니다.
          </div>
        `}
      <//>
    </div>
  `
}
