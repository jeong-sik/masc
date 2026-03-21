import { html } from 'htm/preact'
import { signal, useSignalEffect } from '@preact/signals'
import { fetchLogs } from '../api/dashboard.js'
import type { LogEntry } from '../api/dashboard.js'

const logEntries = signal<LogEntry[]>([])
const logTotal = signal(0)
const logLoading = signal(false)
const logError = signal<string | null>(null)
const levelFilter = signal('INFO')
const moduleFilter = signal('')
const autoRefresh = signal(true)
const logLimit = signal(500)

const LEVEL_COLORS: Record<string, string> = {
  DEBUG: 'var(--text-muted)',
  INFO: 'var(--text-body)',
  WARN: '#e6a700',
  ERROR: '#e05050',
}

async function loadLogs() {
  logLoading.value = true
  logError.value = null
  try {
    const resp = await fetchLogs({
      limit: logLimit.value,
      level: levelFilter.value,
      module: moduleFilter.value || undefined,
    })
    logEntries.value = resp.entries
    logTotal.value = resp.total
  } catch (err) {
    logError.value = err instanceof Error ? err.message : String(err)
  } finally {
    logLoading.value = false
  }
}

export function LogViewer() {
  useSignalEffect(() => {
    void loadLogs()
    if (!autoRefresh.value) return
    const id = setInterval(() => { void loadLogs() }, 3000)
    return () => clearInterval(id)
  })

  return html`
    <div class="logs-viewer">
      <div class="logs-toolbar">
        <div class="logs-filters">
          <select
            class="logs-select"
            value=${levelFilter.value}
            onChange=${(e: Event) => {
              levelFilter.value = (e.target as HTMLSelectElement).value
              void loadLogs()
            }}
          >
            <option value="DEBUG">DEBUG+</option>
            <option value="INFO">INFO+</option>
            <option value="WARN">WARN+</option>
            <option value="ERROR">ERROR</option>
          </select>

          <input
            class="logs-module-input"
            type="text"
            placeholder="module filter"
            value=${moduleFilter.value}
            onInput=${(e: Event) => {
              moduleFilter.value = (e.target as HTMLInputElement).value
            }}
            onKeyDown=${(e: KeyboardEvent) => {
              if (e.key === 'Enter') void loadLogs()
            }}
          />

          <select
            class="logs-select"
            value=${String(logLimit.value)}
            onChange=${(e: Event) => {
              logLimit.value = parseInt((e.target as HTMLSelectElement).value, 10)
              void loadLogs()
            }}
          >
            <option value="100">100</option>
            <option value="500">500</option>
            <option value="1000">1000</option>
            <option value="3000">3000</option>
          </select>
        </div>

        <div class="logs-actions">
          <span class="logs-total">${(logTotal.value ?? 0).toLocaleString()}건</span>
          <label class="logs-auto-label">
            <input
              type="checkbox"
              checked=${autoRefresh.value}
              onChange=${() => { autoRefresh.value = !autoRefresh.value }}
            />
            자동
          </label>
          <button class="logs-refresh-btn" onClick=${() => { void loadLogs() }}
            disabled=${logLoading.value}>
            ${logLoading.value ? '...' : '새로고침'}
          </button>
        </div>
      </div>

      ${logError.value ? html`
        <div class="logs-error">${logError.value}</div>
      ` : null}

      <div class="logs-table-wrap">
        <table class="logs-table">
          <thead>
            <tr>
              <th class="logs-col-ts">timestamp</th>
              <th class="logs-col-level">level</th>
              <th class="logs-col-module">module</th>
              <th class="logs-col-msg">message</th>
            </tr>
          </thead>
          <tbody>
            ${logEntries.value.map(entry => html`
              <tr key=${entry.seq} class="logs-row logs-level-${entry.level.toLowerCase()}">
                <td class="logs-col-ts">${entry.ts.replace('T', ' ').replace('Z', '')}</td>
                <td class="logs-col-level" style="color: ${LEVEL_COLORS[entry.level] ?? 'inherit'}">
                  ${entry.level}
                </td>
                <td class="logs-col-module">${entry.module}</td>
                <td class="logs-col-msg">${entry.message}</td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
    </div>
  `
}
