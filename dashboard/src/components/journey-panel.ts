import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useState } from 'preact/hooks'

import {
  fetchKeeperToolCalls,
  fetchKeeperTrajectory,
  type ToolCallsResponse,
  type TrajectoryResponse,
} from '../api/dashboard'
import {
  fetchKeeperRuntimeTrace,
  type KeeperRuntimeTraceResponse,
} from '../api/keeper'
import { formatCost, formatMsCompact } from '../lib/format-number'
import { errorToString } from '../lib/format-string'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { keepers } from '../store'
import type { Keeper } from '../types'
import { ActionButton } from './common/button'
import { SurfaceCard } from './common/card'
import { EmptyState, ErrorState, LoadingState } from './common/feedback-state'
import { Select } from './common/select'
import { StatusChip, keeperStateTone } from './common/status-chip'
import { TimeAgo } from './common/time-ago'
import { formatIndependentCounters } from './counter-format'
import { pipelineStageDetailLabel } from './keeper-phase-indicator'
import {
  buildJourneyWaterfall,
  selectDefaultJourneyKeeper,
  type JourneyWaterfallEntry,
  type JourneyWaterfallModel,
  type JourneyWaterfallRuntimeEvidence,
  type JourneyWaterfallTurn,
} from './journey-waterfall-state'
import {
  durationColor,
  formatArgs,
  normalizeToolName,
  toolCategory,
} from './tool-call-shared'

interface WaterfallLoadResult {
  model: JourneyWaterfallModel
  sourceErrors: string[]
  fetchedAtMs: number
}

type SettledSource<T> =
  | { ok: true; data: T }
  | { ok: false; label: string; error: string }

async function settleSource<T>(
  label: string,
  promise: Promise<T>,
): Promise<SettledSource<T>> {
  try {
    return { ok: true, data: await promise }
  } catch (err) {
    return {
      ok: false,
      label,
      error: errorToString(err),
    }
  }
}

async function fetchWaterfallSources(
  keeperName: string,
  signal: AbortSignal,
): Promise<WaterfallLoadResult> {
  const [trajectory, toolCalls, runtimeTrace] = await Promise.all([
    settleSource<TrajectoryResponse>(
      'trajectory',
      fetchKeeperTrajectory(keeperName, 200, true, true),
    ),
    settleSource<ToolCallsResponse>(
      'tool-calls',
      fetchKeeperToolCalls(keeperName, 200, { signal }),
    ),
    settleSource<KeeperRuntimeTraceResponse>(
      'runtime-trace',
      fetchKeeperRuntimeTrace(keeperName, { limit: 200, signal }),
    ),
  ])

  const sourceErrors = [trajectory, toolCalls, runtimeTrace]
    .filter((result): result is Extract<SettledSource<unknown>, { ok: false }> => !result.ok)
    .map(result => `${result.label}: ${result.error}`)

  const hasAnySource = trajectory.ok || toolCalls.ok || runtimeTrace.ok
  if (!hasAnySource) {
    throw new Error(sourceErrors.join(' | ') || 'waterfall sources unavailable')
  }

  return {
    model: buildJourneyWaterfall({
      keeper: keeperName,
      trajectory: trajectory.ok ? trajectory.data : null,
      toolCalls: toolCalls.ok ? toolCalls.data : null,
      runtimeTrace: runtimeTrace.ok ? runtimeTrace.data : null,
    }),
    sourceErrors,
    fetchedAtMs: Date.now(),
  }
}

function keeperOptions(rows: Keeper[]): Array<{ value: string; label: string }> {
  return rows
    .filter(row => row.name.trim() !== '')
    .slice()
    .sort((left, right) => left.name.localeCompare(right.name))
    .map(row => ({
      value: row.name,
      label: row.agent_name && row.agent_name !== row.name
        ? `${row.name} (${row.agent_name})`
        : row.name,
    }))
}

function keeperByName(rows: readonly Keeper[], name: string | null): Keeper | null {
  if (!name) return null
  return rows.find(row => row.name === name) ?? null
}

function formatTimestamp(ms: number | null): string {
  if (ms == null || !Number.isFinite(ms)) return 'not recorded'
  return new Date(ms).toISOString()
}

