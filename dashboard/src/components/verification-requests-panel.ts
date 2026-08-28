// VerificationRequestsPanel — Mission detail surface for cross-agent
// verification requests.
//
// Consumes:
//   GET /api/v1/verification/requests?task_id=&limit=
//
// Pattern mirrors RuntimeConfigPanel: managed async resource + manual
// refresh + 15s auto-tick. Row expansion uses <details> so we avoid
// component-local state plumbing for a read-only table. Async task verdicts
// belong to the system LLM completion-authority boundary, not a Keeper claim.

import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import { signal } from '@preact/signals'
import {
  fetchVerificationRequests,
  type VerificationRequest,
  type VerificationRequestsResponse,
} from '../api/dashboard'
import { Btn } from './btn'
import { SectionCard } from './common/card'
import { EmptyState } from './common/feedback-state'
import { ErrorState, LoadingState } from './common/feedback-state'
import { relativeTime } from '../lib/format-time'
import { TextInput } from './common/input'
import type { ManagedAsyncResource } from '../lib/async-state'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { truncate } from '../lib/truncate'
import { route } from '../router'

function ThLeft({ children }: { children: unknown }) {
  return html`<th scope="col" class="text-left py-1 pr-2">${children}</th>`
}

const AUTO_REFRESH_MS = 15_000
const DEFAULT_LIMIT = 100

/**
 * Pure filter for verification requests.
 *
 * Case-insensitive substring match on `request_id`, `task_id`,
 * and `submitted_by`.
 *
 * Empty/whitespace query returns the input reference unchanged (no
 * new array allocation, preserves referential equality for memoisation).
 *
 * Input is never mutated.
 */
function filterVerificationRequests(
  rows: readonly VerificationRequest[],
  query: string,
): readonly VerificationRequest[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return rows
  return rows.filter((row) => {
    if (row.request_id.toLowerCase().includes(needle)) return true
    if (row.task_id.toLowerCase().includes(needle)) return true
    if (row.submitted_by.toLowerCase().includes(needle)) return true
    return false
  })
}

const searchQuery = signal('')

export function __resetVerificationRequestsPanelForTest(): void {
  searchQuery.value = ''
}

async function loadData(
  resource: ManagedAsyncResource<VerificationRequestsResponse>,
) {
  await resource.load(async (signal) => {
    return fetchVerificationRequests({ limit: DEFAULT_LIMIT, signal })
  })
}

function DetailLabel({ children }: { children: unknown }) {
  return html`
    <div class="text-3xs font-semibold uppercase tracking-4 text-[var(--color-fg-muted)] mb-1">
      ${children}
    </div>
  `
}

// ── Row ───────────────────────────────────────────────

function VerificationRow({ row }: { row: VerificationRequest }) {
  const hasContract = row.completion_contract.length > 0
  const hasRequiredArtifacts = row.required_artifacts.length > 0
  const hasSubmittedEvidence = row.submitted_evidence.length > 0
  const hasEvidenceProjectionError = row.evidence_projection_error != null
  const hasTaskTitle = row.task_title !== ''
  const hasDetails =
    hasContract ||
    hasRequiredArtifacts ||
    hasSubmittedEvidence ||
    hasEvidenceProjectionError ||
    hasTaskTitle
  return html`
    <tr class="v2-workspace-row border-b border-[var(--color-border-default)] last:border-b-0 align-top">
      <td class="py-2 pr-2">
        <code class="text-[var(--color-fg-secondary)]" title=${row.request_id}>
          ${truncate(row.request_id, 14)}
        </code>
      </td>
      <td class="py-2 pr-2">
        <code class="text-[var(--color-fg-primary)]" title=${row.task_id}>
          ${truncate(row.task_id, 20)}
        </code>
      </td>
      <td class="py-2 pr-2 text-[var(--color-fg-primary)]">${row.submitted_by}</td>
      <td class="py-2 pr-2 text-[var(--color-fg-muted)] tabular-nums whitespace-nowrap"
          title=${row.created_at}>
        ${relativeTime(row.created_at)}
      </td>
      <td class="py-2">
        ${hasEvidenceProjectionError
          ? html`
              <div
                role="alert"
                class="mb-1 text-3xs text-[var(--text-bad)]"
              >
                Evidence projection error: ${row.evidence_projection_error}
              </div>
            `
          : null}
        ${hasDetails
          ? html`
              <details class="text-2xs">
                <summary class="cursor-pointer text-[var(--color-fg-muted)] hover:text-[var(--color-fg-primary)]">
                  자세히
                </summary>
                <div class="v2-workspace-detail flex flex-col gap-2 mt-2 p-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)]">
                  ${hasTaskTitle
                    ? html`
                        <div>
                          <${DetailLabel}>Task Title</${DetailLabel}>
                          <div class="text-[var(--color-fg-primary)]">${row.task_title}</div>
                        </div>
                      `
                    : null}
                  ${hasContract
                    ? html`
                        <div>
                          <${DetailLabel}>Completion Contract</${DetailLabel}>
                          <ul class="list-disc list-inside flex flex-col gap-1 text-[var(--color-fg-primary)]">
                            ${row.completion_contract.map((c) => html`<li>${c}</li>`)}
                          </ul>
                        </div>
                      `
                    : null}
                  ${hasRequiredArtifacts
                    ? html`
                        <div>
                          <${DetailLabel}>Required Artifacts</${DetailLabel}>
                          <ul class="list-disc list-inside flex flex-col gap-1 text-[var(--color-fg-primary)] break-words">
                            ${row.required_artifacts.map((artifact) => html`<li><code>${artifact}</code></li>`)}
                          </ul>
                        </div>
                      `
                    : null}
                  ${hasSubmittedEvidence
                    ? html`
                        <div>
                          <${DetailLabel}>Submitted Evidence</${DetailLabel}>
                          <!-- Identity lines are producer-supplied: the live store holds a
                               1083-char reference and 77 notes over 200 chars, and a path has
                               no spaces to break at. Without break-words these overflow the
                               row horizontally instead of wrapping. -->
                          <ul class="list-disc list-inside flex flex-col gap-1 text-[var(--color-fg-primary)] break-words">
                            ${row.submitted_evidence.map((evidence) => html`<li><code>${evidence}</code></li>`)}
                          </ul>
                        </div>
                      `
                    : null}
                </div>
              </details>
            `
          : html`<span class="text-[var(--color-fg-muted)]">—</span>`}
      </td>
    </tr>
  `
}

