// VerificationRequestsPanel — Mission detail surface for cross-agent
// verification requests.
//
// Consumes:
//   GET /api/v1/verification/requests?task_id=&limit=
//   POST /api/v1/verification/resolve
//
// Pattern mirrors CascadeConfigPanel: managed async resource + manual
// refresh + 15s auto-tick. Row expansion uses <details> so we avoid
// component-local state plumbing for a read-only table. Pending rows
// expose approve/reject action buttons that call the resolve endpoint;
// in-flight state is held in a per-row signal map.

import { html } from 'htm/preact'
import { useEffect, useMemo, useRef } from 'preact/hooks'
import { signal } from '@preact/signals'
import {
  fetchVerificationRequests,
  resolveVerificationRequest,
  type VerificationRequest,
  type VerificationRequestStatus,
  type VerificationRequestVerdict,
  type VerificationRequestsResponse,
} from '../api/dashboard'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { ErrorState, LoadingState } from './common/feedback-state'
import { StatusChip } from './common/status-chip'
import { FilterChips } from './common/filter-chips'
import { TextInput } from './common/input'
import {
  createManagedAsyncResource,
  type ManagedAsyncResource,
} from '../lib/async-state'

const AUTO_REFRESH_MS = 15_000
const DEFAULT_LIMIT = 100

/**
 * Pure filter for verification requests.
 *
 * Case-insensitive substring match on `request_id`, `task_id`,
 * `submitted_by`, and `approved_by` so operators can locate a request
 * by partial id, by the owning task, or by the agent that submitted /
 * approved it.
 *
 * Empty/whitespace query returns the input reference unchanged (no
 * new array allocation, preserves referential equality for memoisation).
 *
 * Input is never mutated.
 */
export function filterVerificationRequests(
  rows: readonly VerificationRequest[],
  query: string,
): readonly VerificationRequest[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return rows
  return rows.filter((row) => {
    if (row.request_id.toLowerCase().includes(needle)) return true
    if (row.task_id.toLowerCase().includes(needle)) return true
    if (row.submitted_by.toLowerCase().includes(needle)) return true
    if (row.approved_by && row.approved_by.toLowerCase().includes(needle)) return true
    return false
  })
}

type StatusFilter = VerificationRequestStatus | 'all'

const statusFilter = signal<StatusFilter>('all')
const searchQuery = signal('')

// Per-request mutation state. Signal-valued Map avoids component-local
// state plumbing: the row reads `rowActions.value.get(request_id)` and the
// action handler mutates a new Map to preserve signal identity semantics.
//
// State machine:
//   idle
//     → confirm-approve    (first click on 승인)
//     → compose-reject     (first click on 반려)
//   confirm-approve
//     → pending(approve)   (click 확정)
//     → idle               (click 취소)
//   compose-reject
//     → pending(reject)    (submit with reason)
//     → idle               (click 취소)
//   pending
//     → idle               (on success)
//     → error              (on failure; user can retry from idle)
type RowActionState =
  | { kind: 'idle' }
  | { kind: 'confirm-approve' }
  | { kind: 'compose-reject'; reason: string }
  | { kind: 'pending'; decision: 'approve' | 'reject' }
  | { kind: 'error'; message: string }

const rowActions = signal<ReadonlyMap<string, RowActionState>>(new Map())

function setRowAction(requestId: string, state: RowActionState): void {
  const next = new Map(rowActions.value)
  if (state.kind === 'idle') next.delete(requestId)
  else next.set(requestId, state)
  rowActions.value = next
}

const FILTER_OPTIONS: { value: StatusFilter; label: string }[] = [
  { value: 'all', label: '전체' },
  { value: 'pending', label: '검증 대기' },
  { value: 'approved', label: '승인' },
  { value: 'rejected', label: '반려' },
  { value: 'timed_out', label: '시간 초과' },
]

async function loadData(
  resource: ManagedAsyncResource<VerificationRequestsResponse>,
) {
  await resource.load(async (signal) => {
    return fetchVerificationRequests({ limit: DEFAULT_LIMIT, signal })
  })
}

// ── Label + tone maps ─────────────────────────────────

const STATUS_LABEL: Record<VerificationRequestStatus, string> = {
  pending: '검증 대기',
  approved: '승인',
  rejected: '반려',
  timed_out: '시간 초과',
}

function statusTone(s: VerificationRequestStatus): 'ok' | 'warn' | 'bad' {
  switch (s) {
    case 'approved': return 'ok'
    case 'rejected': return 'bad'
    case 'timed_out': return 'bad'
    case 'pending': return 'warn'
  }
}

const VERDICT_LABEL: Record<NonNullable<VerificationRequestVerdict>, string> = {
  pass: 'pass',
  fail: 'fail',
  partial: 'partial',
}