function formatMaybeDuration(ms: number | null): string {
  return typeof ms === 'number' && Number.isFinite(ms) && ms > 0
    ? formatMsCompact(ms)
    : 'not recorded'
}

function runtimeTone(evidence: JourneyWaterfallRuntimeEvidence | null): string {
  const health = evidence?.health.toLowerCase() ?? ''
  if (health === 'ok' || health === 'healthy') return 'ok'
  if (health === 'stale' || health === 'partial' || health === 'warning') return 'warn'
  if (health === 'missing' || health === 'error' || health.includes('gap')) return 'bad'
  return evidence ? 'neutral' : 'muted'
}

function statusTone(entry: JourneyWaterfallEntry): string {
  switch (entry.status) {
    case 'success':
      return 'ok'
    case 'failure':
      return 'bad'
    case 'gate_rejected':
      return 'warn'
    case 'unknown':
    default:
      return 'neutral'
  }
}

function turnTone(turn: JourneyWaterfallTurn): string {
  if (turn.failureCount > 0) return 'bad'
  if (turn.gateRejectedCount > 0) return 'warn'
  if (turn.toolCallCount > 0) return 'ok'
  return 'neutral'
}

function sourceLabel(entry: JourneyWaterfallEntry): string {
  switch (entry.source) {
    case 'trajectory+tool_call_log':
      return 'trajectory + I/O'
    case 'tool_call_log':
      return 'tool log'
    case 'trajectory':
      return 'trajectory'
    case 'unknown':
    default:
      return 'unknown'
  }
}

function MetricCell({
  label,
  value,
  tone = 'neutral',
}: {
  label: string
  value: string | number
  tone?: string
}) {
  return html`
    <div class="v2-monitoring-card rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2">
      <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">${label}</div>
      <div class="mt-1">
        <${StatusChip} tone=${tone} uppercase=${false}>${value}<//>
      </div>
    </div>
  `
}

function SourceWarning({ errors }: { errors: string[] }) {
  if (errors.length === 0) return null
  return html`
    <div class="v2-monitoring-warning rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-10)] px-3 py-2 text-xs text-[var(--color-status-warn)]">
      ${errors.map(error => html`<div class="break-all font-mono">${error}</div>`)}
    </div>
  `
}

function RuntimeEvidenceStrip({
  evidence,
}: {
  evidence: JourneyWaterfallRuntimeEvidence | null
}) {
  if (!evidence) {
    return html`
      <div class="text-2xs text-[var(--color-fg-muted)]">
        Runtime trace not recorded for this turn.
      </div>
    `
  }

  const provider = evidence.providerTerminalExceptionKind
    ? `${evidence.providerTerminalStatus ?? 'unknown'} / ${evidence.providerTerminalExceptionKind}`
    : evidence.providerTerminalStatus ?? 'unknown'

  return html`
    <div class="flex flex-wrap gap-1.5 text-3xs">
      <${StatusChip} tone=${runtimeTone(evidence)} uppercase=${false}>runtime ${evidence.health}<//>
      <span class="rounded-[var(--r-1)] border border-[var(--color-border-default)] px-1.5 py-0.5 font-mono text-[var(--color-fg-muted)]">
        agent turns ${evidence.maxOasTurnCount ?? 'not recorded'}
      </span>
      <span class="rounded-[var(--r-1)] border border-[var(--color-border-default)] px-1.5 py-0.5 font-mono text-[var(--color-fg-muted)]">
        runtime terminal ${provider}
      </span>
      <span class="rounded-[var(--r-1)] border border-[var(--color-border-default)] px-1.5 py-0.5 font-mono text-[var(--color-fg-muted)]">
        attempts ${evidence.providerAttemptStartedCount}/${evidence.providerAttemptFinishedCount}
      </span>
      <span class="rounded-[var(--r-1)] border border-[var(--color-border-default)] px-1.5 py-0.5 font-mono text-[var(--color-fg-muted)]">
        events ${evidence.eventBusCorrelatedCount}
      </span>
      <span class="rounded-[var(--r-1)] border border-[var(--color-border-default)] px-1.5 py-0.5 font-mono text-[var(--color-fg-muted)]">
        mem ${formatIndependentCounters({
          leftLabel: 'inj',
          leftValue: evidence.memoryInjectedCount,
          rightLabel: 'flush',
          rightValue: evidence.memoryFlushedCount,
        })}
      </span>
    </div>
  `
}