// ── Table ─────────────────────────────────────────────

function RequestsTable({
  requests,
  totalBeforeFilter,
}: {
  requests: readonly VerificationRequest[]
  totalBeforeFilter: number
}) {
  if (requests.length === 0) {
    const hasFilter = searchQuery.value.trim() !== ''
    if (hasFilter && totalBeforeFilter > 0) {
      return html`
        <${EmptyState}>
          필터 결과 없음 (${totalBeforeFilter} items)
        <//>
      `
    }
    return html`
      <${EmptyState}>
        검증 제출이 없습니다.
      <//>
    `
  }
  return html`
    <div class="overflow-x-auto">
      <table class="v2-workspace-table w-full text-xs" aria-label="검증 요청 목록">
        <thead>
          <tr class="text-[var(--color-fg-muted)] border-b border-[var(--color-border-default)]">
            <${ThLeft}>요청</${ThLeft}>
            <${ThLeft}>작업</${ThLeft}>
            <${ThLeft}>제출자</${ThLeft}>
            <${ThLeft}>생성</${ThLeft}>
            <th scope="col" class="text-left py-1">세부</th>
          </tr>
        </thead>
        <tbody>
          ${requests.map(
            (row) => html`<${VerificationRow}
              key=${row.request_id}
              row=${row}
            />`,
          )}
        </tbody>
      </table>
    </div>
  `
}

// ── Panel ─────────────────────────────────────────────

export function VerificationRequestsPanel() {
  const resource = useManagedAsyncResource<VerificationRequestsResponse>()

  useEffect(() => {
    void loadData(resource)
    const id = setInterval(() => void loadData(resource), AUTO_REFRESH_MS)
    return () => {
      clearInterval(id)
      resource.cancel()
    }
  }, [resource])

  // Deep-link support: task-detail-overlay renders a read-only "검증 보기" link with
  // ?task=<id> so operators land on this panel pre-filtered to the pending
  // request they came from. Treat the URL as a one-shot hint — write the
  // task id into the shared search signal once on mount (and whenever the
  // route param changes), but leave subsequent typing in the search input
  // untouched so operators can widen the filter manually.
  const taskParam = route.value.params.task
  useEffect(() => {
    if (taskParam && searchQuery.value !== taskParam) {
      searchQuery.value = taskParam
    }
  }, [taskParam])

  const current = resource.state.value
  const data = current.data ?? null
  const rows = data?.requests ?? []
  const filtered = useMemo(
    () => filterVerificationRequests(rows, searchQuery.value),
    [rows, searchQuery.value],
  )

  return html`
    <div class="v2-workspace-surface flex flex-col gap-4">
      <div class="flex items-center gap-3 flex-wrap">
        <${Btn} class="v2-workspace-action" onClick=${() => void loadData(resource)}>
          새로고침
        <//>
        ${current.loading
          ? html`<span class="text-xs text-[var(--color-fg-muted)]" role="status">로딩 중...</span>`
          : null}
        ${data?.updated_at
          ? html`<span class="text-xs text-[var(--color-fg-muted)]">
              updated · ${relativeTime(data.updated_at)}
            </span>`
          : null}
        ${data
          ? html`<span class="text-xs text-[var(--color-fg-muted)]">
              ${!searchQuery.value ? `총 ${data.total}건` : `${filtered.length} / ${data.total}건`}
            </span>`
          : null}
      </div>

      <${TextInput}
        type="search"
        class="max-w-65"
        placeholder="request / task / 제출자 필터"
        ariaLabel="검증 요청 필터"
        value=${searchQuery.value}
        onInput=${(e: Event) => { searchQuery.value = (e.target as HTMLInputElement).value }}
      />

      ${current.error ? html`<${ErrorState} message=${current.error} />` : null}

      ${current.loading && !data
        ? html`<${LoadingState}>검증 요청 불러오는 중...<//>`
        : null}

      <${SectionCard} label="검증 요청">
        ${data
          ? html`<${RequestsTable}
              requests=${filtered}
              totalBeforeFilter=${data.requests.length}
            />`
          : null}
      <//>
    </div>
  `
}
