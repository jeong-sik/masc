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
import {
  isKeeperToolActivityEvent,
  isKeeperToolEvidenceCommittedEvent,
  sseEventMatchesKeeper,
} from './keeper-sse-match'

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

// Route links derive from the recorded row (action_radius target plus the
// identity fields the writer persisted) instead of re-deriving them from the
// tool input here: the server parses the redacted input once at record time
// (keeper_runtime_contract.action_radius_json), so every consumer reads the
// same recorded value.
//
// target_kind says whether the target is a file or a directory, so Code link
// promotion reads it directly. Execute rows used to be held back here by name,
// because their cwd arrived as target_kind "path" and there was no way to tell
// it from a file (masc#29013); the writer now records "directory" for a cwd or
// a repo_path.

/** Pure: the route links one recorded row earns. Exported so tests can pin
    which target_kind values promote a Code link without rendering the row. */
export function toolCallRouteLinks(entry: ToolCallEntry): ReadonlyArray<IdeContextRouteLink> {
  const radius = entry.action_radius
  const filePath = radius?.target_kind === 'path'
    ? radius.target_path ?? radius.observed_paths?.[0]
    : undefined
  const goalId = entry.goal_ids?.[0]
  const taskId = entry.task_id
  const sessionId = entry.session_id
  if (filePath === undefined && goalId === undefined && taskId === undefined && sessionId === undefined) {
    return []
  }
  const links = routeLinksForContext({
    filePath,
    goalId,
    taskId,
    sessionId,
    surface: 'Tool',
    label: entry.tool,
    sourceId: `tool:${entry.keeper}:${entry.ts}:${entry.tool}`,
    keeperId: entry.keeper,
    telemetry: sessionId !== undefined,
  })
  return links.some(link => link.label !== 'Keeper') ? links : []
}

// ── Composition tree grouping ───────────────────────────

export type ToolCallTreeNode = {
  entry: ToolCallEntry
  children: ToolCallEntry[]
}

