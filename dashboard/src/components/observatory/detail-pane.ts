// Observatory detail pane — keeper-v2 monitor-more design (.ob-detail).
//
// One dashed strip under the readout: an .ia-k label plus either the dim
// hint (nothing picked) or .ob-detail-body with the selection badge, title,
// keeper and time. Click drill-down is persistent (detail-selection-store);
// the close button clears it. The meta grid and raw-JSON details below the
// design's single row are live-only extras, kept full-width inside the strip.

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

function outcomeTag(entry: TelemetryEntry): { label: string; tone: 'ok' | 'bad' } | null {
  if (entry.success === true) return { label: 'success', tone: 'ok' }
  if (entry.success === false) return { label: 'failure', tone: 'bad' }
  const err = entry.error
  if (err != null && err !== '') return { label: 'error', tone: 'bad' }
  return null
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

  if (selection === null) {
    return html`
      <div class="ob-detail" role="region" aria-label="선택 항목 상세">
        <span class="ia-k">Detail pane</span>
        <span class="dim">이벤트 마커를 클릭하면 상세가 여기에 열립니다.</span>
      </div>
    `
  }

  const outcome = outcomeTag(selection.entry)
  const keeper = keeperOf(selection.entry)
  const source = typeof selection.entry.source === 'string' ? selection.entry.source : null

  return html`
    <div class="ob-detail" role="region" aria-label="선택 항목 상세">
      <span class="ia-k">Detail pane</span>
      <div class="ob-detail-body">
        ${outcome ? html`<span class="ai-b ${outcome.tone}">${outcome.label}</span>` : null}
        <span class="mono">${selectionTitle(selection)}</span>
        ${keeper ? html`<span class="mono">${keeper}</span>` : null}
        <span class="dim">${new Date(selection.ts).toLocaleString()}</span>
        <button
          type="button"
          class="ia-filter"
          onClick=${clearSelection}
          aria-label="상세 패널 닫기"
        >
          ✕
        </button>
      </div>
      <div class="w-full grid grid-cols-1 gap-1.5 md:grid-cols-2">
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
      <details class="w-full">
        <summary class="cursor-pointer py-1.5 text-2xs text-text-dim hover:text-text-strong">
          raw entry (JSON)
        </summary>
        <pre class="max-h-64 overflow-auto px-3 py-2 text-3xs font-mono text-text-strong bg-[var(--color-bg-elevated)]/30">${formatJson(selection.entry)}</pre>
      </details>
    </div>
  `
}
