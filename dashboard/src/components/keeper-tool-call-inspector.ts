// Keeper Tool Call Inspector — shows full tool call I/O (input args + output)
// Fetches from GET /api/v1/keepers/:name/tool-calls

import { html } from 'htm/preact'
import { useCallback, useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { fetchKeeperToolCalls } from '../api/dashboard'
import type { ToolCallEntry, ToolCallsResponse, TelemetryFreshnessMetadata } from '../api/dashboard'
import { lastEvent } from '../sse'
import { formatTimeHms } from '../lib/format-time'
import { formatMsCompact } from '../lib/format-number'
import { LoadingState } from './common/feedback-state'
import { asRecord, mergeRouteRecord, hasRouteContext, type MutableRouteContext } from './common/normalize'
import { SectionCap } from './common/section-cap'
import { toolCategory, durationColor, prettyJson } from './tool-call-shared'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { parseToolBlobMarker, type ToolBlobMarker } from '../lib/tool-blob-marker'
import { fetchToolBlob } from '../api/tool-blob'
import { CopyIdButton } from './common/copy-id-button'
import { TextInput } from './common/input'
import { ringFocusClasses } from './common/ring'
import { coverageGapDisplay, sourceHealthClass, freshnessText } from './common/source-health'
import { StatusChip, type StatusChipTone } from './common/status-chip'
import {
  openIdeContextRouteLink,
  routeLinksForContext,
  type IdeContextRouteLink,
} from './ide/ide-context-lens'
import { isKeeperToolActivityEvent, sseEventMatchesKeeper } from './keeper-sse-match'

// Delegated to lib/format-time (SSOT)
const formatTimestamp = formatTimeHms
const NO_DURATION_LABEL = '—'

function FreshnessLine({ data }: { data: TelemetryFreshnessMetadata }) {
  const gap = coverageGapDisplay(data)
  return html`
    <div class="text-3xs text-[var(--color-fg-disabled)] v2-monitoring-row">
      <span class="font-mono">${data.source ?? '(unknown source)'}</span>
      <span class="mx-1" aria-hidden="true">·</span>
      <span class="font-mono ${sourceHealthClass(data.health)}">${data.health ?? 'unknown'}</span>
      <span class="mx-1" aria-hidden="true">·</span>
      <span>${freshnessText(data)}</span>
      ${typeof data.entry_count === 'number' ? html`
        <span class="mx-1" aria-hidden="true">·</span>
        <span>${data.entry_count.toLocaleString()} rows</span>
      ` : null}
      ${gap ? html`
        <div class="mt-1 font-mono text-[var(--color-status-warn)]">${gap.summary}</div>
        ${gap.details.length > 0 ? html`
          <div class="mt-0.5 break-all font-mono text-[var(--color-fg-muted)]">${gap.details.join(' · ')}</div>
        ` : null}
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
  return prettyJson(s)
}

function parseInputRecord(input: string): Record<string, unknown> | null {
  try {
    return asRecord(JSON.parse(input))
  } catch {
    return null
  }
}

function mergeToolInputContext(
  context: MutableRouteContext,
  input: unknown,
  depth = 0,
): void {
  if (depth > 4) return
  if (typeof input === 'string') {
    mergeToolInputContext(context, parseInputRecord(input), depth + 1)
    return
  }
  const record = asRecord(input)
  if (!record) return
  const failureEnvelope = asRecord(record.failure_envelope)
  mergeRouteRecord(context, asRecord(record.context))
  mergeRouteRecord(context, asRecord(record.evidence_ref))
  mergeRouteRecord(context, asRecord(failureEnvelope?.evidence_ref))
  mergeRouteRecord(context, asRecord(record.tool_args))
  mergeToolInputContext(context, record.input, depth + 1)
  mergeRouteRecord(context, record, true)
}

function toolCallRouteLinks(entry: ToolCallEntry): ReadonlyArray<IdeContextRouteLink> {
  const context: MutableRouteContext = {}
  mergeToolInputContext(context, entry.input)
  if (!hasRouteContext(context)) return []
  const links = routeLinksForContext({
    ...context,
    surface: 'Tool',
    label: entry.tool,
    sourceId: `tool:${entry.keeper}:${entry.ts}:${entry.tool}`,
    keeperId: entry.keeper,
    telemetry: context.logId !== undefined
      || context.sessionId !== undefined
      || context.operationId !== undefined
      || context.workerRunId !== undefined,
  })
  return links.some(link => link.label !== 'Keeper') ? links : []
}

type ToolCallDossierCard = {
  key: string
  label: string
  value: string
  detail: string
  tone: StatusChipTone
  title?: string
}

type ToolCallDossierIssue = {
  key: string
  label: string
  detail: string
  tone: StatusChipTone
}

export type KeeperToolCallDossier = {
  headline: string
  tone: StatusChipTone
  cards: ToolCallDossierCard[]
  evidenceLinks: Array<{ label: string; count: number }>
  issues: ToolCallDossierIssue[]
}

function newestToolCall(entries: readonly ToolCallEntry[]): ToolCallEntry | null {
  let latest: ToolCallEntry | null = null
  for (const entry of entries) {
    if (latest === null || entry.ts > latest.ts) latest = entry
  }
  return latest
}

function slowestToolCall(entries: readonly ToolCallEntry[]): ToolCallEntry | null {
  let slowest: ToolCallEntry | null = null
  for (const entry of entries) {
    if (entry.duration_ms == null) continue
    if (slowest === null || slowest.duration_ms == null || entry.duration_ms > slowest.duration_ms) slowest = entry
  }
  return slowest
}

function countByTool(entries: readonly ToolCallEntry[]): Array<{ tool: string; count: number }> {
  const counts = new Map<string, number>()
  for (const entry of entries) {
    counts.set(entry.tool, (counts.get(entry.tool) ?? 0) + 1)
  }
  return [...counts.entries()]
    .map(([tool, count]) => ({ tool, count }))
    .sort((a, b) => b.count - a.count || a.tool.localeCompare(b.tool))
}

function countEvidenceLinks(entries: readonly ToolCallEntry[]): Array<{ label: string; count: number }> {
  const counts = new Map<string, number>()
  for (const entry of entries) {
    for (const link of toolCallRouteLinks(entry)) {
      counts.set(link.label, (counts.get(link.label) ?? 0) + 1)
    }
  }
  return [...counts.entries()]
    .map(([label, count]) => ({ label, count }))
    .sort((a, b) => b.count - a.count || a.label.localeCompare(b.label))
}

function sourceTone(health: string | undefined): StatusChipTone {
  switch (health) {
    case 'ok':
      return 'ok'
    case 'coverage_gap':
    case 'stale':
    case 'warn':
      return 'warn'
    case 'error':
    case 'bad':
      return 'bad'
    default:
      return 'neutral'
  }
}

function durationTone(durationMs: number): StatusChipTone {
  if (durationMs >= 2_000) return 'bad'
  if (durationMs >= 500) return 'warn'
  return 'ok'
}

function entryScopeLabel(entry: ToolCallEntry): string {
  const goalIds = entry.goal_ids ?? []
  const parts = [
    typeof entry.turn === 'number' ? `turn ${entry.turn}` : null,
    typeof entry.keeper_turn_id === 'number' ? `keeper ${entry.keeper_turn_id}` : null,
    entry.lane ? `lane ${entry.lane}` : null,
    entry.task_id ? `task ${entry.task_id}` : null,
    goalIds.length > 0 ? `goal ${goalIds.join(',')}` : null,
    entry.trace_id ? `trace ${entry.trace_id}` : null,
    entry.session_id ? `session ${entry.session_id}` : null,
    entry.model ? `model ${entry.model}` : null,
  ].filter((part): part is string => part !== null)
  return parts.length > 0 ? parts.join(' · ') : 'scope unavailable'
}

function toolCallSucceeded(entry: ToolCallEntry): boolean {
  return entry.success
}

function toolCallStatusLabel(entry: ToolCallEntry): string {
  return toolCallSucceeded(entry) ? 'ok' : 'failed'
}

export function deriveKeeperToolCallDossier(
  entries: readonly ToolCallEntry[],
  response: TelemetryFreshnessMetadata | null | undefined,
): KeeperToolCallDossier {
  const latest = newestToolCall(entries)
  const slowest = slowestToolCall(entries)
  const failed = entries.filter(entry => !toolCallSucceeded(entry))
  const toolCounts = countByTool(entries)
  const hotTool = toolCounts[0] ?? null
  const evidenceLinks = countEvidenceLinks(entries)
  const evidenceCount = evidenceLinks.reduce((sum, item) => sum + item.count, 0)
  const freshnessTone = sourceTone(response?.health)
  const rows = typeof response?.entry_count === 'number' ? response.entry_count : entries.length
  const totalCalls = entries.length
  const failedCount = failed.length
  let latestTone: StatusChipTone = 'neutral'
  if (latest !== null) {
    latestTone = toolCallSucceeded(latest) ? 'ok' : 'bad'
  }

  let headline = 'no calls'
  if (totalCalls > 0 && failedCount > 0) {
    headline = `${failedCount} failed / ${totalCalls}`
  } else if (totalCalls > 0) {
    headline = `${totalCalls} calls clean`
  }

  let tone: StatusChipTone = 'neutral'
  if (failedCount > 0) {
    tone = 'bad'
  } else if (totalCalls > 0) {
    tone = 'ok'
  }

  const cards: ToolCallDossierCard[] = [
    {
      key: 'latest',
      label: 'latest',
      value: latest?.tool ?? 'none',
      detail: latest
        ? `${formatTimestamp(latest.ts)} · ${toolCallStatusLabel(latest)} · ${latest.duration_ms != null ? formatMsCompact(latest.duration_ms) : NO_DURATION_LABEL}`
        : 'no recent tool call',
      tone: latestTone,
      title: latest ? entryScopeLabel(latest) : undefined,
    },
    {
      key: 'failures',
      label: 'failures',
      value: `${failedCount}`,
      detail: failedCount > 0
        ? `${failed[failedCount - 1]!.tool} · ${entryScopeLabel(failed[failedCount - 1]!)}`
        : 'no failed calls in this window',
      tone: failedCount > 0 ? 'bad' : 'ok',
    },
    {
      key: 'slowest',
      label: 'slowest',
      value: slowest?.duration_ms != null ? formatMsCompact(slowest.duration_ms) : NO_DURATION_LABEL,
      detail: slowest ? `${slowest.tool} · ${entryScopeLabel(slowest)}` : 'no duration sample',
      tone: slowest?.duration_ms != null ? durationTone(slowest.duration_ms) : 'neutral',
    },
    {
      key: 'hot-tool',
      label: 'hot tool',
      value: hotTool ? hotTool.tool : 'none',
      detail: hotTool ? `${hotTool.count} calls in current window` : 'no tool concentration',
      tone: hotTool ? 'info' : 'neutral',
    },
    {
      key: 'linked-evidence',
      label: 'linked evidence',
      value: `${evidenceCount}`,
      detail: evidenceLinks.length > 0
        ? evidenceLinks.slice(0, 4).map(item => `${item.label}:${item.count}`).join(' · ')
        : 'no routeable evidence links',
      tone: evidenceCount > 0 ? 'info' : 'neutral',
    },
    {
      key: 'source',
      label: 'source',
      value: response?.health ?? 'unknown',
      detail: `${response?.source ?? 'tool_call_io'} · ${rows} rows`,
      tone: freshnessTone,
    },
  ]

  const issues: ToolCallDossierIssue[] = []
  const latestFailure = failed[failed.length - 1] ?? null
  if (latestFailure) {
    issues.push({
      key: 'latest-failure',
      label: 'latest failure',
      detail: `${latestFailure.tool} · ${formatTimestamp(latestFailure.ts)} · ${entryScopeLabel(latestFailure)}`,
      tone: 'bad',
    })
  }
  if (slowest?.duration_ms != null && slowest.duration_ms >= 2_000) {
    issues.push({
      key: 'slow-call',
      label: 'slow call',
      detail: `${slowest.tool} · ${formatMsCompact(slowest.duration_ms)} · ${entryScopeLabel(slowest)}`,
      tone: 'warn',
    })
  }
  if (freshnessTone !== 'ok' && response?.health) {
    issues.push({
      key: 'freshness',
      label: 'source health',
      detail: `${response.source ?? 'tool_call_io'} · ${response.health}`,
      tone: freshnessTone,
    })
  }

  return {
    headline,
    tone,
    cards,
    evidenceLinks: evidenceLinks.slice(0, 8),
    issues,
  }
}

// Tool output may be (a) a raw string, (b) a JSON blob we logged as a string,
// (c) a [masc:blob ...] marker produced by Tool_output.encode_for_oas
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

// Extract the blob marker from either persisted shape ({_blob: {...}}
// descriptor or legacy [masc:blob ...] string). Null for inline outputs.
export function blobMarkerOfOutput(
  output: ToolCallEntry['output'],
): ToolBlobMarker | null {
  if (output == null) return null
  if (typeof output === 'object') {
    const { sha256, bytes, mime, preview } = output._blob
    return { sha256, bytes, mime, preview }
  }
  return parseToolBlobMarker(output)
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
    <div class="v2-monitoring-panel">
      <div class="mb-1 flex items-center justify-between gap-2">
        <${SectionCap}>${title}<//>
        <${CopyIdButton}
          value=${value}
          label=${`tool call ${title.toLowerCase()}`}
          ariaLabel=${ariaLabel}
          size=${12}
        />
      </div>
      <pre class=${`text-xs font-mono bg-[var(--bg-deep)] rounded-[var(--r-1)] p-2 overflow-x-auto ${maxHeightClass} whitespace-pre-wrap text-[var(--color-fg-secondary)]`}>${value}</pre>
    </div>
  `
}

// Output block with on-demand full-blob hydration. Externalized outputs
// (Tool_blob_store) persist only a ~200-char preview in the jsonl; the full
// bytes stay addressable by sha256 via GET /api/v1/artifacts/<sha>. Without
// this button the inspector shows the truncated preview only, which reads
// as "the tool returned nothing" for large outputs like keeper_context_status
// (#20910).
function ToolCallOutputBlock({ entry }: { entry: ToolCallEntry }) {
  const fullText = useSignal<string | null>(null)
  const loading = useSignal(false)
  const error = useSignal<string | null>(null)
  const marker = blobMarkerOfOutput(entry.output)

  const onLoadFull = async () => {
    if (marker === null || loading.value) return
    loading.value = true
    error.value = null
    try {
      const blob = await fetchToolBlob(marker.sha256)
      fullText.value = tryPrettyJson(blob.content) ?? blob.content
    } catch (e) {
      error.value = e instanceof Error ? e.message : String(e)
    } finally {
      loading.value = false
    }
  }

  return html`
    <div class="space-y-1 v2-monitoring-panel">
      <${CopyableToolCallBlock}
        title="출력"
        value=${fullText.value ?? formatOutput(entry.output)}
        maxHeightClass=${fullText.value !== null ? 'max-h-100' : 'max-h-64'}
        ariaLabel="도구 호출 출력 복사"
      />
      ${marker !== null && fullText.value === null ? html`
        <div class="flex items-center gap-2 v2-monitoring-toolbar">
          <button
            type="button"
            data-testid="tool-output-load-full"
            class=${`rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-3xs font-semibold text-[var(--color-accent-fg)] hover:border-[var(--color-accent-border)] hover:bg-[var(--color-bg-hover)] ${ringFocusClasses()} v2-monitoring-action`}
            disabled=${loading.value}
            onClick=${() => void onLoadFull()}
          >
            ${loading.value ? '불러오는 중…' : `전체 출력 보기 (${marker.bytes.toLocaleString()}B)`}
          </button>
          ${error.value !== null ? html`
            <span class="text-3xs text-[var(--color-status-err)]">${error.value}</span>
          ` : null}
        </div>
      ` : null}
    </div>
  `
}

function ToolCallRow({ entry }: { entry: ToolCallEntry }) {
  const expanded = useSignal(false)
  const cat = toolCategory(entry.tool)
  const formattedInput = formatInput(entry.input)
  const routeLinks = toolCallRouteLinks(entry)

  return html`
    <div
      class="border-b border-[var(--color-border-default)] hover:bg-[var(--color-bg-hover)] transition-colors v2-monitoring-row"
    >
      <button
        type="button"
        class=${`w-full flex items-center gap-2 px-3 py-2 text-xs cursor-pointer text-left ${ringFocusClasses()} v2-monitoring-action`}
        aria-expanded=${expanded.value}
        onClick=${() => { expanded.value = !expanded.value }}
      >
        <span class="font-mono ${cat.color} w-4 text-center flex-shrink-0">${cat.icon}</span>
        <span class="font-mono text-[var(--color-fg-secondary)] flex-shrink-0 w-16">${formatTimestamp(entry.ts)}</span>
        <span class="font-mono font-medium text-[var(--color-fg-secondary)] truncate flex-1" title=${entry.tool}>${entry.tool}</span>
        <span class=${`font-mono flex-shrink-0 w-16 text-right ${entry.duration_ms != null ? durationColor(entry.duration_ms) : 'text-[var(--color-fg-disabled)]'}`}>
          ${entry.duration_ms != null ? formatMsCompact(entry.duration_ms) : NO_DURATION_LABEL}
        </span>
        <span
          class=${`flex-shrink-0 w-5 text-center ${toolCallSucceeded(entry) ? 'text-[var(--color-status-ok)]' : 'text-[var(--color-status-err)]'}`}
          title=${entry.success ? 'ok' : 'failed'}
        >
          ${toolCallSucceeded(entry) ? 'O' : 'X'}
        </span>
        <span class="flex-shrink-0 w-4 text-[var(--color-fg-muted)] text-center">
          ${expanded.value ? '-' : '+'}
        </span>
      </button>

      ${expanded.value ? html`
        <div class="px-3 pb-3 space-y-2 v2-monitoring-panel">
          ${entry.model ? html`
            <div class="text-3xs text-[var(--color-fg-muted)]">model: <span class="text-[var(--color-fg-secondary)] font-mono">${entry.model}</span></div>
          ` : null}
          ${routeLinks.length > 0 ? html`
            <div class="flex items-center justify-between gap-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-2 v2-monitoring-toolbar">
              <span class="min-w-0 truncate text-3xs font-mono text-[var(--color-fg-muted)]" title=${routeLinks.map(link => link.evidence).join(' · ')}>
                ${routeLinks.map(link => link.evidence).join(' · ')}
              </span>
              <div class="flex shrink-0 flex-wrap justify-end gap-1">
                ${routeLinks.map(link => html`
                  <button
                    key=${link.id}
                    type="button"
                    data-testid=${link.label === 'Code' ? 'keeper-tool-code-link' : undefined}
                    class=${`keeper-tool-route-link rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-3xs font-semibold text-[var(--color-accent-fg)] hover:border-[var(--color-accent-border)] hover:bg-[var(--color-bg-hover)] ${ringFocusClasses()} v2-monitoring-action`}
                    title=${link.evidence}
                    aria-label=${`Open ${link.evidence}`}
                    onClick=${() => openIdeContextRouteLink(link)}
                  >
                    ${link.label}
                  </button>
                `)}
              </div>
            </div>
          ` : null}
          <${CopyableToolCallBlock}
            title="입력"
            value=${formattedInput}
            maxHeightClass="max-h-48"
            ariaLabel="도구 호출 입력 복사"
          />
          <${ToolCallOutputBlock} entry=${entry} />
        </div>
      ` : null}
    </div>
  `
}

function ToolCallDossier({ entries, response }: { entries: readonly ToolCallEntry[]; response: ToolCallsResponse }) {
  const dossier = deriveKeeperToolCallDossier(entries, response)
  return html`
    <div
      class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-panel-alt)] p-3 v2-monitoring-panel"
      data-testid="keeper-tool-call-dossier"
    >
      <div class="flex flex-wrap items-center justify-between gap-2 v2-monitoring-toolbar">
        <${SectionCap} weight="semibold">Activity Dossier<//>
        <${StatusChip} tone=${dossier.tone} uppercase=${false}>${dossier.headline}<//>
      </div>
      <div class="mt-3 grid grid-cols-[repeat(auto-fit,minmax(150px,1fr))] gap-2 v2-monitoring-row">
        ${dossier.cards.map(card => html`
          <div
            key=${card.key}
            class="min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-2 v2-monitoring-card"
            title=${card.title ?? card.detail}
          >
            <div class="flex items-center justify-between gap-2">
              <span class="min-w-0 truncate text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${card.label}</span>
              <${StatusChip} tone=${card.tone} uppercase=${false} class="shrink-0">${card.tone}<//>
            </div>
            <div class="mt-1 min-w-0 truncate text-xs font-mono font-medium text-[var(--color-fg-primary)]">${card.value}</div>
            <div class="mt-0.5 min-w-0 truncate text-3xs text-[var(--color-fg-muted)]">${card.detail}</div>
          </div>
        `)}
      </div>
      ${dossier.evidenceLinks.length > 0 ? html`
        <div class="mt-3 flex min-w-0 flex-wrap items-center gap-1.5 v2-monitoring-row">
          <span class="shrink-0 text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">Evidence links</span>
          ${dossier.evidenceLinks.map(item => html`
            <span
              key=${item.label}
              class="inline-flex max-w-full items-center gap-1 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-0.5 text-3xs text-[var(--color-fg-secondary)]"
            >
              <span class="min-w-0 truncate">${item.label}</span>
              <span class="font-mono text-[var(--color-fg-muted)]">${item.count}</span>
            </span>
          `)}
        </div>
      ` : null}
      ${dossier.issues.length > 0 ? html`
        <div class="mt-3 grid gap-1.5 v2-monitoring-row">
          ${dossier.issues.map(issue => html`
            <div
              key=${issue.key}
              class="flex min-w-0 items-center gap-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-1.5 text-3xs v2-monitoring-row"
            >
              <${StatusChip} tone=${issue.tone} uppercase=${false} class="shrink-0">${issue.label}<//>
              <span class="min-w-0 truncate text-[var(--color-fg-muted)]" title=${issue.detail}>${issue.detail}</span>
            </div>
          `)}
        </div>
      ` : null}
    </div>
  `
}

// ── Main component ──────────────────────────────────────

export function KeeperToolCallInspector({ keeperName }: { keeperName: string }) {
  const resource = useManagedAsyncResource<ToolCallsResponse | null>(null)
  const filterTool = useSignal('')

  const loadToolCalls = useCallback((signal: AbortSignal) =>
    fetchKeeperToolCalls(keeperName, 100, { signal }), [keeperName])

  useEffect(() => {
    void resource.load(loadToolCalls)
    return () => {
      resource.cancel()
    }
  }, [loadToolCalls, resource])

  useEffect(() => {
    const unsubscribe = lastEvent.subscribe((event) => {
      if (!event) return
      if (!isKeeperToolActivityEvent(event)) return
      if (!sseEventMatchesKeeper(event, keeperName)) return
      void resource.load(loadToolCalls)
    })
    return () => {
      unsubscribe()
    }
  }, [keeperName, loadToolCalls, resource])

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
    return html`<div class="text-xs text-[var(--color-status-err)] p-4 v2-monitoring-panel" role="alert">${resource.state.value.error}</div>`
  }

  const entries = allEntries

  if (entries.length === 0) {
    return html`
      <div class="p-4 v2-monitoring-panel">
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
    <div class="space-y-3 v2-monitoring-surface">
      <${ToolCallDossier} entries=${entries} response=${response ?? { keeper: keeperName, count: entries.length, source: 'tool_call_io', entries }} />

      <div class="flex items-center justify-between gap-3 flex-wrap v2-monitoring-toolbar">
        <div class="flex gap-4 text-xs text-[var(--color-fg-muted)]">
          <span>${totalCalls} calls</span>
          <span>${uniqueTools} tools</span>
          <span class=${successRate < 80 ? 'text-[var(--color-status-warn)]' : ''}>${successRate}% ok</span>
        </div>
        <${FreshnessLine} data=${response ?? { source: 'tool_call_io' }} />
        <${TextInput}
          type="text"
          placeholder="도구 필터..."
          ariaLabel="도구 필터"
          class="!bg-[var(--bg-deep)] !px-2 !py-1 !text-xs font-mono w-40"
          value=${filterTool.value}
          onInput=${(e: Event) => { filterTool.value = (e.target as HTMLInputElement).value }}
        />
      </div>

      <div class="border border-[var(--color-border-default)] rounded-[var(--r-1)] overflow-hidden max-h-[500px] overflow-y-auto v2-monitoring-panel">
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
