// Session trace entry — expandable row for a single event in the trace timeline.
// Tool category patterns shared via tool-call-shared.ts.

import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { JsonViewerCard, parseJsonLikeData } from '../common/json-viewer'
import { TimeAgo } from '../common/time-ago'
import { Markdown } from '../common/markdown'
import { ProgressBar } from '../common/progress-bar'
import { truncate } from '../../lib/truncate'
import { asNullableString, asRecord, extractCodeLocation, type CodeLocation } from '../common/normalize'
import { deriveTokPerSec, formatCost, formatMsCompact, formatTokPerSec } from '../../lib/format-number'
import { toolCategory, durationColor, formatArgs as sharedFormatArgs } from '../tool-call-shared'
import { SectionHeader } from '../common/section-header'
import {
  openIdeContextRouteLink,
  routeLinksForContext,
  type IdeContextRouteContext,
  type IdeContextRouteLink,
} from '../ide/ide-context-lens'
import type { UnifiedTraceEvent, TraceEventKind } from './session-trace-state'

// ── Constants ──────────────────────────────────────────

const BROADCAST_PREVIEW_MAX = 160

const TRACE_TONE = {
  brassText: 'text-[var(--color-brass-fg)]',
  brassPanel: 'bg-[var(--color-brass-soft)] border border-[var(--color-brass-border)]',
  infoText: 'text-[var(--color-info-fg)]',
  infoFill: 'bg-[var(--color-info-fg)]',
  infoPanel: 'bg-[var(--color-info-soft)] border border-[var(--color-info-border)]',
} as const

function detailNumber(detail: Record<string, unknown>, ...keys: string[]): number | null {
  for (const key of keys) {
    const value = detail[key]
    if (typeof value === 'number' && Number.isFinite(value)) return value
  }
  return null
}

// ── Trace badge helper ──────────────────────────────────

function TraceBadge({
  tone,
  wide,
  children,
}: {
  tone: 'neutral' | 'bad' | 'ok'
  wide?: boolean
  children: unknown
}) {
  const cls = (() => {
    switch (tone) {
      case 'bad':
        return 'text-3xs px-1.5 py-0.5 rounded-[var(--r-1)] bg-[var(--bad-10)] text-[var(--color-status-err)]'
      case 'ok':
        return 'text-3xs px-1.5 py-0.5 rounded-[var(--r-1)] bg-[var(--color-ok-soft)] text-[var(--color-status-ok)]'
      case 'neutral':
      default:
        return `text-3xs px-1.5 py-0.5 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-disabled)] uppercase${wide ? ' tracking-wider' : ''}`
    }
  })()
  return html`<span class="${cls}">${children}</span>`
}

// ── Search highlight ────────────────────────────────────

interface HighlightSegment {
  text: string
  match: boolean
}

function highlightSegments(text: string, query: string): HighlightSegment[] | null {
  if (!query) return null
  const lower = text.toLowerCase()
  const q = query.toLowerCase()
  if (!lower.includes(q)) return null

  const parts: HighlightSegment[] = []
  let lastIndex = 0
  let index = lower.indexOf(q, lastIndex)
  while (index !== -1) {
    if (index > lastIndex) {
      parts.push({ text: text.slice(lastIndex, index), match: false })
    }
    parts.push({ text: text.slice(index, index + q.length), match: true })
    lastIndex = index + q.length
    index = lower.indexOf(q, lastIndex)
  }
  if (lastIndex < text.length) {
    parts.push({ text: text.slice(lastIndex), match: false })
  }
  return parts
}

function HighlightedText({ text, query }: { text: string; query: string }) {
  const segments = highlightSegments(text, query)
  if (!segments) return html`<span>${text}</span>`
  return html`
    <span>${segments.map(seg =>
      seg.match
        ? html`<mark class="bg-[var(--color-brass-soft)] text-[var(--color-fg-secondary)] px-0.5 rounded-[var(--r-1)]">${seg.text}</mark>`
        : seg.text
    )}</span>
  `
}
const RESULT_COLLAPSED_MAX_HEIGHT = 200 // px
const RESULT_LINES_THRESHOLD = 12 // lines above which we collapse

// ── Kind styling ───────────────────────────────────────

interface KindStyle {
  icon: string
  color: string
  label: string
}

const KIND_STYLES: Record<TraceEventKind, KindStyle> = {
  broadcast:  { icon: 'M', color: TRACE_TONE.brassText, label: '브로드캐스트' },
  task:       { icon: 'T', color: 'text-[var(--color-accent-fg)]', label: '태스크' },
  tool_call:  { icon: '>', color: 'text-[var(--color-status-ok)]', label: '도구 호출' },
  heartbeat:  { icon: 'H', color: 'text-[var(--color-fg-muted)]', label: '하트비트' },
  lifecycle:  { icon: 'L', color: 'text-[var(--color-status-warn)]', label: '생명주기' },
  thinking:   { icon: '\u{1F4AD}', color: TRACE_TONE.infoText, label: '내부 사고' },
  oas_tool:   { icon: 'O', color: 'text-[var(--amber-bright)]', label: 'OAS 도구' },
  oas_turn:   { icon: 'R', color: 'text-[var(--rose-light)]', label: 'OAS 턴' },
  oas_context: { icon: 'C', color: TRACE_TONE.infoText, label: 'OAS 압축' },
}

