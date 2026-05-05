import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  streamKeeperShell,
  type KeeperShellStreamEvent,
} from '../../api/keeper-shell'

const MAX_TERMINAL_LINES = 5000

interface ShellLine {
  text: string
  stream: 'stdout' | 'stderr' | 'meta'
}

interface KeeperShellDrawerProps {
  keeperName: string
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

function lineClass(stream: ShellLine['stream']): string {
  switch (stream) {
    case 'stderr':
      return 'term-line is-err'
    case 'meta':
      return 'term-line is-meta'
    default:
      return 'term-line is-out'
  }
}

export function KeeperShellDrawer({ keeperName }: KeeperShellDrawerProps) {
  const keeper = keeperName.trim()
  const [lines, setLines] = useState<ShellLine[]>([])
  const [status, setStatus] = useState<'idle' | 'streaming' | 'closed' | 'error'>('idle')
  const [taskId, setTaskId] = useState<string | null>(null)
  const viewportRef = useRef<HTMLDivElement | null>(null)

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

  return html`
    <aside
      class="border-t border-solid border-[var(--color-border-divider)] bg-[var(--color-bg-page)]"
      data-testid="keeper-shell-drawer"
      data-keeper=${keeper}
      aria-label="Keeper shell drawer"
    >
      <div
        class="flex items-center gap-2 border-b border-solid border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-1.5 font-mono text-2xs"
      >
        <span class="text-[var(--color-fg-secondary)]">TERMINAL</span>
        <span class="text-[var(--color-fg-muted)]">${keeper || 'none'}</span>
        ${taskId
          ? html`<span class="truncate text-[var(--color-fg-disabled)]">${taskId}</span>`
          : null}
        <span class="ml-auto text-[var(--color-fg-muted)]">${status}</span>
      </div>
      <div
        ref=${viewportRef}
        class="h-[260px] overflow-auto bg-[var(--color-bg-page)] px-3 py-2 font-mono text-xs leading-relaxed"
        role="log"
        aria-live="polite"
        aria-atomic="false"
      >
        ${lines.length === 0
          ? html`<div class="term-line is-meta">waiting for keeper shell output</div>`
          : lines.map(
              (line, index) => html`
                <div key=${index} class=${lineClass(line.stream)}>${line.text}</div>
              `,
            )}
      </div>
    </aside>
  `
}
