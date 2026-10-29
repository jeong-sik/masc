import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  streamExecuteOutput,
  type ExecuteOutputLine,
  type ExecuteOutputStreamEvent,
} from '../../api/execute-output'
import { tasks } from '../../store'
import type { Task } from '../../types'
import { StatusChip, type StatusChipTone } from '../common/status-chip'
import { Terminal, type TerminalLine } from '../common/terminal'
import {
  openIdeContextRouteLink,
  routeLinksForContext,
  type IdeContextRouteLink,
} from './ide-context-lens'
import { IDE_CONTEXT_BADGE_STYLE } from './context-badge-style'
import { routeLinkLabels } from './ide-context-route-helpers'
import { errorToString } from '../../lib/format-string'

const MAX_TERMINAL_LINES = 5000

interface OutputLine {
  text: string
  stream: 'stdout' | 'stderr' | 'meta'
}

interface ExecuteOutputDrawerProps {
  keeperName: string
  /** Render the persistent IDE drawer without opening a live stream until the
      operator explicitly requests terminal execution for the current route. */
  readonly streamEnabled?: boolean
  /** Match the keeper-v2 IDE drawer geometry while preserving live output. */
  readonly compact?: boolean
  /** Stop live output. Offered only while a stream is enabled. */
  readonly onStop?: () => void
}

/** [ended]: the stream stopped without the task saying it closed, so the
    output may be incomplete. */
type ExecuteOutputStatus = 'idle' | 'streaming' | 'closed' | 'unknown' | 'ended' | 'error'

export interface ExecuteOutputSummary {
  readonly total: number
  readonly stdout: number
  readonly stderr: number
  readonly meta: number
  readonly droppedBytes: number
  readonly lastStream: OutputLine['stream'] | null
}

export interface ExecuteOutputRouteLinkInput {
  readonly keeperName: string
  readonly taskId: string | null
  readonly taskList: ReadonlyArray<Task>
}

function splitChunkLines(chunk: string): string[] {
  if (!chunk) return []
  const normalized = chunk.replace(/\r\n/g, '\n')
  const lines = normalized.split('\n')
  if (normalized.endsWith('\n')) lines.pop()
  return lines
}

function outputLineFromExecuteLine(line: ExecuteOutputLine): OutputLine {
  if (line.stream === 'stderr') return { text: line.text, stream: 'stderr' }
  if (line.stream === 'stdout') return { text: line.text, stream: 'stdout' }
  if (line.stream === 'cmd') return { text: `command summary: ${line.text}`, stream: 'meta' }
  if (line.stream === 'status') {
    const status = statusFromLine(line)
    const description = executionStatusLine({
      type: 'task_closed', keeper: '', stream_id: line.stream_id, task_id: line.task_id, status,
    })
    return { text: description ?? `Execute status: ${line.text}`, stream: 'meta' }
  }
  return { text: line.text, stream: 'meta' }
}

function statusObject(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null
}

function executionStatus(event: ExecuteOutputStreamEvent): Record<string, unknown> | null {
  return statusObject(event.status)
}

function statusFromLine(line: ExecuteOutputLine): Record<string, unknown> | null {
  if (line.stream !== 'status') return null
  try {
    return statusObject(JSON.parse(line.text) as unknown)
  } catch {
    return null
  }
}

