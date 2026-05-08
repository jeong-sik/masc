// Keeper Reactivity Monitor — Phase 1–3 observability for keeper stopping
// patterns, auto-pause status, and proactive turn metrics.
//
// Implements five data views:
//   1. Health Grid     — compact grid: phase, pause status, last activity
//   2. Lifecycle       — transition timeline (delegates to KeeperPhaseTimeline)
//   3. Auto-Pause      — keepers in Paused phase + Prometheus pause counters
//   4. Proactive       — proactive turn skip reasons from /metrics
//   5. Stale           — stale termination class breakdown from /metrics
//
// All Prometheus data is fetched lazily from the existing /metrics endpoint;
// there are no new backend changes required.

import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import { keepers } from '../store'
import { navigate } from '../router'
import { KeeperPhaseBadge } from './keeper-phase-indicator'
import { KeeperPhaseTimeline, refreshKeeperPhaseTimeline } from './keeper-phase-strip'
import { KeeperLifecycleTimeline, refreshKeeperLifecycleTimeline } from './keeper-lifecycle-timeline'
import { TurnBudgetGaugePanel } from './turn-budget-gauge'
import { parsePrometheusText, type ParsedMetric } from './prometheus-metrics'
import { fetchWithTimeout, authHeaders } from '../api/core'
import { TimeAgo } from './common/time-ago'
import { LoadingState, ErrorRecoverable } from './common/feedback-state'
import { EmptyState } from './common/empty-state'
import { FilterChips } from './common/filter-chips'
import type { Keeper } from '../types'

// ── Types ─────────────────────────────────────────────────────────────────

export interface KeeperStopSummary {
  keeper: string
  stale_total: number
  idle_turn: number
  in_turn_hung: number
  noop_failure_loop: number
  budget_strikes: number
  storm_pauses: number
  budget_loop_pauses: number
}

export interface ProactiveSkipRow {
  keeper: string
  reason: string
  count: number
}

export interface BatchTerminationRow {
  batch: string
  count: number
}

// ── Helper functions ───────────────────────────────────────────────────────

/** Extract per-keeper stop/pause summaries from parsed Prometheus metrics. */
export function extractKeeperStopSummaries(
  metrics: ParsedMetric[],
): KeeperStopSummary[] {
  const map = new Map<string, KeeperStopSummary>()

  function entry(keeper: string): KeeperStopSummary {
    const existing = map.get(keeper)
    if (existing) return existing
    const fresh: KeeperStopSummary = {
      keeper,
      stale_total: 0,
      idle_turn: 0,
      in_turn_hung: 0,
      noop_failure_loop: 0,
      budget_strikes: 0,
      storm_pauses: 0,
      budget_loop_pauses: 0,
    }
    map.set(keeper, fresh)
    return fresh
  }

  for (const m of metrics) {
    if (m.name === 'masc_keeper_stale_termination_total') {
      for (const s of m.samples) {
        if (s.labels.keeper) {
          entry(s.labels.keeper).stale_total += s.value
        }
      }
    } else if (m.name === 'masc_keeper_stale_termination_by_class_total') {
      for (const s of m.samples) {
        const k = s.labels.keeper
        const cls = s.labels.class
        if (!k) continue
        const e = entry(k)
        if (cls === 'idle_turn') e.idle_turn += s.value
        else if (cls === 'in_turn_hung') e.in_turn_hung += s.value
        else if (cls === 'noop_failure_loop') e.noop_failure_loop += s.value
      }
    } else if (
      m.name === 'masc_keeper_oas_timeout_budget_strike' ||
      m.name === 'masc_keeper_oas_timeout_budget_strike_total'
    ) {
      for (const s of m.samples) {
        if (s.labels.keeper) entry(s.labels.keeper).budget_strikes += s.value
      }
    } else if (m.name === 'masc_keeper_stale_storm_paused_total') {
      for (const s of m.samples) {
        if (s.labels.keeper) entry(s.labels.keeper).storm_pauses += s.value
      }
    } else if (m.name === 'masc_keeper_oas_timeout_budget_loop_paused_total') {
      for (const s of m.samples) {
        if (s.labels.keeper) entry(s.labels.keeper).budget_loop_pauses += s.value
      }
    }
  }

  return [...map.values()].sort((a, b) => {
    // Sort: most stale terminations first, then alphabetically.
    const diff = b.stale_total - a.stale_total
    return diff !== 0 ? diff : a.keeper.localeCompare(b.keeper)
  })
}

