// Keeper detail sub-components — KPIs, charts, field dictionary,
// equipment, relationships, traits
// Redesigned: individual KPI cards, clean table, proper spacing.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { formatPct, formatTokens } from '../lib/format-number'
import { TextInput } from './common/input'
import { CopyIdButton } from './common/copy-id-button'
import { ProgressBar } from './common/progress-bar'
import type { Keeper, KeeperMetricPoint, PromptSegmentTelemetry } from '../types'

// ── Context pressure thresholds (shared across KPIs, charts) ─
const CTX_CRITICAL_PCT = 85
const CTX_WARN_PCT = 70
const CTX_COLOR_CRITICAL = 'var(--bad)'
const CTX_COLOR_WARN = 'var(--amber-bright)'
const CTX_COLOR_OK = 'var(--emerald)'

export function ctxColor(pct: number): string {
  return pct > CTX_CRITICAL_PCT ? CTX_COLOR_CRITICAL : pct > CTX_WARN_PCT ? CTX_COLOR_WARN : CTX_COLOR_OK
}

// ── Utility functions ────────────────────────────────────

export function autonomyHint(count: number | undefined, proactiveEnabled: boolean | undefined): string | undefined {
  if ((count ?? 0) === 0) return proactiveEnabled ? '활성 · 미발동' : '자율 비활성'
  return undefined
}

const CTX_SEGMENT_LABELS: Record<string, string> = {
  system_prompt: 'System prompt',
  dynamic_context: 'Turn context',
  memory_context: 'Memory',
  temporal_context: 'Temporal',
  user_message: 'Current input',
  history_user: 'History · user',
  history_assistant_text: 'History · assistant',
  history_tool_use: 'History · tool use',
  history_tool_result: 'History · tool result',
  history_other: 'History · other',
  unattributed: 'Unattributed',
}

const CTX_SEGMENT_COLORS: Record<string, string> = {
  system_prompt: 'var(--amber-bright)',
  dynamic_context: '#8b5cf6',
  memory_context: 'var(--rose-light)',
  temporal_context: '#14b8a6',
  user_message: 'var(--sky-400)',
  history_user: 'var(--purple)',
  history_assistant_text: 'var(--blue-400)',
  history_tool_use: '#84cc16',
  history_tool_result: 'var(--bad-light)',
  history_other: 'var(--slate-400)',
  unattributed: 'var(--slate-600)',
}

export function ctxSegmentLabel(key: string): string {
  return CTX_SEGMENT_LABELS[key] ?? key.replace(/[_-]+/g, ' ')
}

