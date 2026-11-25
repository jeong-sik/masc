/**
 * `⌘T` Queue & Context Read-Only Quick-Peek Content.
 *
 * Rendered inside the single shell-hosted `QuickPeekDrawer` (`[⤢]` wide expand).
 * Strictly read-only — links to `/work/inbox` or `/keepers` for actions.
 */

import { html } from 'htm/preact'
import { InlineSpinner } from '../components/common/inline-spinner'
import { MarkdownContent } from '../components/common/markdown-renderer'
import { activeScheduleRead, subscribeActiveSchedulesRefresh } from '../components/schedule/schedule-state'
import type { VNode } from 'preact'
import { useEffect } from 'preact/hooks'
import { isAuthenticated, sessionEpoch } from '../core/auth'
import { formatObserved, resourceCache } from '../core/resource-cache'
import { apiGet } from '../core/transport'
import { formatTimestampKo } from '../lib/format-time'
import { navigate } from '../routes/router'
import {
  closeActiveOverlay,
  effectiveHitlSourceStatus,
  formatInboxPendingCount,
  inboxPendingCount,
  inboxUncheckedSources,
  pendingApprovals,
  pendingAsks,
  pendingGateApprovals,
  pendingGoalConfirmations,
  pendingVerifications,
  refreshPendingHitl,
  uncheckedHitlStatusLabel,
  type HitlSourceState,
} from './shell-state'

interface ShellQueueSummary {
  readonly keepers: number | null
  readonly tasks: number | null
  readonly agents: number | null
  readonly pendingApprovals: number
  readonly pendingAsks: number
}

interface QuickPeekSchedule {
  readonly id: string
  readonly summary: string
  readonly summaryIsProse: boolean
  readonly keeper: string | null
  readonly dueAt: string | null
  readonly status: string
}

const SHELL_CACHE_KEY = 'shell:queue-context'

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function asNumberOrNull(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null
}

function asStr(v: unknown): string | null {
  return typeof v === 'string' && v.trim().length > 0 ? v.trim() : null
}

function decodeShellSummary(raw: unknown): ShellQueueSummary {
  const counts = isRecord(raw) && isRecord(raw.counts) ? raw.counts : null
  return {
    keepers: asNumberOrNull(counts?.keepers),
    tasks: asNumberOrNull(counts?.tasks),
    agents: asNumberOrNull(counts?.agents),
    pendingApprovals: pendingApprovals.peek().length,
    pendingAsks: pendingAsks.peek().length,
  }
}

const MAX_QPEEK_PREVIEW = 10
const MAX_SCHEDULE_PREVIEW = 5

function formatScheduleDue(isoRaw: unknown, unixRaw: unknown): string | null {
  const iso = asStr(isoRaw)
  if (iso) return iso
  const unix = asNumberOrNull(unixRaw)
  if (unix !== null && unix > 0) {
    try {
      return new Date(unix * 1000).toISOString()
    } catch {
      return null
    }
  }
  return null
}

function quickPeekSchedule(raw: unknown): QuickPeekSchedule[] {
  if (!isRecord(raw)) return []
  const id = asStr(raw.schedule_id)
  if (!id) return []
  const summary = asStr(raw.payload_summary)
  return [{
    id,
    summary: summary ?? id,
    summaryIsProse: summary !== null && raw.payload_kind === 'masc.keeper_wake',
    keeper: asStr(raw.payload_keeper_name) ?? asStr(raw.payload_target),
    dueAt: formatScheduleDue(raw.next_due_at_iso, raw.next_due_at) ?? formatScheduleDue(raw.due_at_iso, raw.due_at),
    status: asStr(raw.status) ?? '미보고',
  }]
}

