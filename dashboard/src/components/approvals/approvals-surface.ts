// MASC Dashboard — Gate / HITL Surface
// Pending external effects wait here for Human judgment without blocking the
// Keeper lane. Exact Always rules and Auto Judge share this same Gate contract.
//
// Data source: gateData.value?.approval_queue (KeeperApprovalQueueItem[]).
// Actions: respondToKeeperApproval(id, 'approve' | 'reject', rememberRule).
// The live decision model is the closed set {approve, reject} (+ rememberRule);
// there is no defer/undo endpoint, so the prototype's 보류/되돌리기 controls are
// intentionally not rendered. History is read-only from recent_resolved.
// Visual layout ports the keeper-v2 .ap-* design.

import { html } from 'htm/preact'
import { Fragment } from 'preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import type {
  KeeperApprovalQueueItem,
  KeeperApprovalRule,
  KeeperApprovalRulesState,
  KeeperGateModeOverride,
  KeeperExactLanePreference,
  KeeperGateSettingsState,
  KeeperResolvedApprovalItem,
  KeeperResolvedApprovalPage,
  GateDecisionSource,
  GateMode,
  HitlContextSummary,
  KeeperAutoJudgeRearmExpectation,
  KeeperExactAttemptState,
  KeeperSummaryAttemptDisposition,
} from '../../types'
import { TELEMETRY_AUTO_REFRESH_MS } from '../../config/constants'
import { setupVisibleAutoRefresh } from '../../lib/auto-refresh'
import { formatDateTimeKo, formatDurationCompound } from '../../lib/format-time'
import {
  keeperResolvedApprovalDecisionClass,
  keeperResolvedApprovalDecisionTone,
  keeperResolvedApprovalDecisionLabel,
  type KeeperResolvedApprovalDecision,
} from '../../lib/keeper-approval-decision'
import { navigate } from '../../router'
import { AgentAvatar } from '../overview/agent-avatar'
import { LoadingState } from '../common/feedback-state'
import {
  gateData,
  gateError,
  gateLoading,
  gateApprovalActing,
  gateAuditWriteFailures,
  clearGateAuditWriteFailures,
  deleteKeeperApprovalRule,
  refreshGate,
  respondToKeeperApproval,
  retryKeeperAutoJudge,
  setKeeperExternalGateMode,
  setKeeperGateMode,
} from '../gate-store'

function ApprovalAuditWriteFailureAlert() {
  const notices = gateAuditWriteFailures.value
  if (notices.length === 0) return null
  return html`
    <section
      class="ap-error ap-audit-write-alert sev-bad"
      role="alert"
      data-testid="approval-audit-write-unavailable"
    >
      <strong><span aria-hidden="true">!</span> 권한 변경은 커밋됐지만 감사 기록은 저장되지 않았습니다</strong>
      <span>재실행하지 마세요. 아래 receipt는 실제 변경 성공과 감사 저장 실패를 함께 증명합니다.</span>
      ${notices.map(notice => html`
        <div class="ap-audit-failure" key=${`${notice.id ?? '-'}:${notice.receipt.event}:${notice.observed_at}`}>
          <span class="mono">
            ${notice.receipt.event} · ${notice.receipt.stage} ·
            ${notice.id ?? 'id 없음'} · ${notice.transport.toUpperCase()} ·
            관측 ${formatDateTimeKo(notice.observed_at)}
          </span>
          <span>${notice.receipt.detail}</span>
          <details>
            <summary>RAW receipt</summary>
            <pre data-testid="approval-audit-write-raw">${JSON.stringify(notice.receipt, null, 2)}</pre>
          </details>
        </div>
      `)}
      <button type="button" class="ap-viewbtn" onClick=${clearGateAuditWriteFailures}>
        확인 후 숨기기
      </button>
    </section>
  `
}

type ApprovalsView = 'queue' | 'history'
type ApprovalHistoryFilter = 'all' | KeeperResolvedApprovalDecision | GateDecisionSource

// Design pill order (keeper-v2 approvals.jsx AP_HIST_FILTERS): decision pills
// first, then decider pills. The design's 보류 pill is omitted — the live
// decision model is the closed {approve, reject} set (see file header); the
// decider pills are backed by the live decision_source field.
const APPROVAL_HISTORY_FILTERS: ReadonlyArray<{
  id: ApprovalHistoryFilter
  label: string
  predicate: (item: KeeperResolvedApprovalItem) => boolean
}> = [
  { id: 'all', label: '전체', predicate: () => true },
  { id: 'approve', label: '승인', predicate: item => item.decision === 'approve' },
  { id: 'reject', label: '거부', predicate: item => item.decision === 'reject' },
  { id: 'human_operator', label: 'HITL 수동', predicate: item => item.decision_source === 'human_operator' },
  { id: 'auto_judge', label: 'Auto Judge', predicate: item => item.decision_source === 'auto_judge' },
  { id: 'always_allowed', label: 'Always', predicate: item => item.decision_source === 'always_allowed' },
]
const DEFAULT_APPROVAL_HISTORY_FILTER = APPROVAL_HISTORY_FILTERS[0]!

// Aside preview caps. The recent list is a preview of recent_resolved — the full
// set lives in the 이력 (history) tab, so its overflow is expected. The Always
// Rules list has NO other view, so when it overflows we make the hidden count
// explicit (exact Always rules bypass HITL; the Human must know the full set
// exists even if it is not all shown here).
const ASIDE_RECENT_LIMIT = 5
const ASIDE_RULES_LIMIT = 6

// seconds-waited → compound elapsed + "대기" suffix ("2시간 5분 대기").
// Delegates to the shared formatDurationCompound so long HITL waits render with
// an hour tier; the prior bespoke minute-only formatter broke down at scale
// ("150분 0초 대기" for 2.5h). Non-finite / negative input clamps to 0 so the
// queue never surfaces an "확인 필요" label in the age slot.
function apAge(sec: number | null | undefined): string {
  const s = typeof sec === 'number' && Number.isFinite(sec) ? Math.max(0, Math.round(sec)) : 0
  return `${formatDurationCompound(s)} 대기`
}

function compactText(value: string | null | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}

