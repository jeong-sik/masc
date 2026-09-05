// VerificationRunsPanel — what the completion authority actually did.
//
// Consumes:
//   GET /api/v1/dashboard/verification-runs   (RFC-0361 D4)
//
// Sits beside VerificationRequestsPanel and answers the other half of the
// question. A *request* is what a Keeper submitted; a *run* is the review of
// it. Before the registry, a review that produced no verdict — an unavailable
// evaluator, a malformed verdict, a failed commit, a raise — left no trace at
// all, so an operator could not tell a pending request from one whose review
// had already run and come back empty.
//
// Pattern mirrors VerificationRequestsPanel: managed async resource + manual
// refresh + 15s auto-tick, read-only table.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import {
  fetchVerificationRuns,
  type DashboardVerificationRunsResponse,
  type VerificationRunRecord,
  type VerificationRunStatusLabel,
} from '../api/dashboard'
import { Btn } from './btn'
import { EmptyState, ErrorState } from './common/feedback-state'
import { StatusBadge, type StatusBadgeTone } from './common/status-badge'
import { relativeTime } from '../lib/format-time'
import type { ManagedAsyncResource } from '../lib/async-state'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { truncate } from '../lib/truncate'
import { registerInternalAgentRefresh } from '../sse-store'

/** Outcome → badge tone.
 *
 *  Exhaustive by design (no `default` arm): a new backend outcome must fail
 *  type-checking here rather than silently render as neutral.
 *
 *  `rejected` is `info`, not a warning: a rejection returns the producer to
 *  work, which is the review loop functioning. The tones that mean something
 *  is wrong are the ones where no verdict reached the Task —
 *  `not_reviewed` / `commit_failed` / `raised`. Protocol breaks are rejected by
 *  the decoder before a row reaches this projection.
 *
 *  `infrastructure_unavailable` is bad because no semantic verdict reached
 *  the Task; the submitted obligation remains pending for retry. */
export function verificationRunTone(status: VerificationRunStatusLabel): StatusBadgeTone {
  switch (status) {
    case 'running':
      return 'warn'
    case 'approved':
      return 'ok'
    case 'rejected':
      return 'info'
    case 'infrastructure_unavailable':
      return 'bad'
    case 'not_reviewed':
    case 'commit_failed':
    case 'raised':
      return 'bad'
    case 'operator_routed':
      return 'info'
  }
}

/** Operator-facing label. Korean where the backend token is not itself the
    clearest thing to show; the raw token stays available via the row title. */
export function verificationRunLabel(status: VerificationRunStatusLabel): string {
  switch (status) {
    case 'running':
      return '판정 중'
    case 'approved':
      return '승인'
    case 'rejected':
      return '거부'
    case 'infrastructure_unavailable':
      return '판정 기반시설 오류'
    case 'not_reviewed':
      return '판정 없음'
    case 'commit_failed':
      return '커밋 실패'
    case 'raised':
      return '예외'
    case 'operator_routed':
      return '운영자 판정 대기'
  }
}

function formatElapsed(seconds: number | undefined): string {
  if (seconds == null) return '—'
  if (seconds < 1) return `${Math.round(seconds * 1000)}ms`
  return `${seconds.toFixed(1)}s`
}

async function loadData(resource: ManagedAsyncResource<DashboardVerificationRunsResponse>) {
  await resource.load(async (signal) => fetchVerificationRuns({ signal }))
}

function ThLeft({ children }: { children: unknown }) {
  return html`<th scope="col" class="text-left py-1 pr-2">${children}</th>`
}

function VerificationRunRow({ row }: { row: VerificationRunRecord }) {
  return html`
    <tr class="v2-workspace-row border-b border-[var(--color-border-default)] last:border-b-0 align-top">
      <td class="py-2 pr-2">
        <${StatusBadge}
          tone=${verificationRunTone(row.status)}
          label=${verificationRunLabel(row.status)}
        />
      </td>
      <td class="py-2 pr-2">
        <code class="text-[var(--color-fg-primary)]" title=${row.taskId}>
          ${truncate(row.taskId, 20)}
        </code>
      </td>
      <td class="py-2 pr-2 text-[var(--color-fg-primary)]">${row.producer}</td>
      <td class="py-2 pr-2 text-[var(--color-fg-muted)]" title=${row.authorityActor}>
        ${row.evaluatorRuntime ?? '—'}
      </td>
      <td class="py-2 pr-2 text-[var(--color-fg-muted)] tabular-nums whitespace-nowrap">
        ${formatElapsed(row.elapsedSeconds)}
      </td>
      <td class="py-2 pr-2 text-[var(--color-fg-muted)] tabular-nums whitespace-nowrap">
        ${relativeTime(new Date(row.startedAt * 1000).toISOString())}
      </td>
      <td class="py-2 text-[var(--color-fg-secondary)] break-words">
        ${row.gate ? html`<code class="mr-1">${row.gate}</code>` : null}
        ${row.infrastructureStage ? html`<code class="mr-1">${row.infrastructureStage}</code>` : null}
        ${row.retryable === false
          ? html`<span
              class="mr-1 font-semibold text-destructive"
              title="같은 이유로 계속 실패할 것으로 판단되어 자동 재시도가 멈췄습니다. 확인 후 조치가 필요합니다."
            >[수동 확인 필요]</span>`
          : null}
        ${row.cause ?? ''}
      </td>
    </tr>
  `
}

export function VerificationRunsPanel() {
  const resource = useManagedAsyncResource<DashboardVerificationRunsResponse>()

  useEffect(() => {
    void loadData(resource)
    const unregister = registerInternalAgentRefresh(() => { void loadData(resource) })
    return () => {
      unregister()
      resource.cancel()
    }
  }, [resource])

  const current = resource.state.value
  const data = current.data ?? null
  const rows = data?.runs ?? []

  return html`
    <div class="v2-workspace-surface flex flex-col gap-3">
      <div class="flex items-center gap-3 flex-wrap">
        <h2 class="text-sm font-semibold text-[var(--color-fg-primary)]">판정 실행</h2>
        <${Btn} class="v2-workspace-action" onClick=${() => void loadData(resource)}>
          새로고침
        <//>
        ${current.loading
          ? html`<span class="text-xs text-[var(--color-fg-muted)]" role="status">로딩 중...</span>`
          : null}
        ${data?.generatedAt
          ? html`<span class="text-xs text-[var(--color-fg-muted)]">
              updated · ${relativeTime(data.generatedAt)}
            </span>`
          : null}
      </div>

      ${current.error
        ? html`<${ErrorState}>판정 실행 목록을 불러오지 못했습니다: ${current.error}<//>`
        : rows.length === 0
          ? html`<${EmptyState}>기록된 판정 실행이 없습니다.<//>`
          : html`
              <div class="overflow-x-auto">
                <table class="w-full text-xs">
                  <thead class="text-[var(--color-fg-muted)] border-b border-[var(--color-border-default)]">
                    <tr>
                      <${ThLeft}>결과<//>
                      <${ThLeft}>태스크<//>
                      <${ThLeft}>생산자<//>
                      <${ThLeft}>판정 런타임<//>
                      <${ThLeft}>소요<//>
                      <${ThLeft}>시작<//>
                      <${ThLeft}>사유<//>
                    </tr>
                  </thead>
                  <tbody>
                    ${rows.map(
                      (row) =>
                        html`<${VerificationRunRow} key=${row.verificationId} row=${row} />`,
                    )}
                  </tbody>
                </table>
              </div>
            `}
    </div>
  `
}