function executionStatusLine(event: ExecuteOutputStreamEvent): string | null {
  if (event.type !== 'task_closed' && !(event.type === 'snapshot' && event.closed)) return null
  const status = executionStatus(event)
  if (!status) return null
  const phase = status.phase === 'gate_observation' ? 'Gate observation' : 'Execute'
  let description: string
  if (status.outcome === 'unknown') description = `${phase} result unknown`
  else if (status.outcome === 'request_not_sent') description = `${phase} request not sent`
  else if (status.outcome === 'observation_ended') description = 'Gate observation ended'
  else if (status.kind === 'exit' && typeof status.code === 'number') description = `Execute exited with code ${status.code}`
  else if (status.kind === 'signal' && typeof status.signal === 'number') description = `Execute ended by signal ${status.signal}`
  else if (status.kind === 'stopped' && typeof status.signal === 'number') description = `Execute stopped by signal ${status.signal}`
  else if (typeof status.rejected === 'string') description = `Execute rejected: ${status.rejected}`
  else return null
  const identity = [
    typeof event.stream_id === 'number' ? `stream ${event.stream_id}` : null,
    typeof event.task_id === 'string' ? `task ${event.task_id}` : null,
  ].filter(Boolean).join(', ')
  return identity ? `${description} (${identity})` : description
}

// The server sends `gap` only when this viewer fell further behind than the
// output log it retains; the missed entries cannot be fetched again, so the
// terminal says how many are missing at the place they would have been.
function gapLineText(event: ExecuteOutputStreamEvent): string {
  const count = event.missing_count
  const entries = count === undefined ? 'output entries' : `${count} output ${count === 1 ? 'entry' : 'entries'}`
  const range =
    event.missing_from_seq !== undefined && event.missing_to_seq !== undefined
      ? ` (seq ${event.missing_from_seq}-${event.missing_to_seq})`
      : ''
  return `missed ${entries} the server no longer keeps${range}`
}

export function linesFromExecuteOutputEvent(event: ExecuteOutputStreamEvent): OutputLine[] {
  if (event.type === 'error') {
    return [{ text: event.message ?? 'Execute output stream error', stream: 'stderr' }]
  }
  if (event.type === 'no_task') {
    return [{ text: 'no active Execute output task', stream: 'meta' }]
  }
  if (event.type === 'gap') {
    return [{ text: gapLineText(event), stream: 'meta' }]
  }

  const lines: OutputLine[] = []
  let usedStructuredLines = false
  if (event.line) {
    usedStructuredLines = true
    lines.push(outputLineFromExecuteLine(event.line))
  }
  if (Array.isArray(event.lines)) {
    usedStructuredLines = true
    for (const line of event.lines) lines.push(outputLineFromExecuteLine(line))
  }
  if (event.type === 'snapshot' && Array.isArray(event.active_streams)) {
    const retainedCommands = new Set((Array.isArray(event.lines) ? event.lines : [])
      .filter(line => line.stream === 'cmd' && typeof line.stream_id === 'number')
      .map(line => line.stream_id))
    for (const stream of event.active_streams) {
      if (stream && typeof stream.command === 'string' && !retainedCommands.has(stream.stream_id)) {
        lines.push({ text: `command summary: ${stream.command}`, stream: 'meta' })
      }
    }
  }
  if ((event.first_retained_seq ?? 1) > 1) {
    lines.unshift({ text: `earlier output events are no longer retained (before seq ${event.first_retained_seq})`, stream: 'meta' })
  }
  if ((event.lines_omitted ?? 0) > 0) {
    lines.unshift({ text: `${event.lines_omitted} earlier output lines omitted from this view`, stream: 'meta' })
  }
  if (!usedStructuredLines) {
    for (const line of splitChunkLines(event.stdout_since ?? '')) {
      lines.push({ text: line, stream: 'stdout' })
    }
    for (const line of splitChunkLines(event.stderr_since ?? '')) {
      lines.push({ text: line, stream: 'stderr' })
    }
  }
  const dropped =
    (event.bytes_dropped_stdout ?? 0) + (event.bytes_dropped_stderr ?? 0)
  if (dropped > 0) {
    lines.unshift({ text: `dropped ${dropped} older bytes`, stream: 'meta' })
  }
  const retainedStatus = event.type === 'snapshot' && Array.isArray(event.lines)
    ? [...event.lines].reverse().find(line => line.stream === 'status')
    : undefined
  const duplicatesRetainedStatus = retainedStatus !== undefined
    && retainedStatus.task_id === event.task_id
    && JSON.stringify(statusFromLine(retainedStatus)) === JSON.stringify(executionStatus(event))
  const statusLine = duplicatesRetainedStatus ? null : executionStatusLine(event)
  if (statusLine) {
    lines.push({ text: statusLine, stream: 'meta' })
  } else if (event.closed && lines.length === 0) {
    lines.push({ text: 'Execute output task closed', stream: 'meta' })
  }
  return lines
}