function joinUnique(values: Array<string | null | undefined>): string | null {
  const seen: string[] = []
  for (const value of values) {
    const compact = compactText(value)
    if (compact && !seen.includes(compact)) seen.push(compact)
  }
  return seen.length ? seen.join(' · ') : null
}

/** Mirrors `Keeper_identity_gate.gate_operation` — the one closed operation
 *  identity every outside-service call submits under. */
const IDENTITY_CALL_OPERATION = 'identity_call'

/** What a human reads as "the tool". An identity_call carries its real
 *  target inside the input (provider_id · remote_name); the closed operation
 *  name alone would make every outside-service row read the same. */
function approvalToolDisplay(item: KeeperApprovalQueueItem): string {
  if (item.tool_name !== IDENTITY_CALL_OPERATION) return item.tool_name
  const input = item.input
  if (typeof input === 'object' && input !== null && !Array.isArray(input)) {
    const record = input as Record<string, unknown>
    const provider = typeof record.provider_id === 'string' ? record.provider_id.trim() : ''
    const remote = typeof record.remote_name === 'string' ? record.remote_name.trim() : ''
    if (provider && remote) return `${provider} · ${remote}`
    if (remote) return remote
  }
  return item.tool_name
}

function approvalTitle(item: KeeperApprovalQueueItem): string {
  return `${approvalToolDisplay(item)} Gate 요청`
}

function approvalWorkSummary(item: KeeperApprovalQueueItem): string | null {
  return joinUnique([
    item.task_id ? `task ${item.task_id}` : null,
    item.goal_id ? `goal ${item.goal_id}` : null,
    ...(item.goal_ids ?? []).map(id => `goal ${id}`),
  ])
}

function decisionSourceLabel(source: GateDecisionSource | null | undefined): string {
  switch (source) {
    case 'always_allowed': return 'Always Allowed'
    case 'auto_judge': return 'Auto Judge'
    case 'human_operator': return 'Human'
    default: return '판단 주체 미확인'
  }
}

function ResolvedApprovalItem({ item }: { item: KeeperResolvedApprovalItem }) {
  const decision = keeperResolvedApprovalDecisionLabel(item.decision)
  const tone = keeperResolvedApprovalDecisionTone(item.decision)
  const judgeSummary =
    item.summary_status?.status === 'available' ? item.summary_status.summary : null
  const judgeSlot =
    item.exact_attempt?.state === 'bound' ? item.exact_attempt.slot_id : null
  const automated = item.decision_source !== 'human_operator'
  return html`
    <li
      class=${`ap-hist-row dec-${tone}`}
      data-testid="approval-history-item"
      data-approval-id=${item.id}
    >
      <span class="ap-hist-at mono">
        ${item.resolved_at ? formatDateTimeKo(item.resolved_at) : '해결 시각 없음'}
      </span>
      <span class=${`ap-hist-dec ${tone}`}>${decision}</span>
      <div class="ap-hist-body">
        <div class="ap-hist-top">
          <span class="ap-hist-id mono">${item.id}</span>
          <span class="ap-hist-keeper mono">${item.keeper_name}</span>
          <span class="ap-hist-tool mono">${item.tool_name}</span>
          ${judgeSlot
            ? html`<span class="ap-hist-slot mono" data-testid="approval-history-slot">${judgeSlot}</span>`
            : null}
        </div>
        ${/* The design's .ap-hist-reason slot, fed by the audit record's own
             decision_reason — rendered only when the server recorded one
             (mark, don't fake). */''}
        ${item.decision_reason
          ? html`<div class="ap-hist-reason" data-testid="approval-history-reason">${item.decision_reason}</div>`
          : null}
        ${judgeSummary
          ? html`
              <details class="ap-hist-judge" data-testid="approval-history-judge">
                <summary>판정 근거</summary>
                <p class="ap-summary-text">${judgeSummary.context_summary}</p>
                ${judgeSummary.key_questions.length
                  ? html`<ul class="ap-summary-questions">
                      ${judgeSummary.key_questions.map(q => html`<li>${q}</li>`)}
                    </ul>`
                  : null}
                ${judgeSummary.rationale.trim()
                  ? html`<p class="ap-summary-rationale">${judgeSummary.rationale.trim()}</p>`
                  : null}
              </details>
            `
          : null}
      </div>
      <span
        class=${`ap-hist-by ${automated ? 'auto' : ''}`}
        title=${decisionSourceLabel(item.decision_source)}
      >
        ${item.actor ?? 'unattributed'}
        <span class="ap-hist-src">${decisionSourceLabel(item.decision_source)}</span>
      </span>
    </li>
  `
}

function resolvedAtMs(item: KeeperResolvedApprovalItem): number {
  const parsed = item.resolved_at ? Date.parse(item.resolved_at) : Number.NaN
  return Number.isFinite(parsed) ? parsed : 0
}

function historyWindowLabel(minutes: number): string {
  if (minutes % 1440 === 0) return `최근 ${minutes / 1440}일`
  if (minutes % 60 === 0) return `최근 ${minutes / 60}시간`
  return `최근 ${minutes}분`
}

/**
 * States the scope of what is on screen. Without it the list reads as the
 * complete history, which it is not when the server capped it — the defect
 * this line exists to remove. A null page means the server did not report its
 * bounds, so the scope is stated as unknown rather than assumed complete.
 */
function ApHistoryScope({ page }: { page: KeeperResolvedApprovalPage | null | undefined }) {
  if (page == null) {
    return html`
      <p class="ap-hist-scope" data-testid="approvals-history-scope">
        조회 범위를 확인할 수 없습니다 — 표시된 항목이 전체가 아닐 수 있습니다.
      </p>
    `
  }
  const scope = historyWindowLabel(page.window_minutes)
  if (page.scan_exhausted) {
    return html`
      <p class="ap-hist-scope warn" data-testid="approvals-history-scope">
        ${scope} · <b class="mono">${page.returned}</b>건 표시 ·
        조회 상한에 걸려 ${scope} 전체를 읽지 못했습니다
      </p>
    `
  }
  if (page.truncated) {
    return html`
      <p class="ap-hist-scope warn" data-testid="approvals-history-scope">
        ${scope} <b class="mono">${page.matched}</b>건 중
        <b class="mono">${page.returned}</b>건 표시
      </p>
    `
  }
  return html`
    <p class="ap-hist-scope" data-testid="approvals-history-scope">
      ${scope} <b class="mono">${page.matched}</b>건 전체
    </p>
  `
}

