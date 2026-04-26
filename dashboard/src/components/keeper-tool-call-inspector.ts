// Keeper Tool Call Inspector — shows full tool call I/O (input args + output)
// Fetches from GET /api/v1/keepers/:name/tool-calls

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { fetchKeeperToolCalls } from '../api/dashboard'
import type { ToolCallEntry, ToolCallsResponse, TelemetryFreshnessMetadata } from '../api/dashboard'
import { formatTimeHms, formatElapsedCompact } from '../lib/format-time'
import { LoadingState } from './common/feedback-state'
import { SectionCap } from './common/section-cap'
import { toolCategory, formatDuration, durationColor } from './tool-call-shared'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { parseToolBlobMarker } from '../lib/tool-blob-marker'
import { CopyIdButton } from './common/copy-id-button'

// Delegated to lib/format-time (SSOT)
const formatTimestamp = formatTimeHms

function sourceHealthClass(health?: string | null): string {
  switch ((health ?? '').toLowerCase()) {
    case 'ok':
      return 'text-[var(--color-status-ok)]'
    case 'stale':
    case 'coverage_gap':
    case 'empty':
      return 'text-[var(--color-status-warn)]'
    case 'missing':
      return 'text-[var(--bad-light)]'
    default:
      return 'text-[var(--color-fg-disabled)]'
  }
}

function freshnessText(d: TelemetryFreshnessMetadata): string {
  if (d.stale_reason) return d.stale_reason
  if (typeof d.latest_age_s !== 'number' || !Number.isFinite(d.latest_age_s)) {
    return 'latest n/a'
  }
  return `latest ${formatElapsedCompact(d.latest_age_s)}`
}

function FreshnessLine({ data }: { data: TelemetryFreshnessMetadata }) {
  return html`
    <div class="text-3xs text-[var(--color-fg-disabled)]">
      <span class="font-mono">${data.source ?? 'tool_call_io'}</span>
      <span class="mx-1">·</span>
      <span class="font-mono ${sourceHealthClass(data.health)}">${data.health ?? 'unknown'}</span>
      <span class="mx-1">·</span>
      <span>${freshnessText(data)}</span>
      ${typeof data.entry_count === 'number' ? html`
        <span class="mx-1">·</span>
        <span>${data.entry_count.toLocaleString()} rows</span>
      ` : null}
    </div>
  `
}

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

function CopyableToolCallBlock({
  title,
  value,
  maxHeightClass,
  ariaLabel,
}: {
  title: string
  value: string
  maxHeightClass: string
  ariaLabel: string
}) {
  return html`
    <div>
      <div class="mb-1 flex items-center justify-between gap-2">
        <${SectionCap}>${title}<//>
        <${CopyIdButton}
          value=${value}
          label=${`tool call ${title.toLowerCase()}`}
          ariaLabel=${ariaLabel}
          size=${12}
        />
      </div>
      <pre class=${`text-xs font-mono bg-[var(--bg-deep)] rounded p-2 overflow-x-auto ${maxHeightClass} whitespace-pre-wrap text-[var(--color-fg-secondary)]`}>${value}</pre>
    </div>
  `
}

