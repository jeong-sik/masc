// Observatory detail pane (RFC-MASC-006 Phase 2d)
//
// Click drill-down: when a track marker is clicked, detailSelection updates
// and this pane renders the raw TelemetryEntry alongside key metadata
// (source, timestamp, keeper, outcome).  Close button clears selection.

import { html } from 'htm/preact'
import type { TelemetryEntry } from '../../api/dashboard'
import { detailSelection, clearSelection, type DetailSelection } from './detail-selection-store'

function selectionTitle(selection: DetailSelection): string {
  const source = typeof selection.entry.source === 'string' ? selection.entry.source : '?'
  const eventType = typeof selection.entry.event_type === 'string' ? selection.entry.event_type : ''
  if (selection.kind === 'tool_call') {
    const name = typeof selection.entry.tool_name === 'string'
      ? selection.entry.tool_name
      : (typeof selection.entry.name === 'string' ? selection.entry.name : '?')
    return `도구 · ${name}`
  }
  return eventType ? `${source}:${eventType}` : source
}

function outcomeTag(entry: TelemetryEntry): { label: string; tone: 'ok' | 'bad' | 'neutral' } | null {
  if (entry.success === true) return { label: 'success', tone: 'ok' }
  if (entry.success === false) return { label: 'failure', tone: 'bad' }
  const err = entry.error
  if (err != null && err !== '') return { label: 'error', tone: 'bad' }
  return null
}

function toneClass(tone: 'ok' | 'bad' | 'neutral'): string {
  if (tone === 'ok') return 'bg-[var(--ok-10)] text-[var(--color-status-ok)] border-[var(--ok-20)]'
  if (tone === 'bad') return 'bg-[var(--bad-10)] text-[var(--bad-light)] border-[var(--bad-20)]'
  return 'bg-white/5 text-text-dim border-card-border'
}

function keeperOf(entry: TelemetryEntry): string | null {
  if (typeof entry.keeper === 'string' && entry.keeper !== '') return entry.keeper
  if (typeof entry.keeper_id === 'string' && entry.keeper_id !== '') return entry.keeper_id
  return null
}

function MetaRow({ label, value }: { label: string; value: string }) {
  return html`
    <div class="flex items-baseline gap-2 text-2xs">
      <span class="w-20 shrink-0 text-text-dim">${label}</span>
      <span class="font-mono text-text-strong break-all">${value}</span>
    </div>
  `
}

function formatJson(entry: TelemetryEntry): string {
  try {
    return JSON.stringify(entry, null, 2)
  } catch {
    return String(entry)
  }
}

export function DetailPane() {
  const selection = detailSelection.value
  if (selection === null) return null

  const outcome = outcomeTag(selection.entry)
  const keeper = keeperOf(selection.entry)
  const source = typeof selection.entry.source === 'string' ? selection.entry.source : null

  return html`
    <div class="rounded border border-accent/30 bg-bg-0/60 shadow-sm" role="region" aria-label="선택 항목 상세">
      <div class="flex items-center justify-between border-b border-card-border px-3 py-2">
        <div class="flex items-center gap-2">
          <span class="text-3xs uppercase tracking-widest text-accent font-semibold">상세</span>
          <span class="text-xs font-semibold text-text-strong">${selectionTitle(selection)}</span>
          ${outcome ? html`
            <span class="rounded-sm border px-2 py-0.5 text-3xs font-mono ${toneClass(outcome.tone)}">
              ${outcome.label}
            </span>
          ` : null}
        </div>
        <button
          type="button"
          class="rounded px-2 py-0.5 text-2xs text-text-dim hover:text-text-strong hover:bg-white/5"
          onClick=${clearSelection}
          aria-label="상세 패널 닫기"
        >
          ✕
        </button>
      </div>
      <div class="grid grid-cols-1 gap-1.5 px-3 py-2 md:grid-cols-2">
        <${MetaRow} label="시각" value=${new Date(selection.ts).toLocaleString()} />
        ${selection.bucketCount > 1 ? html`
          <${MetaRow} label="bucket" value=${`${selection.bucketCount} events`} />
        ` : null}
        ${source ? html`<${MetaRow} label="source" value=${source} />` : null}
        ${keeper ? html`<${MetaRow} label="keeper" value=${keeper} />` : null}
        ${typeof selection.entry.session_id === 'string' ? html`
          <${MetaRow} label="session" value=${selection.entry.session_id} />
        ` : null}
        ${typeof selection.entry.operation_id === 'string' ? html`
          <${MetaRow} label="operation" value=${selection.entry.operation_id} />
        ` : null}
      </div>
      <details class="border-t border-card-border">
        <summary class="cursor-pointer px-3 py-1.5 text-2xs text-text-dim hover:text-text-strong">
          raw entry (JSON)
        </summary>
        <pre class="max-h-64 overflow-auto px-3 py-2 text-3xs font-mono text-text-strong bg-[var(--white-5)]/30">${formatJson(selection.entry)}</pre>
      </details>
    </div>
  `
}