function ApHistory({
  items,
  page,
}: {
  items: KeeperResolvedApprovalItem[]
  page: KeeperResolvedApprovalPage | null | undefined
}) {
  const [filter, setFilter] = useState<ApprovalHistoryFilter>('all')
  const sorted = useMemo(
    () => [...items].sort((a, b) => resolvedAtMs(b) - resolvedAtMs(a)),
    [items],
  )
  const activeFilter = APPROVAL_HISTORY_FILTERS.find(item => item.id === filter)
    ?? DEFAULT_APPROVAL_HISTORY_FILTER
  const shown = sorted.filter(activeFilter.predicate)
  const counts = useMemo(() => ({
    approve: sorted.filter(item => item.decision === 'approve').length,
    reject: sorted.filter(item => item.decision === 'reject').length,
    autoJudge: sorted.filter(item => item.decision_source === 'auto_judge').length,
    keepers: new Set(sorted.map(item => item.keeper_name)).size,
  }), [sorted])

  return html`
    <section class="ap-hist" data-testid="approvals-history-view">
      <${ApHistoryScope} page=${page} />
      <div class="ap-hist-summary" aria-label="승인 이력 요약">
        <div class="ap-hist-stat"><b class="mono ok">${counts.approve}</b> 승인</div>
        <div class="ap-hist-stat"><b class="mono bad">${counts.reject}</b> 거부</div>
        <div class="ap-hist-stat"><b class="mono">${counts.autoJudge}</b> Auto Judge</div>
        ${/* Design's 4th stat is median decision latency; the audit record has
             no latency field, so the slot carries the live-only keeper count
             instead of a fabricated number. */''}
        <div class="ap-hist-stat"><b class="mono">${counts.keepers}</b> 관련 키퍼</div>
      </div>
      <div class="ap-hist-filters" role="tablist" aria-label="승인 이력 필터">
        ${APPROVAL_HISTORY_FILTERS.map(option => html`
          <button
            key=${option.id}
            type="button"
            class=${`ap-hist-f ${filter === option.id ? 'on' : ''}`}
            aria-pressed=${filter === option.id}
            onClick=${() => setFilter(option.id)}
          >${option.label}</button>
        `)}
      </div>
      ${shown.length > 0
        ? html`
            <ul class="ap-hist-list">
              ${shown.map(item => html`<${ResolvedApprovalItem} key=${item.id} item=${item} />`)}
            </ul>
          `
        : html`
            <div class="ap-clear compact" data-testid="approvals-history-empty">
              <div class="ico">${'✓'}</div>
              <h3>해당 필터의 처리 이력 없음</h3>
              <div class="ap-clear-sub">최근 처리 projection에 일치하는 항목 없음</div>
            </div>
          `}
    </section>
  `
}

function approvalDetailRows(item: KeeperApprovalQueueItem): Array<{ label: string; value: string }> {
  const disposition = item.summary_attempt_disposition.code
  const phase = approvalPhase(item)
  const exact =
    item.exact_attempt.state === 'bound'
      ? `${item.exact_attempt.slot_id} · ${item.exact_attempt.status}`
      : item.exact_attempt.state
  const toolDisplay = approvalToolDisplay(item)
  return [
    { label: '키퍼', value: item.keeper_name },
    { label: '도구', value: toolDisplay },
    toolDisplay !== item.tool_name
      ? { label: 'operation', value: item.tool_name }
      : null,
    { label: '상태', value: `${phase.detail} · Keeper lane nonblocking` },
    { label: '대기', value: apAge(item.waiting_s) },
    { label: '연결 작업', value: approvalWorkSummary(item) },
    { label: '턴', value: typeof item.turn_id === 'number' ? `turn ${item.turn_id}` : null },
    { label: '요청시각', value: compactText(item.requested_at) },
    { label: '입력', value: compactText(item.input_preview) || '입력 미리보기 없음' },
    { label: 'Auto Judge', value: disposition },
    { label: 'Exact attempt', value: exact },
  ].filter((row): row is { label: string; value: string } => Boolean(row?.value))
}

type ApprovalPhase = {
  key: 'queued' | 'judging' | 'human_required' | 'blocked'
  label: string
  detail: string
  severity: 'sev-info' | 'sev-warn' | 'sev-bad'
}

// A durable queue row can remain for hours after Auto Judge has already
// stopped. Project the closed summary/disposition states instead of calling
// every row "Human HITL": age is queue age, never model execution duration.
function approvalPhase(item: KeeperApprovalQueueItem): ApprovalPhase {
  const disposition = item.summary_attempt_disposition
  const summary = item.summary_status
  const blocked =
    disposition.code === 'identity_unbound'
    || disposition.code === 'persistence_uncertain'
    || (
      disposition.code === 'pre_worker_unavailable'
      && disposition.reason_code !== 'start_reserved'
    )
    || summary.status === 'failed'
  if (blocked) {
    return {
      key: 'blocked',
      label: '● Auto Judge blocked',
      detail: 'Auto Judge 종료 실패 · 재개나 Human 판단 필요',
      severity: 'sev-bad',
    }
  }
  if (
    summary.status === 'available'
    && summary.summary.judgment === 'require_human'
  ) {
    return {
      key: 'human_required',
      label: '● Human required',
      detail: 'Auto Judge 완료 · Human 판단 필요',
      severity: 'sev-warn',
    }
  }
  const judging =
    disposition.code === 'in_flight'
    || summary.status === 'pending'
    || (
      disposition.code === 'pre_worker_unavailable'
      && disposition.reason_code === 'start_reserved'
    )
    || (
      disposition.code === 'settled'
      && summary.status === 'available'
      && summary.summary.judgment !== 'require_human'
    )
  if (judging) {
    return {
      key: 'judging',
      label: '● Auto Judging',
      detail: 'Auto Judge 판정 중',
      severity: 'sev-info',
    }
  }
  return {
    key: 'queued',
    label: '● Queue waiting',
    detail: '판정 시작 대기',
    severity: 'sev-warn',
  }
}

// Open this keeper's workspace conversation (work.ts idiom).
function openKeeperWorkspace(name: string): void {
  navigate('monitoring', { section: 'agents', view: 'keepers', keeper: name })
}