// Use shared tool category from tool-call-shared (SSOT)
function toolStyle(name: string): { icon: string; color: string } {
  return toolCategory(name)
}

// Durable_event projections carry durable_kind in detail; give each
// a distinct icon/tone so LLM, error, and agent lifecycle events
// are visually separable in the trace timeline.
function durableStyle(kind: unknown): { icon: string; color: string } | null {
  switch (kind) {
    case 'llm_request':      return { icon: '>', color: TRACE_TONE.infoText }
    case 'llm_response':     return { icon: '<', color: TRACE_TONE.brassText }
    case 'error_occurred':   return { icon: '!', color: 'text-[var(--color-status-err)]' }
    case 'tool_called':      return { icon: 't', color: 'text-[var(--color-status-ok)]' }
    case 'tool_completed':   return { icon: 'x', color: 'text-[var(--color-status-ok)]' }
    case 'state_transition': return { icon: '>', color: 'text-[var(--color-accent-fg)]' }
    case 'checkpoint_saved': return { icon: '*', color: 'text-[var(--color-fg-muted)]' }
    case 'turn_started':     return { icon: 'r', color: 'text-[var(--color-status-warn)]' }
    default: return null
  }
}

// ── Formatters ─────────────────────────────────────────

// formatArgs delegated to shared module (SSOT: tool-call-shared.ts)
function formatArgs(args: Record<string, unknown> | string): string {
  return sharedFormatArgs(args)
}

type TraceCodeLocation = CodeLocation

type TraceRouteContextFields = Pick<
  IdeContextRouteContext,
  | 'filePath'
  | 'line'
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

type MutableTraceRouteContext = {
  -readonly [K in keyof TraceRouteContextFields]?: TraceRouteContextFields[K]
}

function stringishField(value: unknown): string | null {
  if (typeof value === 'string') return asNullableString(value)
  if (typeof value === 'number' && Number.isFinite(value)) return String(value)
  return null
}

function recordCodeLocation(value: Record<string, unknown>): TraceCodeLocation | null {
  const direct = extractCodeLocation(value)
  if (direct) return direct

  const input = value.input
  if (input && typeof input === 'object' && !Array.isArray(input)) {
    return recordCodeLocation(input as Record<string, unknown>)
  }
  return null
}

function toolCallCodeRouteLink(event: UnifiedTraceEvent): IdeContextRouteLink | null {
  if (!event.toolArgs) return null
  const parsedArgs = parseJsonLikeData(event.toolArgs)
  if (!parsedArgs || typeof parsedArgs !== 'object' || Array.isArray(parsedArgs)) return null
  const location = recordCodeLocation(parsedArgs as Record<string, unknown>)
  if (!location) return null
  return routeLinksForContext({
    filePath: location.filePath,
    line: location.line,
    surface: 'Tool',
    label: event.toolName ?? 'tool call',
    sourceId: event.id,
    keeperId: event.agentName,
  }).find(link => link.label === 'Code') ?? null
}

export function traceRouteLinks(event: UnifiedTraceEvent): ReadonlyArray<IdeContextRouteLink> {
  const context: MutableTraceRouteContext = {}
  mergeTraceRouteRecord(context, asRecord(event.detail.context))
  mergeTraceRouteRecord(context, asRecord(event.detail.evidence_ref))
  mergeTraceRouteRecord(context, asRecord(event.detail.tool_args))
  mergeTraceRouteRecord(context, asRecord(event.detail.input))
  mergeTraceRouteRecord(context, event.detail, true)

  const parsedArgs = event.toolArgs ? parseJsonLikeData(event.toolArgs) : null
  if (parsedArgs && typeof parsedArgs === 'object' && !Array.isArray(parsedArgs)) {
    mergeTraceRouteRecord(context, parsedArgs as Record<string, unknown>)
  }

  context.sessionId ??= event.sessionId ?? undefined
  context.operationId ??= event.operationId ?? undefined
  context.workerRunId ??= event.workerRunId ?? undefined

  if (!hasTraceRouteContext(context)) return []
  return routeLinksForContext({
    ...context,
    surface: traceRouteSurface(event),
    label: traceRouteLabel(event),
    sourceId: event.id,
    keeperId: event.agentName,
    telemetry: context.logId !== undefined
      || context.sessionId !== undefined
      || context.operationId !== undefined
      || context.workerRunId !== undefined,
    telemetryQuery: context.logId ?? event.id,
  })
}

function TraceContextLinks({
  links,
}: {
  readonly links: ReadonlyArray<IdeContextRouteLink>
}) {
  if (links.length === 0) return null
  return html`
    <div
      class="v2-monitoring-trace-context flex flex-wrap items-center gap-1.5 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-2"
      aria-label="Trace operational context links"
    >
      ${links.map(link => html`
        <button
          key=${link.id}
          type="button"
          data-testid="session-trace-context-link"
          class="v2-monitoring-trace-action inline-flex max-w-44 items-center gap-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-3xs font-mono text-[var(--color-fg-muted)] hover:border-[var(--color-accent-border)] hover:text-[var(--color-accent-fg)]"
          title=${link.evidence}
          aria-label=${`Open ${link.evidence}`}
          onClick=${() => openIdeContextRouteLink(link)}
        >
          <span class="shrink-0 font-semibold text-[var(--color-fg-secondary)]">${link.label}</span>
          <span class="min-w-0 truncate">${traceLinkEvidenceSuffix(link)}</span>
        </button>
      `)}
    </div>
  `
}

