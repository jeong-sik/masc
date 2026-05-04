// CascadeTrace — OAS cascade routing trace visualization.
// Shows miss/hit/skipped steps with timing bars and outcome distribution.

import { html } from 'htm/preact'
import {
  CASCADE_TRACES,
  cascadeStepColor,
  cascadeTierLabel,
  cascadeTierStyle,
  type CascadeStepStatus,
  type CascadeStep,
} from './data'

const STATUS_FILL: Record<CascadeStepStatus, string> = {
  hit: 'var(--color-status-ok)',
  miss: 'var(--color-status-err)',
  skipped: 'var(--color-fg-muted)',
}

function stepStatusLabel(status: CascadeStepStatus): string {
  switch (status) {
    case 'hit':     return 'HIT'
    case 'miss':    return 'MISS'
    case 'skipped': return 'SKIP'
  }
}

function formatMs(ms: number): string {
  if (ms === 0) return '—'
  if (ms < 1000) return `${ms}ms`
  return `${(ms / 1000).toFixed(1)}s`
}

function OutcomeDistBar() {
  const all = CASCADE_TRACES.flatMap(t => t.steps)
  const hits = all.filter(s => s.status === 'hit').length
  const misses = all.filter(s => s.status === 'miss').length
  const skips = all.filter(s => s.status === 'skipped').length
  const total = all.length
  if (total === 0) return null
  const entries = ([['hit', hits], ['miss', misses], ['skipped', skips]] as const).filter(([, c]) => c > 0)

  return html`
    <div class="flex items-center gap-3">
      <span class="text-2xs text-[var(--color-fg-muted)] w-16">결과 분포</span>
      <div class="flex-1 flex w-full h-2.5 rounded-[var(--r-0)] overflow-hidden bg-[var(--color-bg-elevated)]">
        ${entries.map(([key, count]) => html`
          <div style="width: ${(count / total * 100).toFixed(1)}%; background: ${STATUS_FILL[key]}"
               title="${key}: ${count}건" class="h-full"></div>
        `)}
      </div>
      <span class="text-2xs font-mono text-[var(--color-fg-muted)]">${hits}/${total} HIT</span>
    </div>
  `
}

function TraceTimingBar({ steps }: { steps: CascadeStep[] }) {
  const totalMs = steps.reduce((s, st) => s + st.ms, 0)
  if (totalMs === 0) return null

  return html`
    <div class="flex w-full h-3 rounded-[var(--r-0)] overflow-hidden bg-[var(--color-bg-elevated)]">
      ${steps.map((step, i) => {
        const pct = (step.ms / totalMs * 100)
        if (pct === 0) return null
        return html`
          <div key=${i} class="h-full"
               style="width: ${pct.toFixed(1)}%; background: ${STATUS_FILL[step.status]}; opacity: ${step.status === 'hit' ? 0.8 : 0.5}"
               title="${step.provider}: ${formatMs(step.ms)} (${stepStatusLabel(step.status)})">
          </div>
        `
      })}
    </div>
  `
}

function ArrowConnector() {
  return html`
    <div class="flex items-center px-1 text-[var(--color-fg-disabled)]">
      <svg width="16" height="12" viewBox="0 0 16 12" fill="none" aria-hidden="true" focusable="false">
        <path d="M0 6H12M12 6L8 2M12 6L8 10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </div>
  `
}

function StepBlock({ step, maxMs }: { step: CascadeStep; maxMs: number }) {
  const pct = maxMs > 0 && step.ms > 0 ? (step.ms / maxMs * 100) : 0
  return html`
    <div class="flex-1 flex flex-col items-center gap-1 min-w-[100px]">
      <span class="t-caption t-dim">${step.provider}</span>
      <span class="chip sm ${cascadeStepColor(step.status)}">
        ${stepStatusLabel(step.status)}
      </span>
      <span class="t-caption">${formatMs(step.ms)}</span>
      ${pct > 0 ? html`
        <div class="w-full h-1 rounded-[var(--r-0)] bg-[var(--color-bg-elevated)] overflow-hidden">
          <div class="h-full rounded-[var(--r-0)]"
               style="width: ${pct.toFixed(1)}%; background: ${STATUS_FILL[step.status]}; opacity: 0.6"></div>
        </div>
      ` : null}
      <span class="t-micro max-w-[100px] truncate" title=${step.reason}>${step.reason}</span>
    </div>
  `
}

export function CascadeTrace() {
  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center gap-4 t-caption px-1">
        <span>OAS Cascade = Provider 순차 시도 + Cooldown 게이트</span>
        <span class="text-[var(--color-border-default)]">|</span>
        <span class="flex items-center gap-1">
          <span class="inline-block w-3 h-2 rounded-sm bg-[var(--ok-10)]"></span> HIT
        </span>
        <span class="flex items-center gap-1">
          <span class="inline-block w-3 h-2 rounded-sm bg-[var(--bad-10)]"></span> MISS
        </span>
        <span class="flex items-center gap-1">
          <span class="inline-block w-3 h-2 rounded-sm bg-[var(--white-4)]"></span> SKIP
        </span>
      </div>

      <${OutcomeDistBar} />

      ${CASCADE_TRACES.map(trace => {
        const totalMs = trace.steps.reduce((s, st) => s + st.ms, 0)
        const maxMs = Math.max(1, ...trace.steps.map(s => s.ms))
        return html`
        <div key=${trace.id} class="pm-card">
          <div class="pm-card-head">
            <div class="flex items-center gap-2">
              <span class="t-label">${trace.label}</span>
              <span class="chip sm ${cascadeTierStyle(trace.tier)}">
                ${cascadeTierLabel(trace.tier)}
              </span>
            </div>
            <span class="t-caption">${formatMs(totalMs)} total</span>
          </div>
          <div class="px-3 py-2 bg-[var(--shell-rail-bg)]">
            <${TraceTimingBar} steps=${trace.steps} />
          </div>
          <div class="flex items-stretch px-2 py-2">
            ${trace.steps.map((step, i) => {
              const isLast = i === trace.steps.length - 1
              return html`
                <${StepBlock} key=${i} step=${step} maxMs=${maxMs} />
                ${!isLast ? html`<${ArrowConnector} />` : null}
              `
            })}
          </div>
        </div>
        `
      })}
    </div>
  `
}