// Render the HITL context-summary worker's Human briefing. `available`
// carries the LLM-generated summary a Human reads before deciding;
// `pending`/`failed` are surfaced (not hidden) so a stuck or errored summary is
// visible rather than silently absent. `not_requested`/`null` render nothing.
function renderAvailableSummary(summary: HitlContextSummary) {
  return html`
    <div class="ap-summary sev-summary" data-testid="approval-summary" data-summary-state="available">
      <div class="ap-summary-head">
        <span class="ap-summary-label">🧭 컨텍스트 요약</span>
        <span class="ap-summary-uncertainty">${summary.judgment === 'require_human' ? 'Human 판단 필요' : summary.judgment === 'approve' ? '승인 제안' : '거부 제안'}</span>
      </div>
      <p class="ap-summary-text">${summary.context_summary}</p>
      ${summary.key_questions.length
        ? html`<ul class="ap-summary-questions">
            ${summary.key_questions.map(q => html`<li>${q}</li>`)}
          </ul>`
        : null}
      ${summary.rationale.trim()
        ? html`<p class="ap-summary-rationale">${summary.rationale.trim()}</p>`
        : null}
    </div>
  `
}

function exactAttemptLabel(attempt: KeeperExactAttemptState): string {
  return attempt.state === 'unbound'
    ? 'exact identity unbound'
    : `exact ${attempt.slot_id} · ${attempt.status}`
}

function summaryRearmExpectation(
  item: KeeperApprovalQueueItem,
): KeeperAutoJudgeRearmExpectation | null {
  const disposition = item.summary_attempt_disposition
  const exactAttempt = item.exact_attempt
  const preWorkerRearmable =
    disposition.code === 'pre_worker_unavailable'
    && (
      disposition.reason_code === 'auto_judge_unavailable'
      || disposition.reason_code === 'mode_state_invalid'
    )
  const summaryRearmable =
    item.summary_status.status === 'pending'
    || (
      preWorkerRearmable
      && item.summary_status.status === 'not_requested'
    )
  if (!summaryRearmable) return null
  if (disposition.code === 'pre_worker_unavailable') {
    return preWorkerRearmable && exactAttempt.state === 'unbound'
      ? {
          input_hash: item.input_hash,
          sequence: item.sequence,
          exact_attempt: exactAttempt,
          summary_attempt_disposition: disposition,
        }
      : null
  }
  if (disposition.code === 'identity_unbound') {
    return exactAttempt.state === 'unbound'
      ? {
          input_hash: item.input_hash,
          sequence: item.sequence,
          exact_attempt: exactAttempt,
          summary_attempt_disposition: disposition,
        }
      : null
  }
  if (
    disposition.code !== 'persistence_uncertain'
    || (
      exactAttempt.state === 'bound'
      && exactAttempt.status !== 'released_recovery_required'
    )
  ) return null
  return {
    input_hash: item.input_hash,
    sequence: item.sequence,
    exact_attempt: exactAttempt,
    summary_attempt_disposition: disposition,
  }
}

function blockedSummaryAttempt(
  disposition:
    Extract<
      KeeperSummaryAttemptDisposition,
      { code: 'identity_unbound' | 'persistence_uncertain' | 'pre_worker_unavailable' }
    >,
  exactAttempt: KeeperExactAttemptState,
) {
  const label = disposition.code === 'identity_unbound'
    ? 'Auto Judge 중단 · exact identity 미결합'
    : disposition.code === 'persistence_uncertain'
      ? 'Auto Judge 중단 · durability 확인 필요'
      : disposition.reason_code === 'start_reserved'
        ? 'Auto Judge 시작 · exact identity 예약됨'
        : disposition.reason_code === 'mode_state_invalid'
          ? 'Auto Judge 중단 · Gate mode 상태 불가'
          : 'Auto Judge 중단 · 시작 불가'
  return html`
    <div
      class="ap-summary ap-summary-failed"
      data-testid="approval-summary"
      data-summary-state=${disposition.code}
    >
      <span class="ap-summary-label">${label}</span>
      <span class="ap-summary-reason">${disposition.operator_detail}</span>
      <span class="ap-summary-reason mono">${exactAttemptLabel(exactAttempt)}</span>
    </div>
  `
}

function approvalSummaryBlock(item: KeeperApprovalQueueItem) {
  const status = item.summary_status
  const disposition = item.summary_attempt_disposition
  const exactAttempt = item.exact_attempt
  if (
    disposition.code === 'identity_unbound'
    || disposition.code === 'persistence_uncertain'
    || disposition.code === 'pre_worker_unavailable'
  ) {
    return blockedSummaryAttempt(disposition, exactAttempt)
  }
  switch (status.status) {
    case 'not_requested':
      return null
    case 'pending':
      return html`<div class="ap-summary ap-summary-pending" data-testid="approval-summary" data-summary-state="pending">
        <span class="ap-summary-label">${disposition.code === 'ready' ? '컨텍스트 요약 재개 대기' : '컨텍스트 요약 생성 중…'}</span>
      </div>`
    case 'failed':
      return html`<div class="ap-summary ap-summary-failed" data-testid="approval-summary" data-summary-state="failed">
        <span class="ap-summary-label">컨텍스트 요약 terminal 실패 · Human 판단 필요</span>
        ${status.reason ? html`<span class="ap-summary-reason">${status.reason}</span>` : null}
      </div>`
    case 'available':
      return renderAvailableSummary(status.summary)
    default: {
      // Exhaustive over HitlSummaryStatus — a new backend variant fails typecheck here.
      const _never: never = status
      return _never
    }
  }
}