function WaterfallEntryRow({
  entry,
  maxDurationMs,
}: {
  entry: JourneyWaterfallEntry
  maxDurationMs: number
}) {
  const isTool = entry.kind === 'tool_call'
  const style = toolCategory(entry.toolName ?? entry.summary)
  const widthPct = entry.durationMs && maxDurationMs > 0
    ? Math.max(8, Math.min(100, Math.round((entry.durationMs / maxDurationMs) * 100)))
    : 8
  const status = entry.status === 'gate_rejected'
    ? 'gate rejected'
    : entry.status
  const resultPreview = entry.error ?? entry.toolResult ?? entry.thinkingContent ?? ''

  return html`
    <div class="v2-monitoring-card grid gap-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-2" data-testid="journey-waterfall-entry">
      <div class="flex flex-wrap items-center gap-2">
        <span class="inline-flex h-5 min-w-5 items-center justify-center rounded-[var(--r-0)] border border-[var(--color-border-default)] px-1 font-mono text-3xs ${isTool ? style.color : 'text-[var(--color-info-fg)]'}">
          ${isTool ? style.icon : 'TH'}
        </span>
        <span class="min-w-0 flex-1 truncate text-sm font-medium text-[var(--color-fg-secondary)]">
          ${isTool ? normalizeToolName(entry.toolName ?? entry.summary) : 'thinking'}
        </span>
        <${StatusChip} tone=${statusTone(entry)} uppercase=${false}>${status}<//>
        <span class="rounded-[var(--r-1)] border border-[var(--color-border-default)] px-1.5 py-0.5 text-3xs text-[var(--color-fg-muted)]">
          ${sourceLabel(entry)}
        </span>
        ${entry.round != null
          ? html`<span class="font-mono text-3xs text-[var(--color-fg-disabled)]">round ${entry.round}</span>`
          : null}
      </div>

      ${isTool
        ? html`
            <div class="grid grid-cols-[minmax(0,1fr)_auto_auto] items-center gap-2">
              <div class="h-2 overflow-hidden rounded-[var(--r-0)] bg-[var(--color-bg-hover)]">
                <div
                  class="h-full rounded-[var(--r-0)] bg-[var(--color-accent-fg)]"
                  style="width: ${widthPct}%"
                  aria-hidden="true"
                />
              </div>
              <span class="font-mono text-3xs ${entry.durationMs != null ? durationColor(entry.durationMs) : 'text-[var(--color-fg-disabled)]'}">
                ${formatMaybeDuration(entry.durationMs)}
              </span>
              <span class="font-mono text-3xs text-[var(--color-fg-muted)]">${formatCost(entry.costUsd, '$0')}</span>
            </div>
            ${entry.toolArgs
              ? html`<div class="truncate font-mono text-3xs text-[var(--color-fg-muted)]">${formatArgs(entry.toolArgs)}</div>`
              : null}
          `
        : html`
            <div class="text-xs leading-relaxed text-[var(--color-fg-muted)]">
              ${entry.thinkingRedacted ? 'Thinking content redacted.' : entry.thinkingContent ?? 'No thinking text recorded.'}
            </div>
          `}

      ${entry.gateReason
        ? html`<div class="text-xs text-[var(--color-status-warn)]">gate: ${entry.gateReason}</div>`
        : null}

      ${resultPreview && isTool
        ? html`
            <details class="v2-monitoring-detail text-xs text-[var(--color-fg-muted)]">
              <summary class="cursor-pointer text-2xs text-[var(--color-fg-disabled)]">details</summary>
              <pre class="mt-2 max-h-48 overflow-auto whitespace-pre-wrap rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] p-2 font-mono text-3xs">${resultPreview}</pre>
            </details>
          `
        : null}
    </div>
  `
}

