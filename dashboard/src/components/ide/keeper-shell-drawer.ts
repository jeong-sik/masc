import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  streamKeeperShell,
  type KeeperShellStreamEvent,
} from '../../api/keeper-shell'
import { tasks } from '../../store'
import type { Task } from '../../types'
import { StatusChip, type StatusChipTone } from '../common/status-chip'
import { Terminal, type TerminalLine } from '../common/terminal'
import {
  openIdeContextRouteLink,
  routeLinksForContext,
  type IdeContextRouteLink,
} from './ide-context-lens'
import { cursorOverlaySignal, type KeeperCursor } from './keeper-cursor-overlay'

const MAX_TERMINAL_LINES = 5000

interface ShellLine {
  text: string
  stream: 'stdout' | 'stderr' | 'meta'
}

interface KeeperShellDrawerProps {
  keeperName: string
}

type KeeperShellStatus = 'idle' | 'streaming' | 'closed' | 'error'

export interface KeeperShellSummary {
  readonly total: number
  readonly stdout: number
  readonly stderr: number
  readonly meta: number
  readonly droppedBytes: number
  readonly lastStream: ShellLine['stream'] | null
}

export interface KeeperShellRouteLinkInput {
  readonly keeperName: string
  readonly taskId: string | null
  readonly taskList: ReadonlyArray<Task>
  readonly cursor: KeeperCursor | null
}

function splitChunkLines(chunk: string): string[] {
  if (!chunk) return []
  const normalized = chunk.replace(/\r\n/g, '\n')
  const lines = normalized.split('\n')
  if (normalized.endsWith('\n')) lines.pop()
  return lines
}

export function linesFromShellEvent(event: KeeperShellStreamEvent): ShellLine[] {
  if (event.type === 'error') {
    return [{ text: event.message ?? 'keeper shell stream error', stream: 'stderr' }]
  }
  if (event.type === 'no_task') {
    return [{ text: 'no active keeper shell task', stream: 'meta' }]
  }

  const lines: ShellLine[] = []
  for (const line of splitChunkLines(event.stdout_since ?? '')) {
    lines.push({ text: line, stream: 'stdout' })
  }
  for (const line of splitChunkLines(event.stderr_since ?? '')) {
    lines.push({ text: line, stream: 'stderr' })
  }
  const dropped =
    (event.bytes_dropped_stdout ?? 0) + (event.bytes_dropped_stderr ?? 0)
  if (dropped > 0) {
    lines.unshift({ text: `dropped ${dropped} older bytes`, stream: 'meta' })
  }
  if (event.closed && lines.length === 0) {
    lines.push({ text: 'keeper shell task closed', stream: 'meta' })
  }
  return lines
}

function appendLines(current: ShellLine[], next: ShellLine[]): ShellLine[] {
  if (next.length === 0) return current
  return [...current, ...next].slice(-MAX_TERMINAL_LINES)
}