function ApprovalCard({
  item,
  selected,
  onSelect,
}: {
  item: KeeperApprovalQueueItem
  selected: boolean
  onSelect: (id: string) => void
}) {
  const actingId = gateApprovalActing.value
  const busy = actingId === item.id
  const anyBusy = Boolean(actingId)
  const title = approvalTitle(item)
  const rearmExpectation = summaryRearmExpectation(item)
  const phase = approvalPhase(item)

  return html`
    <article
      class=${`ap-card ${phase.severity}`}
      data-testid="approval-card"
      data-approval-id=${item.id}
      data-selected=${selected ? 'true' : 'false'}
      data-approval-phase=${phase.key}
    >
      <div class="ap-rail"></div>
      <div class="ap-main">
        <div class="ap-h">
          <span class=${`ap-kind ${phase.severity}`}>${phase.label}</span>
          <span class="ap-tool mono">${approvalToolDisplay(item)}</span>
          <span class="ap-id mono">${item.id}</span>
          <span class=${`ap-age ${phase.severity}`}>${apAge(item.waiting_s)}</span>
          <button
            type="button"
            class="ap-detail-toggle"
            aria-pressed=${selected}
            onClick=${() => onSelect(item.id)}
            title="요청 상세 보기"
          >상세</button>
        </div>
        <h3 class="ap-title">${title}</h3>
        <p class="ap-detail">Keeper lane은 계속 진행 · ${phase.detail}</p>
        ${approvalSummaryBlock(item)}
        <div class="ap-req">
          <${AgentAvatar} name=${item.keeper_name} size="sm" />
          <div class="ap-req-body">
            <div class="ap-req-who">
              <button
                type="button"
                class="ap-klink"
                onClick=${() => openKeeperWorkspace(item.keeper_name)}
                title=${`${item.keeper_name} 대화 열기`}
              >${item.keeper_name}</button>
              ${item.task_id || item.goal_id
                ? html`<button
                    type="button"
                    class="ap-req-goal mono"
                    onClick=${() => navigate('workspace', { section: 'work' })}
                    title="작업 보기"
                  >${[item.task_id ? `task ${item.task_id}` : null, item.goal_id ? `goal ${item.goal_id}` : null]
                    .filter(Boolean)
                    .join(' · ')}</button>`
                : null}
              <span class="ap-req-meta mono">nonblocking</span>
            </div>
            <div class="ap-req-quote">
              ${item.input_preview?.trim() ? `“${item.input_preview.trim()}”` : '입력 미리보기 없음'}
            </div>
          </div>
        </div>
        <div class="ap-actions">
          ${rearmExpectation
            ? html`<button
                type="button"
                class="ap-act retry"
                onClick=${() => void retryKeeperAutoJudge(item.id, rearmExpectation)}
                title="durable blocked state를 operator CAS로 한 번 재개합니다"
                disabled=${anyBusy}
              >${busy ? '요청 중…' : 'Auto Judge 재개'}</button>`
            : null}
          <button
            type="button"
            class="ap-act approve"
            onClick=${() => void respondToKeeperApproval(item.id, 'approve')}
            disabled=${anyBusy}
          >${busy ? '처리 중…' : '승인'}</button>
          <button
            type="button"
            class="ap-act always"
            onClick=${() => void respondToKeeperApproval(item.id, 'approve', true)}
            title="승인하고 동일 요청을 자동 승인하는 Always 규칙을 저장합니다"
            disabled=${anyBusy}
          >${busy ? '처리 중…' : '항상 승인'}</button>
          <button
            type="button"
            class="ap-act deny"
            onClick=${() => void respondToKeeperApproval(item.id, 'reject')}
            disabled=${anyBusy}
          >${busy ? '처리 중…' : '거부'}</button>
          <button
            type="button"
            class="ap-act ghost"
            onClick=${() => openKeeperWorkspace(item.keeper_name)}
            title="맥락 보기"
            disabled=${anyBusy}
          >대화에서 검토 →</button>
        </div>
      </div>
    </article>
  `
}

function ApprovalDetailPanel({
  item,
  variant = 'rail',
}: {
  item: KeeperApprovalQueueItem | null
  variant?: 'rail' | 'inline'
}) {
  if (!item) return null
  const rows = approvalDetailRows(item)
  const phase = approvalPhase(item)

  return html`
    <aside
      class=${`ap-detail-panel ap-detail-panel-${variant}`}
      data-testid=${variant === 'inline' ? 'approval-detail-panel-inline' : 'approval-detail-panel'}
      data-approval-id=${item.id}
    >
      <div class="ap-detail-panel-head">
        <span class=${`ap-kind ${phase.severity}`}>${phase.label}</span>
        <div class="ap-detail-panel-title">
          <strong>${approvalTitle(item)}</strong>
          <span class="mono">${item.id}</span>
        </div>
      </div>
      <dl class="ap-dossier">
        ${rows.map(row => html`
          <div class="ap-dossier-row" key=${row.label}>
            <dt>${row.label}</dt>
            <dd>${row.value}</dd>
          </div>
        `)}
      </dl>
    </aside>
  `
}

function ApprovalRuleRow({ rule }: { rule: KeeperApprovalRule }) {
  const fingerprintPreview = rule.request_fingerprint.slice(0, 12)
  const expired = rule.expires_at !== null && rule.expires_at <= Date.now() / 1000
  const expiryLabel = rule.expires_at === null
    ? '만료 없음'
    : `${expired ? '만료됨' : '만료'} ${formatDateTimeKo(rule.expires_at * 1000)}`
  const deleting = gateApprovalActing.value === `rule:${rule.id}`
  return html`
    <li class="ap-rule-row" data-testid="approval-rule-row">
      <span class="ap-rule-keeper mono">${rule.keeper_name}</span>
      <span class="ap-rule-tool mono">${rule.tool_name}</span>
      <span class="ap-rule-fingerprint mono">${fingerprintPreview}</span>
      <span class="ap-rule-provenance mono">${rule.created_by} · ${rule.source_approval_id}</span>
      <span class=${`ap-rule-expiry ${expired ? 'sev-bad' : ''}`} data-testid="approval-rule-expiry">${expiryLabel}</span>
      <button
        type="button"
        class="ap-rule-delete"
        disabled=${deleting}
        onClick=${() => void deleteKeeperApprovalRule(rule.id)}
        aria-label=${rule.tool_name + ' Always 규칙 삭제'}
      >${deleting ? '삭제 중' : '삭제'}</button>
    </li>
  `
}

const GATE_MODES: ReadonlyArray<{ mode: GateMode; label: string }> = [
  { mode: 'manual', label: 'Human' },
  { mode: 'auto_judge', label: 'Auto Judge' },
  { mode: 'always_allow', label: 'Always Allow' },
]

