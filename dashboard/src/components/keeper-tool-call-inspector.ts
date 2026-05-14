// Keeper Tool Call Inspector — shows full tool call I/O (input args + output)
// Fetches from GET /api/v1/keepers/:name/tool-calls

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { fetchKeeperToolCalls } from '../api/dashboard'
import type { ToolCallEntry, ToolCallsResponse, TelemetryFreshnessMetadata } from '../api/dashboard'
import { formatTimeHms } from '../lib/format-time'
import { LoadingState } from './common/feedback-state'
import { SectionCap } from './common/section-cap'
import { toolCategory, formatDuration, durationColor } from './tool-call-shared'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { parseToolBlobMarker } from '../lib/tool-blob-marker'
import { CopyIdButton } from './common/copy-id-button'
import { TextInput } from './common/input'
import { ringFocusClasses } from './common/ring'
import { coverageGapDisplay, sourceHealthClass, freshnessText } from './common/source-health'
import {
  openIdeContextRouteLink,
  routeLinksForContext,
  type IdeContextRouteContext,
  type IdeContextRouteLink,
} from './ide/ide-context-lens'

// Delegated to lib/format-time (SSOT)
const formatTimestamp = formatTimeHms

function FreshnessLine({ data }: { data: TelemetryFreshnessMetadata }) {
  const gap = coverageGapDisplay(data)
  return html`
    <div class="text-3xs text-[var(--color-fg-disabled)]">
      <span class="font-mono">${data.source ?? 'tool_call_io'}</span>
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
  try {
    return JSON.stringify(JSON.parse(s), null, 2)
  } catch {
    return null
  }
}

type ToolRouteContextFields = Pick<
  IdeContextRouteContext,
  | 'filePath'
  | 'line'
  | 'goalId'
  | 'taskId'
  | 'boardPostId'
  | 'commentId'
  | 'prId'
  | 'gitRef'
  | 'logId'
  | 'sessionId'
  | 'operationId'
  | 'workerRunId'
>
type MutableToolRouteContext = {
  -readonly [K in keyof ToolRouteContextFields]?: ToolRouteContextFields[K]
}

function stringField(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null
}

function positiveLine(value: unknown): number | undefined {
  if (typeof value === 'number' && Number.isSafeInteger(value) && value >= 1) return value
  if (typeof value !== 'string') return undefined
  const trimmed = value.trim()
  return /^[1-9]\d*$/.test(trimmed) ? Number.parseInt(trimmed, 10) : undefined
}

function idString(value: unknown): string | undefined {
  const text = stringField(value)
  if (text) return text
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 1
    ? String(value)
    : undefined
}

function nestedRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null
}

function parseInputRecord(input: string): Record<string, unknown> | null {
  try {
    return nestedRecord(JSON.parse(input))
  } catch {
    return null
  }
}

function codeLocationFromRecord(record: Record<string, unknown> | null): Pick<ToolRouteContextFields, 'filePath' | 'line'> | null {
  if (!record) return null
  const filePath =
    stringField(record.file_path)
    ?? stringField(record.path)
    ?? stringField(record.file)
  if (!filePath) return null
  return {
    filePath,
    line: positiveLine(record.line) ?? positiveLine(record.line_start) ?? positiveLine(record.lineno),
  }
}

function mergeToolRouteRecord(
  context: MutableToolRouteContext,
  record: Record<string, unknown> | null,
  overwrite = false,
): void {
  if (!record) return
  const location = codeLocationFromRecord(record)
  if (location?.filePath && (overwrite || context.filePath === undefined)) context.filePath = location.filePath
  if (location?.line !== undefined && (overwrite || context.line === undefined)) context.line = location.line

  const goalId = idString(record.goal_id)
  if (goalId && (overwrite || context.goalId === undefined)) context.goalId = goalId
  const taskId = idString(record.task_id)
  if (taskId && (overwrite || context.taskId === undefined)) context.taskId = taskId
  const boardPostId = idString(record.board_post_id) ?? idString(record.post_id)
  if (boardPostId && (overwrite || context.boardPostId === undefined)) context.boardPostId = boardPostId
  const commentId = idString(record.comment_id) ?? idString(record.reply_id) ?? idString(record.comment_number)
  if (commentId && (overwrite || context.commentId === undefined)) context.commentId = commentId
  const prId = idString(record.pr_id) ?? idString(record.pull_request) ?? idString(record.pr_number)
  if (prId && (overwrite || context.prId === undefined)) context.prId = prId
  const gitRef = idString(record.git_ref) ?? idString(record.commit) ?? idString(record.branch)
  if (gitRef && (overwrite || context.gitRef === undefined)) context.gitRef = gitRef
  const logId = idString(record.log_id)
  if (logId && (overwrite || context.logId === undefined)) context.logId = logId
  const sessionId = idString(record.session_id)
  if (sessionId && (overwrite || context.sessionId === undefined)) context.sessionId = sessionId
  const operationId = idString(record.operation_id)
  if (operationId && (overwrite || context.operationId === undefined)) context.operationId = operationId
  const workerRunId = idString(record.worker_run_id)
  if (workerRunId && (overwrite || context.workerRunId === undefined)) context.workerRunId = workerRunId
}

function mergeToolInputContext(
  context: MutableToolRouteContext,
  input: unknown,
  depth = 0,
): void {
  if (depth > 4) return
  if (typeof input === 'string') {
    mergeToolInputContext(context, parseInputRecord(input), depth + 1)
    return
  }
  const record = nestedRecord(input)
  if (!record) return
  const failureEnvelope = nestedRecord(record.failure_envelope)
  mergeToolRouteRecord(context, nestedRecord(record.context))
  mergeToolRouteRecord(context, nestedRecord(record.evidence_ref))
  mergeToolRouteRecord(context, nestedRecord(failureEnvelope?.evidence_ref))
  mergeToolRouteRecord(context, nestedRecord(record.tool_args))
  mergeToolInputContext(context, record.input, depth + 1)
  mergeToolRouteRecord(context, record, true)
}

function hasToolRouteContext(context: MutableToolRouteContext): boolean {
  return context.filePath !== undefined
    || context.goalId !== undefined
    || context.taskId !== undefined
    || context.boardPostId !== undefined
    || context.commentId !== undefined
    || context.prId !== undefined
    || context.gitRef !== undefined
    || context.logId !== undefined
    || context.sessionId !== undefined
    || context.operationId !== undefined
    || context.workerRunId !== undefined
}

function toolCallRouteLinks(entry: ToolCallEntry): ReadonlyArray<IdeContextRouteLink> {
  const context: MutableToolRouteContext = {}
  mergeToolInputContext(context, entry.input)
  if (!hasToolRouteContext(context)) return []
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
      <pre class=${`text-xs font-mono bg-[var(--bg-deep)] rounded-[var(--r-1)] p-2 overflow-x-auto ${maxHeightClass} whitespace-pre-wrap text-[var(--color-fg-secondary)]`}>${value}</pre>
    </div>
  `
}