export function summarizeShellLines(lines: ReadonlyArray<ShellLine>): KeeperShellSummary {
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

function toTerminalLine(line: ShellLine): TerminalLine {
  switch (line.stream) {
    case 'stderr':
      return { text: line.text, tone: 'err' }
    case 'meta':
      return { text: line.text, tone: 'meta' }
    default:
      return { text: line.text, tone: 'out' }
  }
}

function statusTone(status: KeeperShellStatus): StatusChipTone {
  if (status === 'streaming') return 'info'
  if (status === 'closed') return 'neutral'
  if (status === 'error') return 'bad'
  return 'neutral'
}

function lineCountLabel(count: number): string {
  return `${count} ${count === 1 ? 'line' : 'lines'}`
}

function shellSummaryLabel(summary: KeeperShellSummary, status: KeeperShellStatus): string {
  const last = summary.lastStream ?? 'none'
  const dropped = summary.droppedBytes > 0 ? `, ${summary.droppedBytes} dropped bytes` : ''
  return `Keeper shell ${status}: ${lineCountLabel(summary.total)}, ${summary.stdout} stdout, ${summary.stderr} stderr, ${summary.meta} meta, last ${last}${dropped}`
}

export function keeperShellRouteLinks({
  keeperName,
  taskId,
  taskList,
  cursor,
}: KeeperShellRouteLinkInput): ReadonlyArray<IdeContextRouteLink> {
  const keeperId = nonEmpty(keeperName)
  if (!keeperId) return []
  const task = taskId
    ? taskList.find(candidate => candidate.id === taskId) ?? null
    : null
  const sourceParts = ['keeper-shell', keeperId, taskId].filter((part): part is string =>
    typeof part === 'string' && part.trim() !== '')
  return routeLinksForContext({
    filePath: cursor?.file_path,
    line: cursor?.line,
    surface: 'Terminal',
    label: taskId ? `keeper shell ${taskId}` : 'keeper shell',
    sourceId: sourceParts.join(':'),
    goalId: task?.goal_id ?? undefined,
    taskId: taskId ?? undefined,
    gitRef: task?.worktree?.branch,
    keeperId,
    telemetry: true,
    telemetryQuery: taskId ?? keeperId,
  })
}

function KeeperShellContextLinks({
  links,
}: {
  readonly links: ReadonlyArray<IdeContextRouteLink>
}) {
  if (links.length === 0) return null
  return html`
    <div class="keeper-shell-context-links" aria-label="Keeper shell operational links">
      ${links.map(link => html`
        <button
          key=${link.id}
          type="button"
          title=${link.evidence}
          aria-label=${`Open ${link.evidence}`}
          onClick=${() => openIdeContextRouteLink(link)}
        >${link.label}</button>
      `)}
    </div>
  `
}

function KeeperShellSummaryStrip({
  summary,
  status,
}: {
  readonly summary: KeeperShellSummary
  readonly status: KeeperShellStatus
}) {
  return html`
    <div
      aria-label=${shellSummaryLabel(summary, status)}
      data-testid="keeper-shell-summary"
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

export function KeeperShellDrawer({ keeperName }: KeeperShellDrawerProps) {
  const keeper = keeperName.trim()
  const [lines, setLines] = useState<ShellLine[]>([])
  const [status, setStatus] = useState<KeeperShellStatus>('idle')
  const [taskId, setTaskId] = useState<string | null>(null)
  const [overlay, setOverlay] = useState(cursorOverlaySignal.value)
  const viewportRef = useRef<HTMLDivElement | null>(null)
  const terminalLines = useMemo(() => lines.map(toTerminalLine), [lines])
  const summary = useMemo(() => summarizeShellLines(lines), [lines])
  const cursor = resolveKeeperCursor(keeper, overlay.cursors)
  const routeLinks = keeperShellRouteLinks({
    keeperName: keeper,
    taskId,
    taskList: tasks.value,
    cursor,
  })

  const prefersReducedMotion = useMemo(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') {
      return false
    }
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches
  }, [])

  useEffect(() => {
    if (!keeper) {
      setLines([{ text: 'no keeper selected', stream: 'meta' }])
      setStatus('idle')
      setTaskId(null)
      return
    }

    const controller = new AbortController()
    setLines([])
    setStatus('streaming')
    setTaskId(null)

    void streamKeeperShell(keeper, {
      signal: controller.signal,
      onEvent: event => {
        setTaskId(typeof event.task_id === 'string' ? event.task_id : null)
        setLines(current => appendLines(current, linesFromShellEvent(event)))
        if (event.type === 'error') setStatus('error')
        else if (event.closed) setStatus('closed')
        else setStatus('streaming')
      },
    }).catch(err => {
      if (controller.signal.aborted) return
      setStatus('error')
      const message = err instanceof Error ? err.message : String(err)
      setLines(current =>
        appendLines(current, [{ text: message, stream: 'stderr' }]),
      )
    })

    return () => controller.abort()
  }, [keeper])

  useEffect(() => {
    if (prefersReducedMotion) return
    const el = viewportRef.current
    if (!el) return
    el.scrollTop = el.scrollHeight
  }, [lines, prefersReducedMotion])

  useEffect(() => {
    const unsub = cursorOverlaySignal.subscribe(v => setOverlay(v))
    return () => unsub()
  }, [])

  return html`
    <aside
      class="border-t border-solid border-[var(--color-border-divider)] bg-[var(--color-bg-page)]"
      data-testid="keeper-shell-drawer"
      data-keeper=${keeper}
      aria-label="Keeper shell drawer"
    >
      <div
        class="flex min-w-0 flex-wrap items-center gap-2 border-b border-solid border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-1.5 font-mono text-2xs"
      >
        <span class="text-[var(--color-fg-secondary)]">TERMINAL</span>
        <span class="text-[var(--color-fg-muted)]">${keeper || 'none'}</span>
        ${taskId
          ? html`<span class="truncate text-[var(--color-fg-disabled)]">${taskId}</span>`
          : null}
        <${StatusChip} tone=${statusTone(status)} uppercase=${false} class="font-mono">${status}</${StatusChip}>
        <${KeeperShellContextLinks} links=${routeLinks} />
        <div class="ml-auto min-w-0">
          <${KeeperShellSummaryStrip} summary=${summary} status=${status} />
        </div>
      </div>
      <${Terminal}
        lines=${terminalLines}
        prompt=${status === 'streaming' ? `${keeper || '(no keeper)'}:$ ` : ''}
        testId="keeper-shell-terminal"
        ariaLabel="Keeper shell terminal"
        emptyText="waiting for keeper shell output"
        className="h-[260px] overflow-auto bg-[var(--color-bg-page)] px-3 py-2 font-mono text-xs leading-relaxed"
        viewportRef=${viewportRef}
      />
    </aside>
  `
}

function resolveKeeperCursor(
  keeperName: string,
  cursors: ReadonlyMap<string, KeeperCursor>,
): KeeperCursor | null {
  const target = keeperName.toLowerCase().trim()
  if (!target) return null
  for (const [id, cursor] of cursors) {
    if (id.toLowerCase() === target) return cursor
    if (cursor.keeper_id.toLowerCase() === target) return cursor
  }
  return null
}

function nonEmpty(value: string | null | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}