function mergeTraceRouteRecord(
  context: MutableTraceRouteContext,
  record: Record<string, unknown> | null,
  overwrite = false,
): void {
  if (!record) return
  const location = recordCodeLocation(record)
  if (location && (overwrite || context.filePath === undefined)) context.filePath = location.filePath
  if (location?.line !== undefined && (overwrite || context.line === undefined)) context.line = location.line

  const taskId = firstStringish(record, ['task_id', 'taskId', 'task'])
  if (taskId && (overwrite || context.taskId === undefined)) context.taskId = taskId
  const boardPostId = firstStringish(record, ['board_post_id', 'boardPostId', 'post_id', 'postId'])
  if (boardPostId && (overwrite || context.boardPostId === undefined)) context.boardPostId = boardPostId
  const commentId = firstStringish(record, ['comment_id', 'commentId'])
  if (commentId && (overwrite || context.commentId === undefined)) context.commentId = commentId
  const prId = firstStringish(record, ['pr_id', 'prId', 'pr', 'pull_request_id', 'pullRequestId'])
  if (prId && (overwrite || context.prId === undefined)) context.prId = prId
  const gitRef = firstStringish(record, ['git_ref', 'gitRef', 'commit', 'commit_sha', 'branch', 'ref'])
  if (gitRef && (overwrite || context.gitRef === undefined)) context.gitRef = gitRef
  const logId = firstStringish(record, ['log_id', 'logId', 'log', 'turn_id', 'turnId'])
  if (logId && (overwrite || context.logId === undefined)) context.logId = logId
  const sessionId = firstStringish(record, ['session_id', 'sessionId'])
  if (sessionId && (overwrite || context.sessionId === undefined)) context.sessionId = sessionId
  const operationId = firstStringish(record, ['operation_id', 'operationId'])
  if (operationId && (overwrite || context.operationId === undefined)) context.operationId = operationId
  const workerRunId = firstStringish(record, ['worker_run_id', 'workerRunId'])
  if (workerRunId && (overwrite || context.workerRunId === undefined)) context.workerRunId = workerRunId
}

function firstStringish(record: Record<string, unknown>, keys: ReadonlyArray<string>): string | null {
  for (const key of keys) {
    const value = stringishField(record[key])
    if (value) return value
  }
  return null
}

function hasTraceRouteContext(context: MutableTraceRouteContext): boolean {
  return context.filePath !== undefined
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

function traceRouteSurface(event: UnifiedTraceEvent): string {
  if (event.kind === 'tool_call') return 'Tool'
  if (event.kind === 'oas_tool') return 'Tool'
  if (event.kind === 'oas_turn') return 'Turn'
  if (event.kind === 'oas_context') return 'Context'
  return KIND_STYLES[event.kind]?.label ?? event.kind
}

function traceRouteLabel(event: UnifiedTraceEvent): string {
  return event.toolName ?? event.summary
}

function traceLinkEvidenceSuffix(link: IdeContextRouteLink): string {
  const evidence = link.evidence.trim()
  const labelPrefix = `${link.label} `
  if (evidence.startsWith(labelPrefix)) return evidence.slice(labelPrefix.length)
  const scoped = evidence.split(' · ').slice(1).join(' · ')
  return scoped || evidence
}

// ── Task event helpers ─────────────────────────────────

function taskIcon(type: string): string {
  switch (type) {
    case 'task_completed':  return 'done'
    case 'task_claimed':    return 'claim'
    case 'task_started':    return 'start'
    case 'task_cancelled':  return 'cancel'
    default: return type.replace('task_', '')
  }
}

function taskColor(type: string): string {
  switch (type) {
    case 'task_completed':  return 'text-[var(--color-status-ok)]'
    case 'task_cancelled':  return 'text-[var(--color-status-err)]'
    default: return 'text-[var(--color-accent-fg)]'
  }
}

// ── Content type detection ─────────────────────────────

type ContentHint = 'plain' | 'code' | 'diff' | 'json'

function detectContentHint(text: string): ContentHint {
  if (!text || text.length < 5) return 'plain'
  const trimmed = text.trimStart()
  // Diff detection: unified diff markers
  if (trimmed.startsWith('@@') || trimmed.startsWith('---') || trimmed.startsWith('+++')
    || /^[-+] /m.test(trimmed.slice(0, 500))) return 'diff'
  // JSON detection
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try { JSON.parse(trimmed); return 'json' } catch { /* not json */ }
  }
  // Code detection: indentation patterns or common code markers
  const lines = trimmed.split('\n').slice(0, 20)
  const indentedLines = lines.filter(l => /^[ \t]{2,}/.test(l)).length
  if (indentedLines > lines.length * 0.4) return 'code'
  if (/^(def |fn |let |const |import |function |class |module |type )/.test(trimmed)) return 'code'
  return 'plain'
}

function isLongContent(text: string): boolean {
  if (!text) return false
  return text.split('\n').length > RESULT_LINES_THRESHOLD || text.length > 1500
}

