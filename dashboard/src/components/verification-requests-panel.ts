// VerificationRequestsPanel — Mission detail surface for cross-agent
// verification requests.
//
// Consumes:
//   GET /api/v1/verification/requests?task_id=&limit=
//
// Pattern mirrors CascadeConfigPanel: managed async resource + manual
// refresh + 15s auto-tick. Row expansion uses <details> so we avoid
// component-local state plumbing for a read-only table.

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import { signal } from '@preact/signals'
import {
  fetchVerificationRequests,
  type VerificationRequest,
  type VerificationRequestStatus,
  type VerificationRequestVerdict,
  type VerificationRequestsResponse,
} from '../api/dashboard'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { ErrorState, LoadingState } from './common/feedback-state'
import { StatusChip } from './common/status-chip'
import {
  createManagedAsyncResource,
  type ManagedAsyncResource,
} from '../lib/async-state'

const AUTO_REFRESH_MS = 15_000
const DEFAULT_LIMIT = 100

type StatusFilter = VerificationRequestStatus | 'all'

const statusFilter = signal<StatusFilter>('all')

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

// ── Row ───────────────────────────────────────────────

function VerificationRow({ row }: { row: VerificationRequest }) {
  const hasContract = row.completion_contract.length > 0
  const hasEvidence = row.required_evidence.length > 0
  const hasDetails = hasContract || hasEvidence || row.verdict_reason !== ''

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
      <td class="py-2">
        ${hasDetails
          ? html`
              <details class="text-[11px]">
                <summary class="cursor-pointer text-[var(--text-muted)] hover:text-[var(--text-body)]">
                  자세히
                </summary>
                <div class="flex flex-col gap-2 mt-2 p-2 rounded border border-[var(--card-border)] bg-[var(--bg-0)]">
                  ${hasContract
                    ? html`
                        <div>
                          <div class="text-[10px] font-semibold uppercase tracking-[0.14em] text-[var(--text-muted)] mb-1">
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
                          <div class="text-[10px] font-semibold uppercase tracking-[0.14em] text-[var(--text-muted)] mb-1">
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
                          <div class="text-[10px] font-semibold uppercase tracking-[0.14em] text-[var(--text-muted)] mb-1">
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

function RequestsTable({ requests }: { requests: VerificationRequest[] }) {
  if (requests.length === 0) {
    return html`
      <${EmptyState}>
        ${statusFilter.value === 'all'
          ? '현재 대기중이거나 완료된 검증 요청이 없습니다.'
          : `"${STATUS_LABEL[statusFilter.value as VerificationRequestStatus]}" 상태의 요청이 없습니다.`}
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
            <th class="text-left py-1">세부</th>
          </tr>
        </thead>
        <tbody>
          ${requests.map(
            (row) => html`<${VerificationRow} key=${row.request_id} row=${row} />`,
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
  const filtered = data
    ? statusFilter.value === 'all'
      ? data.requests
      : data.requests.filter((r) => r.status === statusFilter.value)
    : []

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
              ${statusFilter.value === 'all'
                ? `총 ${data.total}건`
                : `${filtered.length} / ${data.total}건`}
            </span>`
          : null}
      </div>

      <div class="flex items-center gap-1.5 flex-wrap">
        ${FILTER_OPTIONS.map((opt) => html`
          <button
            class=${`rounded px-2 py-0.5 text-[11px] border transition-colors ${
              statusFilter.value === opt.value
                ? 'bg-[var(--text-strong)] text-[var(--bg-0)] border-[var(--text-strong)]'
                : 'bg-[var(--bg-0)] text-[var(--text-muted)] border-[var(--card-border)] hover:text-[var(--text-body)]'
            }`}
            onClick=${() => { statusFilter.value = opt.value }}
          >${opt.label}</button>
        `)}
      </div>

      ${current.error ? html`<${ErrorState} message=${current.error} />` : null}

      ${current.loading && !data
        ? html`<${LoadingState}>검증 요청 불러오는 중...<//>`
        : null}

      <${Card} title="검증 요청">
        ${data ? html`<${RequestsTable} requests=${filtered} />` : null}
      <//>
    </div>
  `
}