function appendLines(current: OutputLine[], next: OutputLine[]): OutputLine[] {
  if (next.length === 0) return current
  return [...current, ...next].slice(-MAX_TERMINAL_LINES)
}

export function summarizeOutputLines(lines: ReadonlyArray<OutputLine>): ExecuteOutputSummary {
  let stdout = 0
  let stderr = 0
  let meta = 0
  let droppedBytes = 0
  for (const line of lines) {
    if (line.stream === 'stdout') stdout += 1
    else if (line.stream === 'stderr') stderr += 1
    else meta += 1

    const dropped = /^dropped\s+(\d+)\s+older bytes$/.exec(line.text)
    if (dropped) droppedBytes += Number(dropped[1])
  }
  return {
    total: lines.length,
    stdout,
    stderr,
    meta,
    droppedBytes,
    lastStream: lines[lines.length - 1]?.stream ?? null,
  }
}

function toTerminalLine(line: OutputLine): TerminalLine {
  switch (line.stream) {
    case 'stderr':
      return { text: line.text, tone: 'err' }
    case 'meta':
      return { text: line.text, tone: 'meta' }
    default:
      return { text: line.text, tone: 'out' }
  }
}

function statusTone(status: ExecuteOutputStatus): StatusChipTone {
  if (status === 'streaming') return 'info'
  if (status === 'closed') return 'neutral'
  if (status === 'error') return 'bad'
  if (status === 'ended' || status === 'unknown') return 'warn'
  return 'neutral'
}

function lineCountLabel(count: number): string {
  return `${count} ${count === 1 ? 'line' : 'lines'}`
}

function executeOutputSummaryLabel(summary: ExecuteOutputSummary, status: ExecuteOutputStatus): string {
  const last = summary.lastStream ?? 'none'
  const dropped = summary.droppedBytes > 0 ? `, ${summary.droppedBytes} dropped bytes` : ''
  return `Execute output ${status}: ${lineCountLabel(summary.total)}, ${summary.stdout} stdout, ${summary.stderr} stderr, ${summary.meta} meta, last ${last}${dropped}`
}

export function executeOutputRouteLinks({
  keeperName,
  taskId,
  taskList,
}: ExecuteOutputRouteLinkInput): ReadonlyArray<IdeContextRouteLink> {
  const keeperId = nonEmpty(keeperName)
  if (!keeperId) return []
  const task = taskId
    ? taskList.find(candidate => candidate.id === taskId) ?? null
    : null
  const sourceParts = ['execute-output', keeperId, taskId].filter((part): part is string =>
    typeof part === 'string' && part.trim() !== '')
  return routeLinksForContext({
    surface: 'Terminal',
    label: taskId ? `Execute output ${taskId}` : 'Execute output',
    sourceId: sourceParts.join(':'),
    goalId: task?.goal_id ?? undefined,
    taskId: taskId ?? undefined,
    keeperId,
    telemetry: true,
    telemetryQuery: taskId ?? keeperId,
  })
}

function ExecuteOutputContextLinks({
  links,
}: {
  readonly links: ReadonlyArray<IdeContextRouteLink>
}) {
  if (links.length === 0) return null
  const routeLabels = routeLinkLabels(links)
  return html`
    <div class="execute-output-context-links" aria-label="Execute output operational links">
      <span
        class="execute-output-context-badge"
        data-context-route-count=${links.length}
        title=${`Linked context: ${routeLabels}`}
        aria-label=${`Execute output has ${links.length} linked context routes: ${routeLabels}`}
        style=${IDE_CONTEXT_BADGE_STYLE}
      >
        CTX ${links.length}
      </span>
      ${links.map(link => html`
        <button
          key=${link.id}
          type="button"
          class="v2-ide-action"
          title=${link.evidence}
          aria-label=${`Open ${link.evidence}`}
          onClick=${() => openIdeContextRouteLink(link)}
        >${link.label}</button>
      `)}
    </div>
  `
}

