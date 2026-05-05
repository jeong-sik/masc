// Keeper detail sub-components — KPIs, charts, field dictionary,
// equipment, relationships, traits
// Redesigned: individual KPI cards, clean table, proper spacing.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { formatPct, formatPct1, formatTokens } from '../lib/format-number'
import { TextInput } from './common/input'
import { CopyIdButton } from './common/copy-id-button'
import { ProgressBar } from './common/progress-bar'
import { Eyebrow } from './common/eyebrow'
import { SectionHeader } from './common/section-header'
import { StatusChip } from './common/status-chip'
import { StatTile } from './common/stat-tile'
import type { Keeper, KeeperMetricPoint, PromptSegmentTelemetry } from '../types'

function MutedSpan({ children }: { children: unknown }) {
  return html`<span class="text-3xs text-[var(--color-fg-disabled)]">${children}</span>`
}

// ── Context pressure thresholds (shared across KPIs, charts) ─
const CTX_CRITICAL_PCT = 85
const CTX_WARN_PCT = 70
const CTX_COLOR_CRITICAL = 'var(--color-status-err)'
const CTX_COLOR_WARN = 'var(--amber-bright)'
const CTX_COLOR_OK = 'var(--emerald)'

function ctxColor(pct: number): string {
  return pct > CTX_CRITICAL_PCT ? CTX_COLOR_CRITICAL : pct > CTX_WARN_PCT ? CTX_COLOR_WARN : CTX_COLOR_OK
}

function DetailRow({ children }: { children: unknown }) {
  return html`<div class="flex items-center justify-between mb-1.5">${children}</div>`
}

// ── Utility functions ────────────────────────────────────

export function autonomyHint(count: number | undefined, proactiveEnabled: boolean | undefined): string | undefined {
  if ((count ?? 0) === 0) return proactiveEnabled ? '활성 · 미발동' : '자율 비활성'
  return undefined
}

const CTX_SEGMENT_LABELS: Record<string, string> = {
  system_prompt: '시스템 프롬프트',
  dynamic_context: '턴 컨텍스트',
  memory_context: '메모리',
  temporal_context: '시간',
  user_message: '현재 입력',
  history_user: '히스토리 · user',
  history_assistant_text: '히스토리 · assistant',
  history_tool_use: '히스토리 · tool use',
  history_tool_result: '히스토리 · tool result',
  history_other: '히스토리 · 기타',
  unattributed: '미할당',
}

const CTX_SEGMENT_COLORS: Record<string, string> = {
  system_prompt: 'var(--amber-bright)',
  dynamic_context: 'var(--purple)',
  memory_context: 'var(--rose-light)',
  temporal_context: 'var(--cyan)',
  user_message: 'var(--sky-400)',
  history_user: 'var(--purple)',
  history_assistant_text: 'var(--blue-400)',
  history_tool_use: 'var(--color-status-ok)',
  history_tool_result: 'var(--bad-light)',
  history_other: 'var(--color-fg-muted)',
  unattributed: 'var(--color-border-default)',
}

function ctxSegmentLabel(key: string): string {
  return CTX_SEGMENT_LABELS[key] ?? key.replace(/[_-]+/g, ' ')
}

function ctxSegmentColor(key: string): string {
  return CTX_SEGMENT_COLORS[key] ?? 'var(--color-fg-muted)'
}

/**
 * Pure filter for CTX composition "latest breakdown" entries.
 *
 * Case-insensitive substring match against either the raw segment key
 * (e.g. `history_tool_result`) or its human label (e.g. `History · tool result`).
 * This lets operators search by either form — raw key is what shows up in
 * backend logs, label is what the dashboard renders.
 *
 * Empty/whitespace query returns the input reference unchanged so the
 * default render path avoids an unnecessary array allocation. Does not
 * mutate the input.
 */