/** Extract proactive skip rows from parsed metrics. */
export function extractProactiveSkips(
  metrics: ParsedMetric[],
): ProactiveSkipRow[] {
  const rows: ProactiveSkipRow[] = []
  for (const m of metrics) {
    if (m.name === 'masc_keeper_proactive_skip_total') {
      for (const s of m.samples) {
        if (s.labels.keeper && s.labels.reason) {
          rows.push({
            keeper: s.labels.keeper,
            reason: s.labels.reason,
            count: s.value,
          })
        }
      }
    }
  }
  // Sort precedence: most skips first, then alphabetically by keeper, then by reason.
  return rows.sort((a, b) => {
    const byCount = b.count - a.count
    if (byCount !== 0) return byCount
    const byKeeper = a.keeper.localeCompare(b.keeper)
    if (byKeeper !== 0) return byKeeper
    return a.reason.localeCompare(b.reason)
  })
}

/** Extract the fleet-wide batch termination count from parsed metrics.
 *
 * `masc_keeper_stale_termination_batch_total` is emitted as a single
 * unlabeled time-series (no per-keeper or per-reason labels). Returns an
 * empty array when the metric is absent or the total is zero, or a single row
 * with key `'fleet'` and the total count when it is present.
 */
export function extractBatchTerminations(
  metrics: ParsedMetric[],
): BatchTerminationRow[] {
  let total = 0
  for (const m of metrics) {
    if (m.name === 'masc_keeper_stale_termination_batch_total') {
      for (const s of m.samples) {
        total += s.value
      }
    }
  }
  return total > 0 ? [{ batch: 'fleet', count: total }] : []
}

// ── Prometheus fetch ───────────────────────────────────────────────────────

async function fetchMetricsText(): Promise<string> {
  const res = await fetchWithTimeout('/metrics', { headers: authHeaders() }, 10_000)
  if (!res.ok) throw new Error(`/metrics returned ${res.status}`)
  return res.text()
}

// ── Sub-component helpers ──────────────────────────────────────────────────

/** True when a keeper is in any paused state (operator or auto-pause).
 *
 * Three fields must be checked because they come from different serialisation
 * paths: `paused` is the legacy boolean from the keeper registry; `phase` is
 * the FSM-derived lifecycle phase from the composite observer; `pipeline_stage`
 * is the activity stage from the heartbeat path.  They are ordinarily in sync,
 * but during transient states (e.g. just after an auto-pause or just before a
 * resume heartbeat arrives) they can briefly disagree.  The OR ensures that any
 * signal of pause is reflected in the UI immediately, matching operator intent.
 */
export function isKeeperPaused(k: Keeper): boolean {
  return k.paused === true || k.phase === 'Paused' || k.pipeline_stage === 'paused'
}

// ── Sub-components ─────────────────────────────────────────────────────────

function PhaseDot({ phase }: { phase: string | null | undefined }) {
  return html`<${KeeperPhaseBadge} phase=${phase} compact />`
}