function ToolCallRow({ entry }: { entry: ToolCallEntry }) {
  const expanded = useSignal(false)
  const cat = toolCategory(entry.tool)
  const formattedInput = formatInput(entry.input)
  const formattedOutput = formatOutput(entry.output)

  return html`
    <div
      class="border-b border-[var(--color-border-default)] hover:bg-[var(--color-bg-hover)] transition-colors"
    >
      <button
        type="button"
        class="w-full flex items-center gap-2 px-3 py-2 text-xs cursor-pointer text-left focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-accent"
        aria-expanded=${expanded.value}
        onClick=${() => { expanded.value = !expanded.value }}
      >
        <span class="font-mono ${cat.color} w-4 text-center flex-shrink-0">${cat.icon}</span>
        <span class="font-mono text-[var(--color-fg-secondary)] flex-shrink-0 w-16">${formatTimestamp(entry.ts)}</span>
        <span class="font-mono font-medium text-[var(--color-fg-secondary)] truncate flex-1" title=${entry.tool}>${entry.tool}</span>
        <span class=${`font-mono flex-shrink-0 w-16 text-right ${durationColor(entry.duration_ms)}`}>
          ${formatDuration(entry.duration_ms)}
        </span>
        <span class=${`flex-shrink-0 w-5 text-center ${entry.success ? 'text-[var(--color-status-ok)]' : 'text-[var(--color-status-err)]'}`}>
          ${entry.success ? 'O' : 'X'}
        </span>
        <span class="flex-shrink-0 w-4 text-[var(--color-fg-muted)] text-center">
          ${expanded.value ? '-' : '+'}
        </span>
      </button>

      ${expanded.value ? html`
        <div class="px-3 pb-3 space-y-2">
          ${entry.model ? html`
            <div class="text-3xs text-[var(--color-fg-muted)]">model: <span class="text-[var(--color-fg-secondary)] font-mono">${entry.model}</span></div>
          ` : null}
          <${CopyableToolCallBlock}
            title="Input"
            value=${formattedInput}
            maxHeightClass="max-h-48"
            ariaLabel="Copy tool call input"
          />
          <${CopyableToolCallBlock}
            title="Output"
            value=${formattedOutput}
            maxHeightClass="max-h-64"
            ariaLabel="Copy tool call output"
          />
        </div>
      ` : null}
    </div>
  `
}

// ── Main component ──────────────────────────────────────

export function KeeperToolCallInspector({ keeperName }: { keeperName: string }) {
  const resource = useManagedAsyncResource<ToolCallsResponse | null>(null)
  const filterTool = useSignal('')

  useEffect(() => {
    void resource.load(async (signal) => {
      return await fetchKeeperToolCalls(keeperName, 100, { signal })
    })
    return () => {
      resource.cancel()
    }
  }, [keeperName, resource])

  const response = resource.state.value.data
  const allEntries = response?.entries ?? []
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
    return html`<div class="text-xs text-[var(--color-status-err)] p-4">${resource.state.value.error}</div>`
  }

  const entries = allEntries

  if (entries.length === 0) {
    return html`
      <div class="p-4">
        <div class="text-xs text-[var(--color-fg-muted)]">도구 호출 데이터 없음</div>
        <${FreshnessLine} data=${response ?? { source: 'tool_call_io' }} />
      </div>
    `
  }

  // Summary stats
  const totalCalls = entries.length
  const successRate = totalCalls > 0
    ? Math.round((entries.filter(e => e.success).length / totalCalls) * 100)
    : 0
  const uniqueTools = new Set(entries.map(e => e.tool)).size

  return html`
    <div class="space-y-3">
      <div class="flex items-center justify-between gap-3 flex-wrap">
        <div class="flex gap-4 text-xs text-[var(--color-fg-muted)]">
          <span>${totalCalls} calls</span>
          <span>${uniqueTools} tools</span>
          <span class=${successRate < 80 ? 'text-[var(--color-status-warn)]' : ''}>${successRate}% ok</span>
        </div>
        <${FreshnessLine} data=${response ?? { source: 'tool_call_io' }} />
        <input
          type="text"
          placeholder="Filter tool..."
          class="text-xs font-mono bg-[var(--bg-deep)] border border-[var(--color-border-default)] rounded px-2 py-1 w-40 text-[var(--color-fg-secondary)]"
          value=${filterTool.value}
          onInput=${(e: Event) => { filterTool.value = (e.target as HTMLInputElement).value }}
        />
      </div>

      <div class="border border-[var(--color-border-default)] rounded overflow-hidden max-h-[500px] overflow-y-auto">
        <${SectionCap} class="flex items-center gap-2 px-3 py-1.5 bg-[var(--bg-deep)] border-b border-[var(--color-border-default)]">
          <span class="w-4"></span>
          <span class="w-16">시간</span>
          <span class="flex-1">도구</span>
          <span class="w-16 text-right">지속시간</span>
          <span class="w-5 text-center">OK</span>
          <span class="w-4"></span>
        </div>
        ${sorted.map((entry: ToolCallEntry) => html`<${ToolCallRow} key=${`${entry.ts}-${entry.keeper}-${entry.tool}`} entry=${entry} />`)}
      </div>
    </div>
  `
}
