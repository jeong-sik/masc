// CascadeTrace — OAS cascade routing trace visualization.
// Shows miss/hit/skipped steps with timing for each provider attempt.

import { html } from 'htm/preact'
import {
  CASCADE_TRACES,
  cascadeStepColor,
  cascadeTierLabel,
  cascadeTierStyle,
  type CascadeStepStatus,
} from './data'

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

function ArrowConnector() {
  return html`
    <div class="flex items-center px-1 text-[var(--color-fg-disabled)]">
      <svg width="16" height="12" viewBox="0 0 16 12" fill="none" aria-hidden="true" focusable="false">
        <path d="M0 6H12M12 6L8 2M12 6L8 10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
    </div>
  `
}

export function CascadeTrace() {
  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center gap-4 text-[10px] font-mono text-[var(--color-fg-muted)] px-1">
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

      ${CASCADE_TRACES.map(trace => {
        const totalMs = trace.steps.reduce((s, st) => s + st.ms, 0)
        return html`
        <div key=${trace.id} class="border border-[var(--color-border-default)] rounded overflow-hidden">
          <div class="flex items-center justify-between px-3 py-1.5 bg-[var(--white-4)] border-b border-[var(--color-border-default)]">
            <div class="flex items-center gap-2">
              <span class="text-xs font-medium text-[var(--color-fg-primary)]">${trace.label}</span>
              <span class="inline-block rounded px-1.5 py-0.5 text-[9px] font-mono font-bold ${cascadeTierStyle(trace.tier)}">
                ${cascadeTierLabel(trace.tier)}
              </span>
            </div>
            <span class="text-[10px] font-mono text-[var(--color-fg-muted)]">${formatMs(totalMs)} total</span>
          </div>
          <div class="flex items-stretch px-2 py-2">
            ${trace.steps.map((step, i) => {
              const isLast = i === trace.steps.length - 1
              return html`
                <${StepBlock} key=${i} step=${step} />
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

function StepBlock({ step }: { step: typeof CASCADE_TRACES[number]['steps'][number] }) {
  return html`
    <div class="flex-1 flex flex-col items-center gap-1 min-w-[100px]">
      <span class="text-[10px] font-medium text-[var(--color-fg-secondary)]">${step.provider}</span>
      <span class="inline-block rounded border px-2.5 py-0.5 text-[10px] font-mono font-bold ${cascadeStepColor(step.status)}">
        ${stepStatusLabel(step.status)}
      </span>
      <span class="text-[10px] font-mono text-[var(--color-fg-muted)]">${formatMs(step.ms)}</span>
      <span class="text-[9px] text-[var(--color-fg-disabled)] max-w-[100px] truncate" title=${step.reason}>${step.reason}</span>
    </div>
  `
}