function ToolCallRow({ entry }: { entry: ToolCallEntry }) {
  const expanded = useSignal(false)
  const cat = toolCategory(entry.tool)
  const formattedInput = formatInput(entry.input)
  const formattedOutput = formatOutput(entry.output)
  const routeLinks = toolCallRouteLinks(entry)

  return html`
    <div
      class="border-b border-[var(--color-border-default)] hover:bg-[var(--color-bg-hover)] transition-colors"
    >
      <button
        type="button"
        class=${`w-full flex items-center gap-2 px-3 py-2 text-xs cursor-pointer text-left ${ringFocusClasses()}`}
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
          ${routeLinks.length > 0 ? html`
            <div class="flex items-center justify-between gap-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-2">
              <span class="min-w-0 truncate text-3xs font-mono text-[var(--color-fg-muted)]" title=${routeLinks.map(link => link.evidence).join(' · ')}>
                ${routeLinks.map(link => link.evidence).join(' · ')}
              </span>
              <div class="flex shrink-0 flex-wrap justify-end gap-1">
                ${routeLinks.map(link => html`
                  <button
                    key=${link.id}
                    type="button"
                    data-testid=${link.label === 'Code' ? 'keeper-tool-code-link' : undefined}
                    class=${`keeper-tool-route-link rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-3xs font-semibold text-[var(--color-accent-fg)] hover:border-[var(--color-accent-border)] hover:bg-[var(--color-bg-hover)] ${ringFocusClasses()}`}
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
          <${CopyableToolCallBlock}
            title="출력"
            value=${formattedOutput}
            maxHeightClass="max-h-64"
            ariaLabel="도구 호출 출력 복사"
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
    return html`<div class="text-xs text-[var(--color-status-err)] p-4" role="alert">${resource.state.value.error}</div>`
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
        <${TextInput}
          type="text"
          placeholder="도구 필터..."
          ariaLabel="도구 필터"
          class="!bg-[var(--bg-deep)] !px-2 !py-1 !text-xs font-mono w-40"
          value=${filterTool.value}
          onInput=${(e: Event) => { filterTool.value = (e.target as HTMLInputElement).value }}
        />
      </div>

      <div class="border border-[var(--color-border-default)] rounded-[var(--r-1)] overflow-hidden max-h-[500px] overflow-y-auto">
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
