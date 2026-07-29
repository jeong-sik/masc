import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { LoadingState } from './common/feedback-state'
import {
  fetchMemorySubsystems,
  type MemorySubsystemsResponse,
  type MemorySubsystemsDelegationRequest,
} from '../api/dashboard'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { DEFAULT_PANEL_REFRESH_MS, setupVisibleAutoRefresh } from '../lib/auto-refresh'

function DelegationRequestRow({
  request,
}: {
  readonly request: MemorySubsystemsDelegationRequest
}) {
  return html`
    <div
      class="v2-monitoring-row grid grid-cols-[10rem_7rem_minmax(0,1fr)_minmax(12rem,20rem)] items-start gap-2 border-b border-[var(--color-border-default)] px-2 py-2 text-xs last:border-b-0 max-lg:grid-cols-[8rem_minmax(0,1fr)]"
      role="listitem"
      aria-label=${`${request.id} · ${request.promotion_state} · ${request.topic}`}
    >
      <span class="min-w-0 truncate font-mono text-[var(--color-fg-muted)]" title=${request.id}>
        ${request.id}
      </span>
      <span class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-1.5 py-0.5 text-center font-mono text-[var(--color-status-warn)]">
        ${request.promotion_state}
      </span>
      <span class="min-w-0 truncate text-[var(--color-fg-primary)]" title=${request.topic}>
        ${request.requester}: ${request.topic}
      </span>
      <span class="min-w-0 truncate font-mono text-[var(--color-fg-disabled)] max-lg:col-span-2" title=${request.task_seed_md_path}>
        ${request.task_seed_md_path}
      </span>
    </div>
  `
}

function DelegationRequestsPanel({
  total,
  shown,
  indexPath,
  requests,
  error,
}: {
  readonly total: number
  readonly shown: number
  readonly indexPath: string
  readonly requests: readonly MemorySubsystemsDelegationRequest[]
  readonly error?: string | null
}) {
  return html`
    <section
      data-testid="delegation-requests"
      aria-label=${`Delegation requests · ${shown} shown`}
      class="flex flex-col gap-2"
    >
      <div class="flex flex-wrap items-center gap-2">
        <h3 class="text-base font-semibold text-[var(--color-fg-muted)]">Delegation requests</h3>
        <span class="font-mono text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">
          ${indexPath}
        </span>
        <span class="ml-auto text-xs text-[var(--color-fg-muted)]">
          total ${total} · shown ${shown}
        </span>
      </div>
      ${
        error
          ? html`<div
              role="alert"
              class="rounded-[var(--r-1)] border border-[var(--warn-fg)] bg-[var(--warn-bg)] px-3 py-2 text-2xs text-[var(--color-fg-primary)]"
            >${error}</div>`
          : null
      }
      ${
        requests.length === 0
          ? html`<div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] p-4 text-center text-sm text-[var(--color-fg-muted)]">
              delegation request 없음
            </div>`
          : html`
              <div
                class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)]"
                role="list"
                aria-label=${`${shown} delegation requests`}
              >
                ${requests.map(request => html`<${DelegationRequestRow} request=${request} />`)}
              </div>
            `
      }
    </section>
  `
}

export function MemorySubsystems() {
  const resource = useManagedAsyncResource<MemorySubsystemsResponse>(null)

  useEffect(() => {
    const run = () => {
      void resource.load(async (signal) =>
        fetchMemorySubsystems({ limit: 100, signal }),
      )
    }
    run()
    const cleanup = setupVisibleAutoRefresh(run, DEFAULT_PANEL_REFRESH_MS)
    return () => {
      resource.cancel()
      cleanup()
    }
  }, [resource])

  const { loading, error, data } = resource.state.value

  if (loading && !data) return html`<${LoadingState} label="기억 서브시스템 로드 중..." />`
  if (error && !data)
    return html`<div class="p-4 text-[var(--bad-light)]">오류: ${error}</div>`

  const delegationRequestBlock = data?.delegation_requests
  const delegationRequests = delegationRequestBlock?.items ?? []

  return html`
    <div class="space-y-6">
      <${DelegationRequestsPanel}
        total=${delegationRequestBlock?.total ?? delegationRequests.length}
        shown=${delegationRequestBlock?.shown ?? delegationRequests.length}
        indexPath=${delegationRequestBlock?.index_path ?? '.masc/delegation-requests/index.jsonl'}
        requests=${delegationRequests}
        error=${delegationRequestBlock?.error ?? null}
      />

      ${error ? html`<div class="text-xs text-[var(--color-status-warn)] mt-2">refresh error: ${error}</div>` : null}
    </div>
  `
}
