// GoalVerificationRunsPanel — independent Goal-verifier attempts and their
// exact lookup/verdict tool calls.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import {
  fetchGoalVerificationRuns,
  type DashboardGoalVerificationRunsResponse,
  type GoalVerificationRunRecord,
  type GoalVerificationRunStatus,
} from '../api/dashboard'
import type { ManagedAsyncResource } from '../lib/async-state'
import { relativeTime } from '../lib/format-time'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { truncate } from '../lib/truncate'
import { registerInternalAgentRefresh } from '../sse-store'
import { Btn } from './btn'
import { EmptyState, ErrorState } from './common/feedback-state'
import { StatusBadge, type StatusBadgeTone } from './common/status-badge'

export function goalVerificationRunTone(status: GoalVerificationRunStatus): StatusBadgeTone {
  switch (status) {
    case 'running': return 'warn'
    case 'reviewed': return 'info'
    case 'committed': return 'ok'
    case 'deferred': return 'info'
    case 'raised': return 'bad'
  }
}

export function goalVerificationRunLabel(status: GoalVerificationRunStatus): string {
  switch (status) {
    case 'running': return '판정 중'
    case 'reviewed': return '판정 기록됨'
    case 'committed': return '커밋됨'
    case 'deferred': return '보류'
    case 'raised': return '예외'
  }
}

function formatElapsed(seconds: number | undefined): string {
  if (seconds == null) return '—'
  if (seconds < 1) return `${Math.round(seconds * 1000)}ms`
  return `${seconds.toFixed(1)}s`
}

async function loadData(resource: ManagedAsyncResource<DashboardGoalVerificationRunsResponse>) {
  await resource.load(async signal => fetchGoalVerificationRuns({ signal }))
}

function ToolCalls({ row }: { row: GoalVerificationRunRecord }) {
  const tools = row.tools ?? []
  if (tools.length === 0) return html`<span class="text-[var(--color-fg-muted)]">—</span>`
  const label = `${tools.length} tool call${tools.length === 1 ? '' : 's'}`
  return html`
    <details data-goal-verification-tools=${row.runId}>
      <summary class="cursor-pointer text-[var(--color-fg-accent)]">${label}</summary>
      <ol class="mt-2 flex flex-col gap-2" aria-label=${`Goal verifier tools for ${row.goalId}`}>
        ${tools.map((tool, index) => html`
          <li key=${`${tool.toolName}-${index}`} class="rounded border border-[var(--color-border-default)] p-2">
            <div class="flex flex-wrap gap-2">
              <code>${tool.toolName}</code>
              <span>${tool.disposition}</span>
              <span class="tabular-nums">${Math.round(tool.durationMs)}ms</span>
            </div>
            <pre class="mt-1 whitespace-pre-wrap break-words text-[var(--color-fg-muted)]">${tool.outputExcerpt}</pre>
          </li>
        `)}
      </ol>
    </details>
  `
}

function GoalVerificationRunRow({ row }: { row: GoalVerificationRunRecord }) {
  return html`
    <tr
      class="v2-workspace-row border-b border-[var(--color-border-default)] last:border-b-0 align-top"
      data-goal-verification-run=${row.runId}
      data-goal-id=${row.goalId}
      data-run-status=${row.status}
      data-review-kind=${row.reviewKind}
    >
      <td class="py-2 pr-2">
        <${StatusBadge}
          tone=${goalVerificationRunTone(row.status)}
          label=${goalVerificationRunLabel(row.status)}
        />
      </td>
      <td class="py-2 pr-2"><code title=${row.goalId}>${truncate(row.goalId, 24)}</code></td>
      <td class="py-2 pr-2">완료증명</td>
      <td class="py-2 pr-2" title=${row.authorityActor}>${row.evaluatorRuntime ?? '—'}</td>
      <td class="py-2 pr-2 tabular-nums">${formatElapsed(row.elapsedSeconds)}</td>
      <td class="py-2 pr-2 whitespace-nowrap">${relativeTime(new Date(row.startedAt * 1000).toISOString())}</td>
      <td class="py-2 pr-2 break-words">
        ${row.retryable === false ? html`<strong>[수동 확인 필요]</strong> ` : null}${row.detail ?? ''}
      </td>
      <td class="py-2"><${ToolCalls} row=${row} /></td>
    </tr>
  `
}

export function GoalVerificationRunsPanel() {
  const resource = useManagedAsyncResource<DashboardGoalVerificationRunsResponse>()

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
    <div
      class="v2-workspace-surface flex flex-col gap-3"
      data-testid="goal-verification-runs-panel"
    >
      <div class="flex flex-wrap items-center gap-3">
        <h2 class="text-sm font-semibold text-[var(--color-fg-primary)]">Goal 판정 실행</h2>
        <${Btn} class="v2-workspace-action" onClick=${() => void loadData(resource)}>새로고침<//>
        ${current.loading ? html`<span role="status">로딩 중...</span>` : null}
        ${data?.generatedAt ? html`<span>updated · ${relativeTime(data.generatedAt)}</span>` : null}
      </div>
      ${current.error
        ? html`<${ErrorState}>Goal 판정 실행을 불러오지 못했습니다: ${current.error}<//>`
        : rows.length === 0
          ? html`<${EmptyState}>기록된 Goal 판정 실행이 없습니다.<//>`
          : html`
              <div class="overflow-x-auto">
                <table class="w-full text-xs">
                  <thead><tr>
                    <th scope="col">결과</th><th scope="col">Goal</th><th scope="col">종류</th>
                    <th scope="col">판정 런타임</th><th scope="col">소요</th><th scope="col">시작</th>
                    <th scope="col">사유</th><th scope="col">도구 증거</th>
                  </tr></thead>
                  <tbody>${rows.map(row => html`<${GoalVerificationRunRow} key=${row.runId} row=${row} />`)}</tbody>
                </table>
              </div>
            `}
    </div>
  `
}
