import { html } from 'htm/preact'
import { signal, useSignalEffect } from '@preact/signals'
import { fetchLogs } from '../api/dashboard.js'
import type { LogEntry } from '../api/dashboard.js'
import { ActionButton } from './common/button.js'
import { ErrorState } from './common/feedback-state.js'

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
    <div class="flex flex-col gap-2 h-full min-h-0">
      <div class="flex justify-between items-center gap-4 py-2 shrink-0">
        <div class="flex gap-2 items-center">
          <select
            class="rounded bg-[var(--white-4)] border border-[var(--card-border)] text-[var(--text-body)] text-xs px-2 py-1"
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
            class="rounded bg-[var(--white-4)] border border-[var(--card-border)] text-[var(--text-body)] text-xs px-2 py-1 placeholder:text-[var(--text-muted)]"
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
            class="rounded bg-[var(--white-4)] border border-[var(--card-border)] text-[var(--text-body)] text-xs px-2 py-1"
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

        <div class="flex gap-3 items-center text-xs text-[var(--text-muted)]">
          <span class="tabular-nums">${(logTotal.value ?? 0).toLocaleString()}건</span>
          <label class="flex items-center gap-1 cursor-pointer">
            <input
              type="checkbox"
              checked=${autoRefresh.value}
              onChange=${() => { autoRefresh.value = !autoRefresh.value }}
            />
            자동
          </label>
          <${ActionButton} variant="ghost" size="sm" onClick=${() => { void loadLogs() }}
            disabled=${logLoading.value}>
            ${logLoading.value ? '...' : '새로고침'}
          </${ActionButton}>
        </div>
      </div>

      ${logError.value ? html`
        <${ErrorState}>${logError.value}</${ErrorState}>
      ` : null}

      <div class="rounded overflow-auto flex-1 min-h-0">
        <table class="w-full text-xs border-collapse">
          <thead class="sticky top-0 bg-[var(--card)] z-[1] text-[10px] uppercase tracking-wider text-[var(--text-muted)]">
            <tr>
              <th class="w-44 whitespace-nowrap text-[var(--text-muted)]">timestamp</th>
              <th class="w-14 whitespace-nowrap font-semibold">level</th>
              <th class="w-32 whitespace-nowrap text-[var(--accent)]">module</th>
              <th class="break-words">message</th>
            </tr>
          </thead>
          <tbody>
            ${logEntries.value.map(entry => html`
              <tr key=${entry.seq} class="hover:bg-[var(--white-3)] ${entry.level === 'ERROR' ? 'bg-[rgba(224,80,80,0.06)]' : entry.level === 'WARN' ? 'bg-[rgba(230,167,0,0.04)]' : ''}">
                <td class="w-44 whitespace-nowrap text-[var(--text-muted)]">${entry.ts.replace('T', ' ').replace('Z', '')}</td>
                <td class="w-14 whitespace-nowrap font-semibold" style="color: ${LEVEL_COLORS[entry.level] ?? 'inherit'}">
                  ${entry.level}
                </td>
                <td class="w-32 whitespace-nowrap text-[var(--accent)]">${entry.module}</td>
                <td class="break-words">${entry.message}</td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
    </div>
  `
}