function ExecuteOutputSummaryStrip({
  summary,
  status,
}: {
  readonly summary: ExecuteOutputSummary
  readonly status: ExecuteOutputStatus
}) {
  return html`
    <div
      aria-label=${executeOutputSummaryLabel(summary, status)}
      data-testid="execute-output-summary"
      class="flex min-w-0 flex-wrap items-center gap-1.5 text-[var(--color-fg-muted)]"
    >
      <${StatusChip} tone="neutral" uppercase=${false}>${lineCountLabel(summary.total)}</${StatusChip}>
      <${StatusChip} tone="ok" uppercase=${false}>stdout ${summary.stdout}</${StatusChip}>
      <${StatusChip} tone=${summary.stderr > 0 ? 'bad' : 'neutral'} uppercase=${false}>stderr ${summary.stderr}</${StatusChip}>
      <${StatusChip} tone="neutral" uppercase=${false}>meta ${summary.meta}</${StatusChip}>
      ${summary.droppedBytes > 0
        ? html`<${StatusChip} tone="warn" uppercase=${false}>dropped ${summary.droppedBytes}B</${StatusChip}>`
        : null}
    </div>
  `
}

export function ExecuteOutputDrawer({
  keeperName,
  streamEnabled = true,
  compact = false,
  onStop,
}: ExecuteOutputDrawerProps) {
  const keeper = keeperName.trim()
  const [lines, setLines] = useState<OutputLine[]>([])
  const [status, setStatus] = useState<ExecuteOutputStatus>('idle')
  const [hasUnconfirmedResult, setHasUnconfirmedResult] = useState(false)
  const [hasIncompleteHistory, setHasIncompleteHistory] = useState(false)
  const [taskId, setTaskId] = useState<string | null>(null)
  const [expanded, setExpanded] = useState(true)
  const viewportRef = useRef<HTMLDivElement | null>(null)
  const terminalLines = useMemo(() => lines.map(toTerminalLine), [lines])
  const summary = useMemo(() => summarizeOutputLines(lines), [lines])
  const routeLinks = executeOutputRouteLinks({
    keeperName: keeper,
    taskId,
    taskList: tasks.value,
  })

  const prefersReducedMotion = useMemo(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') {
      return false
    }
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches
  }, [])

  useEffect(() => {
    if (!streamEnabled) {
      setLines([{ text: 'waiting for an active Execute output task', stream: 'meta' }])
      setStatus('idle')
      setTaskId(null)
      setHasUnconfirmedResult(false)
      setHasIncompleteHistory(false)
      return
    }
    if (!keeper) {
      setLines([{ text: 'no keeper selected', stream: 'meta' }])
      setStatus('idle')
      setTaskId(null)
      setHasUnconfirmedResult(false)
      setHasIncompleteHistory(false)
      return
    }

    const controller = new AbortController()
    setLines([])
    setStatus('streaming')
    setTaskId(null)
    setHasUnconfirmedResult(false)
    setHasIncompleteHistory(false)
    // Whether the latest observation says all executions are closed.
    let settled = false
    // A later execution closing cannot resolve an earlier unknown outcome or
    // reconstruct lifecycle events lost in a gap.
    let unknownResult = false
    let incompleteHistory = false
    // A gap may contain opens or closes; only a snapshot can restore a full
    // inventory after one. IDs are scoped to this server's observation stream.
    let activeStreams: Map<number, string | null> | null = null
    const taskOf = (value: unknown) => typeof value === 'string' ? value : null
    const soleActiveTask = () => activeStreams?.size === 1
      ? [...activeStreams.values()][0] ?? null
      : null

    void streamExecuteOutput(keeper, {
      signal: controller.signal,
      onEvent: event => {
        setLines(current => appendLines(current, linesFromExecuteOutputEvent(event)))
        if (event.type === 'gap') {
          activeStreams = null
          settled = false
          incompleteHistory = true
          setHasIncompleteHistory(true)
          setTaskId(null)
          setStatus('unknown')
          return
        }
        const snapshotStatuses = event.type === 'snapshot' && Array.isArray(event.lines)
          ? event.lines.filter(line => line.stream === 'status').map(statusFromLine)
          : []
        if (((event.type === 'snapshot' || event.type === 'task_closed')
              && executionStatus(event)?.outcome === 'unknown')
            || snapshotStatuses.some(status => status?.outcome === 'unknown')) {
          unknownResult = true
          setHasUnconfirmedResult(true)
        }
        if (event.type === 'snapshot' && (
          (event.first_retained_seq ?? 1) > 1 || (event.lines_omitted ?? 0) > 0
          || snapshotStatuses.some(status => status === null)
        )) {
          incompleteHistory = true
          setHasIncompleteHistory(true)
        }
        const contradictsActiveCount = event.closed === true && (
          (typeof event.active_count === 'number' && event.active_count > 0)
          || (event.type === 'snapshot' && Array.isArray(event.active_streams) && event.active_streams.length > 0)
        )
        if (contradictsActiveCount) {
          incompleteHistory = true
          setHasIncompleteHistory(true)
        }
        const allClosed = event.closed === true && !contradictsActiveCount
        // A later successful close does not identify which earlier execution
        // was unconfirmed. Do not attach that aggregate warning to its task.
        const unconfirmedResult = unknownResult || incompleteHistory
        const closedTask = unconfirmedResult && executionStatus(event)?.outcome !== 'unknown'
          ? null
          : taskOf(event.task_id)
        settled = event.type === 'error' || allClosed
        if (event.type === 'snapshot' && Array.isArray(event.active_streams)) {
          activeStreams = event.active_streams.every(stream =>
            stream !== null && typeof stream === 'object' && Number.isInteger(stream.stream_id)
            && (stream.task_id === null || typeof stream.task_id === 'string'))
            ? new Map(event.active_streams.map(stream => [stream.stream_id, stream.task_id]))
            : null
          if (typeof event.active_count === 'number' && activeStreams?.size !== event.active_count) activeStreams = null
          setTaskId(allClosed && activeStreams?.size === 0 ? closedTask : soleActiveTask())
        } else if (event.type === 'snapshot' || event.type === 'no_task') {
          // Older servers do not send an inventory. A closed snapshot is a
          // complete empty inventory; an open one cannot establish one.
          activeStreams = allClosed ? new Map() : null
          setTaskId(allClosed ? closedTask : taskOf(event.task_id))
        } else if (event.type === 'task_opened') {
          if (activeStreams !== null && typeof event.stream_id === 'number') {
            activeStreams.set(event.stream_id, taskOf(event.task_id))
            setTaskId(soleActiveTask())
          } else {
            activeStreams = null
            setTaskId(null)
          }
        } else if (event.type === 'task_closed') {
          if (activeStreams !== null && typeof event.stream_id === 'number') activeStreams.delete(event.stream_id)
          else activeStreams = null
          if (typeof event.active_count === 'number' && activeStreams?.size !== event.active_count) activeStreams = null
          if (event.active_count === 0) activeStreams = new Map()
          setTaskId(allClosed ? closedTask : soleActiveTask())
        } else if (event.type === 'line' && activeStreams === null) {
          // Legacy events lack stream IDs. Do not resurrect a task after a gap.
          setTaskId(null)
        } else if (event.type === 'error') {
          setTaskId(null)
        }
        if (event.type === 'error') setStatus('error')
        else if (allClosed) setStatus(unconfirmedResult ? 'unknown' : 'closed')
        else setStatus('streaming')
      },
    }).then(() => {
      // The body ended. A task that closed already said so; anything still
      // streaming lost its connection and is not coming back on its own.
      if (controller.signal.aborted || settled) return
      setStatus('ended')
      setLines(current => appendLines(current, [{
        text: 'output stream ended before the task closed',
        stream: 'meta',
      }]))
    }).catch(err => {
      if (controller.signal.aborted) return
      setStatus('error')
      const message = errorToString(err)
      setLines(current =>
        appendLines(current, [{ text: message, stream: 'stderr' }]),
      )
    })

    return () => controller.abort()
  }, [keeper, streamEnabled])

  useEffect(() => {
    if (prefersReducedMotion) return
    const el = viewportRef.current
    if (!el) return
    el.scrollTop = el.scrollHeight
  }, [lines, prefersReducedMotion])

  return html`
    <aside
      class=${`execute-output-drawer v2-ide-panel border-t border-solid border-[var(--color-border-divider)] bg-[var(--color-bg-page)] ${compact ? 'is-compact' : ''} ${expanded ? 'is-expanded' : 'is-collapsed'}`}
      data-testid="execute-output-drawer"
      data-keeper=${keeper}
      aria-label="Execute output drawer"
    >
      <div
        class="execute-output-drawer-header v2-ide-toolbar flex min-w-0 flex-wrap items-center gap-2 border-b border-solid border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-1.5 font-mono text-2xs"
      >
        ${compact ? html`
          <button
            type="button"
            class="execute-output-drawer-toggle"
            aria-expanded=${expanded ? 'true' : 'false'}
            title=${expanded ? '실행 출력 접기' : '실행 출력 펼치기'}
            onClick=${() => setExpanded(current => !current)}
          >
            <span class="execute-output-drawer-chevron" aria-hidden="true">▾</span>
            <span>실행 출력</span>
          </button>
        ` : html`<span class="text-[var(--color-fg-secondary)]">TERMINAL</span>`}
        <span class="text-[var(--color-fg-muted)]">${keeper || 'none'}</span>
        ${taskId
          ? html`<span class="truncate text-[var(--color-fg-disabled)]">${taskId}</span>`
          : null}
        <${StatusChip} tone=${statusTone(status)} uppercase=${false} class="font-mono">${status}</${StatusChip}>
        ${hasUnconfirmedResult && status !== 'unknown'
          ? html`<${StatusChip} tone="warn" uppercase=${false} class="font-mono">unconfirmed result</${StatusChip}>`
          : null}
        ${hasIncompleteHistory
          ? html`<${StatusChip} tone="warn" uppercase=${false} class="font-mono">history incomplete</${StatusChip}>`
          : null}
        <${ExecuteOutputContextLinks} links=${routeLinks} />
        ${streamEnabled && onStop ? html`
          <button
            type="button"
            class="v2-ide-action"
            data-testid="execute-output-stop"
            aria-label="Stop live Execute output"
            title="Stop live Execute output"
            onClick=${onStop}
          >Stop</button>
        ` : null}
        <div class="ml-auto min-w-0">
          <${ExecuteOutputSummaryStrip} summary=${summary} status=${status} />
        </div>
      </div>
      ${expanded ? html`
        <${Terminal}
          lines=${terminalLines}
          prompt=${status === 'streaming' ? `${keeper || '(no keeper)'}:$ ` : ''}
          testId="execute-output-terminal"
          ariaLabel="Execute output terminal"
          emptyText="waiting for Execute output"
          className="h-[260px] overflow-auto bg-[var(--color-bg-page)] px-3 py-2 font-mono text-xs leading-relaxed"
          viewportRef=${viewportRef}
        />
      ` : null}
    </aside>
  `
}

function nonEmpty(value: string | null | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}