export function ctxSegmentColor(key: string): string {
  return CTX_SEGMENT_COLORS[key] ?? 'var(--slate-400)'
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
export function filterCtxCompositionEntries(
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

const KPI_TONE: Record<KpiTone, string> = {
  default: 'border-[var(--card-border)] bg-[var(--white-3)]',
  ok: 'border-[var(--ok-20)] bg-[var(--ok-6)]',
  warn: 'border-[var(--warn-20)] bg-[var(--warn-8)]',
  bad: 'border-[var(--bad-20)] bg-[var(--bad-6)]',
}

const KPI_VALUE_TONE: Record<KpiTone, string> = {
  default: 'text-[var(--text-strong)]',
  ok: 'text-[var(--ok)]',
  warn: 'text-[var(--warn)]',
  bad: 'text-[var(--bad)]',
}

const KPI_ICON: Record<string, string> = {
  '세대': '🔄',
  '턴': '↻',
  '컨텍스트': '📊',
  '활동': '⚡',
  '토큰': '🔤',
  '인계': '🤝',
  '압축': '📦',
  '비용 (USD)': '💰',
}

function KpiCard({ label, value, hint, tone = 'default', progress }: {
  label: string
  value: string | number
  hint?: string
  tone?: KpiTone
  /** 0-100 progress bar */
  progress?: number
}) {
  const icon = KPI_ICON[label] ?? ''
  return html`
    <div class="p-3.5 rounded border ${KPI_TONE[tone]} flex flex-col gap-1.5 transition-colors">
      <div class="flex items-center justify-between">
        <span class="text-3xs font-semibold uppercase tracking-wider text-[var(--text-muted)]">${label}</span>
        ${icon ? html`<span class="text-2xs opacity-60">${icon}</span>` : null}
      </div>
      <div class="text-2xl font-bold ${KPI_VALUE_TONE[tone]} tabular-nums leading-none">${value}</div>
      ${progress != null ? html`
        <div class="w-full h-1 bg-[var(--white-6)] rounded-sm overflow-hidden mt-0.5">
          <div class="h-full rounded-sm transition-all duration-500" style="width:${Math.min(progress, 100)}%;background:${ctxColor(progress)}"></div>
        </div>
      ` : null}
      ${hint ? html`<div class="text-3xs text-[var(--text-dim)] leading-snug">${hint}</div>` : null}
    </div>
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
    <div class="rounded border border-[var(--card-border)] bg-[var(--white-2)] p-3">
      <div class="mb-2 text-3xs font-semibold tracking-1 uppercase text-[var(--text-muted)]">운영 건강도</div>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
        ${hb ? html`
          <div class="p-2 rounded border ${KPI_TONE[hbTone]} flex flex-col gap-0.5">
            <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">하트비트</span>
            <span class="text-xs font-mono ${KPI_VALUE_TONE[hbTone]}">${hb.replace('T', ' ').slice(0, 19)}</span>
          </div>
        ` : null}
        ${compSavedRatio != null ? html`
          <div class="p-2 rounded border ${KPI_TONE[compTone]} flex flex-col gap-0.5">
            <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">압축 절감률</span>
            <span class="text-sm font-mono tabular-nums ${KPI_VALUE_TONE[compTone]}">${(compSavedRatio * 100).toFixed(1)}%</span>
            ${avgSaved != null ? html`<span class="text-3xs text-[var(--text-dim)]">avg ${formatTokens(avgSaved)} saved</span>` : null}
          </div>
        ` : null}
        ${dropRatio != null ? html`
          <div class="p-2 rounded border ${KPI_TONE[dropTone]} flex flex-col gap-0.5">
            <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">메모리 손실률</span>
            <span class="text-sm font-mono tabular-nums ${KPI_VALUE_TONE[dropTone]}">${(dropRatio * 100).toFixed(1)}%</span>
          </div>
        ` : null}
        ${lastCompAgo != null ? html`
          <div class="p-2 rounded border ${KPI_TONE['default']} flex flex-col gap-0.5">
            <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">마지막 압축</span>
            <span class="text-xs font-mono text-[var(--text-strong)]">${formatDuration(lastCompAgo)} 전</span>
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
    passRatePct == null ? 'var(--text-dim)'
    : passRatePct >= 90 ? 'var(--ok)'
    : passRatePct >= 70 ? 'var(--warn)'
    : 'var(--bad)'

  return html`
    <div class="flex flex-col gap-3">
      ${'' /* Row 1 — Success / Failure Ledger */}
      <div class="rounded border border-[var(--card-border)] bg-[var(--white-3)] px-3 py-2">
        <div class="flex items-baseline justify-between gap-2 mb-1.5">
          <span class="text-3xs font-semibold uppercase tracking-wider text-[var(--text-muted)]">성공/실패 (최근 ${observed_turns}턴)</span>
          <span class="text-3xs text-[var(--text-dim)]">${ledgerTotal > 0 ? `합계 ${ledgerTotal}` : '관측 없음'}</span>
        </div>
        <div class="flex items-center gap-3 text-xs">
          <span class="tabular-nums"><span class="text-[var(--ok)]">✅</span> ${successes.substantive_turns} 성공</span>
          <span class="tabular-nums"><span class="text-[var(--warn)]">⚠️</span> ${failures.turn_failed} 실패</span>
          <span class="tabular-nums"><span class="text-[var(--bad)]">🚫</span> ${failures.gate_rejected} 거절</span>
        </div>
        <div class="mt-2 w-full h-1.5 bg-[var(--white-6)] rounded-sm overflow-hidden flex" aria-label="성공/실패 비율 바">
          <div class="h-full bg-[var(--ok)]" style="width:${pctSuccess}%" title=${`성공 ${pctSuccess.toFixed(0)}%`}></div>
          <div class="h-full bg-[var(--warn)]" style="width:${pctFail}%" title=${`실패 ${pctFail.toFixed(0)}%`}></div>
          <div class="h-full bg-[var(--bad)]" style="width:${pctReject}%" title=${`거절 ${pctReject.toFixed(0)}%`}></div>
        </div>
        ${(successes.compactions_ok > 0 || successes.handoffs_ok > 0 || failures.compaction_failed > 0 || failures.handoff_failed > 0) ? html`
          <div class="mt-2 flex flex-wrap gap-1.5 text-3xs">
            ${successes.compactions_ok > 0 ? html`<span class="px-2 py-0.5 rounded-sm border border-[var(--ok-20)] bg-[var(--ok-6)] text-[var(--ok)]">압축 ${successes.compactions_ok}</span>` : null}
            ${failures.compaction_failed > 0 ? html`<span class="px-2 py-0.5 rounded-sm border border-[var(--bad-20)] bg-[var(--bad-6)] text-[var(--bad)]">압축 실패 ${failures.compaction_failed}</span>` : null}
            ${successes.handoffs_ok > 0 ? html`<span class="px-2 py-0.5 rounded-sm border border-[var(--ok-20)] bg-[var(--ok-6)] text-[var(--ok)]">인계 ${successes.handoffs_ok}</span>` : null}
            ${failures.handoff_failed > 0 ? html`<span class="px-2 py-0.5 rounded-sm border border-[var(--bad-20)] bg-[var(--bad-6)] text-[var(--bad)]">인계 실패 ${failures.handoff_failed}</span>` : null}
          </div>
        ` : null}
      </div>

      ${'' /* Row 2 — Validator Pass Rate */}
      <div class="rounded border border-[var(--card-border)] bg-[var(--white-3)] px-3 py-2">
        <div class="flex items-baseline justify-between gap-2 mb-1.5">
          <span class="text-3xs font-semibold uppercase tracking-wider text-[var(--text-muted)]">검증자 (OAS verdict)</span>
          <span class="text-3xs text-[var(--text-dim)]">
            ${verdictTotal > 0 ? `${verdicts.pass}/${verdictTotal} pass` : 'verdict 없음'}
          </span>
        </div>
        ${verdictTotal > 0 ? html`
          <div class="flex items-center gap-2">
            <div class="flex-1 h-1.5 bg-[var(--white-6)] rounded-sm overflow-hidden">
              <div class="h-full rounded-sm transition-all duration-300" style="width:${passRatePct}%;background:${passBarColor}"></div>
            </div>
            <span class="shrink-0 text-sm font-semibold tabular-nums" style="color:${passBarColor}">${passRatePct}%</span>
          </div>
          ${verdicts.top_failure_reasons.length > 0 ? html`
            <div class="mt-2 flex flex-wrap gap-1.5 text-3xs">
              <span class="text-[var(--text-dim)]">주요 실패 원인:</span>
              ${verdicts.top_failure_reasons.map(reason => html`
                <span class="px-2 py-0.5 rounded-sm border border-[var(--card-border)] bg-[var(--white-4)] font-mono text-[var(--text-body)]">${reason}</span>
              `)}
            </div>
          ` : null}
          ${validation.cdal_gate ? html`
            <div class="mt-2 flex flex-wrap gap-3 text-2xs text-[var(--text-body)]">
              <span class="tabular-nums">CDAL pass <span class="font-semibold text-[var(--ok)]">${validation.cdal_gate.pass}</span></span>
              <span class="tabular-nums">reject <span class="font-semibold text-[var(--bad)]">${validation.cdal_gate.reject}</span></span>
              ${validation.cdal_gate.pending_verification > 0 ? html`
                <span class="tabular-nums">검증 대기 <span class="font-semibold text-[var(--warn)]">${validation.cdal_gate.pending_verification}</span></span>
              ` : null}
            </div>
          ` : null}
        ` : html`
          <div class="text-2xs text-[var(--text-dim)] leading-snug">
            이 키퍼에 대해 기록된 OAS verdict가 아직 없습니다.
          </div>
        `}
      </div>

      ${'' /* Row 3 — Resilience Profile */}
      <div class="rounded border border-[var(--card-border)] bg-[var(--white-3)] px-3 py-2">
        <div class="flex items-baseline justify-between gap-2 mb-1.5">
          <span class="text-3xs font-semibold uppercase tracking-wider text-[var(--text-muted)]">회복력</span>
          <span class="text-3xs text-[var(--text-dim)]">supervisor 이력</span>
        </div>
        <div class="flex flex-wrap gap-1.5 text-2xs">
          <span class="px-2 py-0.5 rounded-sm border border-[var(--card-border)] bg-[var(--white-4)] tabular-nums">세대 ${keeper.generation ?? '-'}</span>
          <span class=${`px-2 py-0.5 rounded-sm tabular-nums ${failures.crashes > 0 ? 'border border-[var(--bad-20)] bg-[var(--bad-6)] text-[var(--bad)]' : 'border border-[var(--card-border)] bg-[var(--white-4)] text-[var(--text-body)]'}`}>크래시 ${failures.crashes}회</span>
          <span class=${`px-2 py-0.5 rounded-sm tabular-nums ${failures.restarts > 0 ? 'border border-[var(--warn-20)] bg-[var(--warn-8)] text-[var(--warn)]' : 'border border-[var(--card-border)] bg-[var(--white-4)] text-[var(--text-body)]'}`}>재시작 ${failures.restarts}회</span>
          ${failures.consecutive_fail_current > 0 ? html`
            <span class="px-2 py-0.5 rounded-sm border border-[var(--warn-20)] bg-[var(--warn-8)] text-[var(--warn)] tabular-nums">연속 실패 ${failures.consecutive_fail_current}</span>
          ` : null}
        </div>
      </div>
    </div>
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
// Each section is a rounded card with a ko-language question-header.
// PR 5 will expand the outcomes section with the full Success/Failure
// Ledger, Validator pass-rate grouping, and Resilience Profile.

function KpiSection({ title, question, children }: {
  title: string
  question: string
  children: unknown
}) {
  return html`
    <section class="rounded border border-[var(--card-border)] bg-[var(--white-2)] p-3">
      <header class="mb-2 flex items-baseline justify-between gap-2">
        <h3 class="text-2xs font-semibold tracking-1 uppercase text-[var(--text-muted)]">${title}</h3>
        <span class="text-3xs text-[var(--text-dim)] truncate">${question}</span>
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
          <${KpiCard}
            label="세대"
            value=${keeper.generation ?? '-'}
            hint="같은 keeper의 trace 교체 횟수"
          />
          <${KpiCard}
            label="턴"
            value=${keeper.turn_count ?? '-'}
            hint="총 루프 회차"
          />
          <${KpiCard}
            label="인계"
            value=${keeper.handoff_count_total ?? '-'}
            hint=${(keeper.handoff_count_total ?? 0) === 0 ? '첫 인계 후 표시' : '누적 lineage 길이'}
          />
        </div>
      </${KpiSection}>

      <${KpiSection} title="메모리 압력" question="지금 위험한가?">
        <div class="flex flex-col gap-3">
          <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
            <${KpiCard}
              label="컨텍스트"
              value=${ctxPct != null ? `${ctxPct}%` : '-'}
              hint=${ctxHint}
              tone=${ctxTone}
              progress=${ctxPct ?? undefined}
            />
            <${KpiCard}
              label="토큰"
              value=${formatTokens(keeper.context_tokens)}
              hint=${keeper.context_max ? `/ ${formatTokens(keeper.context_max)}` : undefined}
            />
            <${KpiCard}
              label="압축"
              value=${keeper.compaction_count ?? '-'}
              hint=${(keeper.compaction_count ?? 0) === 0 ? '첫 압축 후 표시' : undefined}
            />
            ${latestCost
              ? html`<${KpiCard} label="비용 (USD)" value=${latestCost} />`
              : null}
          </div>
          <${OperationalHealth} keeper=${keeper} />
          ${totalCalls > 0 ? html`
            <div class="rounded border border-[var(--card-border)] bg-[var(--white-3)] p-3">
              <div class="mb-2 text-3xs font-semibold tracking-1 uppercase text-[var(--text-muted)]">모델 호출 분포</div>
              <div class="flex flex-col gap-1.5">
                ${modelEntries.slice(0, 4).map(([model, count]) => {
                  const pct = Math.round((count / totalCalls) * 100)
                  return html`
                    <div class="flex items-center gap-2 text-xs">
                      <span class="shrink-0 w-35 truncate font-mono text-2xs text-[var(--accent)]" title=${model}>${model}</span>
                      <${ProgressBar}
                        pct=${pct}
                        size="sm"
                        tone="accent"
                        trackTone="dim"
                        trackClass="flex-1"
                      />
                      <span class="shrink-0 w-10 text-right text-[var(--text-muted)]">${count}회</span>
                    </div>
                  `
                })}
              </div>
              ${modelEntries.length > 4 ? html`
                <div class="mt-1 text-3xs text-[var(--text-muted)]">외 ${modelEntries.length - 4}개 모델</div>
              ` : null}
            </div>
          ` : null}
        </div>
      </${KpiSection}>

      <${KpiSection} title="자율성 패턴" question="스스로 돌고 있나?">
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
          <${KpiCard}
            label="자율 턴"
            value=${keeper.autonomous_turn_count ?? 0}
            hint=${keeper.autonomous_text_turn_count != null ? `텍스트 ${keeper.autonomous_text_turn_count} / 도구 ${keeper.autonomous_tool_turn_count ?? 0}` : autonomyHint(keeper.autonomous_turn_count, keeper.proactive_enabled) ?? '미발동'}
          />
          <${KpiCard}
            label="자율 행동"
            value=${keeper.autonomous_action_count ?? 0}
            hint=${keeper.last_proactive_ago_s != null
              ? `${formatDuration(keeper.last_proactive_ago_s)} 전${keeper.last_proactive_reason ? ' · ' + keeper.last_proactive_reason : ''}`
              : autonomyHint(keeper.autonomous_action_count, keeper.proactive_enabled) ?? '행동 횟수'}
          />
          <${KpiCard}
            label="보드 반응"
            value=${keeper.board_reactive_turn_count ?? 0}
            hint="게시판 반응 턴"
          />
          <${KpiCard}
            label="비활동"
            value=${keeper.noop_turn_count ?? 0}
            hint="아무 작업 없는 턴"
          />
        </div>
      </${KpiSection}>

      <${KpiSection} title="결과" question="무엇을 해냈고 실패했고 검증을 통과했나?">
        ${outcomes ? html`<${OutcomesLedger} keeper=${keeper} outcomes=${outcomes} />` : html`
          <div class="text-2xs text-[var(--text-dim)] leading-snug">
            outcomes 집계를 불러오는 중이거나, 이 키퍼는 아직 관찰된 전이가 없습니다.
          </div>
        `}
      </${KpiSection}>
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
      <div class="flex items-center gap-3 mb-5 p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)]">
        <div class="flex-1 h-2 bg-[var(--white-6)] rounded-sm overflow-hidden">
          <div class="h-full rounded-sm transition-all duration-300" style="width:${pct.toFixed(1)}%;background:${color}"></div>
        </div>
        <span class="text-sm font-semibold tabular-nums text-[var(--text-strong)]">${pct.toFixed(1)}%</span>
      </div>`
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
    <div class="flex items-center gap-3 mb-5 p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)]">
      <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded" style="background:var(--bg-deepest);">
        <line x1="${pad}" y1="${(H - pad - 0.5 * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - 0.5 * (H - 2 * pad)).toFixed(1)}" stroke="#444" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${pad}" y1="${(H - pad - (CTX_WARN_PCT / 100) * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - (CTX_WARN_PCT / 100) * (H - 2 * pad)).toFixed(1)}" stroke="#444" stroke-dasharray="3,3" stroke-width="0.5"/>
        <line x1="${pad}" y1="${(H - pad - (CTX_CRITICAL_PCT / 100) * (H - 2 * pad)).toFixed(1)}" x2="${W - pad}" y2="${(H - pad - (CTX_CRITICAL_PCT / 100) * (H - 2 * pad)).toFixed(1)}" stroke="${CTX_COLOR_WARN}" stroke-dasharray="3,3" stroke-width="0.5"/>
        ${pts.filter(({ p }) => p.is_handoff).map(({ x }) => html`
          <line x1="${x.toFixed(1)}" y1="${pad}" x2="${x.toFixed(1)}" y2="${H - pad}" stroke="var(--bad)" stroke-width="1.5" opacity="0.7"/>
        `)}
        <polyline points="${polyline}" fill="none" stroke="${lineColor}" stroke-width="1.5"/>
        ${pts.filter(({ p }) => p.is_compaction).map(({ x, y, p }) => {
          const trigger = p.compaction_trigger ?? 'unknown'
          const saved = p.compaction_saved_tokens ?? 0
          const tip = saved > 0 ? `${trigger} · ${formatTokens(saved)} saved` : trigger
          return html`
            <circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="3" fill="#a855f7" style="cursor:pointer">
              <title>${tip}</title>
            </circle>
          `
        })}
      </svg>
      <span class="text-sm font-semibold tabular-nums text-[var(--text-strong)]">${lastRatio.toFixed(1)}%</span>
    </div>`
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
        <span class="text-2xs font-semibold uppercase tracking-wider text-[var(--text-muted)]">턴 토큰 추세</span>
        <span class="text-3xs text-[var(--text-dim)]">${points.length} turns</span>
      </div>
      <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
        ${'' /* Dual-line chart: input (cyan) + output (green) */}
        <div class="md:col-span-2 p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="flex items-center gap-4 mb-1.5">
            <span class="flex items-center gap-1 text-3xs text-[var(--text-muted)]">
              <span class="inline-block w-2.5 h-0.5 rounded bg-[#67e8f9]"></span> input
              <span class="font-mono text-[var(--cyan)]">${formatTokens(lastInput)}</span>
            </span>
            <span class="flex items-center gap-1 text-3xs text-[var(--text-muted)]">
              <span class="inline-block w-2.5 h-0.5 rounded bg-[var(--ok)]"></span> output
              <span class="font-mono text-[var(--good)]">${formatTokens(lastOutput)}</span>
            </span>
          </div>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded w-full" style="background:var(--bg-deepest);">
            ${inputLine ? html`<polyline points="${inputLine}" fill="none" stroke="#67e8f9" stroke-width="1.5" opacity="0.8"/>` : null}
            ${outputLine ? html`<polyline points="${outputLine}" fill="none" stroke="var(--ok)" stroke-width="1.5" opacity="0.8"/>` : null}
          </svg>
        </div>

        ${'' /* Input/Output ratio */}
        <div class="p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col justify-between">
          <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">In/Out 비율</span>
          <span class="text-lg font-mono tabular-nums text-[var(--accent)]">${avgRatio.toFixed(1)}x</span>
          <span class="text-3xs text-[var(--text-dim)]">${avgRatio > 10 ? '프롬프트 비대 주의' : avgRatio > 5 ? '프롬프트 무거움' : '정상 범위'}</span>
        </div>
      </div>
    </div>
  `
}

export function formatFingerprint(value: string | null | undefined): string {
  if (!value) return '-'
  return value.length > 16 ? `${value.slice(0, 16)}…` : value
}

export function formatSegmentLabel(key: string): string {
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
        <span class="text-2xs font-semibold uppercase tracking-wider text-[var(--text-muted)]">프롬프트 핑거프린트</span>
        <span class="text-3xs text-[var(--text-dim)]">${promptPoints.length}개 스냅샷</span>
        ${latest?.prompt_fingerprint
          ? html`<span class="inline-flex items-center gap-1">
              <span class="text-3xs px-1.5 py-0.5 rounded bg-[var(--white-5)] text-[var(--text-dim)] font-mono" title=${latest.prompt_fingerprint}>${formatFingerprint(latest.prompt_fingerprint)}</span>
              <${CopyIdButton} value=${latest.prompt_fingerprint} label="fingerprint" size=${10} />
            </span>`
          : null}
      </div>
      <div class="grid grid-cols-1 md:grid-cols-4 gap-3">
        <div class="md:col-span-2 p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="flex items-center justify-between mb-1.5">
            <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">estimated prompt tokens</span>
            <span class="text-xs font-mono tabular-nums text-[var(--accent)]">${latestTotal != null ? formatTokens(latestTotal) : '-'}</span>
          </div>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded w-full" style="background:var(--bg-deepest);">
            ${totalLine ? html`<polyline points="${totalLine}" fill="none" stroke="var(--amber-bright)" stroke-width="1.5"/>` : null}
          </svg>
          <div class="mt-1 flex flex-wrap gap-2 text-3xs text-[var(--text-dim)]">
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
        </div>

        <div class="p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col justify-between">
          <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">fingerprint revisions</span>
          <span class="text-lg font-mono tabular-nums text-[var(--warn)]">${fingerprintTransitions}</span>
          <span class="text-3xs text-[var(--text-dim)]">${uniqueFingerprintCount} unique</span>
        </div>

        <div class="p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col justify-between">
          <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">latest fingerprint</span>
          <div class="flex items-center gap-1.5">
            <span class="text-sm font-mono break-all text-[var(--text-strong)]" title=${latest?.prompt_fingerprint ?? ''}>${latest?.prompt_fingerprint ? formatFingerprint(latest.prompt_fingerprint) : '-'}</span>
            ${latest?.prompt_fingerprint ? html`<${CopyIdButton} value=${latest.prompt_fingerprint} label="fingerprint" size=${12} />` : null}
          </div>
          <span class="text-3xs text-[var(--text-dim)]">${latestSegments.length} segments</span>
        </div>
      </div>

      ${latestSegments.length > 0 ? html`
        <div class="mt-3 grid grid-cols-1 md:grid-cols-2 gap-3">
          ${latestSegments.map(([segmentKey, segment]) => html`
            <div class="p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)]">
              <div class="flex items-center justify-between gap-2 mb-2">
                <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">${formatSegmentLabel(segmentKey)}</span>
                <span class="inline-flex items-center gap-1">
                  <span class="text-3xs font-mono text-[var(--text-dim)]" title=${segment.fingerprint ?? ''}>${formatFingerprint(segment.fingerprint)}</span>
                  ${segment.fingerprint ? html`<${CopyIdButton} value=${segment.fingerprint} label="segment fingerprint" size=${10} />` : null}
                </span>
              </div>
              <div class="grid grid-cols-2 gap-2 text-xs">
                <div class="rounded border border-[var(--white-8)] bg-[var(--white-2)] px-2.5 py-2">
                  <div class="text-3xs uppercase tracking-wider text-[var(--text-dim)]">tokens</div>
                  <div class="mt-1 font-mono tabular-nums text-[var(--accent)]">${formatTokens(segment.estimated_tokens)}</div>
                </div>
                <div class="rounded border border-[var(--white-8)] bg-[var(--white-2)] px-2.5 py-2">
                  <div class="text-3xs uppercase tracking-wider text-[var(--text-dim)]">bytes</div>
                  <div class="mt-1 font-mono tabular-nums text-[var(--text-strong)]">${segment.bytes.toLocaleString()}</div>
                </div>
              </div>
            </div>
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
        <span class="text-2xs font-semibold uppercase tracking-wider text-[var(--text-muted)]">CTX Composition</span>
        <span class="text-3xs text-[var(--text-dim)]">${points.length} snapshots</span>
      </div>
      <div class="grid grid-cols-1 md:grid-cols-4 gap-3">
        <div class="md:col-span-2 p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="flex items-center justify-between mb-2 gap-3">
            <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">latest turn input</span>
            <span class="text-xs font-mono tabular-nums text-[var(--accent)]">${formatTokens(latestTotal)}</span>
          </div>
          <div class="h-3 rounded-sm overflow-hidden border border-[var(--white-8)] bg-[var(--white-2)] flex">
            ${latestEntries.map(([key, segment]) => {
              const pct = latestTotal > 0 ? (segment.estimated_tokens / latestTotal) * 100 : 0
              return html`<div
                title=${`${ctxSegmentLabel(key)} · ${formatTokens(segment.estimated_tokens)} · ${pct.toFixed(1)}%`}
                style=${`width:${pct}%;background:${ctxSegmentColor(key)};min-width:${pct > 0 ? '1px' : '0'};`}
              ></div>`
            })}
          </div>
          <div class="mt-2 flex flex-wrap gap-2 text-3xs text-[var(--text-dim)]">
            ${latestActual != null ? html`<span>actual ${formatTokens(latestActual)}</span>` : null}
            <span>known ${formatTokens(latestKnown)}</span>
            <span>${Math.round(knownRatio * 100)}% attributed</span>
            ${unattributedTokens > 0 ? html`<span>residual ${formatTokens(unattributedTokens)}</span>` : null}
          </div>
        </div>

        <div class="p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col justify-between">
          <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">largest bucket</span>
          <span class="text-sm font-medium text-[var(--text-strong)]">${ctxSegmentLabel(latestEntries[0]?.[0] ?? 'unknown')}</span>
          <span class="text-3xs font-mono text-[var(--text-dim)]">
            ${latestEntries[0] ? `${formatTokens(latestEntries[0][1].estimated_tokens)} · ${((latestEntries[0][1].estimated_tokens / latestTotal) * 100).toFixed(1)}%` : '-'}
          </span>
        </div>

        <div class="p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col justify-between">
          <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">residual</span>
          <span class="text-lg font-mono tabular-nums text-[var(--warn)]">${formatTokens(unattributedTokens)}</span>
          <span class="text-3xs text-[var(--text-dim)]">tool schema / provider overhead / estimator gap</span>
        </div>
      </div>

      <div class="mt-3 grid grid-cols-1 md:grid-cols-3 gap-3">
        <div class="md:col-span-2 p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="flex items-center justify-between mb-1.5">
            <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">stacked history</span>
            <span class="text-3xs text-[var(--text-dim)]">${points.length} turns</span>
          </div>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded w-full" style="background:var(--bg-deepest);">
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
        </div>

        <div class="p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="flex items-center justify-between gap-2 mb-2">
            <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">latest breakdown</span>
            <span class="text-3xs font-mono text-[var(--text-dim)]">${visibleCtxEntries.length}/${latestEntries.length}</span>
          </div>
          <input
            type="search"
            value=${ctxCompositionSearch.value}
            placeholder="세그먼트 필터 (예: history, memory)"
            aria-label="context composition 세그먼트 필터"
            onInput=${(e: Event) => { ctxCompositionSearch.value = (e.target as HTMLInputElement).value }}
            class="mb-2 w-full rounded border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1 text-2xs text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)]"
          />
          ${visibleCtxEntries.length === 0 ? html`
            <div class="py-4 text-center text-2xs text-[var(--text-dim)]">
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
                    <span class="truncate text-[var(--text-body)]">${ctxSegmentLabel(key)}</span>
                  </span>
                  <span class="font-mono tabular-nums text-[var(--text-dim)] whitespace-nowrap">
                    ${pct.toFixed(1)}% · ${formatTokens(segment.estimated_tokens)}
                  </span>
                </div>
              `
            })}
          </div>
        </div>
      </div>
    </div>
  `
}

// ── Metrics Charts (Latency + Cost + Model) ─────────────

const SPARKLINE_W = 200
const SPARKLINE_H = 40
const SPARKLINE_PAD = 2
const MODEL_NAME_MAX_LEN = 20

export function miniSparkline(
  data: number[],
  maxOverride?: number,
): string {
  const W = SPARKLINE_W, H = SPARKLINE_H, pad = SPARKLINE_PAD
  const n = data.length
  if (n < 2) return ''
  const maxVal = maxOverride ?? Math.max(...data, 1)
  return data.map((v, i) => {
    const x = pad + (i / (n - 1)) * (W - 2 * pad)
    const y = H - pad - (v / maxVal) * (H - 2 * pad)
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
  const latencies = telemetryPoints.map(
    (p: KeeperMetricPoint) => p.inference_telemetry?.request_latency_ms ?? 0,
  )
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
  const latencyLine = miniSparkline(latencies)

  const lastFp = telemetryPoints[telemetryPoints.length - 1]?.inference_telemetry?.system_fingerprint

  return html`
    <div class="mb-5">
      <div class="flex items-center gap-2 mb-2">
        <span class="text-2xs font-semibold uppercase tracking-wider text-[var(--text-muted)]">추론 텔레메트리</span>
        <span class="text-3xs text-[var(--text-dim)]">${telemetryPoints.length}개 지점</span>
        ${lastFp ? html`<span class="text-3xs px-1.5 py-0.5 rounded bg-[var(--white-5)] text-[var(--text-dim)] font-mono">${lastFp}</span>` : null}
      </div>
      <div class="grid grid-cols-2 md:grid-cols-5 gap-3">
        ${wallTokPerSec.length > 0 ? html`
        <div class="p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="flex items-center justify-between mb-1.5">
            <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">wall tok/s</span>
            <span class="text-xs font-mono tabular-nums text-[var(--good)]">${lastWallTps.toFixed(1)}</span>
          </div>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded w-full" style="background:var(--bg-deepest);">
            ${wallTpsLine ? html`<polyline points="${wallTpsLine}" fill="none" stroke="var(--ok)" stroke-width="1.5"/>` : null}
          </svg>
          <div class="text-3xs text-[var(--text-dim)] mt-1">avg ${avgWallTps.toFixed(1)}</div>
        </div>
        ` : null}

        ${hwTokPerSec.length > 0 ? html`
        <div class="p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="flex items-center justify-between mb-1.5">
            <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">hw tok/s</span>
            <span class="text-xs font-mono tabular-nums text-[var(--good)]">${lastHwTps.toFixed(1)}</span>
          </div>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded w-full" style="background:var(--bg-deepest);">
            ${hwTpsLine ? html`<polyline points="${hwTpsLine}" fill="none" stroke="var(--ok)" stroke-width="1.5"/>` : null}
          </svg>
          <div class="text-3xs text-[var(--text-dim)] mt-1">avg ${avgHwTps.toFixed(1)} · decode-only</div>
        </div>
        ` : null}

        ${'' /* request latency */}
        <div class="p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="flex items-center justify-between mb-1.5">
            <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">API latency</span>
            <span class="text-xs font-mono tabular-nums text-[var(--accent)]">${lastLatency > 0 ? `${(lastLatency / 1000).toFixed(1)}s` : '-'}</span>
          </div>
          <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded w-full" style="background:var(--bg-deepest);">
            ${latencyLine ? html`<polyline points="${latencyLine}" fill="none" stroke="#9ad9ff" stroke-width="1.5"/>` : null}
          </svg>
        </div>

        ${'' /* cache hits */}
        <div class="p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col justify-between">
          <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">KV Cache</span>
          <span class="text-lg font-mono tabular-nums text-[var(--purple)]">${totalCacheN > 0 ? totalCacheN.toLocaleString() : '-'}</span>
          <span class="text-3xs text-[var(--text-dim)]">cumulative tokens</span>
        </div>

        ${'' /* reasoning tokens */}
        <div class="p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)] flex flex-col justify-between">
          <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">Reasoning</span>
          <span class="text-lg font-mono tabular-nums text-[var(--warn)]">${totalReasoning > 0 ? totalReasoning.toLocaleString() : '-'}</span>
          <span class="text-3xs text-[var(--text-dim)]">total tokens</span>
        </div>
      </div>
    </div>
  `
}

export function MetricsCharts({ keeper }: { keeper: Keeper }) {
  const series = keeper.metrics_series ?? []
  if (series.length < 2) return null

  const latencies = series.map((p: KeeperMetricPoint) => p.latency_ms ?? 0)
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

  const latencyLine = miniSparkline(latencies)
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
      <div class="p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)]">
        <div class="flex items-center justify-between mb-1.5">
          <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">지연 시간</span>
          <span class="flex items-center gap-2">
            ${fallbackCount > 0 ? html`<span class="text-3xs px-1.5 py-0.5 rounded bg-[var(--bad-soft)] text-[var(--bad)] font-mono">FB ${fallbackCount}</span>` : null}
            <span class="text-xs font-mono tabular-nums text-[var(--accent)]">${lastLatency > 0 ? `${(lastLatency / 1000).toFixed(1)}s` : '-'}</span>
          </span>
        </div>
        <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded w-full" style="background:var(--bg-deepest);">
          ${fallbackIndices.map((idx: number) => {
            const x = SPARKLINE_PAD + (idx / Math.max(n - 1, 1)) * (W - 2 * SPARKLINE_PAD)
            return html`<line x1="${x.toFixed(1)}" y1="${SPARKLINE_PAD}" x2="${x.toFixed(1)}" y2="${H - SPARKLINE_PAD}" stroke="var(--bad)" stroke-width="1.5" opacity="0.6"/>`
          })}
          ${latencyLine ? html`<polyline points="${latencyLine}" fill="none" stroke="#9ad9ff" stroke-width="1.5"/>` : null}
        </svg>
      </div>

      ${'' /* Cost */}
      <div class="p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)]">
        <div class="flex items-center justify-between mb-1.5">
          <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">비용</span>
          <span class="text-xs font-mono tabular-nums text-[var(--purple)]">$${totalCost.toFixed(4)}</span>
        </div>
        <svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" class="rounded w-full" style="background:var(--bg-deepest);">
          ${costLine ? html`<polyline points="${costLine}" fill="none" stroke="var(--purple)" stroke-width="1.5"/>` : null}
        </svg>
      </div>

      ${'' /* Model timeline */}
      ${modelSwitches.length > 0 ? html`
        <div class="md:col-span-2 p-3 rounded border border-[var(--card-border)] bg-[var(--white-3)]">
          <div class="flex items-center justify-between mb-1.5">
            <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">모델 전환</span>
            <span class="text-3xs text-[var(--text-dim)]">${modelSwitches.length}회</span>
          </div>
          <div class="flex flex-wrap gap-1.5">
            ${modelSwitches.map(s => html`
              <span class="text-3xs px-2 py-0.5 rounded-sm bg-[var(--warn-10)] text-[var(--warn)] border border-[var(--warn-20)] font-mono">
                T${s.index} -> ${s.model.length > MODEL_NAME_MAX_LEN ? s.model.slice(0, MODEL_NAME_MAX_LEN) + '...' : s.model}
              </span>
            `)}
          </div>
        </div>
      ` : null}

      ${'' /* Cascade fallback events */}
      ${fallbackCount > 0 ? html`
        <div class="md:col-span-2 p-3 rounded border border-[var(--bad-20)] bg-[var(--bad-6)]">
          <div class="flex items-center justify-between mb-1.5">
            <span class="text-3xs uppercase tracking-wider text-[var(--text-muted)]">캐스케이드 폴백</span>
            <span class="text-3xs text-[var(--bad)]">${fallbackCount}회</span>
          </div>
          <div class="flex flex-wrap gap-1.5">
            ${series.filter((p: KeeperMetricPoint) => p.fallback_applied).slice(-10).map((p: KeeperMetricPoint) => html`
              <span class="text-3xs px-2 py-0.5 rounded-sm bg-[var(--bad-10)] text-[var(--bad)] border border-[var(--bad-20)] font-mono">
                ${p.fallback_from ?? '?'} -> ${p.fallback_to ?? p.model_used}${p.fallback_reason ? ` (${p.fallback_reason.length > 20 ? p.fallback_reason.slice(0, 20) + '...' : p.fallback_reason})` : ''}
              </span>
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
    { title: 'Name', key: 'name', value: keeper.name },
    { title: 'Emoji', key: 'emoji', value: keeper.emoji ?? '-' },
    { title: 'Korean', key: 'koreanName', value: keeper.koreanName ?? '-' },
    { title: 'Model', key: 'model', value: keeper.model ?? '-' },
    { title: 'Status', key: 'status', value: keeper.status },
    { title: 'Primary', key: 'primaryValue', value: keeper.primaryValue ?? '-' },
    { title: 'Gen', key: 'generation', value: String(keeper.generation ?? '-') },
    { title: 'Turns', key: 'turn_count', value: String(keeper.turn_count ?? '-') },
    { title: 'Context', key: 'context_ratio', value: formatPct(keeper.context_ratio) },
    { title: 'Heartbeat', key: 'last_heartbeat', value: keeper.last_heartbeat ?? '-' },
    { title: 'Traits', key: 'traits', value: keeper.traits?.join(', ') || '-' },
    { title: 'Interests', key: 'interests', value: keeper.interests?.join(', ') || '-' },
  ]

  // Extra fields from keeper object
  const extras: { title: string; value: string; mono?: boolean }[] = []
  if (keeper.trace_id) extras.push({ title: 'Trace ID', value: keeper.trace_id, mono: true })
  if (keeper.agent_name) extras.push({ title: 'Agent', value: keeper.agent_name })
  if (keeper.primary_model) extras.push({ title: 'Primary Model', value: keeper.primary_model, mono: true })
  if (keeper.active_model) extras.push({ title: 'Active Model', value: keeper.active_model, mono: true })
  if (keeper.next_model_hint) extras.push({ title: 'Next Model Hint', value: keeper.next_model_hint, mono: true })
  if (keeper.skill_primary) extras.push({ title: 'Skill (Primary)', value: keeper.skill_primary })
  if (keeper.skill_secondary?.length) extras.push({ title: 'Skill (Secondary)', value: keeper.skill_secondary.join(', ') })
  if (keeper.skill_reason) extras.push({ title: 'Skill Reason', value: keeper.skill_reason })
  if (keeper.context_source) extras.push({ title: 'Context Source', value: keeper.context_source })
  if (keeper.context_tokens != null) extras.push({ title: 'Context Tokens', value: formatTokens(keeper.context_tokens) })
  if (keeper.context_max != null) extras.push({ title: 'Context Max', value: formatTokens(keeper.context_max) })
  if (keeper.memory_recent_note) extras.push({ title: 'Memory Note', value: keeper.memory_recent_note })
  if (keeper.k2k_count != null) extras.push({ title: 'K2K Count', value: String(keeper.k2k_count) })
  if (keeper.conversation_tail_count != null) extras.push({ title: 'Conv Tail', value: String(keeper.conversation_tail_count) })
  if (keeper.handoff_count_total != null) extras.push({ title: 'Total Handoffs', value: String(keeper.handoff_count_total) })
  if (keeper.compaction_count != null) extras.push({ title: 'Compactions', value: String(keeper.compaction_count) })
  if (keeper.last_compaction_saved_tokens != null) extras.push({ title: 'Last Compact Saved', value: formatTokens(keeper.last_compaction_saved_tokens) })
  if (keeper.context?.message_count != null) extras.push({ title: 'Message Count', value: String(keeper.context.message_count) })
  if (keeper.context?.has_checkpoint != null) extras.push({ title: 'Has Checkpoint', value: keeper.context.has_checkpoint ? 'Yes' : 'No' })

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
          <div class="grid grid-cols-[100px_80px_1fr] gap-2 py-2 px-2 text-xs rounded ${i % 2 === 0 ? 'bg-[var(--white-2)]' : ''}">
            <span class="font-semibold text-[var(--text-body)] truncate">${f.title}</span>
            <span class="font-mono text-[var(--cyan)] text-2xs truncate">${f.key}</span>
            <span class="text-right text-[var(--text-body)] truncate">${f.value}</span>
          </div>
        `)}
        ${extras.map((f, i) => html`
          <div class="grid grid-cols-[100px_1fr] gap-2 py-2 px-2 text-xs rounded ${(filtered.length + i) % 2 === 0 ? 'bg-[var(--white-2)]' : ''}">
            <span class="font-semibold text-[var(--text-body)] truncate">${f.title}</span>
            <span class="text-right text-[var(--text-body)] truncate ${f.mono ? 'font-mono' : ''}">${f.value}</span>
          </div>
        `)}
      </div>
    </div>
  `
}

// ── Equipment, Relationships, Traits ───────────────

export function EquipmentList({ items }: { items: string[] }) {
  if (items.length === 0) return html`<div class="py-2 px-3 text-xs text-[var(--text-muted)] italic">장비 없음</div>`

  return html`
    <div class="flex flex-col gap-1.5">
      ${items.map((item, i) => html`
        <div class="flex items-center justify-between py-2 px-3 rounded bg-[var(--white-3)]">
          <span class="text-xs text-[var(--text-body)]">${item}</span>
          <span class="text-3xs text-[var(--cyan)] font-mono">#${i + 1}</span>
        </div>
      `)}
    </div>
  `
}

export function RelationshipList({ rels }: { rels: Record<string, string> }) {
  const entries = Object.entries(rels)
  if (entries.length === 0) return html`<div class="py-2 px-3 text-xs text-[var(--text-muted)] italic">관계 없음</div>`

  return html`
    <div class="max-h-55 overflow-y-auto flex flex-col gap-1.5">
      ${entries.map(([name, relation]) => html`
        <div class="flex items-center gap-2 py-2 px-3 bg-[var(--white-3)] rounded">
          <span class="inline-flex items-center py-0.5 px-2 rounded-sm text-2xs font-medium bg-[var(--accent-12)] text-[var(--accent)] border border-[var(--accent-30)]">${name}</span>
          <span class="text-2xs text-[var(--text-muted)] font-mono">${relation}</span>
        </div>
      `)}
    </div>
  `
}

export function TraitsList({ traits, label }: { traits: string[]; label: string }) {
  if (traits.length === 0) return null

  return html`
    <div class="mb-3">
      <div class="text-3xs text-[var(--text-muted)] uppercase tracking-wider font-semibold mb-2">${label}</div>
      <div class="flex flex-wrap gap-1.5">
        ${traits.map(t => html`<span class="inline-flex items-center py-0.5 px-2.5 rounded-sm text-2xs font-medium bg-[var(--accent-12)] text-[var(--accent)] border border-[var(--accent-30)]">${t}</span>`)}
      </div>
    </div>
  `
}