function WaterfallTurnRow({
  turn,
  maxDurationMs,
}: {
  turn: JourneyWaterfallTurn
  maxDurationMs: number
}) {
  const tone = turnTone(turn)

  return html`
    <section class="v2-monitoring-card grid gap-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] p-3" data-testid="journey-waterfall-turn">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <h3 class="m-0 text-base font-semibold tracking-normal text-[var(--color-fg-secondary)]">${turn.label}</h3>
            <${StatusChip} tone=${tone} uppercase=${false}>${turn.entries.length} events<//>
          </div>
          <div class="mt-1 flex flex-wrap gap-2 text-3xs text-[var(--color-fg-muted)]">
            <span><${TimeAgo} timestamp=${formatTimestamp(turn.startTs)} /></span>
            <span>span ${formatMaybeDuration(turn.endTs - turn.startTs)}</span>
            <span>tools ${turn.toolCallCount}</span>
            <span>thinking ${turn.thinkingCount}</span>
            <span>failures ${turn.failureCount}</span>
            <span>gate ${turn.gateRejectedCount}</span>
          </div>
        </div>
        <div class="flex flex-wrap gap-1.5 text-3xs">
          <span class="rounded-[var(--r-1)] border border-[var(--color-border-default)] px-1.5 py-0.5 font-mono text-[var(--color-fg-muted)]">
            tool time ${formatMaybeDuration(turn.totalDurationMs)}
          </span>
          <span class="rounded-[var(--r-1)] border border-[var(--color-border-default)] px-1.5 py-0.5 font-mono text-[var(--color-fg-muted)]">
            cost ${formatCost(turn.totalCostUsd, '$0')}
          </span>
        </div>
      </div>

      <${RuntimeEvidenceStrip} evidence=${turn.runtimeEvidence} />

      <div class="grid gap-2">
        ${turn.entries.map(entry => html`
          <${WaterfallEntryRow}
            key=${entry.id}
            entry=${entry}
            maxDurationMs=${maxDurationMs}
          />
        `)}
      </div>
    </section>
  `
}

function WaterfallBody({
  result,
  loading,
  onRefresh,
}: {
  result: WaterfallLoadResult | null
  loading: boolean
  onRefresh: () => void
}) {
  if (loading && !result) {
    return html`<${LoadingState}>Loading keeper waterfall...<//>`
  }
  if (!result) {
    return html`<${EmptyState} message="No keeper waterfall data loaded." compact />`
  }

  const model = result.model
  const summary = model.summary
  const maxDurationMs = Math.max(1, ...model.turns.flatMap(turn =>
    turn.entries.map(entry => entry.durationMs ?? 0),
  ))

  return html`
    <div class="flex flex-col gap-4">
      <${SourceWarning} errors=${result.sourceErrors} />

      <div class="grid gap-3 md:grid-cols-3 xl:grid-cols-6">
        <${MetricCell} label="turns" value=${summary.totalTurns} tone="info" />
        <${MetricCell} label="events" value=${summary.totalEntries} />
        <${MetricCell} label="tools" value=${summary.toolCallCount} tone="ok" />
        <${MetricCell} label="failures" value=${summary.failureCount} tone=${summary.failureCount > 0 ? 'bad' : 'ok'} />
        <${MetricCell} label="tool time" value=${formatMaybeDuration(summary.totalDurationMs)} />
        <${MetricCell} label="cost" value=${formatCost(summary.totalCostUsd, '$0')} />
      </div>

      <div class="flex flex-wrap items-center justify-between gap-2 text-3xs text-[var(--color-fg-muted)]">
        <div>
          ${summary.timelineStartTs != null && summary.timelineEndTs != null
            ? html`
                <span>${new Date(summary.timelineStartTs).toLocaleString()}</span>
                <span class="mx-1">-></span>
                <span>${new Date(summary.timelineEndTs).toLocaleString()}</span>
              `
            : html`<span>timeline not recorded</span>`}
        </div>
        <div class="flex items-center gap-2">
          <span>fetched <${TimeAgo} timestamp=${new Date(result.fetchedAtMs).toISOString()} /></span>
          <${ActionButton} variant="ghost" size="sm" class="v2-monitoring-action" onClick=${onRefresh} disabled=${loading}>
            ${loading ? 'Refreshing...' : 'Refresh'}
          <//>
        </div>
      </div>

      ${model.turns.length === 0
        ? html`<${EmptyState} message="No trajectory or tool-call rows are recorded for this keeper." compact />`
        : html`
            <div class="flex flex-col gap-3" aria-label="Keeper turn waterfall">
              ${model.turns.map(turn => html`
                <${WaterfallTurnRow}
                  key=${turn.key}
                  turn=${turn}
                  maxDurationMs=${maxDurationMs}
                />
              `)}
            </div>
          `}
    </div>
  `
}