// One Keeper an operator singled out. Both kinds render the same way -- who,
// what was chosen, and who chose it -- because that is what an operator scans
// the list for. The mode override says only what was asked for: the Gate keeps
// the stricter of it and the workspace, and a row asking for less is on file
// without being in force.
function KeeperGateSettingRow({
  keeperName,
  value,
  updatedBy,
  updatedAt,
  testId,
}: {
  keeperName: string
  value: string
  updatedBy: string
  updatedAt: string
  testId: string
}) {
  return html`
    <li class="ap-rule-row" data-testid=${testId}>
      <span class="ap-rule-keeper mono">${keeperName}</span>
      <span class="ap-rule-tool mono">${value}</span>
      <span class="ap-rule-provenance mono">${updatedBy}</span>
      <span class="ap-rule-expiry mono">${updatedAt === '' ? '시각 없음' : updatedAt}</span>
    </li>
  `
}

function KeeperGateSettingsCard({
  modes,
  modesState,
  exactLanes,
  exactLanesState,
}: {
  modes: KeeperGateModeOverride[]
  modesState: KeeperGateSettingsState
  exactLanes: KeeperExactLanePreference[]
  exactLanesState: KeeperGateSettingsState
}) {
  const modeLabel = (mode: GateMode) =>
    GATE_MODES.find(entry => entry.mode === mode)?.label ?? mode
  return html`
    <section class="wka-card" data-testid="keeper-gate-settings">
      <div class="wka-h">
        <h3>Keeper 개별 설정</h3>
        <span class="mono">${(modes.length + exactLanes.length).toLocaleString()}</span>
      </div>
      <div class="wka-hint mono">Gate mode — workspace 설정보다 엄격한 쪽만 적용</div>

      ${modesState.state === 'unavailable'
        ? html`<div class="ap-env-warn" role="alert" data-testid="keeper-modes-unavailable">모드 오버라이드 읽기 실패: ${modesState.error}</div>`
        : modes.length > 0
        ? html`
            <ul class="ap-rule-list">${modes.map(row => html`
              <${KeeperGateSettingRow}
                key=${`mode:${row.keeper_name}`}
                keeperName=${row.keeper_name}
                value=${modeLabel(row.mode)}
                updatedBy=${row.updated_by}
                updatedAt=${row.updated_at}
                testId="keeper-mode-row"
              />
            `)}</ul>
          `
        : html`<div class="ap-side-empty">모드를 따로 정한 Keeper 없음</div>`}

      <div class="wka-hint mono">Exact lane — Keeper별 첫 slot, 나머지는 failover</div>
      ${exactLanesState.state === 'unavailable'
        ? html`<div class="ap-env-warn" role="alert" data-testid="keeper-exact-lanes-unavailable">Exact lane 설정 읽기 실패: ${exactLanesState.error}</div>`
        : exactLanes.length > 0
        ? html`
            <ul class="ap-rule-list">${exactLanes.map(row => html`
              <${KeeperGateSettingRow}
                key=${`exact:${row.keeper_name}:${row.lane_id}`}
                keeperName=${row.keeper_name}
                value=${`${row.lane_id} → ${row.slot_id}`}
                updatedBy=${row.updated_by}
                updatedAt=${row.updated_at}
                testId="keeper-exact-lane-row"
              />
            `)}</ul>
          `
        : html`<div class="ap-side-empty">Exact lane 첫 slot을 따로 정한 Keeper 없음</div>`}
    </section>
  `
}