// Nest composition children (rows carrying a composition_run_id) under the
// composite parent row they were dispatched from. The join is typed-field
// equality on recorded identity: parent.tool === child.composition_tool and
// parent.tool_use_id === child.parent_tool_use_id, both non-blank (provider
// ids may be blank or repeated).
//
// Recorded write order differs by execution mode: inline composites write
// the parent row after the children complete (parent ts >= every child ts),
// async composites write it at dispatch (parent ts < every child ts) — both
// observed in .masc/tool_calls 2026-08-18. When several parent rows share
// the join key, the recorded composition_execution of the children picks the
// shape to try first: an all-async run attaches to the candidate nearest
// at-or-before its oldest child, any other run to the candidate nearest
// at-or-after its newest child, with the other shape as fallback. A
// candidate set strictly inside the child ts window matches neither
// recorded shape and is left unattributed rather than guessed. Children
// whose parent row is outside the given list stay top-level, so a filtered
// window never hides recorded calls.
export function groupToolCallTree(entries: readonly ToolCallEntry[]): ToolCallTreeNode[] {
  const parentKey = (tool: string, toolUseId: string): string => `${tool}\u0000${toolUseId}`
  const parentsByKey = new Map<string, ToolCallEntry[]>()
  for (const entry of entries) {
    if (entry.composition_run_id !== undefined) continue
    if (entry.tool_use_id === undefined || entry.tool_use_id === '') continue
    const key = parentKey(entry.tool, entry.tool_use_id)
    const bucket = parentsByKey.get(key)
    if (bucket === undefined) {
      parentsByKey.set(key, [entry])
    } else {
      bucket.push(entry)
    }
  }

  type RunGroup = {
    key: string
    children: ToolCallEntry[]
    newestChildTs: number
    oldestChildTs: number
  }
  const groupsByRun = new Map<string, RunGroup>()
  for (const entry of entries) {
    if (entry.composition_run_id === undefined) continue
    if (entry.composition_tool === undefined) continue
    if (entry.parent_tool_use_id === undefined || entry.parent_tool_use_id === '') continue
    const key = parentKey(entry.composition_tool, entry.parent_tool_use_id)
    const group = groupsByRun.get(entry.composition_run_id)
    if (group === undefined) {
      groupsByRun.set(entry.composition_run_id, {
        key,
        children: [entry],
        newestChildTs: entry.ts,
        oldestChildTs: entry.ts,
      })
    } else {
      group.children.push(entry)
      group.newestChildTs = Math.max(group.newestChildTs, entry.ts)
      group.oldestChildTs = Math.min(group.oldestChildTs, entry.ts)
    }
  }

  const childrenByParent = new Map<ToolCallEntry, ToolCallEntry[]>()
  const nestedChildren = new Set<ToolCallEntry>()
  for (const group of groupsByRun.values()) {
    const candidates = parentsByKey.get(group.key)
    if (candidates === undefined) continue
    // Inline shape: parent written after the children completed.
    const completionParent = (): ToolCallEntry | null => {
      let found: ToolCallEntry | null = null
      for (const candidate of candidates) {
        if (candidate.ts < group.newestChildTs) continue
        if (found === null || candidate.ts < found.ts) found = candidate
      }
      return found
    }
    // Async shape: parent written at dispatch, before every child.
    const dispatchParent = (): ToolCallEntry | null => {
      let found: ToolCallEntry | null = null
      for (const candidate of candidates) {
        if (candidate.ts > group.oldestChildTs) continue
        if (found === null || candidate.ts > found.ts) found = candidate
      }
      return found
    }
    const allAsync = group.children.every(child => child.composition_execution === 'async')
    const parent = allAsync
      ? dispatchParent() ?? completionParent()
      : completionParent() ?? dispatchParent()
    if (parent === null) continue
    const existing = childrenByParent.get(parent)
    if (existing === undefined) {
      childrenByParent.set(parent, [...group.children])
    } else {
      existing.push(...group.children)
    }
    for (const child of group.children) nestedChildren.add(child)
  }

  const nodes: ToolCallTreeNode[] = []
  for (const entry of entries) {
    if (nestedChildren.has(entry)) continue
    nodes.push({ entry, children: childrenByParent.get(entry) ?? [] })
  }
  return nodes
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
    typeof entry.planned_index === 'number' ? `plan ${entry.planned_index}` : null,
    typeof entry.batch_index === 'number' && typeof entry.batch_size === 'number'
      ? `batch ${entry.batch_index} · size ${entry.batch_size}`
      : null,
    entry.execution_mode ? `mode ${entry.execution_mode}` : null,
    entry.disposition ? `result ${entry.disposition}` : null,
    entry.composition_tool ? `composition ${entry.composition_tool}` : null,
    entry.composition_run_id ? `run ${entry.composition_run_id}` : null,
    entry.composition_node_id ? `node ${entry.composition_node_id}` : null,
    entry.composition_execution ? `execution ${entry.composition_execution}` : null,
    entry.parent_tool_use_id !== undefined
      ? `parent_tool_use_id ${entry.parent_tool_use_id === '' ? '(blank)' : entry.parent_tool_use_id}`
      : null,
    entry.tool_use_id !== undefined
      ? `tool_use_id ${entry.tool_use_id === '' ? '(blank)' : entry.tool_use_id}`
      : null,
    typeof entry.keeper_turn_id === 'number' ? `keeper ${entry.keeper_turn_id}` : null,
    entry.turn_kind ? `turn ${entry.turn_kind}` : null,
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
  return entry.disposition === 'completed' || (entry.disposition === undefined && entry.success)
}

function toolCallDeferred(entry: ToolCallEntry): boolean {
  return entry.disposition === 'deferred'
}

function toolCallFailed(entry: ToolCallEntry): boolean {
  return entry.disposition === 'failed' || (entry.disposition === undefined && !entry.success)
}

function toolCallStatusLabel(entry: ToolCallEntry): string {
  return entry.disposition ?? (toolCallSucceeded(entry) ? 'completed' : 'failed')
}

/** succeeded / deferred / neither, resolved once so the three places that
    branch on it (tone, colour, glyph) cannot drift apart. */
type ToolCallOutcome = 'ok' | 'deferred' | 'failed'

function toolCallOutcome(entry: ToolCallEntry): ToolCallOutcome {
  if (toolCallSucceeded(entry)) return 'ok'
  if (toolCallDeferred(entry)) return 'deferred'
  return 'failed'
}

const TOOL_CALL_OUTCOME_TONE: Record<ToolCallOutcome, StatusChipTone> = {
  ok: 'ok',
  deferred: 'warn',
  failed: 'bad',
}

const TOOL_CALL_OUTCOME_COLOR: Record<ToolCallOutcome, string> = {
  ok: 'text-[var(--color-status-ok)]',
  deferred: 'text-[var(--color-status-warn)]',
  failed: 'text-[var(--color-status-err)]',
}

const TOOL_CALL_OUTCOME_GLYPH: Record<ToolCallOutcome, string> = {
  ok: 'O',
  deferred: 'D',
  failed: 'X',
}