export function JourneyPanel() {
  const keeperRows = keepers.value
  const options = useMemo(() => keeperOptions(keeperRows), [keeperRows])
  const [selectedKeeper, setSelectedKeeper] = useState<string | null>(() =>
    selectDefaultJourneyKeeper(keeperRows),
  )
  const resource = useManagedAsyncResource<WaterfallLoadResult>(null)
  const selected = keeperByName(keeperRows, selectedKeeper)

  useEffect(() => {
    const next = selectDefaultJourneyKeeper(keeperRows, selectedKeeper)
    if (next !== selectedKeeper) setSelectedKeeper(next)
  }, [keeperRows, selectedKeeper])

  const refresh = useCallback(() => {
    if (!selectedKeeper) {
      resource.reset(null)
      return
    }
    void resource.load((signal) => fetchWaterfallSources(selectedKeeper, signal))
  }, [resource, selectedKeeper])

  useEffect(() => {
    refresh()
    return () => {
      resource.cancel()
    }
  }, [refresh, resource])

  const state = resource.state.value

  return html`
    <div class="v2-monitoring-surface flex flex-col gap-4">
      <${SurfaceCard} class="v2-monitoring-panel flex flex-col gap-4">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="m-0 text-lg font-semibold tracking-normal text-[var(--color-fg-secondary)]">Keeper Turn Waterfall</h2>
              <${StatusChip} tone="neutral" uppercase=${false}>hidden diagnostic<//>
            </div>
            <div class="mt-1 text-sm leading-relaxed text-[var(--color-fg-muted)]">
              Per-keeper turn flow from trajectory, tool-call I/O, and runtime trace evidence.
            </div>
          </div>
          ${selected
            ? html`
                <div class="flex flex-wrap items-center gap-2 text-2xs">
                  <${StatusChip} tone=${keeperStateTone(selected.status)} uppercase=${false}>${selected.status}<//>
                  ${selected.pipeline_stage
                    ? html`<${StatusChip} tone="info" uppercase=${false} title=${selected.pipeline_stage_detail ? pipelineStageDetailLabel(selected.pipeline_stage_detail) ?? selected.pipeline_stage_detail : undefined}>${selected.pipeline_stage}<//>`
                    : null}
                  <span class="font-mono text-[var(--color-fg-muted)]">turns ${selected.turn_count ?? selected.total_turns ?? 'not recorded'}</span>
                </div>
              `
            : null}
        </div>

        ${options.length === 0
          ? html`<${EmptyState} message="No keepers are available in the execution projection." compact />`
          : html`
              <div class="grid gap-3 md:grid-cols-[minmax(16rem,24rem)_auto] md:items-center">
                <${Select}
                  value=${selectedKeeper ?? ''}
                  options=${options}
                  ariaLabel="Select keeper for journey waterfall"
                  testId="journey-keeper-select"
                  onInput=${(value: string) => setSelectedKeeper(value)}
                />
                <${ActionButton} variant="ghost" size="md" class="v2-monitoring-action" onClick=${refresh} disabled=${state.loading || !selectedKeeper}>
                  ${state.loading ? 'Refreshing...' : 'Refresh'}
                <//>
              </div>
            `}
      <//>

      ${state.error
        ? html`
            <div class="flex flex-col gap-3">
              <${ErrorState} message=${state.error} />
              <div>
                <${ActionButton} variant="ghost" size="sm" class="v2-monitoring-action" onClick=${refresh} disabled=${state.loading || !selectedKeeper}>Retry<//>
              </div>
            </div>
          `
        : html`
            <${WaterfallBody}
              result=${state.data}
              loading=${state.loading}
              onRefresh=${refresh}
            />
          `}
    </div>
  `
}