function verdictTone(v: VerificationRequestVerdict): 'ok' | 'warn' | 'bad' {
  switch (v) {
    case 'pass': return 'ok'
    case 'partial': return 'warn'
    case 'fail': return 'bad'
    case null: return 'warn'
  }
}

// ── Formatting helpers ────────────────────────────────

function truncate(s: string, max = 20): string {
  if (s.length <= max) return s
  return s.slice(0, max - 1) + '…'
}

function parseIso(ts: string | null | undefined): number | null {
  if (!ts) return null
  const n = Date.parse(ts)
  return Number.isNaN(n) ? null : n
}

function relativeTime(ts: string): string {
  const ms = parseIso(ts)
  if (ms == null) return ts
  const delta = (Date.now() - ms) / 1000
  if (delta < 60) return `${Math.floor(delta)}초 전`
  if (delta < 3600) return `${Math.floor(delta / 60)}분 전`
  if (delta < 86400) return `${Math.floor(delta / 3600)}시간 전`
  return `${Math.floor(delta / 86400)}일 전`
}

// ── Action handler ────────────────────────────────────

async function submitResolve(
  row: VerificationRequest,
  decision: 'approve' | 'reject',
  reason: string,
  refresh: () => void,
): Promise<void> {
  setRowAction(row.request_id, { kind: 'pending', decision })
  try {
    await resolveVerificationRequest({
      task_id: row.task_id,
      verification_id: row.request_id,
      decision,
      reason,
    })
    setRowAction(row.request_id, { kind: 'idle' })
    refresh()
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    setRowAction(row.request_id, { kind: 'error', message })
  }
}

// ── Row actions (approve/reject UI) ───────────────────

const BTN_PRIMARY =
  'rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-2xs text-[var(--text-strong)] hover:bg-[var(--bg-panel-hover)] disabled:opacity-50 disabled:cursor-not-allowed'

const BTN_SECONDARY =
  'rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-2xs text-[var(--text-body)] hover:bg-[var(--bg-panel-hover)] disabled:opacity-50 disabled:cursor-not-allowed'

function RowActions({
  row,
  state,
  refresh,
}: {
  row: VerificationRequest
  state: RowActionState
  refresh: () => void
}) {
  const requestId = row.request_id

  if (state.kind === 'pending') {
    return html`
      <span class="text-2xs text-[var(--text-muted)]">
        ${state.decision === 'approve' ? '승인 중…' : '반려 중…'}
      </span>
    `
  }

  if (state.kind === 'confirm-approve') {
    return html`
      <div class="flex items-center gap-1 flex-wrap">
        <span class="text-2xs text-[var(--text-strong)]">승인 확정?</span>
        <button
          class=${BTN_PRIMARY}
          onClick=${() => void submitResolve(row, 'approve', '', refresh)}
        >예</button>
        <button
          class=${BTN_SECONDARY}
          onClick=${() => setRowAction(requestId, { kind: 'idle' })}
        >취소</button>
      </div>
    `
  }

  if (state.kind === 'compose-reject') {
    const reason = state.reason
    const canSubmit = reason.trim().length > 0
    return html`
      <div class="flex items-center gap-1 flex-wrap">
        <input
          type="text"
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-2 py-1 text-2xs text-[var(--text-body)] w-[200px]"
          placeholder="반려 사유 (필수)"
          value=${reason}
          autofocus
          onInput=${(e: Event) => setRowAction(requestId, {
            kind: 'compose-reject',
            reason: (e.target as HTMLInputElement).value,
          })}
          onKeyDown=${(e: KeyboardEvent) => {
            if (e.key === 'Enter' && canSubmit) {
              void submitResolve(row, 'reject', reason.trim(), refresh)
            } else if (e.key === 'Escape') {
              setRowAction(requestId, { kind: 'idle' })
            }
          }}
        />
        <button
          class=${BTN_PRIMARY}
          disabled=${!canSubmit}
          onClick=${() => void submitResolve(row, 'reject', reason.trim(), refresh)}
        >확정</button>
        <button
          class=${BTN_SECONDARY}
          onClick=${() => setRowAction(requestId, { kind: 'idle' })}
        >취소</button>
      </div>
    `
  }

  // idle or error — show primary action buttons; error surfaces retry hint
  return html`
    <div class="flex items-center gap-1 flex-wrap">
      <button
        class=${BTN_PRIMARY}
        onClick=${() => setRowAction(requestId, { kind: 'confirm-approve' })}
      >승인</button>
      <button
        class=${BTN_SECONDARY}
        onClick=${() => setRowAction(requestId, { kind: 'compose-reject', reason: '' })}
      >반려</button>
      ${state.kind === 'error'
        ? html`<span class="text-3xs text-[var(--text-bad)]" title=${state.message}>
            실패 · 다시 시도
          </span>`
        : null}
    </div>
  `
}

// ── Row ───────────────────────────────────────────────