function ApAside({
  openCount,
  resolvedItems,
  rules,
  rulesState,
}: {
  openCount: number
  resolvedItems: KeeperResolvedApprovalItem[]
  rules: KeeperApprovalRule[]
  rulesState: KeeperApprovalRulesState
}) {
  const hitl = gateData.value?.hitl
  const recent = [...resolvedItems]
    .sort((a, b) => resolvedAtMs(b) - resolvedAtMs(a))
    .slice(0, ASIDE_RECENT_LIMIT)
  const gateMode = hitl?.gate_mode
  const externalGateMode = hitl?.external_gate_mode
  const judgeLane = hitl?.judge_lane
  const acting = gateApprovalActing.value
  const modeDisabled = acting !== null
  const hiddenRules = Math.max(0, rules.length - ASIDE_RULES_LIMIT)
  return html`
    <aside class="ap-aside" data-testid="approvals-aside">
      <section class="wka-card ap-auto-card">
        <div class="wka-h">
          <h3>Gate 모드</h3>
        </div>
        <div class="wka-auto">
          <div class="wka-auto-top">
            <span class="wka-auto-lbl">
              Gate 모드
              <b>${GATE_MODES.find(option => option.mode === gateMode?.mode)?.label ?? '확인 필요'}</b>
            </span>
            <div class="wka-mode wka-mode-3" role="radiogroup" aria-label="Gate 모드" data-testid="gate-mode-selector">
              ${GATE_MODES.map(option => html`
                <button
                  key=${option.mode}
                  type="button"
                  class=${`wka-mode-b ${gateMode?.mode === option.mode ? 'on' : ''}`}
                  role="radio"
                  aria-checked=${gateMode?.mode === option.mode}
                  onClick=${() => void setKeeperGateMode(option.mode)}
                  disabled=${modeDisabled}
                ><b>${option.label}</b></button>
              `)}
            </div>
          </div>
          <div class="wka-auto-top">
            <span class="wka-auto-lbl">
              바깥 서비스 쓰기
              <b>${GATE_MODES.find(option => option.mode === externalGateMode?.mode)?.label ?? '확인 필요'}</b>
            </span>
            <div class="wka-mode wka-mode-3" role="radiogroup" aria-label="바깥 서비스 Gate 모드" data-testid="gate-external-mode-selector">
              ${GATE_MODES.map(option => html`
                <button
                  key=${option.mode}
                  type="button"
                  class=${`wka-mode-b ${externalGateMode?.mode === option.mode ? 'on' : ''}`}
                  role="radio"
                  aria-checked=${externalGateMode?.mode === option.mode}
                  onClick=${() => void setKeeperExternalGateMode(option.mode)}
                  disabled=${modeDisabled}
                ><b>${option.label}</b></button>
              `)}
            </div>
          </div>
          <div class="wka-auto-stat">${rulesState.state === 'ready' ? `${rules.length.toLocaleString()}개 Always 규칙` : 'Always 규칙 확인 불가'} · 열린 승인 ${openCount.toLocaleString()}건</div>
          <div class="wka-auto-note">
            Human은 사람이 판단하고, Auto Judge는 LLM이 판단하며, Always Allow는 workspace의 명시적 선택입니다.
            바깥 서비스 쓰기(Jira · Slack · GitHub)는 자기 스위치를 따로 탑니다 — 위 Gate 모드를 열어도 바깥 쓰기는 열리지 않습니다.
          </div>
          ${judgeLane
            ? judgeLane.status === 'available'
              ? html`
                  <div class="wka-auto-stat mono" data-testid="gate-judge-lane">
                    판정 모델 ${judgeLane.slots[0]}${judgeLane.slots.length > 1
                      ? ` (+${judgeLane.slots.length - 1} failover)`
                      : ''}
                  </div>
                `
              : html`
                  <div class="ap-env-warn mono" data-testid="gate-judge-lane">
                    판정 lane ${judgeLane.lane_id} 확인 불가: ${judgeLane.reason}
                  </div>
                `
            : null}
          ${gateMode?.state === 'invalid' || gateMode?.state === 'unavailable'
            ? html`<div class="ap-env-warn mono">Gate mode ${gateMode.state}: ${gateMode.read_error}</div>`
            : null}
          ${externalGateMode?.state === 'invalid' || externalGateMode?.state === 'unavailable'
            ? html`<div class="ap-env-warn mono">External gate mode ${externalGateMode.state}: ${externalGateMode.read_error}</div>`
            : null}
        </div>
      </section>

      <section class="wka-card">
        <div class="wka-h">
          <h3>Always Rules</h3>
          <span class="mono">${rules.length}</span>
        </div>
        ${rulesState.state === 'ready'
          ? html`<div class="wka-hint mono">정확일치 규칙 — keeper · tool · request fingerprint</div>`
          : null}
        ${rulesState.state === 'unavailable'
          ? html`<div class="ap-env-warn" role="alert" data-testid="approval-rules-unavailable">${rulesState.error}</div>`
          : rules.length > 0
          ? html`
              <ul class="ap-rule-list">${rules.slice(0, ASIDE_RULES_LIMIT).map(rule => html`<${ApprovalRuleRow} key=${rule.id} rule=${rule} />`)}</ul>
              ${hiddenRules > 0
                ? html`<div class="ap-side-empty mono" data-testid="approvals-rules-overflow">외 ${hiddenRules.toLocaleString()}건 더</div>`
                : null}
            `
          : html`<div class="ap-side-empty">저장된 Always 규칙 없음</div>`}
      </section>

      <${KeeperGateSettingsCard}
        modes=${gateData.value?.keeper_modes ?? []}
        modesState=${gateData.value?.keeper_modes_state ?? { state: 'ready' }}
        exactLanes=${gateData.value?.keeper_exact_lanes ?? []}
        exactLanesState=${gateData.value?.keeper_exact_lanes_state ?? { state: 'ready' }}
      />

      <section class="wka-card">
        <div class="wka-h">
          <h3>최근 처리</h3>
          <span class="mono">${resolvedItems.length}</span>
        </div>
        ${recent.length > 0
          ? html`
              <ul class="ap-recent-list">
                ${recent.map(item => html`
                  <li class="ap-recent-row" key=${item.id}>
                    <span class=${`ap-recent-dec ${keeperResolvedApprovalDecisionClass(item.decision)}`}>
                      ${keeperResolvedApprovalDecisionLabel(item.decision)}
                    </span>
                    <span class="ap-recent-body">
                      <span class="ap-recent-top">
                        <span class="mono">${item.tool_name}</span>
                        <span>${item.keeper_name}</span>
                      </span>
                      <span class="ap-recent-sub mono">${item.id}</span>
                    </span>
                  </li>
                `)}
              </ul>
            `
          : html`<div class="ap-side-empty">최근 처리 projection 없음</div>`}
      </section>
    </aside>
  `
}