/** Health Grid — compact per-keeper status table. */
function HealthGrid({ allKeepers }: { allKeepers: Keeper[] }) {
  if (allKeepers.length === 0) {
    return html`<${EmptyState} message="등록된 키퍼 없음" />`
  }

  return html`
    <div class="overflow-x-auto" role="region" aria-label="키퍼 상태 그리드">
      <table class="w-full text-xs" aria-label="키퍼 상태">
        <thead>
          <tr class="border-b border-[var(--color-border-default)] text-left text-[var(--color-fg-muted)]">
            <th scope="col" class="pb-2 pr-3 font-normal">키퍼</th>
            <th scope="col" class="pb-2 pr-3 font-normal">단계</th>
            <th scope="col" class="pb-2 pr-3 font-normal">활동</th>
            <th scope="col" class="pb-2 pr-3 font-normal">마지막 활동</th>
            <th scope="col" class="pb-2 pr-3 font-normal text-right">회전 수</th>
          </tr>
        </thead>
        <tbody>
          ${allKeepers.map(k => {
            const lastActivityMs = k.last_activity_ago_s != null
              ? Date.now() - k.last_activity_ago_s * 1000
              : null
            const isPaused = isKeeperPaused(k)
            const isCrashed = k.phase === 'Crashed' || k.phase === 'Dead' || k.phase === 'Zombie'

            return html`
              <tr
                key=${k.name}
                class="group border-b border-[var(--color-border-default)]/40 hover:bg-[var(--color-bg-surface)]"
              >
                <td class="py-2 pr-3 font-medium">
                  <button
                    class="flex items-center gap-1 text-left text-[var(--color-fg-secondary)] group-hover:text-[var(--color-fg-primary)] hover:underline"
                    onClick=${() => navigate('monitoring', { section: 'agents', keeper: k.name })}
                    aria-label="${k.name} 상세 보기"
                  >
                    ${k.emoji ? html`<span class="mr-1" aria-hidden="true">${k.emoji}</span>` : null}
                    <span class="font-mono text-2xs">${k.name}</span>
                  </button>
                </td>
                <td class="py-2 pr-3">
                  <${PhaseDot} phase=${k.phase} />
                  ${isPaused ? html`
                    <span class="ml-1.5 inline-flex items-center text-3xs text-[var(--paused)] font-semibold">⏸ 일시정지</span>
                  ` : null}
                </td>
                <td class="py-2 pr-3 text-[var(--color-fg-muted)] capitalize">
                  ${k.pipeline_stage ?? '—'}
                </td>
                <td class="py-2 pr-3 text-[var(--color-fg-muted)] tabular-nums whitespace-nowrap">
                  ${lastActivityMs
                    ? html`<${TimeAgo} timestamp=${lastActivityMs} />`
                    : html`<span class="text-[var(--color-fg-disabled)]">—</span>`
                  }
                </td>
                <td class="py-2 text-right tabular-nums ${isCrashed ? 'text-[var(--bad-light)]' : 'text-[var(--color-fg-muted)]'}">
                  ${k.total_turns ?? k.turn_count ?? '—'}
                </td>
              </tr>
            `
          })}
        </tbody>
      </table>
    </div>
  `
}

