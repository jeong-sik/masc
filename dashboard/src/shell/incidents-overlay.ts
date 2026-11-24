/**
 * `[I]` Channel 3 Historical Incidents Read-Only Quick-Peek Content.
 *
 * Strictly isolated from Channel 2 Live SSOT (`viewProvenance` / `observerConnected`):
 * records transport/SSE/stream-gap errors without overwriting live fleet health.
 */

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useState } from 'preact/hooks'
import {
  clearDismissedIncidents,
  dismissIncident,
  historicalIncidents,
} from './shell-state'

function formatClock(ts: number): string {
  const d = new Date(ts)
  const hh = String(d.getHours()).padStart(2, '0')
  const mm = String(d.getMinutes()).padStart(2, '0')
  const ss = String(d.getSeconds()).padStart(2, '0')
  return `${hh}:${mm}:${ss}`
}

export function IncidentsOverlayBody(): VNode {
  const [filter, setFilter] = useState('')
  const [showDismissed, setShowDismissed] = useState(false)
  const all = historicalIncidents.value

  const q = filter.trim().toLowerCase()
  const filtered = all.filter((item) => {
    if (!showDismissed && item.dismissed) return false
    if (!q) return true
    return (
      item.summary.toLowerCase().includes(q)
      || item.source.toLowerCase().includes(q)
      || (item.detail?.toLowerCase().includes(q) ?? false)
    )
  })
  const dismissedCount = all.filter((i) => i.dismissed).length

  return html`
    <div class="ap-qpeek-stack" data-testid="incidents-overlay">
      <div class="ap-qpeek-banner">
        Channel 3 Historical Log — isolated from Channel 2 Live SSOT.
      </div>

      <div class="ap-inc-toolbar">
        <input
          type="search"
          class="ap-input"
          placeholder="Filter incidents by source or message…"
          aria-label="장애 이력 필터"
          value=${filter}
          onInput=${(e: Event) => setFilter((e.currentTarget as HTMLInputElement).value)}
        />
        <label class="ap-inc-toggle">
          <input
            type="checkbox"
            checked=${showDismissed}
            onChange=${(e: Event) => setShowDismissed((e.currentTarget as HTMLInputElement).checked)}
          />
          <span>숨김 포함 (${dismissedCount})</span>
        </label>
        ${dismissedCount > 0 && html`
          <button type="button" class="btn-ghost" onClick=${clearDismissedIncidents}>
            숨김 비우기
          </button>
        `}
      </div>

      ${filtered.length === 0
        ? html`<p class="ap-muted">기록된 Channel 3 이력이 없습니다.</p>`
        : html`
            <ul class="ap-qpeek-list">
              ${filtered.map((item) => html`
                <li
                  key=${item.id}
                  class=${`ap-qpeek-card ap-inc-card ap-inc--${item.severity}${item.dismissed ? ' is-dismissed' : ''}`}
                >
                  <div class="ap-qpeek-card-top">
                    <span class="ap-inc-sev">${item.severity.toUpperCase()}</span>
                    <span class="mono ap-muted">${item.source}</span>
                    <span class="mono ap-muted tnum">${formatClock(item.ts)}</span>
                  </div>
                  <div class="ap-inc-summary">${item.summary}</div>
                  ${item.detail && html`<pre class="ap-inc-detail mono">${item.detail}</pre>`}
                  ${!item.dismissed && html`
                    <div class="ap-inc-actions">
                      <button
                        type="button"
                        class="btn-ghost"
                        onClick=${() => dismissIncident(item.id)}
                      >
                        숨김
                      </button>
                    </div>
                  `}
                </li>
              `)}
            </ul>
          `}
    </div>
  `
}