export function QueueContextOverlayBody(): VNode {
  const authed = isAuthenticated.value
  const epoch = sessionEpoch.value
  const approvals = pendingApprovals.value
  const asks = pendingAsks.value
  const gates = pendingGateApprovals.value
  const goalConfirms = pendingGoalConfirmations.value
  const verifications = pendingVerifications.value
  const totalHitl = inboxPendingCount.value
  const sourceStatus = effectiveHitlSourceStatus.value
  const inboxUnchecked = inboxUncheckedSources.value
  const observed = resourceCache.observe<ShellQueueSummary>(SHELL_CACHE_KEY).value
  const { observation: schedules, loading: schedulesLoading, error: schedulesError } = activeScheduleRead.value
  const schedulePage = schedules?.projection.page
  const scheduleRows = schedules?.projection.data.requests.flatMap(quickPeekSchedule).slice(0, MAX_SCHEDULE_PREVIEW) ?? []
  const lastSchedules = schedules !== null && (schedulesLoading || schedulesError !== null)
  const scheduleCount = schedulePage
    ? `${schedulePage.totalCount}${lastSchedules ? ' · 마지막 확인' : ''}`
    : schedulesError ? '조회 실패' : '…'

  const sectionCountLabel = (count: number, st: HitlSourceState): string => {
    if (st.kind === 'ok') return String(count)
    const status = uncheckedHitlStatusLabel(st)
    return count > 0 ? `${count} · ${status}` : status
  }

  useEffect(() => {
    if (!authed) return
    void resourceCache.fetch(
      SHELL_CACHE_KEY,
      (signal) => apiGet<ShellQueueSummary>('/api/v1/dashboard/shell', {
        signal,
        decode: decodeShellSummary,
      }),
      { ttlMs: 10_000, topics: ['workspace_dataset_changed', 'keeper_heartbeat'], reason: 'mount' },
    )
    void refreshPendingHitl()
  }, [authed, epoch])
  useEffect(() => authed ? subscribeActiveSchedulesRefresh() : undefined, [authed])

  const formatMetric = (value: number | null | undefined): string => {
    if (observed.kind !== 'value') return formatObserved(observed)
    return value === null || value === undefined ? '미보고' : String(value)
  }

  return html`
    <div class="ap-qpeek-stack" data-testid="queue-context-overlay">
      <div class="ap-qpeek-banner">
        Read-Only Queue & Context Quick-Peek — mutations live in Unified Inbox & Keepers.
      </div>

      ${!authed
        ? html`<p class="ap-muted">인증 후 활성 큐와 컨텍스트 요약을 표시합니다.</p>`
        : html`
            <div class="ap-mini-kpis">
              <div class="ap-mini-kpi">
                <span class="ap-mini-kpi-k">Keepers</span>
                <strong class="ap-mini-kpi-v tnum">${formatMetric(observed.kind === 'value' ? observed.data.keepers : null)}</strong>
              </div>
              <div class="ap-mini-kpi">
                <span class="ap-mini-kpi-k">Tasks</span>
                <strong class="ap-mini-kpi-v tnum">${formatMetric(observed.kind === 'value' ? observed.data.tasks : null)}</strong>
              </div>
              <div class="ap-mini-kpi">
                <span class="ap-mini-kpi-k">HITL Queue</span>
                <strong class="ap-mini-kpi-v tnum">
                  ${formatInboxPendingCount(totalHitl, inboxUnchecked.length > 0)}
                </strong>
                ${verifications.length > 0 && html`
                  <span class="ap-mini-kpi-sub tnum">+${verifications.length} verif</span>
                `}
                ${sourceStatus.verification.kind !== 'ok' && html`
                  <span class="ap-mini-kpi-sub">
                    검증 ${uncheckedHitlStatusLabel(sourceStatus.verification)}
                  </span>
                `}
              </div>
              <div class="ap-mini-kpi">
                <span class="ap-mini-kpi-k">Schedules</span>
                <strong class="ap-mini-kpi-v tnum">
                  ${scheduleCount}
                </strong>
              </div>
            </div>

            <section class="ap-qpeek-section">
              <header class="ap-qpeek-section-head">
                <h3>Pending Tool Approvals (${sectionCountLabel(approvals.length, sourceStatus.approvals)})</h3>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${() => { closeActiveOverlay(); navigate('/work/inbox') }}
                >
                  Open Inbox →
                </button>
              </header>
              ${sourceStatus.approvals.kind === 'failed' && html`
                <p class="ap-error" role="alert">도구 승인 조회 실패: ${sourceStatus.approvals.message}</p>
              `}
              ${sourceStatus.approvals.kind === 'unbridged'
                ? html`<p class="ap-muted" role="note">멀티 계정 세션에서는 도구 승인 대기열을 조회할 수 없어 미확인 상태입니다.</p>`
                : approvals.length === 0
                  ? (sourceStatus.approvals.kind === 'ok'
                      ? html`<p class="ap-muted">대기 중인 도구 승인 요청이 없습니다.</p>`
                      : null)
                  : html`
                      <ul class="ap-qpeek-list">
                        ${approvals.slice(0, MAX_QPEEK_PREVIEW).map((item) => html`
                          <li key=${item.approvalId} class="ap-qpeek-card">
                            <div class="ap-qpeek-card-top">
                              <strong>${item.keeper}</strong>
                              <code class="mono">${item.tool || item.toolCallId}</code>
                            </div>
                            ${item.question && html`<${MarkdownContent} class="ap-qpeek-card-text" text=${item.question} />`}
                            <div class="ap-qpeek-card-meta mono">
                              req=${item.approvalId} · rev=${item.revision}
                            </div>
                          </li>
                        `)}
                      </ul>
                      ${approvals.length > MAX_QPEEK_PREVIEW && html`
                        <p class="ap-muted">상위 ${MAX_QPEEK_PREVIEW}건 표시 (전체 ${approvals.length}건)</p>
                      `}
                    `}
            </section>

            <section class="ap-qpeek-section">
              <header class="ap-qpeek-section-head">
                <h3>Open Keeper Asks (${sectionCountLabel(asks.length, sourceStatus.asks)})</h3>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${() => { closeActiveOverlay(); navigate('/keepers') }}
                >
                  Open Keepers →
                </button>
              </header>
              ${sourceStatus.asks.kind === 'failed' && html`
                <p class="ap-error" role="alert">Keeper 질문 조회 실패: ${sourceStatus.asks.message}</p>
              `}
              ${sourceStatus.asks.kind === 'unbridged'
                ? html`<p class="ap-muted" role="note">멀티 계정 세션에서는 Keeper 질문 대기열을 조회할 수 없어 미확인 상태입니다.</p>`
                : asks.length === 0
                  ? (sourceStatus.asks.kind === 'ok'
                      ? html`<p class="ap-muted">대기 중인 Keeper 질문이 없습니다.</p>`
                      : null)
                  : html`
                      <ul class="ap-qpeek-list">
                        ${asks.slice(0, MAX_QPEEK_PREVIEW).map((ask) => html`
                          <li key=${ask.askId} class="ap-qpeek-card">
                            <div class="ap-qpeek-card-top">
                              <strong>${ask.keeper}</strong>
                              <span class="mono ap-muted">${ask.askId}</span>
                            </div>
                            <${MarkdownContent} class="ap-qpeek-card-text" text=${ask.prompt} />
                          </li>
                        `)}
                      </ul>
                      ${asks.length > MAX_QPEEK_PREVIEW && html`
                        <p class="ap-muted">상위 ${MAX_QPEEK_PREVIEW}건 표시 (전체 ${asks.length}건)</p>
                      `}
                    `}
            </section>

            ${(gates.length > 0 || sourceStatus.gate.kind !== 'ok') && html`
              <section class="ap-qpeek-section">
                <header class="ap-qpeek-section-head">
                  <h3>Channel Gate Approvals (${sectionCountLabel(gates.length, sourceStatus.gate)})</h3>
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${() => { closeActiveOverlay(); navigate('/work/inbox') }}
                  >
                    Open Inbox →
                  </button>
                </header>
                ${sourceStatus.gate.kind === 'failed' && html`
                  <p class="ap-error" role="alert">Channel Gate 조회 실패: ${sourceStatus.gate.message}</p>
                `}
                ${sourceStatus.gate.kind === 'unbridged' && html`
                  <p class="ap-muted" role="note">멀티 계정 세션에서는 Channel Gate 대기열을 조회할 수 없어 미확인 상태입니다.</p>
                `}
                ${gates.length > 0 && html`
                  <ul class="ap-qpeek-list">
                    ${gates.slice(0, MAX_QPEEK_PREVIEW).map((gate) => html`
                      <li key=${gate.id} class="ap-qpeek-card">
                        <div class="ap-qpeek-card-top">
                          <strong>${gate.keeper}</strong>
                          <code class="mono">${gate.toolName}</code>
                        </div>
                        <div class="ap-qpeek-card-meta mono">
                          phase=${gate.phase}${gate.waitingSec !== null ? ` · wait ${Math.round(gate.waitingSec)}s` : ''}
                        </div>
                      </li>
                    `)}
                  </ul>
                  ${gates.length > MAX_QPEEK_PREVIEW && html`
                    <p class="ap-muted">상위 ${MAX_QPEEK_PREVIEW}건 표시 (전체 ${gates.length}건)</p>
                  `}
                `}
              </section>
            `}

            ${(goalConfirms.length > 0 || sourceStatus.planning.kind !== 'ok') && html`
              <section class="ap-qpeek-section">
                <header class="ap-qpeek-section-head">
                  <h3>Goal Confirmations (${sectionCountLabel(goalConfirms.length, sourceStatus.planning)})</h3>
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${() => { closeActiveOverlay(); navigate('/work/inbox') }}
                  >
                    Open Inbox →
                  </button>
                </header>
                ${sourceStatus.planning.kind === 'failed' && html`
                  <p class="ap-error" role="alert">Goal 확인 대기열 조회 실패: ${sourceStatus.planning.message}</p>
                `}
                ${goalConfirms.length > 0 && html`
                  <ul class="ap-qpeek-list">
                    ${goalConfirms.slice(0, MAX_QPEEK_PREVIEW).map((goal) => html`
                      <li key=${goal.goalId} class="ap-qpeek-card">
                        <div class="ap-qpeek-card-top">
                          <strong>${goal.title}</strong>
                          <span class="mono ap-muted">${goal.goalId}</span>
                        </div>
                      </li>
                    `)}
                  </ul>
                  ${goalConfirms.length > MAX_QPEEK_PREVIEW && html`
                    <p class="ap-muted">상위 ${MAX_QPEEK_PREVIEW}건 표시 (전체 ${goalConfirms.length}건)</p>
                  `}
                `}
              </section>
            `}

            ${(verifications.length > 0 || sourceStatus.verification.kind !== 'ok') && html`
              <section class="ap-qpeek-section">
                <header class="ap-qpeek-section-head">
                  <h3>Awaiting Verifications (${sectionCountLabel(verifications.length, sourceStatus.verification)})</h3>
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${() => { closeActiveOverlay(); navigate('/work/tasks') }}
                  >
                    Open Tasks →
                  </button>
                </header>
                ${sourceStatus.verification.kind === 'failed' && html`
                  <p class="ap-error" role="alert">검증 대기열 조회 실패: ${sourceStatus.verification.message}</p>
                `}
                ${sourceStatus.verification.kind === 'unbridged' && html`
                  <p class="ap-muted" role="note">멀티 계정 세션에서는 검증 대기열을 조회할 수 없어 미확인 상태입니다.</p>
                `}
                ${verifications.length > 0 && html`
                  <ul class="ap-qpeek-list">
                    ${verifications.slice(0, MAX_QPEEK_PREVIEW).map((v) => html`
                      <li key=${v.requestId} class="ap-qpeek-card">
                        <div class="ap-qpeek-card-top">
                          <strong>${v.title}</strong>
                          <span class="mono ap-muted">${v.taskId}</span>
                        </div>
                        ${v.worker && html`<div class="ap-qpeek-card-meta mono">by=${v.worker}</div>`}
                      </li>
                    `)}
                  </ul>
                  ${verifications.length > MAX_QPEEK_PREVIEW && html`
                    <p class="ap-muted">상위 ${MAX_QPEEK_PREVIEW}건 표시 (전체 ${verifications.length}건)</p>
                  `}
                `}
              </section>
            `}

            <section class="ap-qpeek-section">
              <header class="ap-qpeek-section-head">
                <h3>Upcoming Schedules (${scheduleCount})</h3>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${() => { closeActiveOverlay(); navigate('/work/tasks?view=schedules') }}
                >
                  Open Schedules →
                </button>
              </header>
              ${schedulesLoading && html`
                <p class="ap-muted" role="status">
                  <${InlineSpinner} /> ${schedules ? '예약 갱신 중…' : '예약 불러오는 중…'}
                </p>
              `}
              ${schedulesError && html`<p class="ap-error" role="alert">예약 조회 실패 · ${schedulesError}</p>`}
              ${!schedules && !schedulesLoading && !schedulesError && html`
                <p class="ap-muted">예약 조회 대기 중</p>
              `}
              ${schedules && lastSchedules && html`
                <p class="ap-muted">마지막 확인 · <time dateTime=${new Date(schedules.observedAt).toISOString()}>
                  ${formatTimestampKo(schedules.observedAt / 1000)}
                </time></p>
              `}
              ${schedulePage?.totalCount === 0 && html`
                <p class="ap-muted">${lastSchedules ? '마지막 조회에 활성 예약이 없었습니다.' : '활성 예약 자동화가 없습니다.'}</p>
              `}
              ${scheduleRows.length > 0 && html`
                <ul class="ap-qpeek-list">
                  ${scheduleRows.map((s) => html`
                    <li key=${s.id} class="ap-qpeek-card">
                      <div class="ap-qpeek-card-top">
                        <strong>${s.keeper ?? s.id}</strong>
                        <span class="mono ap-muted">${s.status}</span>
                      </div>
                      ${s.summaryIsProse
                        ? html`<${MarkdownContent} class="ap-qpeek-card-text" text=${s.summary} />`
                        : html`<p class="ap-qpeek-card-text">${s.summary}</p>`}
                      ${s.dueAt && html`<div class="ap-qpeek-card-meta mono">due=${s.dueAt}</div>`}
                    </li>
                  `)}
                </ul>
              `}
              ${schedulePage && (schedulePage.truncated || scheduleRows.length < schedulePage.totalCount) && html`
                <p class="ap-muted">표시 제한으로 일부 예약만 표시됩니다. 전체 목록은 Schedules에서 확인하세요.</p>
              `}
            </section>
          `}
    </div>
  `
}
