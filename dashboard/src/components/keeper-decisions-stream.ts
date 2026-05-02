import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { createAsyncResource, type AsyncResource } from '../lib/async-state'
import { fetchKeeperDecisions, type KeeperDecision, type KeeperDecisionsResponse } from '../api/dashboard'
import { formatTimeHms } from '../lib/format-time'
import { AsyncContainer } from './common/async-container'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { KeeperBadge } from './keeper-badge'

interface DecisionStats {
  total: number
  success: number
  error: number
  tool: number
}

const decisions: AsyncResource<KeeperDecisionsResponse> = createAsyncResource()

export function decisionOutcomeTone(outcome?: string | null): string {
  switch ((outcome ?? '').trim().toLowerCase()) {
    case 'success':
    case 'ok':
      return 'text-[var(--color-status-ok)]'
    case 'error':
    case 'failed':
    case 'failure':
      return 'text-[var(--color-status-err)]'
    default:
      return 'text-[var(--color-fg-muted)]'
  }
}

export function formatDecisionTime(tsUnix: number | null): string {
  return tsUnix == null ? '-' : formatTimeHms(tsUnix)
}

export function summarizeDecisionEvents(events: readonly KeeperDecision[]): DecisionStats {
  return events.reduce<DecisionStats>(
    (acc, event) => {
      acc.total += 1
      const outcome = (event.outcome ?? '').trim().toLowerCase()
      if (outcome === 'success' || outcome === 'ok') acc.success += 1
      if (outcome === 'error' || outcome === 'failed' || outcome === 'failure') acc.error += 1
      if (event.tool) acc.tool += 1
      return acc
    },
    { total: 0, success: 0, error: 0, tool: 0 },
  )
}

function MetricCell({ label, value }: { label: string; value: string | number }) {
  return html`
    <div class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-3 py-2">
      <div class="font-mono text-3xs uppercase tracking-[0.08em] text-[var(--color-fg-muted)]">${label}</div>
      <div class="mt-1 font-mono text-lg font-semibold leading-none text-[var(--color-fg-primary)]">${value}</div>
    </div>
  `
}

export function KeeperDecisionsTable({
  events,
  limit,
}: {
  events: KeeperDecision[]
  limit: number
}) {
  if (events.length === 0) {
    return html`<${EmptyState} message="No keeper decision events are available yet." compact />`
  }

  const stats = summarizeDecisionEvents(events)

  return html`
    <div class="flex flex-col gap-3">
      <div class="grid grid-cols-[repeat(auto-fit,minmax(120px,1fr))] gap-2">
        <${MetricCell} label="events" value=${stats.total} />
        <${MetricCell} label="success" value=${stats.success} />
        <${MetricCell} label="errors" value=${stats.error} />
        <${MetricCell} label="tool-linked" value=${stats.tool} />
      </div>

      <div class="flex items-center justify-between rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-3 py-2">
        <span class="font-mono text-3xs uppercase tracking-[0.08em] text-[var(--color-fg-muted)]">
          keeper decisions · ${events.length} events · limit ${limit}
        </span>
      </div>

      <div class="overflow-x-auto rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)]">
        <table class="w-full min-w-[760px]" aria-label="Keeper decision events">
          <thead>
            <tr class="border-b border-[var(--color-border-default)] text-3xs uppercase tracking-[0.08em] text-[var(--color-fg-muted)]">
              <th scope="col" class="px-2 py-1.5 text-left">time</th>
              <th scope="col" class="px-2 py-1.5 text-left">keeper</th>
              <th scope="col" class="px-2 py-1.5 text-left">event</th>
              <th scope="col" class="px-2 py-1.5 text-left">outcome</th>
              <th scope="col" class="px-2 py-1.5 text-left">model</th>
              <th scope="col" class="px-2 py-1.5 text-right">latency</th>
              <th scope="col" class="px-2 py-1.5 text-right">cost</th>
              <th scope="col" class="px-2 py-1.5 text-left">tool</th>
            </tr>
          </thead>
          <tbody>
            ${events.map((event, index) => html`
              <tr key=${`${event.ts_unix ?? 'na'}:${event.keeper_name}:${index}`} class="border-b border-[var(--color-border-default)]/50 text-2xs">
                <td class="px-2 py-1.5 text-left font-mono text-[var(--color-fg-muted)]">${formatDecisionTime(event.ts_unix)}</td>
                <td class="px-2 py-1.5 text-left">
                  <${KeeperBadge} id=${event.keeper_name} variant="full" size="sm" />
                </td>
                <td class="px-2 py-1.5 text-left font-mono text-[var(--color-fg-primary)]">${event.event_type}</td>
                <td class="px-2 py-1.5 text-left font-mono ${decisionOutcomeTone(event.outcome)}">${event.outcome ?? '-'}</td>
                <td class="px-2 py-1.5 text-left font-mono text-[var(--color-fg-muted)]">${event.model_used ?? '-'}</td>
                <td class="px-2 py-1.5 text-right font-mono text-[var(--color-fg-muted)]">
                  ${event.latency_ms == null ? '-' : `${Math.round(event.latency_ms)}ms`}
                </td>
                <td class="px-2 py-1.5 text-right font-mono text-[var(--color-fg-muted)]">
                  ${event.cost_usd == null ? '-' : `$${event.cost_usd.toFixed(4)}`}
                </td>
                <td class="px-2 py-1.5 text-left font-mono text-[var(--color-fg-muted)]">${event.tool ?? '-'}</td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
    </div>
  `
}

function loadDecisions(limit: number): Promise<void> {
  return decisions.load(() => fetchKeeperDecisions(limit))
}

export function KeeperDecisionsStream({ limit = 200 }: { limit?: number }) {
  useEffect(() => {
    void loadDecisions(limit)
  }, [limit])

  return html`
    <${Card} title="Keeper Decisions" class="section">
      <div class="mb-3 flex justify-end">
        <button
          type="button"
          class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2.5 py-1.5 font-mono text-3xs font-medium text-[var(--color-fg-secondary)] transition-colors hover:border-[var(--color-border-strong)] hover:text-[var(--color-fg-primary)]"
          onClick=${() => { void loadDecisions(limit) }}
        >
          refresh
        </button>
      </div>
      <${AsyncContainer}
        state=${decisions.state}
        loadingMessage="Loading keeper decisions..."
        emptyWhen=${(data: KeeperDecisionsResponse) => data.events.length === 0}
        emptyMessage="No keeper decision events are available yet."
        render=${(data: KeeperDecisionsResponse) => html`
          <${KeeperDecisionsTable} events=${data.events} limit=${data.limit || limit} />
        `}
      />
    <//>
  `
}
