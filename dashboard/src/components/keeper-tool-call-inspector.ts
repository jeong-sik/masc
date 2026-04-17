// Keeper Tool Call Inspector — shows full tool call I/O (input args + output)
// Fetches from GET /api/v1/keepers/:name/tool-calls

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { fetchKeeperToolCalls } from '../api/dashboard'
import type { ToolCallEntry } from '../api/dashboard'
import { formatTimeHms } from '../lib/format-time'
import { LoadingState } from './common/feedback-state'
import { SectionCap } from './common/section-cap'
import { toolCategory, formatDuration, durationColor } from './tool-call-shared'
import { createManagedAsyncResource, type ManagedAsyncResource } from '../lib/async-state'

// Delegated to lib/format-time (SSOT)
const formatTimestamp = formatTimeHms

export function formatInput(input: unknown): string {
  if (input == null) return '-'
  if (typeof input === 'string') return input
  try {
    return JSON.stringify(input, null, 2)
  } catch {
    return String(input)
  }
}

// ── Single tool call row (expandable) ───────────────────

function ToolCallRow({ entry }: { entry: ToolCallEntry }) {
  const expanded = useSignal(false)
  const cat = toolCategory(entry.tool)

  return html`
    <div
      class="border-b border-[var(--card-border)] hover:bg-[var(--bg-panel-hover)] transition-colors"
    >
      <div
        class="flex items-center gap-2 px-3 py-2 text-xs cursor-pointer"
        role="button"
        tabIndex=${0}
        aria-expanded=${expanded.value}
        onClick=${() => { expanded.value = !expanded.value }}
        onKeyDown=${(e: KeyboardEvent) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault()
            expanded.value = !expanded.value
          }
        }}
      >
        <span class="font-mono ${cat.color} w-4 text-center flex-shrink-0">${cat.icon}</span>
        <span class="font-mono text-[var(--text-strong)] flex-shrink-0 w-16">${formatTimestamp(entry.ts)}</span>
        <span class="font-mono font-medium text-[var(--text-strong)] truncate flex-1" title=${entry.tool}>${entry.tool}</span>
        <span class=${`font-mono flex-shrink-0 w-16 text-right ${durationColor(entry.duration_ms)}`}>
          ${formatDuration(entry.duration_ms)}
        </span>
        <span class=${`flex-shrink-0 w-5 text-center ${entry.success ? 'text-[var(--ok)]' : 'text-[var(--bad)]'}`}>
          ${entry.success ? 'O' : 'X'}
        </span>
        <span class="flex-shrink-0 w-4 text-[var(--text-muted)] text-center">
          ${expanded.value ? '-' : '+'}
        </span>
      </div>

      ${expanded.value ? html`
        <div class="px-3 pb-3 space-y-2">
          ${entry.model ? html`
            <div class="text-[10px] text-[var(--text-muted)]">model: <span class="text-[var(--text-strong)] font-mono">${entry.model}</span></div>
          ` : null}
          <div>
            <${SectionCap} class="mb-1">Input<//>
            <pre class="text-xs font-mono bg-[var(--bg-deep)] rounded p-2 overflow-x-auto max-h-48 whitespace-pre-wrap text-[var(--text-strong)]">${formatInput(entry.input)}</pre>
          </div>
          <div>
            <${SectionCap} class="mb-1">Output<//>
            <pre class="text-xs font-mono bg-[var(--bg-deep)] rounded p-2 overflow-x-auto max-h-64 whitespace-pre-wrap text-[var(--text-strong)]">${entry.output || '(empty)'}</pre>
          </div>
        </div>
      ` : null}
    </div>
  `
}

// ── Main component ──────────────────────────────────────

export function KeeperToolCallInspector({ keeperName }: { keeperName: string }) {
  const resourceRef = useRef<ManagedAsyncResource<ToolCallEntry[]> | null>(null)
  if (resourceRef.current === null) {
    resourceRef.current = createManagedAsyncResource<ToolCallEntry[]>([])
  }
  const resource = resourceRef.current
  const filterTool = useSignal('')

  useEffect(() => {
    void resource.load(async (signal) => {
      const response = await fetchKeeperToolCalls(keeperName, 100, { signal })
      return response.entries ?? []
    })
    return () => {
      resource.cancel()
    }
  }, [keeperName, resource])

  const allEntries = resource.state.value.data ?? []
  const filter = filterTool.value.toLowerCase()
  const filtered = !filter
    ? allEntries
    : allEntries.filter(entry => entry.tool.toLowerCase().includes(filter))

  // Reverse to show newest first
  const sorted = [...filtered].reverse()

  if (resource.state.value.loading) {
    return html`<${LoadingState}>도구 호출 불러오는 중...<//>`
  }

  if (resource.state.value.error) {
    return html`<div class="text-xs text-[var(--bad)] p-4">${resource.state.value.error}</div>`
  }

  const entries = allEntries

  if (entries.length === 0) {
    return html`<div class="text-xs text-[var(--text-muted)] p-4">도구 호출 데이터 없음. 서버 재시작 후 기록됩니다.</div>`
  }

  // Summary stats
  const totalCalls = entries.length
  const successRate = totalCalls > 0
    ? Math.round((entries.filter(e => e.success).length / totalCalls) * 100)
    : 0
  const uniqueTools = new Set(entries.map(e => e.tool)).size

  return html`
    <div class="space-y-3">
      <div class="flex items-center justify-between gap-3">
        <div class="flex gap-4 text-xs text-[var(--text-muted)]">
          <span>${totalCalls} calls</span>
          <span>${uniqueTools} tools</span>
          <span class=${successRate < 80 ? 'text-[var(--warn)]' : ''}>${successRate}% ok</span>
        </div>
        <input
          type="text"
          placeholder="Filter tool..."
          class="text-xs font-mono bg-[var(--bg-deep)] border border-[var(--card-border)] rounded px-2 py-1 w-40 text-[var(--text-strong)]"
          value=${filterTool.value}
          onInput=${(e: Event) => { filterTool.value = (e.target as HTMLInputElement).value }}
        />
      </div>

      <div class="border border-[var(--card-border)] rounded overflow-hidden max-h-[500px] overflow-y-auto">
        <${SectionCap} class="flex items-center gap-2 px-3 py-1.5 bg-[var(--bg-deep)] border-b border-[var(--card-border)]">
          <span class="w-4"></span>
          <span class="w-16">Time</span>
          <span class="flex-1">Tool</span>
          <span class="w-16 text-right">Duration</span>
          <span class="w-5 text-center">OK</span>
          <span class="w-4"></span>
        </div>
        ${sorted.map((entry: ToolCallEntry) => html`<${ToolCallRow} key=${`${entry.ts}-${entry.keeper}-${entry.tool}`} entry=${entry} />`)}
      </div>
    </div>
  `
}