/** Auto-Pause panel — keepers in paused phase + Prometheus pause event counts. */
function AutoPausePanel({
  allKeepers,
  summaries,
}: {
  allKeepers: Keeper[]
  summaries: KeeperStopSummary[]
}) {
  const pausedKeepers = allKeepers.filter(isKeeperPaused)

  const summaryMap = new Map(summaries.map(s => [s.keeper, s]))

  if (pausedKeepers.length === 0 && summaries.every(s => s.storm_pauses === 0 && s.budget_loop_pauses === 0)) {
    return html`
      <div class="rounded border border-[var(--ok-20)] bg-[var(--ok-10)] px-4 py-3 text-xs text-[var(--color-status-ok)]">
        ✓ 일시정지된 키퍼 없음 — 모든 키퍼가 정상 운영 중입니다
      </div>
    `
  }

  return html`
    <div class="flex flex-col gap-4">
      ${pausedKeepers.length > 0 ? html`
        <div>
          <div class="mb-2 text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">
            현재 일시정지 (${pausedKeepers.length})
          </div>
          <div class="flex flex-col gap-2" role="list">
            ${pausedKeepers.map(k => {
              const s = summaryMap.get(k.name)
              return html`
                <div
                  key=${k.name}
                  class="flex flex-wrap items-center gap-3 rounded border border-[var(--paused-20)] bg-[var(--paused-10)] px-4 py-2.5"
                  role="listitem"
                >
                  <div class="font-mono text-xs font-semibold text-[var(--paused)]">
                    ⏸ ${k.name}
                  </div>
                  <div class="flex flex-wrap gap-2 text-2xs text-[var(--color-fg-muted)]">
                    ${s ? html`
                      ${s.storm_pauses > 0 ? html`
                        <span class="rounded bg-[var(--bad-10)] px-1.5 py-0.5 text-[var(--bad-light)]">
                          storm pause ${s.storm_pauses}
                        </span>
                      ` : null}
                      ${s.budget_loop_pauses > 0 ? html`
                        <span class="rounded bg-[var(--bad-10)] px-1.5 py-0.5 text-[var(--bad-light)]">
                          budget loop pause ${s.budget_loop_pauses}
                        </span>
                      ` : null}
                      ${s.stale_total > 0 ? html`
                        <span class="rounded bg-[var(--warn-10)] px-1.5 py-0.5 text-[var(--color-status-warn)]">
                          stale 종료 ${s.stale_total}
                        </span>
                      ` : null}
                    ` : null}
                    <button
                      class="rounded bg-[var(--accent-10)] px-2 py-0.5 text-[var(--color-accent-fg)] hover:bg-[var(--accent-20)] transition-colors"
                      onClick=${(e: Event) => {
                        e.stopPropagation()
                        navigate('monitoring', { section: 'agents', keeper: k.name })
                      }}
                    >상세 보기 →</button>
                  </div>
                </div>
              `
            })}
          </div>
        </div>
      ` : null}

      ${summaries.some(s => s.storm_pauses > 0 || s.budget_loop_pauses > 0) ? html`
        <div>
          <div class="mb-2 text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">
            자동 일시정지 이력 (Prometheus)
          </div>
          <div class="overflow-x-auto">
            <table class="w-full text-xs" aria-label="자동 일시정지 이력">
              <thead>
                <tr class="border-b border-[var(--color-border-default)] text-left text-[var(--color-fg-muted)]">
                  <th scope="col" class="pb-2 pr-3 font-normal">키퍼</th>
                  <th scope="col" class="pb-2 pr-3 font-normal text-right">storm pause</th>
                  <th scope="col" class="pb-2 pr-3 font-normal text-right">budget loop pause</th>
                  <th scope="col" class="pb-2 pr-3 font-normal text-right">budget strike</th>
                  <th scope="col" class="pb-2 font-normal text-right">stale 종료</th>
                </tr>
              </thead>
              <tbody>
                ${summaries
                  .filter(s => s.storm_pauses > 0 || s.budget_loop_pauses > 0 || s.budget_strikes > 0)
                  .map(s => html`
                    <tr key=${s.keeper} class="border-b border-[var(--color-border-default)]/40 hover:bg-[var(--color-bg-surface)]">
                      <td class="py-1.5 pr-3">
                        <button
                          class="font-mono text-[var(--color-accent-fg)] hover:underline"
                          onClick=${() => navigate('monitoring', { section: 'agents', keeper: s.keeper })}
                        >${s.keeper}</button>
                      </td>
                      <td class="py-1.5 pr-3 text-right tabular-nums ${s.storm_pauses > 0 ? 'text-[var(--bad-light)]' : 'text-[var(--color-fg-muted)]'}">
                        ${s.storm_pauses}
                      </td>
                      <td class="py-1.5 pr-3 text-right tabular-nums ${s.budget_loop_pauses > 0 ? 'text-[var(--bad-light)]' : 'text-[var(--color-fg-muted)]'}">
                        ${s.budget_loop_pauses}
                      </td>
                      <td class="py-1.5 pr-3 text-right tabular-nums ${s.budget_strikes > 0 ? 'text-[var(--color-status-warn)]' : 'text-[var(--color-fg-muted)]'}">
                        ${s.budget_strikes}
                      </td>
                      <td class="py-1.5 text-right tabular-nums ${s.stale_total > 0 ? 'text-[var(--color-status-warn)]' : 'text-[var(--color-fg-muted)]'}">
                        ${s.stale_total}
                      </td>
                    </tr>
                  `)
                }
              </tbody>
            </table>
          </div>
        </div>
      ` : null}
    </div>
  `
}