// ── Diff renderer ─────────────────────────────────────

function DiffBlock({ text }: { text: string }) {
  const allLines = text.split('\n')
  const MAX_LINES = 500
  const lines = allLines.length > MAX_LINES ? allLines.slice(0, MAX_LINES) : allLines
  const truncatedCount = allLines.length - lines.length

  return html`
    <div class="font-mono text-2xs leading-loose overflow-x-auto">
      ${lines.map((line: string) => {
        const cls =
          line.startsWith('+') && !line.startsWith('+++') ? 'text-[var(--color-status-ok)] bg-[var(--ok-6)]'
          : line.startsWith('-') && !line.startsWith('---') ? 'text-[var(--color-status-err)] bg-[var(--bad-6)]'
          : line.startsWith('@@') ? 'text-[var(--color-accent-fg)] font-semibold'
          : 'text-[var(--color-fg-primary)]'
        return html`<div class="${cls} px-2 min-h-[1.6em]">${line || ' '}</div>`
      })}
      ${truncatedCount > 0 ? html`
        <div class="px-2 py-2 text-[var(--color-fg-muted)] italic text-center border-t border-[var(--color-border-default)]">
          ... ${truncatedCount} lines truncated for performance ...
        </div>
      ` : null}
    </div>
  `
}

// ── Collapsible result viewer ─────────────────────────

function ResultViewer({ text, hint, isError: isErr }: { text: string; hint: ContentHint; isError: boolean }) {
  const expanded = useSignal(false)
  const needsCollapse = isLongContent(text)
  const shouldCollapse = needsCollapse && !expanded.value

  const titleLabel = isErr ? 'Error' : 'Result'
  const titleColor = isErr ? 'text-[var(--color-status-err)]' : 'text-[var(--color-fg-muted)]'
  const borderColor = isErr ? 'border-[var(--bad-20)]' : 'border-[var(--color-border-default)]'
  const bgColor = isErr ? 'bg-[var(--bad-6)]' : 'bg-[var(--color-bg-surface)]'

  const MAX_TEXT_LEN = 100000
  const isTruncatedPlain = hint === 'plain' && text.length > MAX_TEXT_LEN
  const displayText = isTruncatedPlain ? text.slice(0, MAX_TEXT_LEN) + '\n\n... (Output truncated for performance) ...' : text

  return html`
    <div>
      <div class="flex items-center justify-between mb-1">
        <span class="text-3xs font-semibold uppercase tracking-wider ${titleColor}">${titleLabel}</span>
        ${hint !== 'plain' ? html`
          <${TraceBadge} tone="neutral">${hint}</${TraceBadge}>
        ` : null}
      </div>
      <div class="rounded-[var(--r-1)] border ${borderColor} ${bgColor} overflow-hidden">
        <div class="${shouldCollapse ? `max-h-[${RESULT_COLLAPSED_MAX_HEIGHT}px] overflow-hidden relative` : ''}"
             style=${shouldCollapse ? `max-height: ${RESULT_COLLAPSED_MAX_HEIGHT}px` : ''}>
          ${hint === 'diff' ? html`<${DiffBlock} text=${text} />`
            : hint === 'json' ? html`<${JsonViewerCard} title=${titleLabel} data=${parseJsonLikeData(text)} />`
            : html`<pre class="m-0 text-2xs font-mono ${isErr ? 'text-[var(--color-status-err)]' : 'text-[var(--color-fg-primary)]'} p-3 overflow-x-auto whitespace-pre-wrap break-all leading-relaxed">${displayText}</pre>`}
          ${shouldCollapse ? html`
            <div class="absolute inset-x-0 bottom-0 h-12 bg-gradient-to-t ${isErr ? 'from-[var(--bad-6)]' : 'from-[var(--color-bg-surface)]'} to-transparent pointer-events-none"></div>
          ` : null}
        </div>
        ${needsCollapse ? html`
          <button
            type="button"
            class="v2-monitoring-trace-action w-full py-1.5 text-3xs font-medium text-[var(--color-accent-fg)] hover:text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-elevated)] transition-colors cursor-pointer border-t border-[var(--color-border-default)] bg-transparent"
            onClick=${() => { expanded.value = !expanded.value }}
          >
            ${expanded.value ? '접기' : `전체 보기 (${text.split('\n').length}줄)`}
          </button>
        ` : null}
      </div>
    </div>
  `
}

// ── Components ─────────────────────────────────────────

