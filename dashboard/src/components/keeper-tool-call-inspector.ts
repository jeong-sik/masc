// Keeper Tool Call Inspector — shows full tool call I/O (input args + output)
// Fetches from GET /api/v1/keepers/:name/tool-calls

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { fetchKeeperToolCalls } from '../api/dashboard'
import type { ToolCallEntry } from '../api/dashboard'
import { formatTimeHms } from '../lib/format-time'
import { LoadingState } from './common/feedback-state'
import { SectionCap } from './common/section-cap'
import { toolCategory, formatDuration, durationColor } from './tool-call-shared'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { parseToolBlobMarker } from '../lib/tool-blob-marker'

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

function tryPrettyJson(s: string): string | null {
  try {
    return JSON.stringify(JSON.parse(s), null, 2)
  } catch {
    return null
  }
}

// Tool output may be (a) a raw string, (b) a JSON blob we logged as a string,
// (c) a [masc:blob ...] sentinel produced by Tool_output.encode_for_oas
// when the bytes exceeded the inline threshold (legacy encoding, kept for
// jsonl entries written before the normalization change), or (d) a
// normalized blob descriptor object {_blob: {...}} written by the current
// keeper_tool_call_log. Render all four uniformly as human-readable text.
export function formatOutput(output: string | { _blob: { sha256: string; bytes: number; mime: string; preview: string } }): string {
  if (output == null) return '(empty)'
  if (typeof output === 'object') {
    const { sha256, bytes, mime, preview } = output._blob
    const prettyPreview = tryPrettyJson(preview) ?? preview
    const shaShort = sha256.slice(0, 12)
    return `[masc:blob sha256=${shaShort}\u2026 bytes=${bytes} mime=${mime}]\n${prettyPreview}`
  }
  if (!output) return '(empty)'
  const marker = parseToolBlobMarker(output)
  if (marker !== null) {
    const prettyPreview = tryPrettyJson(marker.preview) ?? marker.preview
    const shaShort = marker.sha256.slice(0, 12)
    return `[masc:blob sha256=${shaShort}\u2026 bytes=${marker.bytes} mime=${marker.mime}]\n${prettyPreview}`
  }
  return tryPrettyJson(output) ?? output
}

// ── Single tool call row (expandable) ───────────────────

function ToolCallRow({ entry }: { entry: ToolCallEntry }) {
  const expanded = useSignal(false)
  const cat = toolCategory(entry.tool)

  return html`
    <div
      class="border-b border-[var(--card-border)] hover:bg-[var(--bg-panel-hover)] transition-colors"
    >
      <button type="button"
        class="w-full flex items-center gap-2 px-3 py-2 text-xs cursor-pointer text-left focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-accent"
        aria-expanded=${expanded.value}
        aria-label=${`${entry.tool} 도구 호출${expanded.value ? ' 접기' : ' 펼치기'}`}
        onClick=${() => { expanded.value = !expanded.value }}
      >
        <span class="font-mono ${cat.color} w-4 text-center flex-shrink-0">${cat.icon}</span>
        <span class="font-mono text-[var(--text-strong)] flex-shrink-0 w-16">${formatTimestamp(entry.ts)}</span>
        <span class="font-mono font-medium text-[var(--text-strong)] truncate flex-1" title=${entry.tool}>${entry.tool}</span>
        <span class=${`font-mono flex-shrink-0 w-16 text-right ${durationColor(entry.duration_ms)}`}>
          ${formatDuration(entry.duration_ms)}
        </span>
        <span class=${`flex-shrink-0 w-5 text-center ${entry.success ? 'text-[var(--ok)]' : 'text-[var(--bad)]'}`} aria-label=${entry.success ? '성공' : '실패'}>
          ${entry.success ? 'O' : 'X'}
        </span>
        <span class="flex-shrink-0 w-4 text-[var(--text-muted)] text-center">
          ${expanded.value ? '-' : '+'}
        </span>
      </button>

      ${expanded.value ? html`
        <div class="px-3 pb-3 space-y-2">
          ${entry.model ? html`
            <div class="text-3xs text-[var(--text-muted)]">model: <span class="text-[var(--text-strong)] font-mono">${entry.model}</span></div>
          ` : null}
          <div>
            <${SectionCap} class="mb-1">입력<//>
            <pre class="text-xs font-mono bg-[var(--bg-deep)] rounded p-2 overflow-x-auto max-h-48 whitespace-pre-wrap text-[var(--text-strong)] leading-[1.4]" tabindex="0" aria-label="도구 입력">${formatInput(entry.input)}</pre>
          </div>
          <div>
            <${SectionCap} class="mb-1">출력<//>
            <pre class="text-xs font-mono bg-[var(--bg-deep)] rounded p-2 overflow-x-auto max-h-64 whitespace-pre-wrap text-[var(--text-strong)] leading-[1.4]" tabindex="0" aria-label="도구 출력">${formatOutput(entry.output)}</pre>
          </div>
        </div>
      ` : null}
    </div>
  `
}

// ── Main component ──────────────────────────────────────

export function KeeperToolCallInspector({ keeperName }: { keeperName: string }) {
  const resource = useManagedAsyncResource<ToolCallEntry[]>([])
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
    return html`<div class="text-xs text-[var(--bad)] p-4" role="alert">${resource.state.value.error}</div>`
  }

  const entries = allEntries

  if (entries.length === 0) {
    return html`<div class="text-xs text-[var(--text-muted)] p-4" role="status">도구 호출 데이터 없음. 서버 재시작 후 기록됩니다.</div>`
  }

  // Summary stats
  const totalCalls = entries.length
  const successRate = totalCalls > 0
    ? Math.round((entries.filter(e => e.success).length / totalCalls) * 100)
    : 0
  const uniqueTools = new Set(entries.map(e => e.tool)).size

  return html`
    <div class="space-y-3" role="region" aria-label="도구 호출 검사">
      <div class="flex items-center justify-between gap-3">
        <div class="flex gap-4 text-xs text-[var(--text-muted)]">
          <span>${totalCalls} calls</span>
          <span>${uniqueTools} tools</span>
          <span class=${successRate < 80 ? 'text-[var(--warn)]' : ''}>${successRate}% ok</span>
        </div>
        <input
          type="text"
          autoComplete="off"
          placeholder="도구 필터"
          aria-label="도구 필터"
          class="text-xs font-mono bg-[var(--bg-deep)] border border-[var(--card-border)] rounded px-2 py-1 w-40 text-[var(--text-strong)]"
          value=${filterTool.value}
          onInput=${(e: Event) => { filterTool.value = (e.target as HTMLInputElement).value }}
        />
      </div>

      <div class="border border-[var(--card-border)] rounded overflow-hidden max-h-[500px] overflow-y-auto custom-scrollbar" tabindex="0" role="list" aria-label="도구 호출 목록">
        <${SectionCap} class="flex items-center gap-2 px-3 py-1.5 bg-[var(--bg-deep)] border-b border-[var(--card-border)]">
          <span class="w-4"></span>
          <span class="w-16">시간</span>
          <span class="flex-1">도구</span>
          <span class="w-16 text-right">소요</span>
          <span class="w-5 text-center" title="성공 여부">OK</span>
          <span class="w-4"></span>
        </div>
        ${sorted.map((entry: ToolCallEntry) => html`<${ToolCallRow} key=${`${entry.ts}-${entry.keeper}-${entry.tool}`} entry=${entry} />`)}
      </div>
    </div>
  `
}