/** Proactive skip reasons panel. */
function ProactiveSkipPanel({ rows }: { rows: ProactiveSkipRow[] }) {
  if (rows.length === 0) {
    return html`
      <div class="rounded border border-[var(--ok-20)] bg-[var(--ok-10)] px-4 py-3 text-xs text-[var(--color-status-ok)]">
        ✓ 프로액티브 스킵 없음 — 모든 프로액티브 턴이 정상 실행 중입니다
      </div>
    `
  }

  // Group by reason for the summary row.
  const byReason = new Map<string, number>()
  for (const r of rows) {
    byReason.set(r.reason, (byReason.get(r.reason) ?? 0) + r.count)
  }
  const reasonSummary = [...byReason.entries()]
    .sort((a, b) => b[1] - a[1])

  return html`
    <div class="flex flex-col gap-4">
      <div>
        <div class="mb-2 text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">
          이유별 스킵 합계
        </div>
        <div class="flex flex-wrap gap-2">
          ${reasonSummary.map(([reason, total]) => html`
            <span
              key=${reason}
              class="inline-flex items-center gap-1.5 rounded-sm border border-[var(--warn-20)] bg-[var(--warn-10)] px-2.5 py-1 text-2xs font-medium text-[var(--color-status-warn)]"
            >
              <span class="font-mono">${reason}</span>
              <span class="font-semibold tabular-nums">${total}</span>
            </span>
          `)}
        </div>
      </div>

      <div>
        <div class="mb-2 text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">
          키퍼별 스킵 이유
        </div>
        <div class="overflow-x-auto">
          <table class="w-full text-xs" aria-label="프로액티브 스킵 이유 상세">
            <thead>
              <tr class="border-b border-[var(--color-border-default)] text-left text-[var(--color-fg-muted)]">
                <th scope="col" class="pb-2 pr-3 font-normal">키퍼</th>
                <th scope="col" class="pb-2 pr-3 font-normal">이유</th>
                <th scope="col" class="pb-2 font-normal text-right">횟수</th>
              </tr>
            </thead>
            <tbody>
              ${rows.map((r, i) => html`
                <tr key="${r.keeper}-${r.reason}-${i}" class="border-b border-[var(--color-border-default)]/40 hover:bg-[var(--color-bg-surface)]">
                  <td class="py-1.5 pr-3">
                    <button
                      class="font-mono text-[var(--color-accent-fg)] hover:underline"
                      onClick=${() => navigate('monitoring', { section: 'agents', keeper: r.keeper })}
                    >${r.keeper}</button>
                  </td>
                  <td class="py-1.5 pr-3">
                    <span class="rounded bg-[var(--warn-10)] px-1.5 py-0.5 font-mono text-[var(--color-status-warn)]">
                      ${r.reason}
                    </span>
                  </td>
                  <td class="py-1.5 text-right tabular-nums font-semibold ${r.count > 0 ? 'text-[var(--color-status-warn)]' : 'text-[var(--color-fg-muted)]'}">
                    ${r.count}
                  </td>
                </tr>
              `)}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  `
}