function filterCtxCompositionEntries(
  entries: ReadonlyArray<readonly [string, PromptSegmentTelemetry]>,
  query: string,
): ReadonlyArray<readonly [string, PromptSegmentTelemetry]> {
  const needle = query.trim().toLowerCase()
  if (needle === '') return entries
  return entries.filter(([key]) => {
    if (key.toLowerCase().includes(needle)) return true
    return ctxSegmentLabel(key).toLowerCase().includes(needle)
  })
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

function DetailCard({ class: cx, children }: {
  class?: string
  children: unknown
}) {
  return html`
    <div class="p-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] ${cx ?? ''}">${children}</div>
  `
}

// ── Operational Health ───────────────────────────────────

function OperationalHealth({ keeper }: { keeper: Keeper }) {
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

// ── Outcomes Ledger ──────────────────────────────────────
//
// Section-4 body for KpiGrid. Renders three rows that answer the
// operator's question "무엇을 해냈고 실패했고 검증을 통과했나?":
//
//   Row 1 — Success / Failure Ledger
//     Counters pulled from [Keeper_transition_audit] (50-entry ring):
//       ✅ successes.substantive_turns
//       ⚠️ failures.turn_failed
//       🚫 failures.gate_rejected (always 0 until CDAL #7531)
//     Rendered as compact inline counters + a stacked proportion bar.
//     Secondary row lists compactions_ok / handoffs_ok as chips.
//
//   Row 2 — Validator Pass Rate (OAS verdicts)
//     "pass N/M (P%)" with a horizontal progress bar colored by tone,
//     plus up to 3 top failure reasons rendered as muted chips.
//
//   Row 3 — Resilience Profile
//     Chips for 세대 / 크래시 / 재시작 / 연속 실패 (current).
//
// The conservation law (KeeperOutcomesConservation.tla) is guaranteed
// by the backend rollup, so this component can treat the numbers as
// internally consistent — no client-side reconciliation needed.

function OutcomesLedger({ keeper, outcomes }: {
  keeper: Keeper
  outcomes: NonNullable<Keeper['outcomes']>
}) {
  const { successes, failures, validation, observed_turns } = outcomes
  const ledgerTotal = successes.substantive_turns + failures.turn_failed + failures.gate_rejected
  const pctSuccess = ledgerTotal > 0 ? (successes.substantive_turns / ledgerTotal) * 100 : 0
  const pctFail    = ledgerTotal > 0 ? (failures.turn_failed        / ledgerTotal) * 100 : 0
  const pctReject  = ledgerTotal > 0 ? (failures.gate_rejected      / ledgerTotal) * 100 : 0

  const verdicts = validation.oas_verdicts
  const verdictTotal = verdicts.pass + verdicts.fail + verdicts.unknown
  const passRatePct = verdictTotal > 0 ? Math.round((verdicts.pass / verdictTotal) * 100) : null
  const passBarColor =
    passRatePct == null ? 'var(--color-fg-disabled)'
    : passRatePct >= 90 ? 'var(--color-status-ok)'
    : passRatePct >= 70 ? 'var(--color-status-warn)'
    : 'var(--color-status-err)'

  return html`
    <div class="flex flex-col gap-3">
      ${'' /* Row 1 — Success / Failure Ledger */}
      <${DetailCard} class="px-3 py-2">
        <div class="flex items-baseline justify-between gap-2 mb-1.5">
          <${SectionHeader} size="xs">성공/실패 (최근 ${observed_turns}턴)</${SectionHeader}>
          <${MutedSpan}>${ledgerTotal > 0 ? `합계 ${ledgerTotal}` : '관측 없음'}</${MutedSpan}>
        </div>
        <div class="flex items-center gap-3 text-xs">
          <span class="tabular-nums"><span class="text-[var(--color-status-ok)]">✅</span> ${successes.substantive_turns} 성공</span>
          <span class="tabular-nums"><span class="text-[var(--color-status-warn)]">⚠️</span> ${failures.turn_failed} 실패</span>
          <span class="tabular-nums"><span class="text-[var(--color-status-err)]">🚫</span> ${failures.gate_rejected} 거절</span>
        </div>
        <div class="mt-2 w-full h-1.5 bg-[var(--color-bg-hover)] rounded-[var(--r-0)] overflow-hidden flex" aria-label="성공/실패 비율 바">
          <div class="h-full bg-[var(--color-status-ok)]" style="width:${pctSuccess}%" title=${`성공 ${Math.round(pctSuccess)}%`}></div>
          <div class="h-full bg-[var(--color-status-warn)]" style="width:${pctFail}%" title=${`실패 ${Math.round(pctFail)}%`}></div>
          <div class="h-full bg-[var(--color-status-err)]" style="width:${pctReject}%" title=${`거절 ${Math.round(pctReject)}%`}></div>
        </div>
        ${(successes.compactions_ok > 0 || successes.handoffs_ok > 0 || failures.compaction_failed > 0 || failures.handoff_failed > 0) ? html`
          <div class="mt-2 flex flex-wrap gap-1.5 text-3xs">
            ${successes.compactions_ok > 0 ? html`<${StatusChip} tone="ok" uppercase=${false}>압축 ${successes.compactions_ok}<//>` : null}
            ${failures.compaction_failed > 0 ? html`<${StatusChip} tone="bad" uppercase=${false}>압축 실패 ${failures.compaction_failed}<//>` : null}
            ${successes.handoffs_ok > 0 ? html`<${StatusChip} tone="ok" uppercase=${false}>인계 ${successes.handoffs_ok}<//>` : null}
            ${failures.handoff_failed > 0 ? html`<${StatusChip} tone="bad" uppercase=${false}>인계 실패 ${failures.handoff_failed}<//>` : null}
          </div>
        ` : null}
      <//>

      ${'' /* Row 2 — Validator Pass Rate */}
      <${DetailCard} class="px-3 py-2">
        <div class="flex items-baseline justify-between gap-2 mb-1.5">
          <${SectionHeader} size="xs">검증자 (OAS verdict)</${SectionHeader}>
          <${MutedSpan}>
            ${verdictTotal > 0 ? `${verdicts.pass}/${verdictTotal} pass` : 'verdict 없음'}
          </${MutedSpan}>
        </div>
        ${verdictTotal > 0 ? html`
          <div class="flex items-center gap-2">
            <${ProgressBar} pct=${passRatePct} size="sm" trackTone="dim" trackClass="flex-1" class=${`bg-[${passBarColor}]`} />
            <span class="shrink-0 text-sm font-semibold tabular-nums" style="color:${passBarColor}">${passRatePct}%</span>
          </div>
          ${verdicts.top_failure_reasons.length > 0 ? html`
            <div class="mt-2 flex flex-wrap gap-1.5 text-3xs">
              <span class="text-[var(--color-fg-disabled)]">주요 실패 원인:</span>
              ${verdicts.top_failure_reasons.map(reason => html`
                <span class="px-2 py-0.5 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] font-mono text-[var(--color-fg-primary)]">${reason}</span>
              `)}
            </div>
          ` : null}
          ${validation.cdal_gate ? html`
            <div class="mt-2 flex flex-wrap gap-3 text-2xs text-[var(--color-fg-primary)]">
              <span class="tabular-nums">CDAL pass <span class="font-semibold text-[var(--color-status-ok)]">${validation.cdal_gate.pass}</span></span>
              <span class="tabular-nums">reject <span class="font-semibold text-[var(--color-status-err)]">${validation.cdal_gate.reject}</span></span>
              ${validation.cdal_gate.pending_verification > 0 ? html`
                <span class="tabular-nums">검증 대기 <span class="font-semibold text-[var(--color-status-warn)]">${validation.cdal_gate.pending_verification}</span></span>
              ` : null}
            </div>
          ` : null}
        ` : html`
          <div class="text-2xs text-[var(--color-fg-disabled)] leading-snug">
            이 키퍼에 대해 기록된 OAS verdict가 아직 없습니다.
          </div>
        `}
      <//>

      ${'' /* Row 3 — Resilience Profile */}
      <${DetailCard} class="px-3 py-2">
        <div class="flex items-baseline justify-between gap-2 mb-1.5">
          <${SectionHeader} size="xs">회복력</${SectionHeader}>
          <${MutedSpan}>supervisor 이력</${MutedSpan}>
        </div>
        <div class="flex flex-wrap gap-1.5 text-2xs">
          <span class="px-2 py-0.5 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] tabular-nums">세대 ${keeper.generation ?? '-'}</span>
          <span class=${`px-2 py-0.5 rounded-[var(--r-0)] tabular-nums ${failures.crashes > 0 ? 'border border-[var(--bad-20)] bg-[var(--bad-6)] text-[var(--color-status-err)]' : 'border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-primary)]'}`}>크래시 ${failures.crashes}회</span>
          <span class=${`px-2 py-0.5 rounded-[var(--r-0)] tabular-nums ${failures.restarts > 0 ? 'border border-[var(--warn-20)] bg-[var(--warn-8)] text-[var(--color-status-warn)]' : 'border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-primary)]'}`}>재시작 ${failures.restarts}회</span>
          ${failures.consecutive_fail_current > 0 ? html`
            <span class="px-2 py-0.5 rounded-[var(--r-0)] border border-[var(--warn-20)] bg-[var(--warn-8)] text-[var(--color-status-warn)] tabular-nums">연속 실패 ${failures.consecutive_fail_current}</span>
          ` : null}
        </div>
      <//>
    <//>
  `
}

// ── KPI Grid ─────────────────────────────────────────────
//
// 4-section layout mirrors the keeper's 3-layer state model
// (Events → Phase+Conditions → Counters) projected onto the four
// questions an operator asks when opening the modal:
//   1) "얼마나 오래 살았나?"       → identity      (세대/턴/인계)
//   2) "지금 위험한가?"             → memory       (컨텍스트/토큰/압축 + 운영 건강도)
//   3) "스스로 돌고 있나?"          → autonomy     (자율 턴/행동 비율)
//   4) "무엇을 해냈고 실패했나?"   → outcomes     (backed by KeeperOutcomes)
//
// Each section is a rounded-[var(--r-1)] card with a ko-language question-header.
// PR 5 will expand the outcomes section with the full Success/Failure
// Ledger, Validator pass-rate grouping, and Resilience Profile.

function KpiSection({ title, question, children }: {
  title: string
  question: string
  children: unknown
}) {
  return html`
    <section class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3" aria-label=${title}>
      <header class="mb-2 flex items-baseline justify-between gap-2">
        <h3 class="text-2xs font-semibold tracking-[var(--track-caps)] uppercase text-[var(--color-fg-muted)]">${title}</h3>
        <span class="text-3xs text-[var(--color-fg-disabled)] truncate">${question}</span>
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

  // Provider-model call statistics from metrics_series
  const modelCounts: Record<string, number> = {}
  for (const pt of series) {
    if (pt.model_used) {
      modelCounts[pt.model_used] = (modelCounts[pt.model_used] ?? 0) + 1
    }
  }
  const modelEntries = Object.entries(modelCounts).sort((a, b) => b[1] - a[1])
  const totalCalls = modelEntries.reduce((s, [, c]) => s + c, 0)

  const outcomes = keeper.outcomes

  return html`
    <div class="flex flex-col gap-3 mb-5">
      <${KpiSection} title="정체성" question="얼마나 오래 살았나?">
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

      <${KpiSection} title="메모리 압력" question="지금 위험한가?">
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
          ${totalCalls > 0 ? html`
            <${DetailCard} class="p-3">
              <div class="mb-2 text-3xs font-semibold tracking-[var(--track-caps)] uppercase text-[var(--color-fg-muted)]">모델 호출 분포</div>
              <div class="flex flex-col gap-1.5">
                ${modelEntries.slice(0, 4).map(([model, count]) => {
                  const pct = Math.round((count / totalCalls) * 100)
                  return html`
                    <div class="flex items-center gap-2 text-xs">
                      <span class="shrink-0 w-35 truncate font-mono text-2xs text-[var(--color-accent-fg)]" title=${model}>${model}</span>
                      <${ProgressBar}
                        pct=${pct}
                        size="sm"
                        tone="accent"
                        trackTone="dim"
                        trackClass="flex-1"
                      />
                      <span class="shrink-0 w-10 text-right text-[var(--color-fg-muted)]">${count}회</span>
                    </div>
                  `
                })}
              </div>
              ${modelEntries.length > 4 ? html`
                <div class="mt-1 text-3xs text-[var(--color-fg-muted)]">외 ${modelEntries.length - 4}개 모델</div>
              ` : null}
            <//>
          ` : null}
        </div>
      <//>

      <${KpiSection} title="자율성 패턴" question="스스로 돌고 있나?">
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

      <${KpiSection} title="결과" question="무엇을 해냈고 실패했고 검증을 통과했나?">
        ${outcomes ? html`<${OutcomesLedger} keeper=${keeper} outcomes=${outcomes} />` : html`
          <div class="text-2xs text-[var(--color-fg-disabled)] leading-snug">
            outcomes 집계를 불러오는 중이거나, 이 키퍼는 아직 관찰된 전이가 없습니다.
          </div>
        `}
      <//>
    </div>
  `
}

export function formatDuration(sec: number): string {
  if (sec < 60) return `${sec}초`
  if (sec < 3600) return `${Math.floor(sec / 60)}분`
  return `${Math.floor(sec / 3600)}시간 ${Math.floor((sec % 3600) / 60)}분`
}

// ── Context Chart ────────────────────────────────────────

export function ContextChart({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  if (series.length < 2) {
    const pct = ((keeper.context_ratio ?? keeper.context?.context_ratio ?? 0) * 100)
    const color = ctxColor(pct)
    return html`
      <${DetailCard} class="flex items-center gap-3 mb-5">
        <${ProgressBar} pct=${pct} size="md" trackTone="dim" trackClass="flex-1" class=${`bg-[${color}]`} />
        <span class="text-sm font-semibold tabular-nums text-[var(--color-fg-secondary)]">${pct.toFixed(1)}%</span>
      <//>`
  }

  const W = 200, H = 60, pad = 2
  const n = series.length
  const pts = series.map((p: KeeperMetricPoint, i: number) => {
    const x = pad + (i / (n - 1)) * (W - 2 * pad)
    const y = H - pad - (p.context_ratio ?? 0) * (H - 2 * pad)
    return { x, y, p }
  })
  const polyline = pts.map(({ x, y }) => `${x.toFixed(1)},${y.toFixed(1)}`).join(' ')
  const lastRatio = ((series[series.length - 1] as KeeperMetricPoint)?.context_ratio ?? 0) * 100
  const lineColor = ctxColor(lastRatio)

  return html`
    <${DetailCard} class="flex items-center gap-3 mb-5">
      <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)]" role="img" aria-label="컨텍스트 비율 스파크라인" style="background:var(--bg-deepest);">
        <line x1="${pad}" y1="${(H - pad - 0.5 * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - 0.5 * (H - 2 * pad)).toFixed(1)}" stroke="var(--color-line-3)" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${pad}" y1="${(H - pad - (CTX_WARN_PCT / 100) * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - (CTX_WARN_PCT / 100) * (H - 2 * pad)).toFixed(1)}" stroke="var(--color-line-3)" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${pad}" y1="${(H - pad - (CTX_CRITICAL_PCT / 100) * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - (CTX_CRITICAL_PCT / 100) * (H - 2 * pad)).toFixed(1)}" stroke="${CTX_COLOR_WARN}" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${pts.filter(({ p }) => p.is_handoff).map(({ x }) => html`
          <line x1="${x.toFixed(1)}" y1="${pad}" x2="${x.toFixed(1)}" y2="${H - pad}" stroke="var(--color-status-err)" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${polyline}" fill="none" stroke="${lineColor}" stroke-width="1.5"/>
        ${pts.filter(({ p }) => p.is_compaction).map(({ x, y, p }) => {
          const trigger = p.compaction_trigger ?? 'unknown'
          const saved = p.compaction_saved_tokens ?? 0
          const tip = saved > 0 ? `${trigger} · ${formatTokens(saved)} saved` : trigger
          return html`
            <circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="3" fill="var(--purple)" style="cursor:pointer">
              <title>${tip}</title>
            </circle>
          `
        })}
      </svg>
      <span class="text-sm font-semibold tabular-nums text-[var(--color-fg-secondary)]">${lastRatio.toFixed(1)}%</span>
    <//>`
}

// ── Token Trend Chart (per-turn input/output tokens) ────

const TOKEN_CHART_W = 200
const TOKEN_CHART_H = 50

export function TokenTrendChart({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  const points = series.filter(
    (p: KeeperMetricPoint) => p.inference_telemetry?.timings != null,
  )
  if (points.length < 2) return null

  const inputTokens = points.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.timings?.prompt_n ?? 0,
  )
  const outputTokens = points.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.timings?.predicted_n ?? 0,
  )
  const totalPerTurn = inputTokens.map((inp, i) => inp + (outputTokens[i] ?? 0))
  const maxVal = Math.max(...totalPerTurn, 1)

  const W = TOKEN_CHART_W, H = TOKEN_CHART_H, pad = 2
  const n = points.length

  const inputLine = inputTokens.map((v, i) => {
    const x = pad + (i / (n - 1)) * (W - 2 * pad)
    const y = H - pad - (v / maxVal) * (H - 2 * pad)
    return `${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')

  const outputLine = outputTokens.map((v, i) => {
    const x = pad + (i / (n - 1)) * (W - 2 * pad)
    const y = H - pad - (v / maxVal) * (H - 2 * pad)
    return `${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')

  const lastInput = inputTokens[inputTokens.length - 1] ?? 0
  const lastOutput = outputTokens[outputTokens.length - 1] ?? 0
  const avgRatio = inputTokens.reduce((a, b) => a + b, 0) / Math.max(outputTokens.reduce((a, b) => a + b, 0), 1)

  return html`
    <div class="mb-5">
      <div class="flex items-center gap-2 mb-2">
        <span class="text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">턴 토큰 추세</span>
        <${MutedSpan}>${points.length} turns</${MutedSpan}>
      </div>
      <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
        ${'' /* Dual-line chart: input (cyan) + output (green) */}
        <${DetailCard} class="md:col-span-2">
          <div class="flex items-center gap-4 mb-1.5">
            <span class="flex items-center gap-1 text-3xs text-[var(--color-fg-muted)]">
              <span class="inline-block w-2.5 h-0.5 rounded-[var(--r-1)] bg-[var(--cyan)]"></span> input
              <span class="font-mono text-[var(--cyan)]">${formatTokens(lastInput)}</span>
            </span>
            <span class="flex items-center gap-1 text-3xs text-[var(--color-fg-muted)]">
              <span class="inline-block w-2.5 h-0.5 rounded-[var(--r-1)] bg-[var(--color-status-ok)]"></span> output
              <span class="font-mono text-[var(--good)]">${formatTokens(lastOutput)}</span>
            </span>
          </div>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" role="img" aria-label="입출력 토큰 추이" style="background:var(--bg-deepest);">
            ${inputLine ? html`<polyline points="${inputLine}" fill="none" stroke="var(--cyan)" stroke-width="1.5" opacity="0.8"/>` : null}
            ${outputLine ? html`<polyline points="${outputLine}" fill="none" stroke="var(--color-status-ok)" stroke-width="1.5" opacity="0.8"/>` : null}
          </svg>
        <//>

        ${'' /* Input/Output ratio */}
        <${DetailCard} class="flex flex-col justify-between">
          <${Eyebrow}>In/Out 비율</${Eyebrow}>
          <span class="text-lg font-mono tabular-nums text-[var(--color-accent-fg)]">${avgRatio.toFixed(1)}x</span>
          <${MutedSpan}>${avgRatio > 10 ? '프롬프트 비대 주의' : avgRatio > 5 ? '프롬프트 무거움' : '정상 범위'}</${MutedSpan}>
        <//>
      </div>
    </div>
  `
}

function formatFingerprint(value: string | null | undefined): string {
  if (!value) return '-'
  return value.length > 16 ? `${value.slice(0, 16)}…` : value
}

function formatSegmentLabel(key: string): string {
  return key.replace(/[_-]+/g, ' ')
}

export function PromptTelemetryPanel({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  const promptPoints = series.filter(
    (p: KeeperMetricPoint) => p.prompt_metrics != null || p.prompt_fingerprint != null,
  )
  if (promptPoints.length === 0) return null

  const latest = promptPoints[promptPoints.length - 1] ?? null
  const latestPrompt = latest?.prompt_metrics ?? null
  const latestSegments = Object.entries(latestPrompt?.segments ?? {})
    .sort(([left], [right]) => left.localeCompare(right))
  const promptTotals = promptPoints.map(
    (p: KeeperMetricPoint) => p.prompt_metrics?.estimated_total_tokens ?? 0,
  )
  const latestTotal = latestPrompt?.estimated_total_tokens ?? null
  const latestCacheable = latestPrompt?.estimated_cacheable_tokens ?? null
  const latestTimeoutBudget = latest?.timeout_budget ?? null
  const cacheableRatio =
    latestTotal && latestCacheable != null && latestTotal > 0
      ? latestCacheable / latestTotal
      : null

  const fingerprints = promptPoints
    .map((p: KeeperMetricPoint) => p.prompt_fingerprint ?? p.prompt_metrics?.fingerprint ?? null)
    .filter((value): value is string => Boolean(value))
  const uniqueFingerprintCount = new Set(fingerprints).size
  let fingerprintTransitions = 0
  let lastFingerprint: string | null = null
  for (const current of fingerprints) {
    if (lastFingerprint != null && current !== lastFingerprint) fingerprintTransitions += 1
    lastFingerprint = current
  }

  const W = SPARKLINE_W, H = SPARKLINE_H
  const totalLine = miniSparkline(promptTotals)

  return html`
    <div class="mb-5">
      <div class="flex items-center gap-2 mb-2">
        <span class="text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">프롬프트 핑거프린트</span>
        <${MutedSpan}>${promptPoints.length}개 스냅샷</${MutedSpan}>
        ${latest?.prompt_fingerprint
          ? html`<span class="inline-flex items-center gap-1">
              <span class="text-3xs px-1.5 py-0.5 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-disabled)] font-mono" title=${latest.prompt_fingerprint}>${formatFingerprint(latest.prompt_fingerprint)}</span>
              <${CopyIdButton} value=${latest.prompt_fingerprint} label="fingerprint" size=${10} />
            </span>`
          : null}
      </div>
      <div class="grid grid-cols-1 md:grid-cols-4 gap-3">
        <${DetailCard} class="md:col-span-2">
          <${DetailRow}>
            <${Eyebrow}>estimated prompt tokens</${Eyebrow}>
            <span class="text-xs font-mono tabular-nums text-[var(--color-accent-fg)]">${latestTotal != null ? formatTokens(latestTotal) : '-'}</span>
          </${DetailRow}>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" role="img" aria-label="프롬프트 토큰 추이" style="background:var(--bg-deepest);">
            ${totalLine ? html`<polyline points="${totalLine}" fill="none" stroke="var(--amber-bright)" stroke-width="1.5"/>` : null}
          </svg>
          <div class="mt-1 flex flex-wrap gap-2 text-3xs text-[var(--color-fg-disabled)]">
            <span>latest ${latestTotal != null ? formatTokens(latestTotal) : '-'}</span>
            <span>cacheable ${latestCacheable != null ? formatTokens(latestCacheable) : '-'}</span>
            ${cacheableRatio != null ? html`<span>${Math.round(cacheableRatio * 100)}% cacheable</span>` : null}
            ${latestTimeoutBudget?.oas_timeout_sec != null
              ? html`<span>OAS ${Math.round(latestTimeoutBudget.oas_timeout_sec)}s</span>`
              : null}
            ${latestTimeoutBudget?.keeper_turn_timeout_sec != null
              ? html`<span>keeper cap ${Math.round(latestTimeoutBudget.keeper_turn_timeout_sec)}s</span>`
              : null}
            ${latestTimeoutBudget?.source
              ? html`<span>${latestTimeoutBudget.source}</span>`
              : null}
            ${latest?.cascade_strategy
              ? html`<span>strategy ${latest.cascade_strategy}</span>`
              : null}
          </div>
        <//>

        <${DetailCard} class="flex flex-col justify-between">
          <${Eyebrow}>fingerprint revisions</${Eyebrow}>
          <span class="text-lg font-mono tabular-nums text-[var(--color-status-warn)]">${fingerprintTransitions}</span>
          <${MutedSpan}>${uniqueFingerprintCount} unique</${MutedSpan}>
        <//>

        <${DetailCard} class="flex flex-col justify-between">
          <${Eyebrow}>latest fingerprint</${Eyebrow}>
          <div class="flex items-center gap-1.5">
            <span class="text-sm font-mono break-all text-[var(--color-fg-secondary)]" title=${latest?.prompt_fingerprint ?? ''}>${latest?.prompt_fingerprint ? formatFingerprint(latest.prompt_fingerprint) : '-'}</span>
            ${latest?.prompt_fingerprint ? html`<${CopyIdButton} value=${latest.prompt_fingerprint} label="fingerprint" size=${12} />` : null}
          </div>
          <${MutedSpan}>${latestSegments.length} segments</${MutedSpan}>
        <//>
      </div>

      ${latestSegments.length > 0 ? html`
        <div class="mt-3 grid grid-cols-1 md:grid-cols-2 gap-3">
          ${latestSegments.map(([segmentKey, segment]) => html`
            <${DetailCard}>
              <div class="flex items-center justify-between gap-2 mb-2">
                <${Eyebrow}>${formatSegmentLabel(segmentKey)}</${Eyebrow}>
                <span class="inline-flex items-center gap-1">
                  <span class="text-3xs font-mono text-[var(--color-fg-disabled)]" title=${segment.fingerprint ?? ''}>${formatFingerprint(segment.fingerprint)}</span>
                  ${segment.fingerprint ? html`<${CopyIdButton} value=${segment.fingerprint} label="segment fingerprint" size=${10} />` : null}
                </span>
              </div>
              <div class="grid grid-cols-2 gap-2 text-xs">
                <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-2">
                  <${Eyebrow} tone="disabled">tokens</${Eyebrow}>
                  <div class="mt-1 font-mono tabular-nums text-[var(--color-accent-fg)]">${formatTokens(segment.estimated_tokens)}</div>
                </div>
                <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-2">
                  <${Eyebrow} tone="disabled">bytes</${Eyebrow}>
                  <div class="mt-1 font-mono tabular-nums text-[var(--color-fg-secondary)]">${segment.bytes.toLocaleString()}</div>
                </div>
              </div>
            <//>
          `)}
        </div>
      ` : null}
    </div>
  `
}

export function CtxCompositionPanel({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  const points = series.filter(
    (p: KeeperMetricPoint) => (p.ctx_composition?.display_total_tokens ?? 0) > 0,
  )
  if (points.length === 0) return null

  const latest = points[points.length - 1] ?? null
  const latestComposition = latest?.ctx_composition ?? null
  if (!latestComposition) return null

  const latestTotal = latestComposition.display_total_tokens
  const latestActual = latestComposition.actual_input_tokens
  const latestKnown = latestComposition.estimated_known_tokens
  const latestEntries = Object.entries(latestComposition.segments)
    .filter(([, segment]) => (segment?.estimated_tokens ?? 0) > 0)
    .sort(([, left], [, right]) => (right.estimated_tokens ?? 0) - (left.estimated_tokens ?? 0))
  if (latestEntries.length === 0 || latestTotal <= 0) return null
  const visibleCtxEntries = filterCtxCompositionEntries(latestEntries, ctxCompositionSearch.value)

  const allKeys = Array.from(
    new Set(points.flatMap((point: KeeperMetricPoint) => Object.keys(point.ctx_composition?.segments ?? {}))),
  )
  const sortedKeys = allKeys
    .filter((key) => points.some((point: KeeperMetricPoint) => (point.ctx_composition?.segments?.[key]?.estimated_tokens ?? 0) > 0))
    .sort((left, right) => {
      const rightLatest = latestComposition.segments[right]?.estimated_tokens ?? 0
      const leftLatest = latestComposition.segments[left]?.estimated_tokens ?? 0
      if (rightLatest !== leftLatest) return rightLatest - leftLatest
      return left.localeCompare(right)
    })

  const W = SPARKLINE_W
  const H = 56
  const pad = SPARKLINE_PAD
  const innerW = W - (2 * pad)
  const innerH = H - (2 * pad)
  const barStep = innerW / Math.max(points.length, 1)
  const barWidth = Math.max(3, Math.min(8, barStep - 1))

  const knownRatio = latestTotal > 0 ? latestKnown / latestTotal : 0
  const unattributedTokens = latestComposition.segments.unattributed?.estimated_tokens ?? 0

  return html`
    <div class="mb-5">
      <div class="flex items-center gap-2 mb-2">
        <span class="text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">CTX Composition</span>
        <${MutedSpan}>${points.length} snapshots</${MutedSpan}>
      </div>
      <div class="grid grid-cols-1 md:grid-cols-4 gap-3">
        <${DetailCard} class="md:col-span-2">
          <div class="flex items-center justify-between mb-2 gap-3">
            <${Eyebrow}>latest turn input</${Eyebrow}>
            <span class="text-xs font-mono tabular-nums text-[var(--color-accent-fg)]">${formatTokens(latestTotal)}</span>
          </div>
          <div class="h-3 rounded-[var(--r-0)] overflow-hidden border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] flex">
            ${latestEntries.map(([key, segment]) => {
              const pct = latestTotal > 0 ? (segment.estimated_tokens / latestTotal) * 100 : 0
              return html`<div
                title=${`${ctxSegmentLabel(key)} · ${formatTokens(segment.estimated_tokens)} · ${pct.toFixed(1)}%`}
                style=${`width:${pct}%;background:${ctxSegmentColor(key)};min-width:${pct > 0 ? '1px' : '0'};`}
              ></div>`
            })}
          </div>
          <div class="mt-2 flex flex-wrap gap-2 text-3xs text-[var(--color-fg-disabled)]">
            ${latestActual != null ? html`<span>actual ${formatTokens(latestActual)}</span>` : null}
            <span>known ${formatTokens(latestKnown)}</span>
            <span>${Math.round(knownRatio * 100)}% attributed</span>
            ${unattributedTokens > 0 ? html`<span>residual ${formatTokens(unattributedTokens)}</span>` : null}
          </div>
        <//>

        <${DetailCard} class="flex flex-col justify-between">
          <${Eyebrow}>largest bucket</${Eyebrow}>
          <span class="text-sm font-medium text-[var(--color-fg-secondary)]">${ctxSegmentLabel(latestEntries[0]?.[0] ?? 'unknown')}</span>
          <span class="text-3xs font-mono text-[var(--color-fg-disabled)]">
            ${latestEntries[0] ? `${formatTokens(latestEntries[0][1].estimated_tokens)} · ${((latestEntries[0][1].estimated_tokens / latestTotal) * 100).toFixed(1)}%` : '-'}
          </span>
        <//>

        <${DetailCard} class="flex flex-col justify-between">
          <${Eyebrow}>residual</${Eyebrow}>
          <span class="text-lg font-mono tabular-nums text-[var(--color-status-warn)]">${formatTokens(unattributedTokens)}</span>
          <${MutedSpan}>tool schema / provider overhead / estimator gap</${MutedSpan}>
        <//>
      </div>

      <div class="mt-3 grid grid-cols-1 md:grid-cols-3 gap-3">
        <${DetailCard} class="md:col-span-2">
          <${DetailRow}>
            <${Eyebrow}>stacked history</${Eyebrow}>
            <${MutedSpan}>${points.length} turns</${MutedSpan}>
          </${DetailRow}>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" role="img" aria-label="컨텍스트 구성 스택 히스토리" style="background:var(--bg-deepest);">
            ${points.map((point: KeeperMetricPoint, index: number) => {
              const comp = point.ctx_composition
              if (!comp || comp.display_total_tokens <= 0) return null
              const x = pad + (index * barStep) + Math.max(0, (barStep - barWidth) / 2)
              let yCursor = H - pad
              return sortedKeys.map((key) => {
                const tokens = comp.segments[key]?.estimated_tokens ?? 0
                if (tokens <= 0) return null
                const height = (tokens / comp.display_total_tokens) * innerH
                yCursor -= height
                return html`<rect
                  x="${x.toFixed(1)}"
                  y="${yCursor.toFixed(1)}"
                  width="${barWidth.toFixed(1)}"
                  height="${Math.max(height, 1).toFixed(1)}"
                  fill="${ctxSegmentColor(key)}"
                  opacity="0.92"
                />`
              })
            })}
          </svg>
        <//>

        <${DetailCard}>
          <div class="flex items-center justify-between gap-2 mb-2">
            <${Eyebrow}>latest breakdown</${Eyebrow}>
            <span class="text-3xs font-mono text-[var(--color-fg-disabled)]">${visibleCtxEntries.length}/${latestEntries.length}</span>
          </div>
          <${TextInput}
            type="search"
            class="mb-2 !px-2 !py-1 !text-2xs"
            value=${ctxCompositionSearch.value}
            placeholder="세그먼트 필터 (예: history, memory)"
            ariaLabel="context composition 세그먼트 필터"
            onInput=${(e: Event) => { ctxCompositionSearch.value = (e.target as HTMLInputElement).value }}
          />
          ${visibleCtxEntries.length === 0 ? html`
            <div class="py-4 text-center text-2xs text-[var(--color-fg-disabled)]">
              필터 결과 없음 (${latestEntries.length} items)
            </div>
          ` : null}
          <div class="flex flex-col gap-1.5">
            ${visibleCtxEntries.map(([key, segment]) => {
              const pct = latestTotal > 0 ? (segment.estimated_tokens / latestTotal) * 100 : 0
              return html`
                <div class="flex items-center justify-between gap-2 text-2xs">
                  <span class="inline-flex items-center gap-2 min-w-0">
                    <span class="inline-block w-2.5 h-2.5 rounded-full shrink-0" style=${`background:${ctxSegmentColor(key)};`}></span>
                    <span class="truncate text-[var(--color-fg-primary)]">${ctxSegmentLabel(key)}</span>
                  </span>
                  <span class="font-mono tabular-nums text-[var(--color-fg-disabled)] whitespace-nowrap">
                    ${pct.toFixed(1)}% · ${formatTokens(segment.estimated_tokens)}
                  </span>
                </div>
              `
            })}
          </div>
        <//>
      </div>
    </div>
  `
}

// ── Metrics Charts (Latency + Cost + Model) ─────────────

const SPARKLINE_W = 200
const SPARKLINE_H = 40
const SPARKLINE_PAD = 2
const MODEL_NAME_MAX_LEN = 20

function isFiniteMetricValue(value: number | null | undefined): value is number {
  return typeof value === 'number' && Number.isFinite(value)
}

function miniSparkline(
  data: Array<number | null | undefined>,
  maxOverride?: number,
): string {
  const W = SPARKLINE_W, H = SPARKLINE_H, pad = SPARKLINE_PAD
  const n = data.length
  const points = data
    .map((value, index) => ({ value, index }))
    .filter((point): point is { value: number; index: number } =>
      isFiniteMetricValue(point.value),
    )
  if (points.length < 2) return ''
  const maxVal = maxOverride ?? Math.max(...points.map(point => point.value), 1)
  return points.map(({ value, index }) => {
    const x = pad + (index / Math.max(n - 1, 1)) * (W - 2 * pad)
    const y = H - pad - (value / maxVal) * (H - 2 * pad)
    return `${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')
}

export function InferenceTelemetryPanel({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  const telemetryPoints = series.filter(
    (p: KeeperMetricPoint) => p.inference_telemetry != null || p.wall_tokens_per_second != null,
  )
  if (telemetryPoints.length === 0) return null

  const wallTokPerSec = telemetryPoints
    .map((p: KeeperMetricPoint) => p.wall_tokens_per_second)
    .filter((value): value is number => value != null)
  const hwTokPerSec = telemetryPoints
    .map((p: KeeperMetricPoint) => p.inference_telemetry?.timings?.predicted_per_second)
    .filter((value): value is number => value != null)
  const latencySeries = telemetryPoints.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.request_latency_ms ?? null,
  )
  const latencies = latencySeries.filter(isFiniteMetricValue)
  const cacheNs = telemetryPoints.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.timings?.cache_n ?? 0,
  )
  const reasoningTokens = telemetryPoints.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.reasoning_tokens ?? 0,
  )

  const W = SPARKLINE_W, H = SPARKLINE_H
  const lastWallTps = wallTokPerSec[wallTokPerSec.length - 1] ?? 0
  const avgWallTps =
    wallTokPerSec.length > 0
      ? wallTokPerSec.reduce((a, b) => a + b, 0) / wallTokPerSec.length
      : 0
  const lastHwTps = hwTokPerSec[hwTokPerSec.length - 1] ?? 0
  const avgHwTps =
    hwTokPerSec.length > 0
      ? hwTokPerSec.reduce((a, b) => a + b, 0) / hwTokPerSec.length
      : 0
  const lastLatency = latencies[latencies.length - 1] ?? 0
  const totalCacheN = cacheNs.reduce((a, b) => a + b, 0)
  const totalReasoning = reasoningTokens.reduce((a, b) => a + b, 0)

  const wallTpsLine = wallTokPerSec.length > 1 ? miniSparkline(wallTokPerSec) : ''
  const hwTpsLine = hwTokPerSec.length > 1 ? miniSparkline(hwTokPerSec) : ''
  const latencyLine = miniSparkline(latencySeries)

  const lastFp = telemetryPoints[telemetryPoints.length - 1]?.inference_telemetry?.system_fingerprint

  return html`
    <div class="mb-5">
      <div class="flex items-center gap-2 mb-2">
        <span class="text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">추론 텔레메트리</span>
        <${MutedSpan}>${telemetryPoints.length}개 지점</${MutedSpan}>
        ${lastFp ? html`<span class="text-3xs px-1.5 py-0.5 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-disabled)] font-mono">${lastFp}</span>` : null}
      </div>
      <div class="grid grid-cols-2 md:grid-cols-5 gap-3">
        ${wallTokPerSec.length > 0 ? html`
        <${DetailCard}>
          <${DetailRow}>
            <${Eyebrow}>wall tok/s</${Eyebrow}>
            <span class="text-xs font-mono tabular-nums text-[var(--good)]">${lastWallTps.toFixed(1)}</span>
          </${DetailRow}>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" role="img" aria-label="Wall TPS 추이" style="background:var(--bg-deepest);">
            ${wallTpsLine ? html`<polyline points="${wallTpsLine}" fill="none" stroke="var(--color-status-ok)" stroke-width="1.5"/>` : null}
          </svg>
          <div class="text-3xs text-[var(--color-fg-disabled)] mt-1">avg ${avgWallTps.toFixed(1)}</div>
        <//>
        ` : null}

        ${hwTokPerSec.length > 0 ? html`
        <${DetailCard}>
          <${DetailRow}>
            <${Eyebrow}>hw tok/s</${Eyebrow}>
            <span class="text-xs font-mono tabular-nums text-[var(--good)]">${lastHwTps.toFixed(1)}</span>
          </${DetailRow}>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" role="img" aria-label="하드웨어 TPS 추이" style="background:var(--bg-deepest);">
            ${hwTpsLine ? html`<polyline points="${hwTpsLine}" fill="none" stroke="var(--color-status-ok)" stroke-width="1.5"/>` : null}
          </svg>
          <div class="text-3xs text-[var(--color-fg-disabled)] mt-1">avg ${avgHwTps.toFixed(1)} · decode-only</div>
        <//>
        ` : null}

        ${'' /* request latency */}
        <${DetailCard}>
          <${DetailRow}>
            <${Eyebrow}>API latency</${Eyebrow}>
            <span class="text-xs font-mono tabular-nums text-[var(--color-accent-fg)]">${lastLatency > 0 ? `${(lastLatency / 1000).toFixed(1)}s` : '-'}</span>
          </${DetailRow}>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" role="img" aria-label="API 지연 시간 추이" style="background:var(--bg-deepest);">
            ${latencyLine ? html`<polyline points="${latencyLine}" fill="none" stroke="var(--sky-400)" stroke-width="1.5"/>` : null}
          </svg>
        <//>

        ${'' /* cache hits */}
        <${DetailCard} class="flex flex-col justify-between">
          <${Eyebrow}>KV Cache</${Eyebrow}>
          <span class="text-lg font-mono tabular-nums text-[var(--purple)]">${totalCacheN > 0 ? totalCacheN.toLocaleString() : '-'}</span>
          <${MutedSpan}>cumulative tokens</${MutedSpan}>
        <//>

        ${'' /* reasoning tokens */}
        <${DetailCard} class="flex flex-col justify-between">
          <${Eyebrow}>추론</${Eyebrow}>
          <span class="text-lg font-mono tabular-nums text-[var(--color-status-warn)]">${totalReasoning > 0 ? totalReasoning.toLocaleString() : '-'}</span>
          <${MutedSpan}>total tokens</${MutedSpan}>
        <//>
      </div>
    </div>
  `
}

export function MetricsCharts({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  if (series.length < 2) return null

  const latencySeries = series.map((p: KeeperMetricPoint) => p.latency_ms)
  const latencies = latencySeries.filter(isFiniteMetricValue)
  const costs = series.map((p: KeeperMetricPoint) => p.cost_usd ?? 0)
  const W = SPARKLINE_W, H = SPARKLINE_H

  const lastLatency = latencies[latencies.length - 1] ?? 0
  const totalCost = costs.reduce((a: number, b: number) => a + b, 0)

  const modelSwitches: { index: number; model: string }[] = []
  for (let i = 1; i < series.length; i++) {
    if ((series[i] as KeeperMetricPoint).model_used !== (series[i - 1] as KeeperMetricPoint).model_used) {
      modelSwitches.push({ index: i, model: (series[i] as KeeperMetricPoint).model_used })
    }
  }

  const latencyLine = miniSparkline(latencySeries)
  const costLine = miniSparkline(costs)

  // Fallback markers on latency chart
  const n = series.length
  const fallbackIndices = series
    .map((p: KeeperMetricPoint, i: number) => p.fallback_applied ? i : -1)
    .filter((i: number) => i >= 0)
  const fallbackCount = fallbackIndices.length

  return html`
    <div class="grid grid-cols-1 md:grid-cols-2 gap-3 mb-5">
      ${'' /* Latency + fallback markers */}
      <${DetailCard}>
        <${DetailRow}>
          <${Eyebrow}>지연 시간</${Eyebrow}>
          <span class="flex items-center gap-2">
            ${fallbackCount > 0 ? html`<span class="text-3xs px-1.5 py-0.5 rounded-[var(--r-1)] bg-[var(--bad-soft)] text-[var(--color-status-err)] font-mono">FB ${fallbackCount}</span>` : null}
            <span class="text-xs font-mono tabular-nums text-[var(--color-accent-fg)]">${lastLatency > 0 ? `${(lastLatency / 1000).toFixed(1)}s` : '-'}</span>
          </span>
        </${DetailRow}>
        <svg aria-hidden="true" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" style="background:var(--bg-deepest);">
          ${fallbackIndices.map((idx: number) => {
            const x = SPARKLINE_PAD + (idx / Math.max(n - 1, 1)) * (W - 2 * SPARKLINE_PAD)
            return html`<line x1="${x.toFixed(1)}" y1="${SPARKLINE_PAD}" x2="${x.toFixed(1)}" y2="${H - SPARKLINE_PAD}" stroke="var(--color-status-err)" stroke-width="1.5" opacity="0.6"/>`
          })}
          ${latencyLine ? html`<polyline points="${latencyLine}" fill="none" stroke="var(--sky-400)" stroke-width="1.5"/>` : null}
        </svg>
      <//>

      ${'' /* Cost */}
      <${DetailCard}>
        <${DetailRow}>
          <${Eyebrow}>비용</${Eyebrow}>
          <span class="text-xs font-mono tabular-nums text-[var(--purple)]">$${totalCost.toFixed(4)}</span>
        </${DetailRow}>
        <svg aria-hidden="true" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded-[var(--r-1)] w-full" style="background:var(--bg-deepest);">
          ${costLine ? html`<polyline points="${costLine}" fill="none" stroke="var(--purple)" stroke-width="1.5"/>` : null}
        </svg>
      <//>

      ${'' /* Model timeline */}
      ${modelSwitches.length > 0 ? html`
        <${DetailCard} class="md:col-span-2">
          <${DetailRow}>
            <${Eyebrow}>모델 전환</${Eyebrow}>
            <${MutedSpan}>${modelSwitches.length}회</${MutedSpan}>
          </${DetailRow}>
          <div class="flex flex-wrap gap-1.5">
            ${modelSwitches.map(s => html`
              <${StatusChip} tone="warn" uppercase=${false} class="font-mono">
                T${s.index} -> ${s.model.length > MODEL_NAME_MAX_LEN ? s.model.slice(0, MODEL_NAME_MAX_LEN) + '...' : s.model}
              <//>
            `)}
          </div>
        <//>
      ` : null}

      ${'' /* Cascade fallback events */}
      ${fallbackCount > 0 ? html`
        <div class="md:col-span-2 p-3 rounded-[var(--r-1)] border border-[var(--bad-20)] bg-[var(--bad-6)]">
          <${DetailRow}>
            <>캐스케이드 폴백</>
            <span class="text-3xs text-[var(--color-status-err)]">${fallbackCount}회</span>
          </${DetailRow}>
          <div class="flex flex-wrap gap-1.5">
            ${series.filter((p: KeeperMetricPoint) => p.fallback_applied).slice(-10).map((p: KeeperMetricPoint) => html`
              <${StatusChip} tone="bad" uppercase=${false} class="font-mono">
                ${p.fallback_from ?? '?'} -> ${p.fallback_to ?? p.model_used}${p.fallback_reason ? ` (${p.fallback_reason.length > 20 ? p.fallback_reason.slice(0, 20) + '...' : p.fallback_reason})` : ''}
              <//>
            `)}
          </div>
        </div>
      ` : null}
    </div>
  `
}

// ── Raw Data (Debug) ─────────────────────────────────────
// Collapsed-by-default debug dump of all keeper fields.
// Primary display is handled by Header, KpiGrid, Profile, and Config sections.

const fieldSearch = signal('')
const ctxCompositionSearch = signal('')

export function RawDataDebug({ keeper }: { keeper: Keeper }) {
  const filter = fieldSearch.value.toLowerCase()

  const fields: { title: string; key: string; value: string }[] = [
    { title: '이름', key: 'name', value: keeper.name },
    { title: '이모지', key: 'emoji', value: keeper.emoji ?? '-' },
    { title: '한글명', key: 'koreanName', value: keeper.koreanName ?? '-' },
    { title: '모델', key: 'model', value: keeper.model ?? '-' },
    { title: '상태', key: 'status', value: keeper.status },
    { title: '주력', key: 'primaryValue', value: keeper.primaryValue ?? '-' },
    { title: '세대', key: 'generation', value: String(keeper.generation ?? '-') },
    { title: '턴', key: 'turn_count', value: String(keeper.turn_count ?? '-') },
    { title: '컨텍스트', key: 'context_ratio', value: formatPct(keeper.context_ratio) },
    { title: '하트비트', key: 'last_heartbeat', value: keeper.last_heartbeat ?? '-' },
    { title: '특성', key: 'traits', value: keeper.traits?.join(', ') || '-' },
    { title: '관심사', key: 'interests', value: keeper.interests?.join(', ') || '-' },
  ]

  // Extra fields from keeper object
  const extras: { title: string; value: string; mono?: boolean }[] = []
  if (keeper.trace_id) extras.push({ title: '추적 ID', value: keeper.trace_id, mono: true })
  if (keeper.agent_name) extras.push({ title: '에이전트', value: keeper.agent_name })
  if (keeper.primary_model) extras.push({ title: '주력 모델', value: keeper.primary_model, mono: true })
  if (keeper.active_model) extras.push({ title: '활성 모델', value: keeper.active_model, mono: true })
  if (keeper.next_model_hint) extras.push({ title: '다음 모델 힌트', value: keeper.next_model_hint, mono: true })
  if (keeper.skill_primary) extras.push({ title: '스킬 (주)', value: keeper.skill_primary })
  if (keeper.skill_secondary?.length) extras.push({ title: '스킬 (보조)', value: keeper.skill_secondary.join(', ') })
  if (keeper.skill_reason) extras.push({ title: '스킬 사유', value: keeper.skill_reason })
  if (keeper.context_source) extras.push({ title: '컨텍스트 소스', value: keeper.context_source })
  if (keeper.context_tokens != null) extras.push({ title: '컨텍스트 토큰', value: formatTokens(keeper.context_tokens) })
  if (keeper.context_max != null) extras.push({ title: '컨텍스트 최대', value: formatTokens(keeper.context_max) })
  if (keeper.memory_recent_note) extras.push({ title: '메모리 노트', value: keeper.memory_recent_note })
  if (keeper.k2k_count != null) extras.push({ title: 'K2K 카운트', value: String(keeper.k2k_count) })
  if (keeper.conversation_tail_count != null) extras.push({ title: '대화 tail', value: String(keeper.conversation_tail_count) })
  if (keeper.handoff_count_total != null) extras.push({ title: '핸드오프 총합', value: String(keeper.handoff_count_total) })
  if (keeper.compaction_count != null) extras.push({ title: '압축 횟수', value: String(keeper.compaction_count) })
  if (keeper.last_compaction_saved_tokens != null) extras.push({ title: '마지막 압축 절약', value: formatTokens(keeper.last_compaction_saved_tokens) })
  if (keeper.context?.message_count != null) extras.push({ title: '메시지 수', value: String(keeper.context.message_count) })
  if (keeper.context?.has_checkpoint != null) extras.push({ title: '체크포인트 보유', value: keeper.context.has_checkpoint ? '예' : '아니오' })

  const filtered = filter
    ? fields.filter(f => f.title.toLowerCase().includes(filter) || f.key.includes(filter) || f.value.toLowerCase().includes(filter))
    : fields

  return html`
    <div class="max-h-[460px] overflow-y-auto">
      <${TextInput}
        placeholder="필드 검색..."
        value=${fieldSearch.value}
        onInput=${(e: Event) => { fieldSearch.value = (e.target as HTMLInputElement).value }}
      />
      <div class="flex flex-col">
        ${filtered.map((f, i) => html`
          <div class="grid grid-cols-[100px_80px_1fr] gap-2 py-2 px-2 text-xs rounded-[var(--r-1)] ${i % 2 === 0 ? 'bg-[var(--color-bg-surface)]' : ''}">
            <span class="font-semibold text-[var(--color-fg-primary)] truncate">${f.title}</span>
            <span class="font-mono text-[var(--cyan)] text-2xs truncate">${f.key}</span>
            <span class="text-right text-[var(--color-fg-primary)] truncate">${f.value}</span>
          </div>
        `)}
        ${extras.map((f, i) => html`
          <div class="grid grid-cols-[100px_1fr] gap-2 py-2 px-2 text-xs rounded-[var(--r-1)] ${(filtered.length + i) % 2 === 0 ? 'bg-[var(--color-bg-surface)]' : ''}">
            <span class="font-semibold text-[var(--color-fg-primary)] truncate">${f.title}</span>
            <span class="text-right text-[var(--color-fg-primary)] truncate ${f.mono ? 'font-mono' : ''}">${f.value}</span>
          </div>
        `)}
      </div>
    </div>
  `
}

// ── Equipment, Relationships, Traits ───────────────

export function EquipmentList({ items }: { items: string[] }) {
  if (items.length === 0) return html`<div class="py-2 px-3 text-xs text-[var(--color-fg-muted)] italic">장비 없음</div>`

  return html`
    <div class="flex flex-col gap-1.5">
      ${items.map((item, i) => html`
        <div class="flex items-center justify-between py-2 px-3 rounded-[var(--r-1)] bg-[var(--color-bg-surface)]">
          <span class="text-xs text-[var(--color-fg-primary)]">${item}</span>
          <span class="text-3xs text-[var(--cyan)] font-mono">#${i + 1}</span>
        </div>
      `)}
    </div>
  `
}

export function RelationshipList({ rels }: { rels: Record<string, string> }) {
  const entries = Object.entries(rels)
  if (entries.length === 0) return html`<div class="py-2 px-3 text-xs text-[var(--color-fg-muted)] italic">관계 없음</div>`

  return html`
    <div class="max-h-55 overflow-y-auto flex flex-col gap-1.5">
      ${entries.map(([name, relation]) => html`
        <div class="flex items-center gap-2 py-2 px-3 bg-[var(--color-bg-surface)] rounded-[var(--r-1)]">
          <${StatusChip} tone="info" uppercase=${false} class="text-2xs font-medium">${name}<//>
          <span class="text-2xs text-[var(--color-fg-muted)] font-mono">${relation}</span>
        </div>
      `)}
    </div>
  `
}

export function TraitsList({ traits, label }: { traits: string[]; label: string }) {
  if (traits.length === 0) return null

  return html`
    <div class="mb-3">
      <div class="text-3xs text-[var(--color-fg-muted)] uppercase tracking-wider font-semibold mb-2">${label}</div>
      <div class="flex flex-wrap gap-1.5">
        ${traits.map(t => html`<${StatusChip} tone="info" uppercase=${false} class="text-2xs font-medium">${t}<//>`)}
      </div>
    </div>
  `
}
