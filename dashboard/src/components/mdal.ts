// MDAL tab — Metric-Driven Agent Loop dashboard
// Shows active/completed loops, iteration history, metric progress

import { html } from 'htm/preact'
import { computed } from '@preact/signals'
import { Card } from './common/card'
import { StatusBadge } from './common/status-badge'
import { mdalLoops } from '../store'
import type { MdalLoop, MdalIterationRecord } from '../types'

// -- Derived state --

const loopsList = computed(() => {
  const loops = Array.from(mdalLoops.value.values())
  // Running loops first, then by most recent activity
  loops.sort((a, b) => {
    if (a.status === 'running' && b.status !== 'running') return -1
    if (b.status === 'running' && a.status !== 'running') return 1
    if (a.status === 'interrupted' && b.status !== 'interrupted') return -1
    if (b.status === 'interrupted' && a.status !== 'interrupted') return 1
    return b.elapsed_seconds - a.elapsed_seconds
  })
  return loops
})

const runningCount = computed(() =>
  Array.from(mdalLoops.value.values()).filter(l => l.status === 'running').length
)

const completedCount = computed(() =>
  Array.from(mdalLoops.value.values()).filter(l => l.status === 'completed').length
)

const interruptedCount = computed(() =>
  Array.from(mdalLoops.value.values()).filter(l => l.status === 'interrupted').length
)

// -- Helpers --

function statusColor(status: string): string {
  switch (status) {
    case 'running': return '#fbbf24'
    case 'interrupted': return '#38bdf8'
    case 'completed': return '#4ade80'
    case 'stopped': return '#94a3b8'
    case 'error': return '#fb7185'
    default: return '#888'
  }
}

function formatDelta(delta: number): string {
  const sign = delta >= 0 ? '+' : ''
  return `${sign}${delta.toFixed(4)}`
}