/** Stale termination / batch event panel. */
function StaleTerminationPanel({
  summaries,
  batchRows,
}: {
  summaries: KeeperStopSummary[]
  batchRows: BatchTerminationRow[]
}) {
  const hasData = summaries.some(s => s.stale_total > 0) || batchRows.length > 0

  if (!hasData) {
    return html`
      <div class="rounded border border-[var(--ok-20)] bg-[var(--ok-10)] px-4 py-3 text-xs text-[var(--color-status-ok)]">
        ✓ stale 종료 없음 — 이번 실행에 stale 종료 이벤트가 없습니다
      </div>
    `
  }

  return html`
    <div class="flex flex-col gap-4">
      ${batchRows.length > 0 ? html`
        <div>
          <div class="mb-2 text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">
            플릿 배치 종료 이벤트
          </div>
          <div class="flex flex-wrap gap-2">
            ${batchRows.map(r => html`
              <span
                key=${r.batch}
                class="inline-flex items-center gap-1.5 rounded-sm border border-[var(--bad-20)] bg-[var(--bad-10)] px-2.5 py-1 text-2xs font-medium text-[var(--bad-light)]"
              >
                <span class="font-mono">${r.batch}</span>
                <span class="font-semibold tabular-nums">${r.count}</span>
              </span>
            `)}
          </div>
        </div>
      ` : null}

      ${summaries.some(s => s.stale_total > 0) ? html`
        <div>
          <div class="mb-2 text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)]">
            키퍼별 stale 종료 상세
          </div>
          <div class="overflow-x-auto">
            <table class="w-full text-xs" aria-label="stale 종료 상세">
              <thead>
                <tr class="border-b border-[var(--color-border-default)] text-left text-[var(--color-fg-muted)]">
                  <th scope="col" class="pb-2 pr-3 font-normal">키퍼</th>
                  <th scope="col" class="pb-2 pr-3 font-normal text-right">stale 합계</th>
                  <th scope="col" class="pb-2 pr-3 font-normal text-right">idle_turn</th>
                  <th scope="col" class="pb-2 pr-3 font-normal text-right">in_turn_hung</th>
                  <th scope="col" class="pb-2 font-normal text-right">noop_failure_loop</th>
                </tr>
              </thead>
              <tbody>
                ${summaries
                  .filter(s => s.stale_total > 0)
                  .map(s => html`
                    <tr key=${s.keeper} class="border-b border-[var(--color-border-default)]/40 hover:bg-[var(--color-bg-surface)]">
                      <td class="py-1.5 pr-3">
                        <button
                          class="font-mono text-[var(--color-accent-fg)] hover:underline"
                          onClick=${() => navigate('monitoring', { section: 'agents', keeper: s.keeper })}
                        >${s.keeper}</button>
                      </td>
                      <td class="py-1.5 pr-3 text-right tabular-nums font-semibold text-[var(--bad-light)]">
                        ${s.stale_total}
                      </td>
                      <td class="py-1.5 pr-3 text-right tabular-nums ${s.idle_turn > 0 ? 'text-[var(--color-status-warn)]' : 'text-[var(--color-fg-muted)]'}">
                        ${s.idle_turn}
                      </td>
                      <td class="py-1.5 pr-3 text-right tabular-nums ${s.in_turn_hung > 0 ? 'text-[var(--bad-light)]' : 'text-[var(--color-fg-muted)]'}">
                        ${s.in_turn_hung}
                      </td>
                      <td class="py-1.5 text-right tabular-nums ${s.noop_failure_loop > 0 ? 'text-[var(--color-status-warn)]' : 'text-[var(--color-fg-muted)]'}">
                        ${s.noop_failure_loop}
                      </td>
                    </tr>
                  `)
                }
              </tbody>
            </table>
          </div>
        </div>
      ` : null}
    </div>
  `
}

// ── View type ──────────────────────────────────────────────────────────────

type ReactivityView = 'health' | 'lifecycle' | 'events' | 'pause' | 'proactive' | 'stale'

const VIEW_CHIPS: Array<{ key: ReactivityView; label: string; title?: string }> = [
  { key: 'health',           label: '상태 그리드',     title: '전체 키퍼 phase/활동 빠른 뷰' },
  { key: 'lifecycle',        label: '상태 전환',       title: '키퍼 FSM 전환 타임라인' },
  { key: 'events', label: '생명주기 이벤트', title: '수퍼바이저 생명주기 이벤트 (Started, Restarted, Dead_cleaned 등)' },
  { key: 'pause',            label: '자동 일시정지',   title: '스톰/버짓 자동 일시정지 이벤트' },
  { key: 'proactive',        label: '프로액티브 스킵', title: '프로액티브 스케줄러 스킵 이유' },
  { key: 'stale',            label: 'Stale 종료',      title: '키퍼별 stale 종료 클래스 분포' },
]

// ── Main component ─────────────────────────────────────────────────────────