function ToolCallDetail({ event }: { event: UnifiedTraceEvent }) {
  const gateRejected = event.gate?.status === 'reject'
  const toolIoRedacted = event.detail.tool_io_redacted === true
  const resultText = event.error ?? event.toolResult ?? null
  const hint = resultText ? detectContentHint(resultText) : 'plain'
  const codeRouteLink = toolCallCodeRouteLink(event)
  const contextLinks = traceRouteLinks(event).filter(link => link.id !== codeRouteLink?.id)

  return html`
    <div class="mt-2 space-y-2">
      ${codeRouteLink ? html`
        <div class="flex items-center justify-between gap-2 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2.5 py-2">
          <span class="min-w-0 truncate text-3xs font-mono text-[var(--color-fg-muted)]" title=${codeRouteLink.evidence}>
            ${codeRouteLink.evidence}
          </span>
          <button
            type="button"
            data-testid="session-trace-code-link"
            class="v2-monitoring-trace-action shrink-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-3xs font-semibold text-[var(--color-accent-fg)] hover:border-[var(--color-accent-border)] hover:bg-[var(--color-bg-hover)]"
            title=${codeRouteLink.evidence}
            aria-label=${`Open ${codeRouteLink.evidence}`}
            onClick=${() => openIdeContextRouteLink(codeRouteLink)}
          >
            Code
          </button>
        </div>
      ` : null}
      <${TraceContextLinks} links=${contextLinks} />
      ${event.toolArgs ? html`
        <div>
          <${SectionHeader} size="xs" class="mb-1">인자</${SectionHeader}>
          <${JsonViewerCard} title="인자" data=${parseJsonLikeData(event.toolArgs)} />
        </div>
      ` : null}
      ${resultText ? html`
        <${ResultViewer} text=${resultText} hint=${hint} isError=${Boolean(event.error)} />
      ` : null}
      ${gateRejected ? html`
        <div class="text-3xs px-2 py-1 rounded-[var(--r-1)] bg-[var(--bad-10)] text-[var(--color-status-err)] inline-block">
          거부: ${event.gate?.reason ?? ''}
        </div>
      ` : null}
      ${toolIoRedacted ? html`
        <div class="inline-block rounded-[var(--r-1)] border border-[var(--warn-25)] bg-[var(--warn-10)] px-2 py-1 text-3xs text-[var(--color-status-warn)]">
          Tool I/O preview redacted
        </div>
      ` : null}
      ${!event.toolArgs && !resultText && !gateRejected && !toolIoRedacted ? html`
        <div class="text-3xs text-[var(--color-fg-disabled)] italic px-2 py-1">
          세부 정보가 기록되지 않았습니다.
        </div>
      ` : null}
      ${'' /* Metadata row */}
      ${event.cost_usd != null && event.cost_usd > 0 ? html`
        <div class="flex gap-3 text-3xs text-[var(--color-fg-disabled)]">
          <span>비용: <span class="font-mono text-[var(--color-accent-fg)]">${formatCost(event.cost_usd)}</span></span>
          ${event.duration_ms != null ? html`<span>소요: <span class="font-mono ${durationColor(event.duration_ms)}">${formatMsCompact(event.duration_ms)}</span></span>` : null}
        </div>
      ` : null}
    </div>
  `
}

function BroadcastDetail({ event }: { event: UnifiedTraceEvent }) {
  const content = typeof event.detail.content === 'string' ? event.detail.content : ''
  if (!content) return null
  return html`
    <div class="mt-2 text-sm leading-relaxed px-3 py-2 bg-[var(--color-bg-surface)] rounded-[var(--r-1)] border border-[var(--color-border-default)]">
      <${Markdown} text=${content} />
    </div>
  `
}

function TaskDetail({ event }: { event: UnifiedTraceEvent }) {
  const d = event.detail
  const taskId = typeof d.task_id === 'string' ? d.task_id : null
  const title = typeof d.title === 'string' ? d.title : null
  const notes = typeof d.completion_notes === 'string' ? d.completion_notes : null
  return html`
    <div class="mt-2 text-xs text-[var(--color-fg-primary)] space-y-1 px-3 py-2 bg-[var(--color-bg-surface)] rounded-[var(--r-1)]">
      ${taskId ? html`<div><span class="text-[var(--color-fg-disabled)]">ID:</span> <span class="font-mono">${taskId}</span></div>` : null}
      ${title ? html`<div><span class="text-[var(--color-fg-disabled)]">제목:</span> ${title}</div>` : null}
      ${notes ? html`<div><span class="text-[var(--color-fg-disabled)]">노트:</span> ${notes}</div>` : null}
    </div>
  `
}

function ThinkingDetail({ event }: { event: UnifiedTraceEvent }) {
  if (event.thinkingRedacted) {
    return html`
      <div class="mt-2 px-3 py-2 rounded-[var(--r-1)] ${TRACE_TONE.brassPanel} text-xs ${TRACE_TONE.brassText} italic">
        이 사고 과정은 비공개 처리되었습니다.
      </div>
    `
  }
  const content = event.thinkingContent ?? ''
  if (!content) return null
  return html`
    <div class="mt-2 px-3 py-2 rounded-[var(--r-1)] ${TRACE_TONE.brassPanel}">
      <div class="text-sm leading-relaxed text-[var(--color-fg-primary)]">
        <${Markdown} text=${content} />
      </div>
    </div>
  `
}