export function ApprovalsSurface() {
  useEffect(() => {
    void refreshGate()
    const disposeAutoRefresh = setupVisibleAutoRefresh(refreshGate, TELEMETRY_AUTO_REFRESH_MS)
    return () => {
      disposeAutoRefresh()
    }
  }, [])

  const items = gateData.value?.approval_queue ?? null
  const approvalQueueState = gateData.value?.approval_queue_state
  const queueUnavailable =
    approvalQueueState && approvalQueueState.state !== 'ready'
      ? approvalQueueState
      : null
  const resolvedState = gateData.value?.recent_resolved_state ?? null
  const resolvedItems = gateData.value?.recent_resolved ?? []
  const resolvedPage = gateData.value?.recent_resolved_page ?? null
  const resolvedUnavailable =
    resolvedState?.state === 'unavailable' ? resolvedState : null
  const rules = gateData.value?.approval_rules ?? []
  const rulesState = gateData.value?.approval_rules_state ?? null
  const queueViolations = gateData.value?.approval_queue_violations ?? []
  const resolvedViolations = gateData.value?.recent_resolved_violations ?? []
  const error = gateError.value
  // First load only: gateResource is stale-while-revalidate, so a refetch
  // keeps the previous data — gateData is null ONLY before the first load
  // resolves. Show a loading state then, instead of asserting the empty queue.
  const firstLoad = gateLoading.value && gateData.value === null
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [view, setView] = useState<ApprovalsView>('queue')
  const selectedItem =
    items?.find(item => item.id === selectedId) ?? items?.[0] ?? null

  const stats = useMemo(() => {
    if (items === null) return null
    const longest = items.reduce((max, i) => Math.max(max, i.waiting_s ?? 0), 0)
    const keepers = new Set(items.map(i => i.keeper_name)).size
    return { longest, keepers }
  }, [items])

  return html`
    <main class="ov ov-flush ov-2col ss-surface ap-surface bg-surface-page text-text-primary" data-screen-label="Gate HITL 큐" data-testid="approvals-surface">
      <div class="ov-scroll">
        <header class="ov-head">
          <div>
            <span class="ov-eyebrow">HITL</span>
            <h1>Gate · HITL 큐</h1>
            <p class="ov-sub">
              외부 효과 요청의 정확한 입력을 Human이 판단하는 비동기 큐 ·
              <span>Keeper lane은 대기 중에도 다른 활동을 계속</span>
            </p>
          </div>
          <div class="ap-head-actions">
            <div class="ap-viewseg" role="tablist" aria-label="승인 큐 보기">
              <button
                type="button"
                class=${`ap-viewbtn ${view === 'queue' ? 'on' : ''}`}
                aria-selected=${view === 'queue'}
                onClick=${() => setView('queue')}
              >
                큐${items && items.length > 0 ? html`<span class="ap-viewbtn-n mono">${items.length}</span>` : null}
              </button>
              <button
                type="button"
                class=${`ap-viewbtn ${view === 'history' ? 'on' : ''}`}
                aria-selected=${view === 'history'}
                onClick=${() => setView('history')}
              >
                이력${resolvedItems.length > 0
                  ? html`<span class="ap-viewbtn-n neutral mono" data-testid="approvals-history-count">${resolvedItems.length}</span>`
                  : null}
              </button>
            </div>
            ${view === 'queue' && items && items.length > 0 && stats
              ? html`<span class="ap-sla mono" title="가장 오래 대기 중인 건">최장 대기 ${apAge(stats.longest)}</span>`
              : null}
          </div>
        </header>

        ${error ? html`<div class="ap-error" role="alert" data-testid="approvals-error">${error}</div>` : null}
        <${ApprovalAuditWriteFailureAlert} />
        ${resolvedUnavailable
          ? html`
              <div class="ap-error sev-bad" role="alert" data-testid="approvals-history-unavailable">
                <strong><span aria-hidden="true">!</span> 승인 처리 이력을 읽을 수 없습니다</strong>
                <span>${resolvedUnavailable.error}</span>
              </div>
            `
          : null}
        ${resolvedViolations.length > 0
          ? html`
              <div class="ap-error sev-warn" role="alert" data-testid="approvals-history-violations">
                <strong><span aria-hidden="true">!</span> 표시 불가 처리 이력 ${resolvedViolations.length}건</strong>
                <span>
                  아래 행은 디코딩 계약을 위반해 목록에 넣지 못했습니다. 나머지 이력과
                  열린 Gate 수는 그대로 보입니다. 서버 원장(audit-approvals)에서 확인하세요.
                </span>
                ${resolvedViolations.map(violation => html`
                  <span class="mono" key=${violation.index}>
                    #${violation.index} · ${violation.keeper_name ?? 'keeper?'} ·
                    ${violation.tool_name ?? 'tool?'} · ${violation.id ?? 'id?'}
                  </span>
                `)}
              </div>
            `
          : null}
        ${queueViolations.length > 0
          ? html`
              <div class="ap-error sev-warn" role="alert" data-testid="approvals-queue-violations">
                <strong><span aria-hidden="true">!</span> 표시 불가 대기 요청 ${queueViolations.length}건</strong>
                <span>
                  아래 행은 디코딩 계약을 위반해 카드로 표시할 수 없지만, 대기 중인
                  승인 요청은 실재합니다. 서버 원장(audit-approvals)에서 확인하세요.
                </span>
                ${queueViolations.map(violation => html`
                  <span class="mono" key=${violation.index}>
                    #${violation.index} · ${violation.keeper_name ?? 'keeper?'} ·
                    ${violation.tool_name ?? 'tool?'} · ${violation.id ?? 'id?'}
                  </span>
                `)}
              </div>
            `
          : null}
        ${queueUnavailable
          ? html`
              <div
                class=${`ap-error sev-${queueUnavailable.severity}`}
                role="alert"
                data-testid="approvals-queue-unavailable"
                data-severity=${queueUnavailable.severity}
              >
                <strong><span aria-hidden="true">${queueUnavailable.icon}</span> ${queueUnavailable.title}</strong>
                <span>${queueUnavailable.operator_detail}</span>
              </div>
            `
          : null}

        ${firstLoad
          ? html`<${LoadingState}>Gate 큐 불러오는 중...<//>`
          : view === 'history'
            ? resolvedUnavailable
              ? null
              : html`<${ApHistory} items=${resolvedItems} page=${resolvedPage} />`
          : queueUnavailable || items === null
            ? null
          : html`
        <section class="ov-kpis" style=${{ gridTemplateColumns: 'repeat(4, 1fr)' }}>
          <div class="ov-kpi">
            <div class="ov-kpi-k">열린 승인</div>
            <div class=${`ov-kpi-v ${items.length ? 'warn' : 'ok'}`}>${items.length}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">관련 Keeper</div>
            <div class="ov-kpi-v" data-testid="gate-kpi-keepers">${stats?.keepers}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">Always 규칙</div>
            <div class="ov-kpi-v">${rules.length}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">처리 완료</div>
            <div class="ov-kpi-v volt">${resolvedUnavailable ? '—' : resolvedItems.length}</div>
          </div>
        </section>

        ${items.length > 0
          ? html`
              <div class="ap-workspace" data-testid="approvals-workspace">
                <div class="ap-queue" data-testid="approvals-queue">
                  ${items.map(item => html`
                    <${Fragment} key=${item.id}>
                      <${ApprovalCard}
                        item=${item}
                        selected=${selectedItem?.id === item.id}
                        onSelect=${setSelectedId}
                      />
                      ${selectedItem?.id === item.id
                        ? html`<${ApprovalDetailPanel} item=${item} variant="inline" />`
                        : null}
                    <//>
                  `)}
                </div>
                <${ApprovalDetailPanel} item=${selectedItem} variant="rail" />
              </div>
            `
          : null}
        ${items.length === 0 && !error && !queueUnavailable && queueViolations.length === 0
          ? html`
              <div class="ap-clear" data-testid="approvals-empty">
                <div class="ico">${'✓'}</div>
                <h3>열린 Human 판단 없음</h3>
                <div class="ap-clear-sub">HITL 큐 비어 있음</div>
              </div>
            `
          : null}
      `}
      </div>
      ${!firstLoad && !queueUnavailable && !resolvedUnavailable && items !== null && rulesState !== null ? html`
        <${ApAside}
          openCount=${items.length}
          resolvedItems=${resolvedItems}
          rules=${rules}
          rulesState=${rulesState}
        />
      ` : null}
    </main>
  `
}
