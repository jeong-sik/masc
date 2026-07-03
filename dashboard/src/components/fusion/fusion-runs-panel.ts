// RFC-0266 §7 Phase 4 — fusion run status panel.
//
// Renders the in-memory fusion run registry (GET /api/v1/dashboard/fusion-runs)
// as a live status strip: in-progress (`running`) deliberations plus recently
// finished (`completed` / `failed`) ones. This is the half the board-meta detail
// view (FusionSurface) cannot show — a deliberation has no board post while it is
// still running, so only the registry surfaces it. The `fusion_run_status` SSE
// event re-fetches the signal, so a `running` card flips to completed/failed
// without the operator polling.

import { html } from 'htm/preact'
import type { FusionRunRecord, FusionRunStatusLabel } from '../../api/dashboard'
import { fusionRuns, fusionRunsLoading } from '../../store'
import { TimeAgo } from '../common/time-ago'

type StatusTone = 'ok' | 'warn' | 'bad'
type PipelineState = 'done' | 'active' | 'pending' | 'failed'

interface FusionRunPipelineSegment {
  key: 'keeper' | 'registry' | 'deliberation' | 'sink'
  label: string
  state: PipelineState
}

// Reuses the existing `.fus-status.tone-*` chip styling. `running` is `warn`
// (drawing the eye to active work), `completed` `ok`, `failed` `bad`.
export function fusionRunStatusTone(status: FusionRunStatusLabel): StatusTone {
  switch (status) {
    case 'running':
      return 'warn'
    case 'completed':
      return 'ok'
    case 'failed':
      return 'bad'
  }
}

export function fusionRunStatusText(status: FusionRunStatusLabel): string {
  switch (status) {
    case 'running':
      return 'running'
    case 'completed':
      return 'completed'
    case 'failed':
      return 'failed'
  }
}

export function fusionRunPipelineSegments(status: FusionRunStatusLabel): FusionRunPipelineSegment[] {
  const deliberationState: PipelineState =
    status === 'running' ? 'active' : status === 'failed' ? 'failed' : 'done'
  const sinkState: PipelineState =
    status === 'running' ? 'pending' : status === 'failed' ? 'failed' : 'done'
  return [
    { key: 'keeper', label: 'keeper turn', state: 'done' },
    { key: 'registry', label: 'registry', state: 'done' },
    { key: 'deliberation', label: 'panel/judge', state: deliberationState },
    { key: 'sink', label: 'sink', state: sinkState },
  ]
}

function FusionRunPipeline({ status }: { status: FusionRunStatusLabel }) {
  const segments = fusionRunPipelineSegments(status)
  return html`
    <ol
      class="fus-runs-pipe"
      data-testid="fusion-run-pipeline"
      aria-label=${`Fusion registry pipeline: ${fusionRunStatusText(status)}`}
    >
      ${segments.map(segment => html`
        <li
          key=${segment.key}
          class="fus-runs-pipe-node"
          data-stage=${segment.key}
          data-state=${segment.state}
        >
          <span class="fus-runs-pipe-dot" aria-hidden="true"></span>
          <span class="fus-runs-pipe-label">${segment.label}</span>
        </li>
      `)}
    </ol>
  `
}

function FusionRunStatusCard({ run }: { run: FusionRunRecord }) {
  const tone = fusionRunStatusTone(run.status)
  return html`
    <li
      class="fus-runs-card"
      data-testid="fusion-run-status-card"
      data-run-id=${run.runId}
      data-status=${run.status}
    >
      <div class="fus-runs-card-main">
        <span class=${`fus-status tone-${tone}`}>${fusionRunStatusText(run.status)}</span>
        <span class="fus-runs-id">${run.runId}</span>
        <span class="fus-runs-meta">
          <span class="fus-runs-keeper">${run.keeper || 'system'}</span>
          ${run.preset ? html`<span class="fus-runs-preset">${run.preset}</span>` : null}
          <${TimeAgo} timestamp=${run.startedAt} />
        </span>
      </div>
      ${run.status === 'failed' && (run.failureCode || run.error)
        ? html`<div class="fus-runs-reason" data-testid="fusion-run-reason">
            ${run.failureCode
              ? html`<span class="fus-runs-code mono" title=${run.error ?? run.failureCode}>${run.failureCode}</span>`
              : null}
            ${run.error ? html`<span class="fus-runs-reason-text" title=${run.error}>${run.error}</span>` : null}
          </div>`
        : null}
      <${FusionRunPipeline} status=${run.status} />
    </li>
  `
}

export function FusionRunsPanel() {
  const runs = fusionRuns.value
  const loading = fusionRunsLoading.value
  const runningCount = runs.filter(run => run.status === 'running').length

  return html`
    <section class="fus-runs-panel" data-testid="fusion-runs-panel" aria-label="Fusion run status">
      <header class="fus-runs-head">
        <h2>Run status</h2>
        <div class="fus-runs-head-meta">
          ${runningCount > 0
            ? html`<span class="fus-runs-live" title="Deliberations in progress">
                <span class="fus-runs-live-dot"></span>${runningCount} running
              </span>`
            : null}
          <span class="fus-runs-count">${runs.length}</span>
        </div>
      </header>
      ${runs.length === 0
        ? html`<p class="fus-runs-empty" data-testid="fusion-runs-empty">
            ${loading ? 'Loading fusion runs...' : 'No active or recent fusion runs.'}
          </p>`
        : html`<ul class="fus-runs-list" aria-live="polite">
            ${runs.map(run => html`<${FusionRunStatusCard} key=${run.runId} run=${run} />`)}
          </ul>`}
    </section>
  `
}