function OasDetail({ event }: { event: UnifiedTraceEvent }) {
  const d = event.detail

  // ── Tool call ──
  if (event.kind === 'oas_tool') {
    const phase = typeof d.phase === 'string' ? d.phase : ''
    const toolName = typeof d.tool_name === 'string' ? d.tool_name : 'unknown'
    const phaseLabel = phase === 'called' ? '호출' : phase === 'completed' ? '완료' : phase
    const phaseColor = phase === 'called' ? 'text-[var(--color-accent-fg)]' : 'text-[var(--color-status-ok)]'
    return html`
      <div class="mt-2 px-3 py-2 rounded-[var(--r-1)] bg-[var(--color-bg-surface)] border border-[var(--color-border-default)] space-y-1">
        <div class="flex items-center gap-2 text-xs">
          <span class="text-[var(--color-fg-disabled)]">단계:</span>
          <span class="font-mono font-semibold ${phaseColor}">${phaseLabel}</span>
        </div>
        <div class="flex items-center gap-2 text-xs">
          <span class="text-[var(--color-fg-disabled)]">도구:</span>
          <span class="font-mono text-[var(--color-fg-primary)]">${toolName}</span>
        </div>
      </div>
    `
  }

  // ── Turn ──
  if (event.kind === 'oas_turn') {
    const phase = typeof d.phase === 'string' ? d.phase : ''
    const turn = d.turn
    const phaseLabel = phase === 'started' ? '시작' : phase === 'completed' ? '완료' : phase
    return html`
      <div class="mt-2 px-3 py-2 rounded-[var(--r-1)] bg-[var(--color-bg-surface)] border border-[var(--color-border-default)]">
        <div class="flex items-center gap-2 text-xs">
          <span class="text-[var(--color-fg-disabled)]">턴 ${turn != null ? String(turn) : '-'}:</span>
          <span class="font-mono font-semibold text-[var(--color-fg-primary)]">${phaseLabel}</span>
        </div>
      </div>
    `
  }

  // ── OAS context compaction ──
  if (event.kind === 'oas_context') {
    const before = typeof d.before_tokens === 'number' ? d.before_tokens : null
    const after = typeof d.after_tokens === 'number' ? d.after_tokens : null
    const saved = before != null && after != null ? before - after : null
    const ratio = before != null && after != null && before > 0 ? ((saved ?? 0) / before * 100) : null
    const compactPhase = typeof d.phase === 'string' ? d.phase : ''
    return html`
      <div class="mt-2 px-3 py-2 rounded-[var(--r-1)] ${TRACE_TONE.infoPanel} space-y-2">
        <div class="flex items-center gap-3 text-xs">
          ${before != null ? html`<span><span class="text-[var(--color-fg-disabled)]">Before:</span> <span class="font-mono">${before.toLocaleString()}</span></span>` : null}
          <span class="text-[var(--color-fg-disabled)]">→</span>
          ${after != null ? html`<span><span class="text-[var(--color-fg-disabled)]">After:</span> <span class="font-mono">${after.toLocaleString()}</span></span>` : null}
        </div>
        ${saved != null && saved > 0 ? html`
          <div class="flex items-center gap-2">
            <${ProgressBar}
              pct=${ratio ?? 0}
              size="md"
              trackTone="muted"
              trackClass="flex-1"
              class=${TRACE_TONE.infoFill}
            />
            <span class="text-3xs font-mono ${TRACE_TONE.infoText}">-${saved.toLocaleString()}tok (${(ratio ?? 0).toFixed(0)}%)</span>
          </div>
        ` : null}
        ${compactPhase ? html`<div class="text-3xs text-[var(--color-fg-disabled)]">단계: ${compactPhase}</div>` : null}
      </div>
    `
  }

  // ── Lifecycle with durable_kind ──
  const durableKind = typeof d.durable_kind === 'string' ? d.durable_kind : ''

  if (durableKind === 'llm_request') {
    const inputTokens = typeof d.input_tokens === 'number' ? d.input_tokens : 0
    const cacheCreationTokens = detailNumber(
      d,
      'cache_creation_tokens',
      'cache_creation_input_tokens',
    )
    const cacheReadTokens = detailNumber(
      d,
      'cache_read_tokens',
      'cache_read_input_tokens',
    )
    const cacheMissInputTokens =
      detailNumber(d, 'cache_miss_input_tokens')
      ?? (
        cacheCreationTokens != null || cacheReadTokens != null
          ? Math.max(0, inputTokens - (cacheCreationTokens ?? 0) - (cacheReadTokens ?? 0))
          : null
      )
    const cacheSeenTokens = (cacheReadTokens ?? 0) + (cacheMissInputTokens ?? 0)
    const cacheHitPct =
      cacheSeenTokens > 0
        ? Math.round(((cacheReadTokens ?? 0) / cacheSeenTokens) * 100)
        : null
    const turn = d.turn
    return html`
      <div class="mt-2 px-3 py-2 rounded-[var(--r-1)] ${TRACE_TONE.infoPanel} space-y-1">
        <div class="flex flex-wrap items-center gap-3 text-xs">
          <span><span class="text-[var(--color-fg-disabled)]">런타임:</span> <span class="font-mono">runtime</span></span>
          <span><span class="text-[var(--color-fg-disabled)]">입력:</span> <span class="font-mono">${inputTokens.toLocaleString()}tok</span></span>
          ${cacheReadTokens != null ? html`
            <span><span class="text-[var(--color-fg-disabled)]">캐시 read:</span> <span class="font-mono">${cacheReadTokens.toLocaleString()}tok</span></span>
          ` : null}
          ${cacheCreationTokens != null ? html`
            <span><span class="text-[var(--color-fg-disabled)]">캐시 write:</span> <span class="font-mono">${cacheCreationTokens.toLocaleString()}tok</span></span>
          ` : null}
          ${cacheMissInputTokens != null ? html`
            <span><span class="text-[var(--color-fg-disabled)]">캐시 miss:</span> <span class="font-mono">${cacheMissInputTokens.toLocaleString()}tok</span></span>
          ` : null}
          ${cacheHitPct != null ? html`<span><span class="text-[var(--color-fg-disabled)]">hit:</span> <span class="font-mono">${cacheHitPct}%</span></span>` : null}
          ${turn != null ? html`<span><span class="text-[var(--color-fg-disabled)]">턴:</span> <span class="font-mono">${String(turn)}</span></span>` : null}
        </div>
      </div>
    `
  }

  if (durableKind === 'llm_response') {
    const outputTokens = typeof d.output_tokens === 'number' ? d.output_tokens : null
    const stopReason = typeof d.stop_reason === 'string' ? d.stop_reason : ''
    const durationMs = typeof d.duration_ms === 'number' ? d.duration_ms : null
    const tokPerSec = deriveTokPerSec(outputTokens, durationMs)
    const turn = d.turn
    const responseText = typeof d.response_text === 'string' ? d.response_text : ''
    const stopColor = stopReason === 'end_turn' || stopReason === 'stop' ? 'text-[var(--color-status-ok)]' : 'text-[var(--color-status-warn)]'
    return html`
      <div class="mt-2 px-3 py-2 rounded-[var(--r-1)] ${TRACE_TONE.infoPanel} space-y-1">
        <div class="flex items-center gap-3 text-xs flex-wrap">
          <span><span class="text-[var(--color-fg-disabled)]">출력:</span> <span class="font-mono">${(outputTokens ?? 0).toLocaleString()}tok</span></span>
          <span><span class="text-[var(--color-fg-disabled)]">종료:</span> <span class="font-mono ${stopColor}">${stopReason}</span></span>
          ${durationMs != null ? html`<span><span class="text-[var(--color-fg-disabled)]">소요:</span> <span class="font-mono ${durationColor(durationMs)}">${formatMsCompact(durationMs)}</span></span>` : null}
          ${tokPerSec != null ? html`<span><span class="text-[var(--color-fg-disabled)]">속도:</span> <span class="font-mono text-[var(--color-status-ok)]">${formatTokPerSec(tokPerSec)}</span></span>` : null}
          ${turn != null ? html`<span><span class="text-[var(--color-fg-disabled)]">턴:</span> <span class="font-mono">${String(turn)}</span></span>` : null}
        </div>
        ${responseText ? html`
          <details class="mt-1">
            <summary class="text-3xs text-[var(--color-fg-disabled)] cursor-pointer hover:text-[var(--color-fg-primary)]">응답 텍스트</summary>
            <pre class="mt-1 p-2 rounded-[var(--r-1)] bg-[var(--color-bg-surface)] text-2xs font-mono text-[var(--color-fg-primary)] whitespace-pre-wrap break-all max-h-75 overflow-auto">${responseText}</pre>
          </details>
        ` : null}
      </div>
    `
  }

  if (durableKind === 'error_occurred') {
    const domain = typeof d.error_domain === 'string' ? d.error_domain : 'unknown'
    const errorDetail = typeof d.detail === 'string' ? d.detail : ''
    return html`
      <div class="mt-2 px-3 py-2 rounded-[var(--r-1)] bg-[var(--bad-6)] border border-[var(--bad-soft)] space-y-1">
        <div class="text-xs"><span class="text-[var(--color-fg-disabled)]">도메인:</span> <span class="font-mono text-[var(--color-status-err)]">${domain}</span></div>
        ${errorDetail ? html`<div class="text-2xs font-mono text-[var(--color-fg-primary)] break-all">${errorDetail}</div>` : null}
      </div>
    `
  }

  // ── Fallback: generic detail rows ──
  const detailRows = Object.entries(d)
    .filter(([, value]) => value != null && value !== '')
    .map(([label, value]) => ({ label, value: typeof value === 'string' ? value : JSON.stringify(value) }))
  if (detailRows.length === 0) return null
  return html`
    <div class="mt-2 grid gap-1.5 px-3 py-2 rounded-[var(--r-1)] bg-[var(--color-bg-surface)] border border-[var(--color-border-default)]">
      ${detailRows.map(row => html`
        <div class="flex items-start gap-2 text-xs leading-relaxed">
          <span class="min-w-[92px] text-[var(--color-fg-disabled)] font-mono">${row.label}</span>
          <span class="text-[var(--color-fg-primary)] font-mono break-all">${row.value}</span>
        </div>
      `)}
    </div>
  `
}

