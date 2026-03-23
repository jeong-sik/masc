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
    <div class="flex flex-col gap-4 h-full min-h-0">
      <div class="flex justify-between items-center gap-4 p-3 rounded-2xl border border-card-border/50 bg-card/40 backdrop-blur-md shadow-sm shrink-0">
        <div class="flex gap-2.5 items-center">
          <select
            class="py-1.5 px-3 rounded-lg border border-card-border bg-bg-1/80 text-[12px] font-semibold text-text-strong focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/50 cursor-pointer shadow-inner appearance-none pr-8 relative"
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
            class="py-1.5 px-4 rounded-lg border border-card-border bg-bg-1/80 text-[12px] text-text-strong font-mono placeholder:text-text-muted focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/50 shadow-inner w-48"
            type="text"
            placeholder="module filter..."
            value=${moduleFilter.value}
            onInput=${(e: Event) => {
              moduleFilter.value = (e.target as HTMLInputElement).value
            }}
            onKeyDown=${(e: KeyboardEvent) => {
              if (e.key === 'Enter') void loadLogs()
            }}
          />

          <select
            class="py-1.5 px-3 rounded-lg border border-card-border bg-bg-1/80 text-[12px] font-semibold text-text-strong focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/50 cursor-pointer shadow-inner appearance-none pr-8"
            value=${String(logLimit.value)}
            onChange=${(e: Event) => {
              logLimit.value = parseInt((e.target as HTMLSelectElement).value, 10)
              void loadLogs()
            }}
          >
            <option value="100">100 rows</option>
            <option value="500">500 rows</option>
            <option value="1000">1000 rows</option>
            <option value="3000">3000 rows</option>
          </select>
        </div>

        <div class="flex gap-4 items-center text-[12px] font-medium text-text-muted">
          <span class="tabular-nums px-2.5 py-1 bg-white/5 rounded-md border border-white/5 shadow-sm">${(logTotal.value ?? 0).toLocaleString()}건</span>
          <label class="flex items-center gap-2 cursor-pointer hover:text-text-body transition-colors select-none">
            <div class="relative w-7 h-3.5 rounded-full transition-colors duration-200 ${autoRefresh.value ? 'bg-accent' : 'bg-white/10'}">
              <div class="absolute top-[2px] left-[2px] size-2.5 bg-white rounded-full transition-transform duration-200 shadow-sm ${autoRefresh.value ? 'translate-x-3.5' : 'translate-x-0'}"></div>
            </div>
            자동 갱신
          </label>
          <button class="px-3 py-1.5 rounded-lg border border-transparent bg-white/5 hover:bg-white/10 text-text-strong transition-all duration-200 cursor-pointer shadow-sm disabled:opacity-50" onClick=${() => { void loadLogs() }}
            disabled=${logLoading.value}>
            ${logLoading.value ? '가져오는 중...' : '새로고침'}
          </button>
        </div>
      </div>

      ${logError.value ? html`
        <div class="p-3.5 bg-bad/10 border border-bad/30 text-bad text-[13px] font-medium rounded-xl shadow-sm">${logError.value}</div>
      ` : null}

      <div class="flex-1 min-h-0 rounded-2xl border border-card-border/50 bg-card/60 backdrop-blur-md shadow-inner overflow-hidden flex flex-col">
        <div class="overflow-y-auto custom-scrollbar flex-1">
          <table class="w-full text-left border-collapse text-[12px] font-mono leading-relaxed">
            <thead class="sticky top-0 bg-bg-1/95 backdrop-blur-xl border-b border-card-border/80 z-10 shadow-sm">
              <tr>
                <th class="py-2.5 px-4 w-44 whitespace-nowrap text-text-muted font-semibold tracking-wider">TIMESTAMP</th>
                <th class="py-2.5 px-4 w-16 whitespace-nowrap text-text-strong font-semibold tracking-wider">LEVEL</th>
                <th class="py-2.5 px-4 w-32 whitespace-nowrap text-accent font-semibold tracking-wider">MODULE</th>
                <th class="py-2.5 px-4 text-text-strong font-semibold tracking-wider">MESSAGE</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-card-border/30">
              ${logEntries.value.map(entry => html`
                <tr key=${entry.seq} class="hover:bg-white/5 transition-colors ${entry.level === 'ERROR' ? 'bg-bad/10 hover:bg-bad/20' : entry.level === 'WARN' ? 'bg-warn/10 hover:bg-warn/20' : ''}">
                  <td class="py-1.5 px-4 w-44 whitespace-nowrap text-text-muted/80">${entry.ts.replace('T', ' ').replace('Z', '')}</td>
                  <td class="py-1.5 px-4 w-16 whitespace-nowrap font-bold" style="color: ${LEVEL_COLORS[entry.level] ?? 'inherit'}">
                    ${entry.level}
                  </td>
                  <td class="py-1.5 px-4 w-32 whitespace-nowrap text-accent/90">${entry.module}</td>
                  <td class="py-1.5 px-4 break-words text-text-body whitespace-pre-wrap">${entry.message}</td>
                </tr>
              `)}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  `
}