/** Keeper Reactivity Monitor — real-time keeper lifecycle observability. */
export function KeeperReactivityMonitor({ defaultView }: { defaultView?: ReactivityView }) {
  const activeView = useSignal<ReactivityView>(defaultView ?? 'health')
  const metricsLoading = useSignal(false)
  const metricsError = useSignal<string | null>(null)
  const parsedMetrics = useSignal<ParsedMetric[]>([])
  const metricsUpdatedAt = useSignal<string | null>(null)
  // Monotonic generation counter: each fetch increments it; stale responses
  // from earlier concurrent calls are discarded when they arrive out of order.
  const loadGen = useRef(0)

  async function loadMetrics() {
    const gen = ++loadGen.current
    metricsLoading.value = true
    metricsError.value = null
    try {
      const text = await fetchMetricsText()
      if (gen !== loadGen.current) return  // a newer request superseded this one
      parsedMetrics.value = parsePrometheusText(text)
      metricsUpdatedAt.value = new Date().toLocaleTimeString('ko-KR')
    } catch (e) {
      if (gen !== loadGen.current) return  // stale error — discard
      metricsError.value = e instanceof Error ? e.message : String(e)
    } finally {
      if (gen === loadGen.current) metricsLoading.value = false
    }
  }

  useEffect(() => {
    if (activeView.value !== 'lifecycle' && activeView.value !== 'events') {
      void loadMetrics()
    } else if (activeView.value === 'lifecycle') {
      void refreshKeeperPhaseTimeline()
    } else {
      void refreshKeeperLifecycleTimeline()
    }
  }, [activeView.value])

  const allKeepers = keepers.value
  const stopSummaries = extractKeeperStopSummaries(parsedMetrics.value)
  const proactiveRows = extractProactiveSkips(parsedMetrics.value)
  const batchRows = extractBatchTerminations(parsedMetrics.value)

  const isNonLifecycle = activeView.value !== 'lifecycle' && activeView.value !== 'events'

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center justify-between">
        <div class="flex flex-col gap-0.5">
          <h3 class="text-sm font-semibold text-[var(--color-fg-secondary)]">키퍼 반응성 모니터</h3>
        </div>
        ${isNonLifecycle ? html`
          <div class="flex items-center gap-2">
            ${metricsUpdatedAt.value ? html`
              <span class="text-2xs text-[var(--color-fg-muted)]">${metricsUpdatedAt.value}</span>
            ` : null}
            <button
              class="rounded border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-1.5 text-2xs text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-panel-alt)] transition-colors disabled:opacity-50"
              onClick=${() => void loadMetrics()}
              disabled=${metricsLoading.value}
              aria-label="메트릭 새로고침"
            >
              ${metricsLoading.value ? '불러오는 중...' : '새로고침'}
            </button>
          </div>
        ` : null}
      </div>

      <${FilterChips}
        chips=${VIEW_CHIPS}
        value=${activeView.value}
        onChange=${(v: ReactivityView) => { activeView.value = v }}
        size="sm"
        tone="accent"
      />

      ${metricsError.value && isNonLifecycle ? html`
        <${ErrorRecoverable}
          title="Prometheus 메트릭을 불러오지 못했습니다"
          detail=${metricsError.value}
          onRetry=${() => { void loadMetrics() }}
        />
      ` : metricsLoading.value && parsedMetrics.value.length === 0 && isNonLifecycle ? html`
        <${LoadingState}>Prometheus 메트릭 불러오는 중...<//>
      ` : html`
        <div>
          ${activeView.value === 'health'
            ? html`
              <div class="flex flex-col gap-4">
                <${HealthGrid} allKeepers=${allKeepers} />
                <div>
                  <div class="text-2xs font-semibold uppercase tracking-wider text-[var(--color-fg-muted)] mb-2">재시작 예산 게이지</div>
                  <${TurnBudgetGaugePanel} keepers=${allKeepers} />
                </div>
              </div>
            `
          : activeView.value === 'lifecycle'
            ? html`<${KeeperPhaseTimeline} />`
          : activeView.value === 'events'
            ? html`<${KeeperLifecycleTimeline} />`
          : activeView.value === 'pause'
            ? html`<${AutoPausePanel} allKeepers=${allKeepers} summaries=${stopSummaries} />`
          : activeView.value === 'proactive'
            ? html`<${ProactiveSkipPanel} rows=${proactiveRows} />`
          : html`<${StaleTerminationPanel} summaries=${stopSummaries} batchRows=${batchRows} />`}
        </div>
      `}
    </div>
  `
}