export function SessionTraceEntry({ event, searchQuery }: { event: UnifiedTraceEvent; searchQuery?: string }) {
  const kindStyle = KIND_STYLES[event.kind]
  // For tool_call, use tool-specific icon/color
  // For lifecycle + durable_kind, use durable-specific icon/color
  const durable =
    event.kind === 'lifecycle'
      ? durableStyle(event.detail.durable_kind)
      : null
  const style = event.kind === 'tool_call' && event.toolName
    ? toolStyle(event.toolName)
    : durable ?? kindStyle

  const gateRejected = event.kind === 'tool_call' && event.gate?.status === 'reject'
  const contextLinks = traceRouteLinks(event)

  // Summary text
  let summaryText = event.summary
  if (event.kind === 'tool_call' && event.toolArgs) {
    summaryText = formatArgs(event.toolArgs)
  } else if (event.kind === 'broadcast') {
    summaryText = truncate(event.summary, BROADCAST_PREVIEW_MAX)
  }

  // Determine if this entry has expandable detail
  const hasDetail = event.kind === 'tool_call'
    || (event.kind === 'broadcast' && typeof event.detail.content === 'string' && event.detail.content.length > BROADCAST_PREVIEW_MAX)
    || event.kind === 'task'
    || event.kind === 'thinking'
    || event.kind === 'oas_tool'
    || event.kind === 'oas_turn'
    || event.kind === 'oas_context'
    || (event.kind === 'lifecycle' && event.detail.durable_kind)
    || contextLinks.length > 0

  const row = html`
    <div class="v2-monitoring-trace-row flex items-start gap-3 py-2 px-3 rounded-[var(--r-1)] ${gateRejected ? 'opacity-50' : ''}">
      ${'' /* Icon */}
      <div class="flex-shrink-0 mt-0.5 size-7 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] border border-[var(--color-border-default)] flex items-center justify-center text-2xs font-mono font-bold ${style.color}">
        ${style.icon}
      </div>

      ${'' /* Content */}
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 flex-wrap">
          ${event.kind === 'tool_call' && event.toolName
            ? html`<span class="text-xs font-mono font-medium ${style.color}">${event.toolName}</span>`
            : html`<span class="text-3xs font-medium uppercase tracking-wider ${kindStyle.color}">${kindStyle.label}</span>`}
          <${TraceBadge} tone="neutral" wide>
            ${event.sourceLane === 'oas' ? 'OAS' : 'MASC'}
          </${TraceBadge}>
          ${event.turn != null ? html`
            <span class="text-3xs text-[var(--color-fg-disabled)]">
              T${event.turn}${event.round != null ? `R${event.round}` : ''}
            </span>
          ` : null}
          ${event.sessionId ? html`<span class="text-3xs text-[var(--color-fg-disabled)] font-mono">S ${event.sessionId}</span>` : null}
          ${event.operationId ? html`<span class="text-3xs text-[var(--color-fg-disabled)] font-mono">OP ${event.operationId}</span>` : null}
          ${event.workerRunId ? html`<span class="text-3xs text-[var(--color-fg-disabled)] font-mono">WR ${event.workerRunId}</span>` : null}
          ${event.kind === 'task' ? html`
            <span class="text-3xs font-bold uppercase tracking-wider ${taskColor(String(event.detail.type))} bg-[var(--color-bg-elevated)] px-1.5 py-0.5 rounded-[var(--r-1)]">
              ${taskIcon(String(event.detail.type))}
            </span>
          ` : null}
          ${event.error
            ? html`<${TraceBadge} tone="bad">오류</${TraceBadge}>`
            : gateRejected
              ? html`<${TraceBadge} tone="bad">거부</${TraceBadge}>`
              : event.kind === 'tool_call'
                ? html`<${TraceBadge} tone="ok">완료</${TraceBadge}>`
                : null}
        </div>
        <div class="mt-0.5 text-2xs text-[var(--color-fg-muted)] font-mono truncate max-w-full" title=${event.summary}>
          <${HighlightedText} text=${summaryText} query=${searchQuery ?? ''} />
        </div>
      </div>

      ${'' /* Right side: duration + time */}
      <div class="flex-shrink-0 flex flex-col items-end gap-0.5">
        ${event.duration_ms != null ? html`
          <span class="text-2xs font-mono ${durationColor(event.duration_ms)}">${formatMsCompact(event.duration_ms)}</span>
        ` : null}
        <${TimeAgo} timestamp=${event.ts_iso} class="text-3xs text-[var(--color-fg-disabled)]" />
      </div>
    </div>
  `

  if (!hasDetail) return row

  return html`
    <details class="v2-monitoring-trace-detail rounded-[var(--r-1)] hover:bg-[var(--color-bg-surface)] transition-colors group">
      <summary class="list-none cursor-pointer relative pr-8">
        ${row}
        <div class="absolute right-3 top-1/2 -translate-y-1/2 opacity-40 group-hover:opacity-100 transition-opacity">
          <svg aria-hidden="true" class="w-4 h-4 text-[var(--color-fg-muted)] group-open:rotate-90 transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" />
          </svg>
        </div>
      </summary>
      <div class="px-3 pb-3 pl-13">
        ${event.kind === 'tool_call' ? html`<${ToolCallDetail} event=${event} />` : null}
        ${event.kind !== 'tool_call' ? html`<${TraceContextLinks} links=${contextLinks} />` : null}
        ${event.kind === 'broadcast' ? html`<${BroadcastDetail} event=${event} />` : null}
        ${event.kind === 'task' ? html`<${TaskDetail} event=${event} />` : null}
        ${event.kind === 'thinking' ? html`<${ThinkingDetail} event=${event} />` : null}
        ${event.kind === 'oas_tool' || event.kind === 'oas_turn' || event.kind === 'oas_context'
          || (event.kind === 'lifecycle' && event.detail.durable_kind)
          ? html`<${OasDetail} event=${event} />`
          : null}
      </div>
    </details>
  `
}