function formatElapsed(seconds: number): string {
  if (seconds < 60) return `${Math.round(seconds)}s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${Math.round(seconds % 60)}s`
  return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`
}

// -- Metric spark line (text-based) --

function MetricSpark({ history }: { history: MdalIterationRecord[] }) {
  if (history.length === 0) {
    return html`<span class="mdal-spark-empty">No iterations yet</span>`
  }

  // history is most-recent-first, reverse for display
  const ordered = [...history].reverse()
  const values = ordered.map(r => r.metric_after)
  const min = Math.min(...values)
  const max = Math.max(...values)
  const range = max - min || 1

  const BARS = '\u2581\u2582\u2583\u2584\u2585\u2586\u2587\u2588'
  const spark = values.map(v => {
    const idx = Math.min(Math.floor(((v - min) / range) * 7), 7)
    return BARS[idx]
  }).join('')

  return html`
    <span class="mdal-spark" title="Metric progression (${values.length} iterations)">
      ${spark}
    </span>
  `
}

// -- Sub-components --

function IterationRow({ record }: { record: MdalIterationRecord }) {
  const deltaClass = record.delta > 0 ? 'positive' : record.delta < 0 ? 'negative' : 'neutral'
  const evidenceText =
    record.evidence
      ? `${record.evidence.tool_call_count} tool${record.evidence.tool_call_count === 1 ? '' : 's'}: ${record.evidence.tool_names.join(', ')}`
      : 'No evidence snapshot'
  return html`
    <div class="mdal-iter-row">
      <span class="mdal-iter-num">#${record.iteration}</span>
      <span class="mdal-iter-metric">${record.metric_before.toFixed(4)}</span>
      <span class="mdal-iter-arrow">\u2192</span>
      <span class="mdal-iter-metric">${record.metric_after.toFixed(4)}</span>
      <span class="mdal-iter-delta ${deltaClass}">${formatDelta(record.delta)}</span>
      <span class="mdal-iter-evidence" title=${evidenceText}>${evidenceText}</span>
      <span class="mdal-iter-time">${record.elapsed_ms}ms</span>
    </div>
  `
}

function LoopCard({ loop }: { loop: MdalLoop }) {
  const totalDelta = loop.current_metric - loop.baseline_metric
  const statusNote =
    loop.status === 'error'
      ? (loop.error_message ?? loop.stop_reason ?? 'Runtime error')
      : loop.stop_reason ?? null
  const latestTools =
    loop.latest_tool_names && loop.latest_tool_names.length > 0
      ? loop.latest_tool_names.join(', ')
      : 'none'

  return html`
    <${Card} title=${`${loop.loop_id}`} class="mdal-loop-card">
      <div class="mdal-loop-header">
        <div class="mdal-loop-badges">
          <${StatusBadge} status=${loop.status} />
          <span class="mdal-profile-badge">${loop.profile}</span>
        </div>
        <span class="mdal-loop-target" title="Target">${loop.target}</span>
      </div>

      <div class="mdal-loop-metrics">
        <div class="mdal-metric-pair">
          <span class="mdal-metric-label">Baseline</span>
          <span class="mdal-metric-value">${loop.baseline_metric.toFixed(4)}</span>
        </div>
        <div class="mdal-metric-pair">
          <span class="mdal-metric-label">Current</span>
          <span class="mdal-metric-value">${loop.current_metric.toFixed(4)}</span>
        </div>
        <div class="mdal-metric-pair">
          <span class="mdal-metric-label">Total Delta</span>
          <span class="mdal-metric-value ${totalDelta >= 0 ? 'positive' : 'negative'}">
            ${formatDelta(totalDelta)}
          </span>
        </div>
        <div class="mdal-metric-pair">
          <span class="mdal-metric-label">Iteration</span>
          <span class="mdal-metric-value">
            ${loop.current_iteration}${loop.max_iterations > 0 ? `/${loop.max_iterations}` : ''}
          </span>
        </div>
        <div class="mdal-metric-pair">
          <span class="mdal-metric-label">Stagnation</span>
          <span class="mdal-metric-value">
            ${loop.stagnation_streak}${loop.stagnation_limit > 0 ? `/${loop.stagnation_limit}` : ''}
          </span>
        </div>
        <div class="mdal-metric-pair">
          <span class="mdal-metric-label">Elapsed</span>
          <span class="mdal-metric-value">${formatElapsed(loop.elapsed_seconds)}</span>
        </div>
      </div>

      <div class="mdal-spark-section">
        <span class="mdal-metric-label">Progress</span>
        <${MetricSpark} history=${loop.history} />
      </div>

      <div class="mdal-loop-footnotes">
        <span>${loop.strict_mode ? 'Strict hard evidence' : 'Legacy loop'}</span>
        <span>Mode ${loop.execution_mode ?? 'unknown'}</span>
        <span>Engine ${loop.worker_engine ?? 'unknown'}</span>
        <span>Model ${loop.worker_model ?? 'unknown'}</span>
        <span>Latest tools ${loop.latest_tool_call_count ?? 0}: ${latestTools}</span>
        <span>Evidence ${loop.evidence_status ?? 'unknown'}</span>
        <span>Storage ${loop.persistence_backend ?? 'unknown'}</span>
        <span>${loop.recoverable ? 'Recoverable' : 'Terminal'}</span>
      </div>

      ${statusNote
        ? html`<div class="mdal-loop-status-note">${statusNote}</div>`
        : null}

      ${loop.history.length > 0 ? html`
        <details class="mdal-history-details">
          <summary>Iteration History (${loop.history.length})</summary>
          <div class="mdal-iter-list">
            ${loop.history.map(r => html`<${IterationRow} key=${r.iteration} record=${r} />`)}
          </div>
        </details>
      ` : null}
    <//>
  `
}

// -- Main component --

export function Mdal() {
  const loops = loopsList.value
  const running = runningCount.value
  const interrupted = interruptedCount.value
  const completed = completedCount.value
  const terminal = loops.filter(l => l.status === 'stopped' || l.status === 'error').length

  return html`
    <style>
      .mdal-loop-card { margin-bottom: 12px; }
      .mdal-loop-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; flex-wrap: wrap; gap: 4px; }
      .mdal-loop-badges { display: flex; gap: 6px; align-items: center; }
      .mdal-profile-badge { background: #334155; color: #e2e8f0; padding: 2px 8px; border-radius: 4px; font-size: 12px; }
      .mdal-loop-target { color: #94a3b8; font-size: 13px; }
      .mdal-loop-metrics { display: grid; grid-template-columns: repeat(auto-fill, minmax(130px, 1fr)); gap: 8px; margin: 8px 0; }
      .mdal-metric-pair { display: flex; flex-direction: column; }
      .mdal-metric-label { font-size: 11px; color: #64748b; text-transform: uppercase; letter-spacing: 0.5px; }
      .mdal-metric-value { font-size: 16px; font-weight: 600; font-variant-numeric: tabular-nums; }
      .mdal-metric-value.positive { color: #4ade80; }
      .mdal-metric-value.negative { color: #fb7185; }
      .mdal-spark-section { margin: 8px 0; }
      .mdal-spark { font-family: monospace; font-size: 18px; letter-spacing: 1px; color: #38bdf8; }
      .mdal-spark-empty { color: #64748b; font-size: 13px; }
      .mdal-loop-footnotes { display: flex; gap: 12px; flex-wrap: wrap; color: #64748b; font-size: 12px; margin: 8px 0 0; }
      .mdal-loop-status-note { margin-top: 8px; color: #cbd5e1; font-size: 13px; }
      .mdal-history-details { margin-top: 8px; }
      .mdal-history-details summary { cursor: pointer; color: #94a3b8; font-size: 13px; }
      .mdal-iter-list { margin-top: 6px; }
      .mdal-iter-row { display: flex; gap: 8px; align-items: center; padding: 3px 0; font-size: 13px; font-variant-numeric: tabular-nums; border-bottom: 1px solid #1e293b; }
      .mdal-iter-num { color: #64748b; min-width: 28px; }
      .mdal-iter-metric { color: #e2e8f0; min-width: 60px; text-align: right; }
      .mdal-iter-arrow { color: #475569; }
      .mdal-iter-delta { min-width: 70px; text-align: right; font-weight: 600; }
      .mdal-iter-delta.positive { color: #4ade80; }
      .mdal-iter-delta.negative { color: #fb7185; }
      .mdal-iter-delta.neutral { color: #94a3b8; }
      .mdal-iter-evidence { color: #38bdf8; min-width: 180px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .mdal-iter-time { color: #64748b; margin-left: auto; }
    </style>

    <div class="stats-grid">
      <div class="stat-card">
        <div class="stat-label">Running</div>
        <div class="stat-value" style="color:${statusColor('running')}">${running}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Completed</div>
        <div class="stat-value" style="color:${statusColor('completed')}">${completed}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Interrupted</div>
        <div class="stat-value" style="color:${statusColor('interrupted')}">${interrupted}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Terminal</div>
        <div class="stat-value" style="color:${statusColor('stopped')}">${terminal}</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Total Loops</div>
        <div class="stat-value">${loops.length}</div>
      </div>
    </div>

    <div class="council-grid">
      ${loops.length === 0
        ? html`
          <${Card} title="MDAL Loops" class="section">
            <div class="empty-state">
              No MDAL loops active. Start one with <code>masc_mdal_start</code>.
            </div>
          <//>
        `
        : loops.map(loop => html`<${LoopCard} key=${loop.loop_id} loop=${loop} />`)}
    </div>
  `
}
