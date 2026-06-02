import { html } from 'htm/preact'
import { useCallback, useEffect, useState } from 'preact/hooks'
import { ArrowLeft, RefreshCw, Trophy } from 'lucide-preact'
import { fetchBoardKarmaLedger } from '../../api/board'
import type { BoardKarmaLedger, BoardKarmaLedgerEvent } from '../../types'
import { navigate } from '../../router'
import { ActionButton } from '../common/button'
import { EmptyState, ErrorState, LoadingState } from '../common/feedback-state'
import { TextInput } from '../common/input'
import { Select } from '../common/select'
import { SurfaceCard } from '../common/card'
import { TimeAgo } from '../common/time-ago'

const LIMIT_OPTIONS = [
  { value: '25', label: '25 events' },
  { value: '50', label: '50 events' },
  { value: '100', label: '100 events' },
]

function signedDelta(delta: number): string {
  return delta > 0 ? `+${delta}` : String(delta)
}

function targetLabel(event: BoardKarmaLedgerEvent): string {
  return `${event.target_kind}:${event.target_id}`
}

function emptyLedger(): BoardKarmaLedger {
  return { events: [], count: 0, scoring_rule: '', totals: [] }
}

export function BoardKarmaPanel() {
  const [ledger, setLedger] = useState<BoardKarmaLedger>(emptyLedger)
  const [agentInput, setAgentInput] = useState('')
  const [agentFilter, setAgentFilter] = useState('')
  const [limit, setLimit] = useState(50)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setLedger(await fetchBoardKarmaLedger({
        agent: agentFilter || undefined,
        limit,
      }))
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load board karma ledger')
    } finally {
      setLoading(false)
    }
  }, [agentFilter, limit])

  useEffect(() => {
    void load()
  }, [load])

  const submitFilter = (event: Event) => {
    event.preventDefault()
    setAgentFilter(agentInput.trim())
  }

  return html`
    <section class="grid gap-4" aria-labelledby="board-karma-heading">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div class="min-w-0">
          <div class="flex items-center gap-2 text-2xs uppercase text-[var(--color-fg-muted)]">
            <${Trophy} size=${13} aria-hidden="true" />
            Board karma
          </div>
          <h2 id="board-karma-heading" class="mt-1 text-xl font-semibold text-[var(--color-fg-primary)]">Karma ledger</h2>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <${ActionButton} variant="ghost" size="sm" onClick=${() => navigate('workspace', { section: 'board' })} ariaLabel="Back to board">
            <span class="inline-flex items-center gap-1.5"><${ArrowLeft} size=${14} aria-hidden="true" />Board<//>
          <//>
          <${ActionButton} variant="ghost" size="sm" onClick=${() => { void load() }} disabled=${loading} ariaLabel="Refresh board karma">
            <span class="inline-flex items-center gap-1.5"><${RefreshCw} size=${14} aria-hidden="true" />Refresh<//>
          <//>
        </div>
      </div>

      <form
        class="flex flex-col gap-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3 sm:flex-row sm:items-end"
        data-testid="karma-filter-form"
        onSubmit=${submitFilter}
      >
        <label class="grid min-w-0 flex-1 gap-1 text-2xs font-medium uppercase text-[var(--color-fg-muted)]">
          Agent
          <${TextInput}
            value=${agentInput}
            placeholder="all agents"
            ariaLabel="Karma agent filter"
            testId="karma-agent-filter"
            disabled=${loading}
            onInput=${(event: Event) => setAgentInput((event.target as HTMLInputElement).value)}
          />
        </label>
        <label class="grid gap-1 text-2xs font-medium uppercase text-[var(--color-fg-muted)]">
          Limit
          <${Select}
            value=${String(limit)}
            options=${LIMIT_OPTIONS}
            ariaLabel="Karma event limit"
            testId="karma-event-limit"
            disabled=${loading}
            class="!min-w-32"
            onInput=${(value: string) => setLimit(Number.parseInt(value, 10))}
          />
        </label>
        <${ActionButton}
          type="submit"
          variant="primary"
          size="md"
          disabled=${loading}
          testId="karma-filter-apply"
        >
          Apply
        <//>
      </form>

      ${error && ledger.events.length > 0 ? html`
        <div class="rounded-[var(--r-1)] border border-[var(--color-status-err)]/40 bg-[var(--color-status-err)]/10 px-3 py-2 text-xs text-[var(--color-status-err)]" role="alert">${error}</div>
      ` : null}
      ${loading
        ? html`<${LoadingState}>Loading board karma...<//>`
        : error && ledger.events.length === 0
          ? html`<${ErrorState} message=${error} />`
          : html`
            <div class="grid gap-3 lg:grid-cols-[0.8fr_1.2fr]">
              <${SurfaceCard} variant="compact">
                <div class="mb-3 flex items-center justify-between gap-2">
                  <h3 class="text-xs font-semibold uppercase text-[var(--color-fg-muted)]">Totals</h3>
                  <span class="font-mono text-2xs text-[var(--color-fg-muted)]">${ledger.totals.length} agents</span>
                </div>
                ${ledger.totals.length === 0
                  ? html`<${EmptyState} message="No karma totals." compact />`
                  : html`
                    <div class="grid gap-2">
                      ${ledger.totals.map((row, index) => html`
                        <div key=${row.agent} class="flex items-center justify-between gap-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2.5 py-2">
                          <div class="min-w-0">
                            <div class="truncate text-sm font-medium text-[var(--color-fg-primary)]">${row.agent}</div>
                            <div class="font-mono text-2xs text-[var(--color-fg-muted)]">#${index + 1}</div>
                          </div>
                          <div class="font-mono text-lg font-semibold tabular-nums text-[var(--color-fg-primary)]">${row.karma}</div>
                        </div>
                      `)}
                    </div>
                  `}
              <//>

              <${SurfaceCard} variant="compact">
                <div class="mb-3 flex flex-wrap items-center justify-between gap-2">
                  <h3 class="text-xs font-semibold uppercase text-[var(--color-fg-muted)]">Ledger events</h3>
                  <div class="flex flex-wrap items-center gap-2 font-mono text-2xs text-[var(--color-fg-muted)]">
                    <span>${ledger.count} events</span>
                    ${ledger.scoring_rule ? html`<span>${ledger.scoring_rule}</span>` : null}
                  </div>
                </div>
                ${ledger.events.length === 0
                  ? html`<${EmptyState} message="No karma events." compact />`
                  : html`
                    <div class="grid gap-2">
                      ${ledger.events.map((event, index) => html`
                        <div key=${`${event.ts}:${event.recipient}:${event.voter}:${event.target_id}:${index}`} class="grid gap-1 border-b border-[var(--color-border-subtle)] pb-2 last:border-b-0 last:pb-0">
                          <div class="flex flex-wrap items-center gap-2 text-xs">
                            <span class="font-medium text-[var(--color-fg-primary)]">${event.recipient}</span>
                            <span class="font-mono tabular-nums text-[var(--ok-bright)]">${signedDelta(event.delta)}</span>
                            <span class="text-[var(--color-fg-muted)]">from ${event.voter}</span>
                          </div>
                          <div class="flex flex-wrap items-center gap-2 font-mono text-2xs text-[var(--color-fg-muted)]">
                            <span>${targetLabel(event)}</span>
                            <span><${TimeAgo} timestamp=${event.ts_iso} /></span>
                          </div>
                        </div>
                      `)}
                    </div>
                  `}
              <//>
            </div>
          `}
    </section>
  `
}