export function deriveKeeperToolCallDossier(
  entries: readonly ToolCallEntry[],
  response: TelemetryFreshnessMetadata | null | undefined,
): KeeperToolCallDossier {
  const latest = newestToolCall(entries)
  const slowest = slowestToolCall(entries)
  const failed = entries.filter(toolCallFailed)
  const deferred = entries.filter(toolCallDeferred)
  const toolCounts = countByTool(entries)
  const hotTool = toolCounts[0] ?? null
  const evidenceLinks = countEvidenceLinks(entries)
  const evidenceCount = evidenceLinks.reduce((sum, item) => sum + item.count, 0)
  const freshnessTone = sourceTone(response?.health)
  const rows = typeof response?.entry_count === 'number' ? response.entry_count : entries.length
  const totalCalls = entries.length
  const failedCount = failed.length
  const deferredCount = deferred.length
  const latestTone: StatusChipTone =
    latest === null ? 'neutral' : TOOL_CALL_OUTCOME_TONE[toolCallOutcome(latest)]

  let headline = 'no calls'
  if (totalCalls > 0 && failedCount > 0) {
    headline = `${failedCount} failed / ${totalCalls}`
  } else if (totalCalls > 0 && deferredCount > 0) {
    headline = `${deferredCount} deferred / ${totalCalls}`
  } else if (totalCalls > 0) {
    headline = `${totalCalls} calls clean`
  }

  let tone: StatusChipTone = 'neutral'
  if (failedCount > 0) {
    tone = 'bad'
  } else if (deferredCount > 0) {
    tone = 'warn'
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
// (c) a [masc:blob ...] marker produced by Tool_output.encode_for_agentCore
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

// ── Recorded execution evidence (route / contract / radius) ──

type EvidencePair = readonly [string, string | undefined]

function EvidenceBlock({ title, pairs }: { title: string; pairs: ReadonlyArray<EvidencePair> }) {
  const rows = pairs.filter((pair): pair is readonly [string, string] => pair[1] !== undefined)
  if (rows.length === 0) return null
  return html`
    <details class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-1.5">
      <summary class="cursor-pointer text-3xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${title}</summary>
      <div class="mt-1 space-y-0.5">
        ${rows.map(([label, value]) => html`
          <div key=${label} class="flex gap-2 text-3xs">
            <span class="w-28 flex-shrink-0 text-[var(--color-fg-muted)]">${label}</span>
            <span class="min-w-0 break-all font-mono text-[var(--color-fg-secondary)]">${value}</span>
          </div>
        `)}
      </div>
    </details>
  `
}

function formatFlag(value: boolean | undefined): string | undefined {
  if (value === undefined) return undefined
  return value ? 'true' : 'false'
}

function joinedOrAbsent(values: readonly string[] | undefined): string | undefined {
  return values !== undefined && values.length > 0 ? values.join(' · ') : undefined
}

function ToolCallEvidenceSection({ entry }: { entry: ToolCallEntry }) {
  const route = entry.route_evidence
  const contract = entry.runtime_contract
  const radius = entry.action_radius
  if (route === undefined && contract === undefined && radius === undefined) return null
  const receiptEntries = route?.receipt_labels !== undefined ? Object.entries(route.receipt_labels) : []
  const receiptLabels = receiptEntries.length > 0
    ? receiptEntries.map(([key, value]) => `${key}=${value}`).join(' ')
    : undefined
  const pathResolution = contract?.path_resolution
  const pathResolutionFlags = pathResolution === undefined
    ? undefined
    : [
        pathResolution.read_implicit_cwd !== undefined
          ? `read_implicit_cwd=${pathResolution.read_implicit_cwd}`
          : null,
        pathResolution.read_explicit_cwd_supported !== undefined
          ? `read_explicit_cwd_supported=${pathResolution.read_explicit_cwd_supported}`
          : null,
      ].filter((part): part is string => part !== null).join(' ') || undefined
  return html`
    <div class="space-y-1 v2-monitoring-panel" data-testid="tool-call-evidence">
      <${EvidenceBlock}
        title="route evidence"
        pairs=${[
          ['descriptor', route?.descriptor_id],
          ['capability', route?.capability_id],
          ['executor', route?.executor],
          ['backend', route?.backend],
          ['runtime handler', route?.runtime_handler],
          ['readonly', formatFlag(route?.readonly)],
          ['status', route?.status],
          ['receipt labels', receiptLabels],
        ]}
      />
      <${EvidenceBlock}
        title="runtime contract"
        pairs=${[
          ['agent', contract?.agent_name],
          ['generation', contract?.generation !== undefined ? String(contract.generation) : undefined],
          ['sandbox root', contract?.sandbox_root],
          ['allowed paths', joinedOrAbsent(contract?.allowed_paths)],
          ['network mode', contract?.network_mode],
          ['runtime profile', contract?.runtime_profile],
          ['path resolution', pathResolutionFlags],
        ]}
      />
      <${EvidenceBlock}
        title="action radius"
        pairs=${[
          ['action key', radius?.action_key],
          ['target kind', radius?.target_kind],
          ['target path', radius?.target_path],
          ['observed paths', joinedOrAbsent(radius?.observed_paths)],
          ['error', radius?.error],
        ]}
      />
    </div>
  `
}

function invocationLabel(entry: ToolCallEntry): string | null {
  const parts = [
    entry.thinking_enabled !== undefined ? `thinking ${entry.thinking_enabled ? 'on' : 'off'}` : null,
    entry.thinking_budget !== undefined ? `budget ${entry.thinking_budget}` : null,
    entry.tool_choice !== undefined ? `tool_choice ${entry.tool_choice}` : null,
    entry.prompt_fingerprint !== undefined ? `prompt ${entry.prompt_fingerprint.slice(0, 12)}` : null,
  ].filter((part): part is string => part !== null)
  return parts.length > 0 ? parts.join(' · ') : null
}

function ToolCallRow({ entry }: { entry: ToolCallEntry }) {
  const expanded = useSignal(false)
  const cat = toolCategory(entry.tool)
  const formattedInput = formatInput(entry.input)
  const routeLinks = toolCallRouteLinks(entry)

  return html`
    <div
      data-composition-node=${entry.composition_node_id}
      data-composition-run=${entry.composition_run_id}
      data-composition-execution=${entry.composition_execution}
      data-tool-call-disposition=${entry.disposition}
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
        ${entry.composition_node_id ? html`
          <span
            class="max-w-40 truncate rounded-[var(--r-1)] border border-[var(--color-accent-border)] bg-[var(--color-accent-muted)] px-1.5 py-0.5 font-mono text-3xs text-[var(--color-accent-fg)]"
            title=${`${entry.composition_tool ?? 'composition'} / ${entry.composition_node_id} / ${entry.composition_execution ?? 'unknown'}`}
          >↳ ${entry.composition_node_id} · ${entry.composition_execution ?? 'unknown'}</span>
        ` : null}
        <span class=${`font-mono flex-shrink-0 w-16 text-right ${entry.duration_ms != null ? durationColor(entry.duration_ms) : 'text-[var(--color-fg-disabled)]'}`}>
          ${entry.duration_ms != null ? formatMsCompact(entry.duration_ms) : NO_DURATION_LABEL}
        </span>
        <span
          class=${`flex-shrink-0 w-5 text-center ${TOOL_CALL_OUTCOME_COLOR[toolCallOutcome(entry)]}`}
          title=${toolCallStatusLabel(entry)}
        >
          ${TOOL_CALL_OUTCOME_GLYPH[toolCallOutcome(entry)]}
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
          ${invocationLabel(entry) !== null ? html`
            <div class="text-3xs text-[var(--color-fg-muted)]">
              invocation: <span class="text-[var(--color-fg-secondary)] font-mono" title=${entry.prompt_fingerprint}>${invocationLabel(entry)}</span>
            </div>
          ` : null}
          <div class="text-3xs text-[var(--color-fg-muted)]">
            occurrence: <span class="text-[var(--color-fg-secondary)] font-mono">${entryScopeLabel(entry)}</span>
          </div>
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
          <${ToolCallEvidenceSection} entry=${entry} />
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
      if (!isKeeperToolActivityEvent(event) && !isKeeperToolEvidenceCommittedEvent(event)) return
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
        ${groupToolCallTree(sorted).map((node: ToolCallTreeNode) => html`
          <div key=${`${node.entry.ts}-${node.entry.keeper}-${node.entry.tool}`}>
            <${ToolCallRow} entry=${node.entry} />
            ${node.children.length > 0 ? html`
              <div
                class="ml-4 border-l border-[var(--color-accent-border)] v2-monitoring-panel"
                data-composition-children=${node.entry.tool_use_id}
              >
                ${node.children.map((child: ToolCallEntry) => html`
                  <${ToolCallRow} key=${`${child.ts}-${child.keeper}-${child.tool}-${child.composition_node_id ?? ''}`} entry=${child} />
                `)}
              </div>
            ` : null}
          </div>
        `)}
      </div>
    </div>
  `
}