function VerificationRow({
  row,
  refresh,
}: { row: VerificationRequest; refresh: () => void }) {
  const hasContract = row.completion_contract.length > 0
  const hasEvidence = row.required_evidence.length > 0
  const hasTaskTitle = row.task_title !== ''
  const hasDetails =
    hasContract || hasEvidence || hasTaskTitle || row.verdict_reason !== ''
  const actionState = rowActions.value.get(row.request_id) ?? { kind: 'idle' as const }

  return html`
    <tr class="border-b border-[var(--card-border)] last:border-b-0 align-top">
      <td class="py-2 pr-2">
        <${StatusChip} tone=${statusTone(row.status)}>
          ${STATUS_LABEL[row.status]}
        <//>
      </td>
      <td class="py-2 pr-2">
        <code class="text-[var(--text-strong)]" title=${row.request_id}>
          ${truncate(row.request_id, 14)}
        </code>
      </td>
      <td class="py-2 pr-2">
        <code class="text-[var(--text-body)]" title=${row.task_id}>
          ${truncate(row.task_id, 20)}
        </code>
      </td>
      <td class="py-2 pr-2 text-[var(--text-body)]">${row.submitted_by}</td>
      <td class="py-2 pr-2">
        ${row.approved_by
          ? html`<span class="text-[var(--text-body)]">${row.approved_by}</span>`
          : html`<span class="text-[var(--text-muted)]">—</span>`}
      </td>
      <td class="py-2 pr-2 text-[var(--text-muted)] tabular-nums whitespace-nowrap"
          title=${row.created_at}>
        ${relativeTime(row.created_at)}
      </td>
      <td class="py-2 pr-2">
        ${row.verdict
          ? html`<${StatusChip} tone=${verdictTone(row.verdict)}>
              ${VERDICT_LABEL[row.verdict]}
            <//>`
          : html`<span class="text-[var(--text-muted)]">—</span>`}
      </td>
      <td class="py-2 pr-2">
        ${row.status === 'pending'
          ? html`<${RowActions} row=${row} state=${actionState} refresh=${refresh} />`
          : html`<span class="text-[var(--text-muted)]">—</span>`}
      </td>
      <td class="py-2">
        ${hasDetails
          ? html`
              <details class="text-2xs">
                <summary class="cursor-pointer text-[var(--text-muted)] hover:text-[var(--text-body)]">
                  자세히
                </summary>
                <div class="flex flex-col gap-2 mt-2 p-2 rounded border border-[var(--card-border)] bg-[var(--bg-0)]">
                  ${hasTaskTitle
                    ? html`
                        <div>
                          <div class="text-3xs font-semibold uppercase tracking-[0.14em] text-[var(--text-muted)] mb-1">
                            Task Title
                          </div>
                          <div class="text-[var(--text-body)]">${row.task_title}</div>
                        </div>
                      `
                    : null}
                  ${hasContract
                    ? html`
                        <div>
                          <div class="text-3xs font-semibold uppercase tracking-[0.14em] text-[var(--text-muted)] mb-1">
                            Completion Contract
                          </div>
                          <ul class="list-disc list-inside flex flex-col gap-1 text-[var(--text-body)]">
                            ${row.completion_contract.map((c) => html`<li>${c}</li>`)}
                          </ul>
                        </div>
                      `
                    : null}
                  ${hasEvidence
                    ? html`
                        <div>
                          <div class="text-3xs font-semibold uppercase tracking-[0.14em] text-[var(--text-muted)] mb-1">
                            Required Evidence
                          </div>
                          <ul class="list-disc list-inside flex flex-col gap-1 text-[var(--text-body)]">
                            ${row.required_evidence.map((e) => html`<li><code>${e}</code></li>`)}
                          </ul>
                        </div>
                      `
                    : null}
                  ${row.verdict_reason !== ''
                    ? html`
                        <div>
                          <div class="text-3xs font-semibold uppercase tracking-[0.14em] text-[var(--text-muted)] mb-1">
                            Verdict Reason
                          </div>
                          <div class="text-[var(--text-body)]">${row.verdict_reason}</div>
                        </div>
                      `
                    : null}
                </div>
              </details>
            `
          : html`<span class="text-[var(--text-muted)]">—</span>`}
      </td>
    </tr>
  `
}

// ── Table ─────────────────────────────────────────────

function RequestsTable({
  requests,
  totalBeforeFilter,
  refresh,
}: {
  requests: readonly VerificationRequest[]
  totalBeforeFilter: number
  refresh: () => void
}) {
  if (requests.length === 0) {
    const hasFilter = statusFilter.value !== 'all' || searchQuery.value.trim() !== ''
    if (hasFilter && totalBeforeFilter > 0) {
      return html`
        <${EmptyState}>
          필터 결과 없음 (${totalBeforeFilter} items)
        <//>
      `
    }
    return html`
      <${EmptyState}>
        현재 대기중이거나 완료된 검증 요청이 없습니다.
      <//>
    `
  }
  return html`
    <div class="overflow-x-auto">
      <table class="w-full text-xs">
        <thead>
          <tr class="text-[var(--text-muted)] border-b border-[var(--card-border)]">
            <th class="text-left py-1 pr-2">상태</th>
            <th class="text-left py-1 pr-2">Request</th>
            <th class="text-left py-1 pr-2">Task</th>
            <th class="text-left py-1 pr-2">제출자</th>
            <th class="text-left py-1 pr-2">승인자</th>
            <th class="text-left py-1 pr-2">생성</th>
            <th class="text-left py-1 pr-2">Verdict</th>
            <th class="text-left py-1 pr-2">액션</th>
            <th class="text-left py-1">세부</th>
          </tr>
        </thead>
        <tbody>
          ${requests.map(
            (row) => html`<${VerificationRow}
              key=${row.request_id}
              row=${row}
              refresh=${refresh}
            />`,
          )}
        </tbody>
      </table>
    </div>
  `
}

// ── Panel ─────────────────────────────────────────────

export function VerificationRequestsPanel() {
  const resourceRef = useRef<
    ManagedAsyncResource<VerificationRequestsResponse> | null
  >(null)
  if (resourceRef.current === null) {
    resourceRef.current = createManagedAsyncResource<VerificationRequestsResponse>()
  }
  const resource = resourceRef.current

  useEffect(() => {
    void loadData(resource)
    const id = setInterval(() => void loadData(resource), AUTO_REFRESH_MS)
    return () => {
      clearInterval(id)
      resource.cancel()
    }
  }, [resource])

  const current = resource.state.value
  const data = current.data ?? null
  const rows = data?.requests ?? []
  const filtered = useMemo(() => {
    const byStatus =
      statusFilter.value === 'all'
        ? rows
        : rows.filter((r) => r.status === statusFilter.value)
    return filterVerificationRequests(byStatus, searchQuery.value)
  }, [rows, statusFilter.value, searchQuery.value])

  // UX hint: when requests exist but none are pending, the 액션 column is
  // empty by design (approve/reject only apply to pending rows). Surface the
  // reason so operators don't read "—" as a broken control.
  const pendingCount = rows.filter((r) => r.status === 'pending').length
  const showNoPendingHint = rows.length > 0 && pendingCount === 0

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center gap-3 flex-wrap">
        <button
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-1 text-xs text-[var(--text-strong)] hover:bg-[var(--bg-panel-hover)]"
          onClick=${() => void loadData(resource)}
        >
          새로고침
        </button>
        ${current.loading
          ? html`<span class="text-xs text-[var(--text-muted)]">로딩 중...</span>`
          : null}
        ${data?.updated_at
          ? html`<span class="text-xs text-[var(--text-muted)]">
              updated · ${relativeTime(data.updated_at)}
            </span>`
          : null}
        ${data
          ? html`<span class="text-xs text-[var(--text-muted)]">
              ${statusFilter.value === 'all' && !searchQuery.value
                ? `총 ${data.total}건`
                : `${filtered.length} / ${data.total}건`}
            </span>`
          : null}
      </div>

      <${FilterChips}
        chips=${FILTER_OPTIONS.map((opt) => ({
          key: opt.value,
          label: opt.label,
          count: data
            ? opt.value === 'all'
              ? data.total
              : data.requests.filter((r) => r.status === opt.value).length
            : null,
        }))}
        active=${statusFilter}
      />

      <${TextInput}
        type="search"
        class="max-w-[260px]"
        placeholder="request / task / 제출자 / 승인자 필터"
        ariaLabel="검증 요청 필터"
        value=${searchQuery.value}
        onInput=${(e: Event) => { searchQuery.value = (e.target as HTMLInputElement).value }}
      />

      ${current.error ? html`<${ErrorState} message=${current.error} />` : null}

      ${current.loading && !data
        ? html`<${LoadingState}>검증 요청 불러오는 중...<//>`
        : null}

      ${showNoPendingHint
        ? html`
            <div
              role="note"
              class="rounded border border-[var(--card-border)] bg-[var(--bg-panel)] px-3 py-2 text-2xs text-[var(--text-muted)]"
            >
              검증 대기(pending) 요청이 없어 액션 컬럼이 비어 있습니다. 승인/반려 버튼은
              <code class="text-[var(--text-strong)]">pending</code> 상태에서만 표시됩니다.
            </div>
          `
        : null}

      <${Card} title="검증 요청">
        ${data
          ? html`<${RequestsTable}
              requests=${filtered}
              totalBeforeFilter=${data.requests.length}
              refresh=${() => void loadData(resource)}
            />`
          : null}
      <//>
    </div>
  `
}
