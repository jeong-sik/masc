/**
 * Live Sandbox Terminal Output Viewer for Keeper `Work & Sandbox` tab.
 *
 * - Authenticated `fetch` SSE streaming against `GET /api/v1/dashboard/execute-output/:keeper`
 *   (Bearer token + credentials: same-origin + sessionEpoch + AbortController — never raw EventSource)
 * - Handles `snapshot`, `no_task`, `task_opened`, `line`, `task_closed`, `gap` events
 * - Pure ANSI SGR rendering via `parseAnsiSgr` as Preact text nodes (never `dangerouslySetInnerHTML`)
 * - Capped DOM line buffer (2,000 lines) with head-drop notice
 * - Default-collapsed Host Container / VM Logs disclosure (`GET /api/v1/gate/keeper-sandbox-logs`)
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  authSession,
  currentSessionEpoch,
  getSingleUserToken,
  isEpochCurrent,
  resolveWorkspaceUrl,
  sessionEpoch,
} from '../../core/auth'
import { parseSseBlock } from '../../core/observer'
import { apiGet } from '../../core/transport'
import { parseAnsiSgr, stripAnsi, type AnsiSpan } from '../../lib/ansi-sgr'
import { pushShellToast } from '../../shell/shell-state'
import '../infra/infra.css'

export const MAX_TERMINAL_LINES = 2_000

export type TerminalLineStream = 'cmd' | 'stdout' | 'stderr' | 'status' | 'system'

export interface TerminalLine {
  readonly id: string
  readonly seq: number | null
  readonly stream: TerminalLineStream
  readonly text: string
  readonly exitCode?: number | null
  readonly exitOk?: boolean | null
  readonly tsMs?: number | null
}

export interface ActiveTerminalCommand {
  readonly streamId: number | null
  readonly taskId: string | null
  readonly command: string
  readonly cwd: string | null
  readonly sandboxProfile: string | null
}

export interface TerminalGapNotice {
  readonly missingFromSeq: number | null
  readonly missingToSeq: number | null
  readonly missingCount: number | null
  readonly firstRetainedSeq: number | null
  readonly bytesDroppedStdout: number
  readonly bytesDroppedStderr: number
}

export interface TerminalStreamState {
  readonly lines: readonly TerminalLine[]
  readonly headDroppedCount: number
  readonly activeCommand: ActiveTerminalCommand | null
  readonly noTask: boolean
  readonly gap: TerminalGapNotice
  readonly lastSeq: number | null
  readonly sandboxProfile: string | null
}

export type TerminalConnectionStatus = 'connecting' | 'connected' | 'disconnected'
export type TerminalStreamFilter = 'all' | 'stdout' | 'stderr'
export type TerminalHeightPreset = 'compact' | 'standard' | 'tall'

const HEIGHT_PRESET_PX: Readonly<Record<TerminalHeightPreset, number>> = {
  compact: 180,
  standard: 320,
  tall: 520,
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function asStr(v: unknown): string | null {
  return typeof v === 'string' && v.trim().length > 0 ? v.trim() : null
}

function asNum(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null
}

export function formatExitStatus(status: unknown): {
  readonly label: string
  readonly code: number | null
  readonly ok: boolean | null
} {
  if (typeof status === 'number' && Number.isFinite(status)) {
    return { label: `exit ${status}`, code: status, ok: status === 0 }
  }
  if (typeof status === 'string' && status.trim()) {
    const t = status.trim()
    const m = /^exited[:\s]+(\d+)$/i.exec(t)
    if (m) {
      const code = Number(m[1])
      return { label: `exit ${code}`, code, ok: code === 0 }
    }
    return { label: t, code: null, ok: t === 'ok' || t === '0' ? true : null }
  }
  if (isRecord(status)) {
    const exited = asNum(status.exited) ?? asNum(status.code) ?? asNum(status.exit_code)
    if (exited !== null) {
      return { label: `exit ${exited}`, code: exited, ok: exited === 0 }
    }
    const signaled = asNum(status.signaled) ?? asNum(status.signal)
    if (signaled !== null) {
      return { label: `signal ${signaled}`, code: signaled, ok: false }
    }
    const kind = asStr(status.kind) ?? asStr(status.status)
    if (kind) return { label: kind, code: null, ok: kind === 'ok' ? true : false }
  }
  return { label: 'closed', code: null, ok: null }
}

export function createInitialTerminalState(): TerminalStreamState {
  return {
    lines: [],
    headDroppedCount: 0,
    activeCommand: null,
    noTask: false,
    gap: {
      missingFromSeq: null,
      missingToSeq: null,
      missingCount: null,
      firstRetainedSeq: null,
      bytesDroppedStdout: 0,
      bytesDroppedStderr: 0,
    },
    lastSeq: null,
    sandboxProfile: null,
  }
}

let syntheticLineSeq = 0
function nextSyntheticId(prefix: string): string {
  syntheticLineSeq += 1
  return `${prefix}-${syntheticLineSeq}`
}

function normalizeStreamKind(raw: unknown): TerminalLineStream {
  if (raw === 'cmd' || raw === 'stdout' || raw === 'stderr' || raw === 'status' || raw === 'system') {
    return raw
  }
  return 'stdout'
}

function decodeLineObject(raw: unknown): TerminalLine | null {
  if (!isRecord(raw)) return null
  if (typeof raw.text !== 'string') return null
  const seq = asNum(raw.seq)
  const stream = normalizeStreamKind(raw.stream)
  return {
    id: seq !== null ? `seq-${seq}` : nextSyntheticId(stream),
    seq,
    stream,
    text: raw.text,
    tsMs: asNum(raw.ts_ms),
  }
}

function appendCapped(
  existing: readonly TerminalLine[],
  incoming: readonly TerminalLine[],
  prevHeadDropped: number,
  cap = MAX_TERMINAL_LINES,
): { readonly lines: readonly TerminalLine[]; readonly headDroppedCount: number } {
  if (incoming.length === 0) return { lines: existing, headDroppedCount: prevHeadDropped }
  const combined = [...existing, ...incoming]
  if (combined.length <= cap) {
    return { lines: combined, headDroppedCount: prevHeadDropped }
  }
  const dropped = combined.length - cap
  return {
    lines: combined.slice(dropped),
    headDroppedCount: prevHeadDropped + dropped,
  }
}

function pickActiveCommand(rec: Record<string, unknown>): ActiveTerminalCommand | null {
  const streams = Array.isArray(rec.active_streams) ? rec.active_streams : []
  for (let i = streams.length - 1; i >= 0; i -= 1) {
    const item = streams[i]
    if (!isRecord(item)) continue
    const cmd = asStr(item.command)
    if (!cmd) continue
    return {
      streamId: asNum(item.stream_id),
      taskId: asStr(item.task_id),
      command: cmd,
      cwd: asStr(item.cwd) ?? asStr(rec.cwd),
      sandboxProfile: asStr(item.sandbox_profile) ?? asStr(rec.sandbox_profile),
    }
  }
  const directCmd = asStr(rec.command)
  if (directCmd) {
    return {
      streamId: asNum(rec.stream_id),
      taskId: asStr(rec.task_id),
      command: directCmd,
      cwd: asStr(rec.cwd),
      sandboxProfile: asStr(rec.sandbox_profile),
    }
  }
  return null
}

export function reduceTerminalEvent(
  state: TerminalStreamState,
  rawEvent: unknown,
  cap = MAX_TERMINAL_LINES,
): TerminalStreamState {
  if (!isRecord(rawEvent)) return state
  const type = asStr(rawEvent.type) ?? asStr(rawEvent.kind)
  if (!type) return state

  const eventSandboxProfile = asStr(rawEvent.sandbox_profile) ?? state.sandboxProfile
  const droppedOut = asNum(rawEvent.bytes_dropped_stdout)
  const droppedErr = asNum(rawEvent.bytes_dropped_stderr)

  const mergeDrops = (g: TerminalGapNotice): TerminalGapNotice => ({
    ...g,
    bytesDroppedStdout: droppedOut !== null ? Math.max(g.bytesDroppedStdout, droppedOut) : g.bytesDroppedStdout,
    bytesDroppedStderr: droppedErr !== null ? Math.max(g.bytesDroppedStderr, droppedErr) : g.bytesDroppedStderr,
  })

  switch (type) {
    case 'snapshot': {
      const rawLines = Array.isArray(rawEvent.lines) ? rawEvent.lines : []
      const decodedLines: TerminalLine[] = []
      for (const item of rawLines) {
        const line = decodeLineObject(item)
        if (line) decodedLines.push(line)
      }
      // The server sends only its newest rows and counts the older rows it
      // still holds but left out in `lines_omitted`.
      const capped = appendCapped([], decodedLines, asNum(rawEvent.lines_omitted) ?? 0, cap)
      const activeCommand = pickActiveCommand(rawEvent)
      const firstRetained = asNum(rawEvent.first_retained_seq)
      const lastSeq = asNum(rawEvent.last_seq) ?? decodedLines.at(-1)?.seq ?? state.lastSeq
      return {
        lines: capped.lines,
        headDroppedCount: capped.headDroppedCount,
        activeCommand,
        noTask: decodedLines.length === 0 && activeCommand === null,
        gap: mergeDrops({
          ...state.gap,
          firstRetainedSeq: firstRetained ?? state.gap.firstRetainedSeq,
        }),
        lastSeq,
        sandboxProfile: activeCommand?.sandboxProfile ?? eventSandboxProfile,
      }
    }

    case 'no_task': {
      return {
        ...state,
        activeCommand: null,
        noTask: state.lines.length === 0,
        sandboxProfile: eventSandboxProfile,
      }
    }

    case 'task_opened': {
      const cmd = pickActiveCommand(rawEvent)
      const seq = asNum(rawEvent.seq)
      const incoming: TerminalLine[] = []
      if (cmd?.command) {
        incoming.push({
          id: seq !== null ? `open-${seq}` : nextSyntheticId('cmd'),
          seq,
          stream: 'cmd',
          text: cmd.command,
        })
      }
      const capped = appendCapped(state.lines, incoming, state.headDroppedCount, cap)
      return {
        ...state,
        lines: capped.lines,
        headDroppedCount: capped.headDroppedCount,
        activeCommand: cmd ?? state.activeCommand,
        noTask: false,
        lastSeq: seq ?? state.lastSeq,
        sandboxProfile: cmd?.sandboxProfile ?? eventSandboxProfile,
      }
    }

    case 'line': {
      const candidate = isRecord(rawEvent.line) ? rawEvent.line : rawEvent
      const line = decodeLineObject(candidate)
      if (!line) return state
      if (line.seq !== null && state.lastSeq !== null && line.seq <= state.lastSeq) {
        return state
      }
      const capped = appendCapped(state.lines, [line], state.headDroppedCount, cap)
      return {
        ...state,
        lines: capped.lines,
        headDroppedCount: capped.headDroppedCount,
        noTask: false,
        gap: mergeDrops(state.gap),
        lastSeq: line.seq ?? state.lastSeq,
        sandboxProfile: eventSandboxProfile,
      }
    }

    case 'task_closed': {
      const seq = asNum(rawEvent.seq)
      const exitInfo = formatExitStatus(rawEvent.status)
      const statusLine: TerminalLine = {
        id: seq !== null ? `close-${seq}` : nextSyntheticId('status'),
        seq,
        stream: 'status',
        text: exitInfo.label,
        exitCode: exitInfo.code,
        exitOk: exitInfo.ok,
      }
      const capped = appendCapped(state.lines, [statusLine], state.headDroppedCount, cap)
      const closedStreamId = asNum(rawEvent.stream_id)
      const stillActive =
        state.activeCommand !== null
        && closedStreamId !== null
        && state.activeCommand.streamId !== null
        && state.activeCommand.streamId !== closedStreamId
          ? state.activeCommand
          : null
      return {
        ...state,
        lines: capped.lines,
        headDroppedCount: capped.headDroppedCount,
        activeCommand: stillActive,
        noTask: false,
        gap: mergeDrops(state.gap),
        lastSeq: seq ?? state.lastSeq,
        sandboxProfile: eventSandboxProfile,
      }
    }

    case 'gap': {
      return {
        ...state,
        gap: mergeDrops({
          ...state.gap,
          missingFromSeq: asNum(rawEvent.missing_from_seq) ?? state.gap.missingFromSeq,
          missingToSeq: asNum(rawEvent.missing_to_seq) ?? state.gap.missingToSeq,
          missingCount: asNum(rawEvent.missing_count) ?? state.gap.missingCount,
        }),
      }
    }

    default:
      return state
  }
}

function hasGapWarning(gap: TerminalGapNotice): boolean {
  return (
    (gap.missingCount !== null && gap.missingCount > 0)
    || (gap.firstRetainedSeq !== null && gap.firstRetainedSeq > 1)
    || gap.bytesDroppedStdout > 0
    || gap.bytesDroppedStderr > 0
  )
}

function renderAnsiSpans(text: string, ansiEnabled: boolean) {
  if (!ansiEnabled) return stripAnsi(text)
  const spans: AnsiSpan[] = parseAnsiSgr(text)
  if (spans.length === 0) return ''
  return spans.map((span, idx) => {
    const s = span.style
    const hasStyle = Boolean(s.fg || s.bg || s.bold || s.dim || s.italic || s.underline)
    if (!hasStyle) return span.text
    const inlineStyle: Record<string, string | number> = {}
    if (s.fg) inlineStyle.color = s.fg
    if (s.bg) inlineStyle.backgroundColor = s.bg
    if (s.bold) inlineStyle.fontWeight = 700
    if (s.dim) inlineStyle.opacity = 0.65
    if (s.italic) inlineStyle.fontStyle = 'italic'
    if (s.underline) inlineStyle.textDecoration = 'underline'
    return html`<span key=${idx} style=${inlineStyle}>${span.text}</span>`
  })
}

// ── Host Container / VM Logs (secondary collapsed disclosure) ───────────

interface SandboxLogInstance {
  readonly instanceId: string
  readonly instanceName: string
  readonly running: boolean | null
  readonly stdout: string
  readonly stderr: string
  readonly error: string | null
}

interface SandboxLogsPayload {
  readonly backend: string | null
  readonly state: string
  readonly reason: string | null
  readonly reasonCode: string | null
  readonly instances: readonly SandboxLogInstance[]
}

function decodeSandboxLogs(raw: unknown): SandboxLogsPayload | null {
  if (!isRecord(raw)) return null
  const state = asStr(raw.state)
  if (!state) return null
  const rawInstances = Array.isArray(raw.instances) ? raw.instances : []
  const instances: SandboxLogInstance[] = []
  for (const item of rawInstances) {
    if (!isRecord(item)) continue
    instances.push({
      instanceId: asStr(item.instance_id) ?? 'unknown',
      instanceName: asStr(item.instance_name) ?? asStr(item.instance_id) ?? 'instance',
      running: typeof item.running === 'boolean' ? item.running : null,
      stdout: typeof item.stdout === 'string' ? item.stdout : '',
      stderr: typeof item.stderr === 'string' ? item.stderr : '',
      error: asStr(item.error),
    })
  }
  return {
    backend: asStr(raw.backend),
    state,
    reason: asStr(raw.reason),
    reasonCode: asStr(raw.reason_code),
    instances,
  }
}

export interface KeeperSandboxTerminalProps {
  readonly keeperName: string
  readonly sandboxBackend?: string | null
}

export function KeeperSandboxTerminal(props: KeeperSandboxTerminalProps) {
  const { keeperName, sandboxBackend = null } = props
  const epoch = sessionEpoch.value

  const [connStatus, setConnStatus] = useState<TerminalConnectionStatus>('connecting')
  const [connDetail, setConnDetail] = useState<string | null>(null)
  const [termState, setTermState] = useState<TerminalStreamState>(() => createInitialTerminalState())
  const [reconnectToken, setReconnectToken] = useState(0)

  const [ansiEnabled, setAnsiEnabled] = useState(true)
  const [streamFilter, setStreamFilter] = useState<TerminalStreamFilter>('all')
  const [textFilter, setTextFilter] = useState('')
  const [autoScroll, setAutoScroll] = useState(true)
  const [heightPreset, setHeightPreset] = useState<TerminalHeightPreset>('standard')

  // Host container / VM logs disclosure state
  const [hostLogsOpen, setHostLogsOpen] = useState(false)
  const [hostLogsLoading, setHostLogsLoading] = useState(false)
  const [hostLogsError, setHostLogsError] = useState<string | null>(null)
  const [hostLogsData, setHostLogsData] = useState<SandboxLogsPayload | null>(null)
  const hostLogsAbortRef = useRef<AbortController | null>(null)

  const viewportRef = useRef<HTMLDivElement>(null)
  const reconnectTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Reset local buffer when keeper or epoch changes.
  useEffect(() => {
    setTermState(createInitialTerminalState())
    setConnDetail(null)
    setHostLogsData(null)
    setHostLogsError(null)
  }, [keeperName, epoch])

  // Authenticated fetch SSE stream to GET /api/v1/dashboard/execute-output/:keeper
  useEffect(() => {
    const trimmed = typeof keeperName === 'string' ? keeperName.trim() : ''
    if (!trimmed) return

    const startEpoch = currentSessionEpoch()
    const controller = new AbortController()
    let readerRef: ReadableStreamDefaultReader<Uint8Array> | null = null
    let disposed = false

    const clearTimer = () => {
      if (reconnectTimerRef.current !== null) {
        clearTimeout(reconnectTimerRef.current)
        reconnectTimerRef.current = null
      }
    }

    const abortStream = () => {
      disposed = true
      clearTimer()
      controller.abort()
      if (readerRef) {
        void readerRef.cancel().catch(() => {})
        readerRef = null
      }
    }

    const unsubEpoch = sessionEpoch.subscribe((nextEpoch) => {
      if (nextEpoch !== startEpoch) abortStream()
    })

    const run = async () => {
      setConnStatus('connecting')
      setConnDetail(null)

      const headers: Record<string, string> = { Accept: 'text/event-stream' }
      const session = authSession.peek()
      if (session.kind === 'single_user_local') {
        const token = getSingleUserToken()
        if (token) headers.Authorization = `Bearer ${token}`
      }
      const url = resolveWorkspaceUrl(`/api/v1/dashboard/execute-output/${encodeURIComponent(trimmed)}`)

      try {
        const res = await fetch(url, {
          method: 'GET',
          credentials: 'same-origin',
          headers,
          signal: controller.signal,
        })
        if (disposed || controller.signal.aborted || !isEpochCurrent(startEpoch)) return

        if (!res.ok) {
          setConnStatus('disconnected')
          setConnDetail(`HTTP ${res.status}`)
          // Reconnect only on transient failures (408/429/5xx).
          if (res.status === 408 || res.status === 429 || res.status >= 500) {
            reconnectTimerRef.current = setTimeout(() => {
              if (!disposed && isEpochCurrent(startEpoch)) {
                setReconnectToken((n) => n + 1)
              }
            }, 3_000)
          }
          return
        }

        const ct = res.headers.get('content-type') ?? ''
        if (!res.body || (ct !== '' && !ct.includes('text/event-stream'))) {
          setConnStatus('disconnected')
          setConnDetail(ct ? `예상치 못한 응답 형식 (${ct})` : '스트림 본문 없음')
          return
        }

        setConnStatus('connected')
        const reader = res.body.getReader()
        readerRef = reader
        const decoder = new TextDecoder()
        let buffer = ''

        while (!disposed && !controller.signal.aborted && isEpochCurrent(startEpoch)) {
          const { value, done } = await reader.read()
          if (done) break
          if (disposed || controller.signal.aborted || !isEpochCurrent(startEpoch)) break
          buffer += decoder.decode(value, { stream: true })
          const normalized = buffer.replace(/\r\n/g, '\n')
          let start = 0
          const incomingEvents: unknown[] = []
          for (;;) {
            const sep = normalized.indexOf('\n\n', start)
            if (sep === -1) break
            const frame = parseSseBlock(normalized.slice(start, sep))
            if (frame && isRecord(frame.data)) incomingEvents.push(frame.data)
            start = sep + 2
          }
          buffer = normalized.slice(start)
          if (incomingEvents.length > 0) {
            setTermState((prev) => {
              let next = prev
              for (const ev of incomingEvents) {
                next = reduceTerminalEvent(next, ev)
              }
              return next
            })
          }
        }

        if (!disposed && !controller.signal.aborted && isEpochCurrent(startEpoch)) {
          const tail = buffer.trim()
          if (tail) {
            const frame = parseSseBlock(tail)
            if (frame && isRecord(frame.data)) {
              setTermState((prev) => reduceTerminalEvent(prev, frame.data))
            }
          }
          setConnStatus('disconnected')
          setConnDetail('스트림 종료')
        }
      } catch (err) {
        if (disposed || controller.signal.aborted || !isEpochCurrent(startEpoch)) return
        setConnStatus('disconnected')
        setConnDetail(err instanceof Error ? err.message : '연결 오류')
      } finally {
        readerRef = null
      }
    }

    void run()

    return () => {
      unsubEpoch()
      abortStream()
    }
  }, [keeperName, epoch, reconnectToken])

  // Auto-scroll to bottom when enabled and lines grow.
  useEffect(() => {
    if (!autoScroll) return
    const el = viewportRef.current
    if (!el) return
    el.scrollTop = el.scrollHeight
  }, [termState.lines, autoScroll])

  const handleViewportScroll = useCallback(() => {
    const el = viewportRef.current
    if (!el) return
    const distanceFromBottom = el.scrollHeight - el.scrollTop - el.clientHeight
    if (distanceFromBottom > 32 && autoScroll) {
      setAutoScroll(false)
    } else if (distanceFromBottom <= 8 && !autoScroll) {
      setAutoScroll(true)
    }
  }, [autoScroll])

  const jumpToBottom = useCallback(() => {
    setAutoScroll(true)
    const el = viewportRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [])

  const filteredLines = useMemo(() => {
    const query = textFilter.trim().toLowerCase()
    return termState.lines.filter((line) => {
      if (streamFilter === 'stdout' && line.stream !== 'stdout') return false
      if (streamFilter === 'stderr' && line.stream !== 'stderr') return false
      if (query) {
        const plain = stripAnsi(line.text).toLowerCase()
        if (!plain.includes(query)) return false
      }
      return true
    })
  }, [termState.lines, streamFilter, textFilter])

  const handleCopyOutput = useCallback(async () => {
    const text = filteredLines
      .map((l) => (l.stream === 'cmd' ? `$ ${stripAnsi(l.text)}` : stripAnsi(l.text)))
      .join('\n')
    try {
      if (typeof navigator !== 'undefined' && navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(text)
        pushShellToast('터미널 출력을 클립보드에 복사했습니다.', 'success')
      } else {
        pushShellToast('이 환경에서는 클립보드 복사를 지원하지 않습니다.', 'warning')
      }
    } catch {
      pushShellToast('클립보드 복사에 실패했습니다.', 'error')
    }
  }, [filteredLines])

  const handleClearBuffer = useCallback(() => {
    setTermState((prev) => ({
      ...prev,
      lines: [],
      headDroppedCount: 0,
    }))
  }, [])

  const loadHostLogs = useCallback(async () => {
    hostLogsAbortRef.current?.abort()
    const ctrl = new AbortController()
    hostLogsAbortRef.current = ctrl
    const startEpoch = currentSessionEpoch()
    setHostLogsLoading(true)
    setHostLogsError(null)
    const res = await apiGet<unknown>(
      `/api/v1/gate/keeper-sandbox-logs?name=${encodeURIComponent(keeperName)}&tail=200`,
      { signal: ctrl.signal },
    )
    if (ctrl.signal.aborted || !isEpochCurrent(startEpoch)) return
    setHostLogsLoading(false)
    if (!res.ok) {
      setHostLogsError(res.error.message)
      return
    }
    const decoded = decodeSandboxLogs(res.value)
    if (!decoded) {
      setHostLogsError('호스트 샌드박스 로그 응답 형식을 해석하지 못했습니다.')
      return
    }
    setHostLogsData(decoded)
  }, [keeperName])

  useEffect(() => () => {
    hostLogsAbortRef.current?.abort()
    hostLogsAbortRef.current = null
  }, [])

  const handleToggleHostLogs = useCallback((e: Event) => {
    const details = e.currentTarget as HTMLDetailsElement
    const open = details.open
    setHostLogsOpen(open)
    if (open && !hostLogsData && !hostLogsLoading) {
      void loadHostLogs()
    }
  }, [hostLogsData, hostLogsLoading, loadHostLogs])

  const statusMeta = useMemo(() => {
    if (connStatus === 'connecting') return { label: '연결 중', tone: 'info' as const }
    if (connStatus === 'disconnected') return { label: '연결 끊김', tone: 'bad' as const }
    if (termState.activeCommand) return { label: '실행 중', tone: 'ok' as const }
    return { label: '대기', tone: 'idle' as const }
  }, [connStatus, termState.activeCommand])

  const effectiveBackend = termState.sandboxProfile ?? sandboxBackend
  const showGapBanner = hasGapWarning(termState.gap)

  return html`
    <section class="kp-card kst-root" data-testid="keeper-sandbox-terminal" aria-label="실시간 샌드박스 터미널">
      <!-- Header bar -->
      <div class="kst-head">
        <div class="kst-head-left">
          <span
            class="kst-status-pill"
            data-tone=${statusMeta.tone}
            data-testid="kst-status-pill"
            role="status"
          >
            <span class="kst-status-dot" aria-hidden="true" />
            <span>${statusMeta.label}</span>
          </span>
          <h3 class="kst-title">Live Sandbox Terminal</h3>
          ${effectiveBackend && html`
            <span class="kst-badge mono" data-testid="kst-backend-badge">sandbox: ${effectiveBackend}</span>
          `}
          ${connDetail && connStatus === 'disconnected' && html`
            <span class="kst-conn-detail mono" role="status">${connDetail}</span>
          `}
        </div>

        <div class="kst-head-actions">
          <button
            type="button"
            class="btn-ghost kst-btn"
            data-testid="kst-reconnect-btn"
            onClick=${() => setReconnectToken((n) => n + 1)}
          >
            재연결
          </button>
          <button
            type="button"
            class="btn-ghost kst-btn"
            aria-pressed=${ansiEnabled ? 'true' : 'false'}
            data-testid="kst-ansi-toggle"
            onClick=${() => setAnsiEnabled((v) => !v)}
          >
            ${ansiEnabled ? 'ANSI' : 'Plain'}
          </button>
          <button
            type="button"
            class="btn-ghost kst-btn"
            aria-pressed=${autoScroll ? 'true' : 'false'}
            data-testid="kst-autoscroll-toggle"
            onClick=${() => (autoScroll ? setAutoScroll(false) : jumpToBottom())}
          >
            자동 스크롤
          </button>
          <button
            type="button"
            class="btn-ghost kst-btn"
            data-testid="kst-copy-btn"
            disabled=${filteredLines.length === 0}
            onClick=${() => void handleCopyOutput()}
          >
            복사
          </button>
          <button
            type="button"
            class="btn-ghost kst-btn"
            data-testid="kst-clear-btn"
            disabled=${termState.lines.length === 0}
            onClick=${handleClearBuffer}
          >
            지우기
          </button>
        </div>
      </div>

      <!-- Active command bar -->
      ${termState.activeCommand && html`
        <div class="kst-cmd-bar mono" data-testid="kst-active-command">
          <span class="kst-cmd-prompt">$</span>
          <span class="kst-cmd-text" title=${termState.activeCommand.command}>${termState.activeCommand.command}</span>
          ${termState.activeCommand.cwd && html`
            <span class="kst-cmd-cwd" title=${termState.activeCommand.cwd}>${termState.activeCommand.cwd}</span>
          `}
        </div>
      `}

      <!-- Filter & Height controls -->
      <div class="kst-toolbar">
        <div class="kst-seg" role="group" aria-label="스트림 필터">
          ${(['all', 'stdout', 'stderr'] as const).map((mode) => html`
            <button
              key=${mode}
              type="button"
              class="kst-seg-btn"
              aria-pressed=${streamFilter === mode ? 'true' : 'false'}
              data-testid=${`kst-filter-${mode}`}
              onClick=${() => setStreamFilter(mode)}
            >
              ${mode === 'all' ? '전체' : mode}
            </button>
          `)}
        </div>

        <input
          type="search"
          class="kp-input kst-search"
          aria-label="터미널 출력 필터"
          placeholder="출력 필터…"
          value=${textFilter}
          data-testid="kst-text-filter"
          onInput=${(e: Event) => setTextFilter((e.currentTarget as HTMLInputElement).value)}
        />

        <div class="kst-seg" role="group" aria-label="터미널 높이 프리셋">
          ${(['compact', 'standard', 'tall'] as const).map((preset) => html`
            <button
              key=${preset}
              type="button"
              class="kst-seg-btn"
              aria-pressed=${heightPreset === preset ? 'true' : 'false'}
              data-testid=${`kst-height-${preset}`}
              onClick=${() => setHeightPreset(preset)}
            >
              ${preset === 'compact' ? 'Compact' : preset === 'standard' ? 'Standard' : 'Tall'}
            </button>
          `)}
        </div>
      </div>

      <!-- Honest gap / ring-buffer drop warning banner -->
      ${showGapBanner && html`
        <div class="kst-gap-banner" role="status" data-testid="kst-gap-banner">
          <strong>일부 실시간 출력이 서버 링 버퍼에서 누락되었습니다.</strong>
          <span>
            ${[
              termState.gap.missingCount && termState.gap.missingCount > 0
                ? `누락 이벤트 ${termState.gap.missingCount}건${termState.gap.missingFromSeq != null && termState.gap.missingToSeq != null ? ` (seq ${termState.gap.missingFromSeq}–${termState.gap.missingToSeq})` : ''}`
                : null,
              termState.gap.firstRetainedSeq != null && termState.gap.firstRetainedSeq > 1
                ? `초기 seq 1–${termState.gap.firstRetainedSeq - 1} 생략`
                : null,
              termState.gap.bytesDroppedStdout > 0
                ? `stdout ${termState.gap.bytesDroppedStdout.toLocaleString()}B 드롭`
                : null,
              termState.gap.bytesDroppedStderr > 0
                ? `stderr ${termState.gap.bytesDroppedStderr.toLocaleString()}B 드롭`
                : null,
            ].filter(Boolean).join(' · ')}
          </span>
        </div>
      `}

      <!-- Terminal viewport -->
      <div class="kst-viewport-wrap">
        <div
          ref=${viewportRef}
          class="kst-viewport mono"
          style=${{ height: `${HEIGHT_PRESET_PX[heightPreset]}px` }}
          data-testid="kst-viewport"
          onScroll=${handleViewportScroll}
        >
          ${termState.headDroppedCount > 0 && html`
            <div class="kst-head-drop" data-testid="kst-head-drop-notice">
              앞부분 ${termState.headDroppedCount.toLocaleString()}줄이 메모리 보호를 위해 생략되었습니다 (최대 ${MAX_TERMINAL_LINES.toLocaleString()}줄 유지).
            </div>
          `}

          ${filteredLines.length === 0
            ? html`
                <div class="kst-empty" data-testid="kst-empty-state">
                  ${termState.lines.length > 0
                    ? '현재 필터와 일치하는 출력 줄이 없습니다.'
                    : termState.noTask
                      ? '현재 실행 중인 샌드박스 명령이 없습니다. 실시간 스트림은 서버 시작 이후 실행된 Execute 출력을 표시하며, 이전 실행 기록은 아래 Tool Calls 테이블에서 확인할 수 있습니다.'
                      : connStatus === 'connecting'
                        ? '실시간 샌드박스 출력 스트림에 연결 중…'
                        : '표시할 실시간 출력이 없습니다. 아래 Tool Calls 테이블에서 저장된 Execute 호출 기록을 확인할 수 있습니다.'}
                </div>
              `
            : filteredLines.map((line) => {
                if (line.stream === 'cmd') {
                  return html`
                    <div key=${line.id} class="kst-line kst-line--cmd">
                      <span class="kst-prompt" aria-hidden="true">$</span>
                      <span class="kst-line-text">${stripAnsi(line.text)}</span>
                    </div>
                  `
                }
                if (line.stream === 'status') {
                  const tone = line.exitOk === true ? 'ok' : line.exitOk === false ? 'bad' : 'idle'
                  return html`
                    <div key=${line.id} class="kst-line kst-line--status">
                      <span class="kst-exit-pill" data-tone=${tone}>${line.text}</span>
                    </div>
                  `
                }
                return html`
                  <div
                    key=${line.id}
                    class=${`kst-line ${line.stream === 'stderr' ? 'kst-line--stderr' : line.stream === 'system' ? 'kst-line--system' : 'kst-line--stdout'}`}
                  >
                    <span class="kst-line-text">${renderAnsiSpans(line.text, ansiEnabled)}</span>
                  </div>
                `
              })}
        </div>

        ${!autoScroll && filteredLines.length > 0 && html`
          <button
            type="button"
            class="kst-jump-bottom"
            data-testid="kst-jump-bottom"
            onClick=${jumpToBottom}
          >
            ↓ 최신으로
          </button>
        `}
      </div>

      <!-- Default-collapsed Host Container / VM Logs disclosure -->
      <details
        class="ap-disclosure kst-host-logs"
        data-testid="kst-host-logs-disclosure"
        open=${hostLogsOpen}
        onToggle=${handleToggleHostLogs}
      >
        <summary class="ap-disclosure-trigger">
          <span>Host Container / VM Logs (tail 200)</span>
          <span class="kst-host-logs-hint mono">
            ${hostLogsData ? hostLogsData.state : '펼쳐서 조회'}
          </span>
        </summary>
        <div class="ap-disclosure-body kst-host-logs-body" data-testid="kst-host-logs-body">
          <div class="kst-host-logs-bar">
            <span class="kp-roster-sub">
              ${hostLogsData?.backend ? `backend: ${hostLogsData.backend}` : '로컬 호스트 런타임 로그'}
            </span>
            <button
              type="button"
              class="btn-ghost kst-btn"
              disabled=${hostLogsLoading}
              data-testid="kst-host-logs-refresh"
              onClick=${() => void loadHostLogs()}
            >
              ${hostLogsLoading ? '불러오는 중…' : '새로고침'}
            </button>
          </div>

          ${hostLogsError && html`
            <div class="kst-host-logs-msg" role="status">${hostLogsError}</div>
          `}

          ${hostLogsData && (hostLogsData.state === 'no_instance' || hostLogsData.state === 'no_local_stream') && html`
            <div class="kst-host-logs-msg" data-testid="kst-host-logs-reason" role="status">
              <strong class="mono">${hostLogsData.state}</strong>
              ${hostLogsData.reason
                ? ` · ${hostLogsData.reason}`
                : hostLogsData.state === 'no_instance'
                  ? ' · 현재 실행 중인 컨테이너/VM 인스턴스가 없습니다.'
                  : ' · 이 Keeper 프로필은 로컬 호스트 로그 스트림을 사용하지 않습니다.'}
            </div>
          `}

          ${hostLogsData && hostLogsData.instances.map((inst) => html`
            <div key=${inst.instanceId} class="kst-host-instance" data-testid="kst-host-log-instance">
              <div class="kst-host-instance-head mono">
                <span>${inst.instanceName}</span>
                ${inst.running !== null && html`
                  <span class="kp-pill" data-tone=${inst.running ? 'ok' : 'default'}>
                    ${inst.running ? 'running' : 'stopped'}
                  </span>
                `}
              </div>
              ${inst.error && html`<div class="kst-host-logs-msg">${inst.error}</div>`}
              ${inst.stdout && html`
                <div class="kst-host-stream-label">stdout</div>
                <pre class="kst-host-pre mono">${stripAnsi(inst.stdout)}</pre>
              `}
              ${inst.stderr && html`
                <div class="kst-host-stream-label kst-host-stream-label--err">stderr</div>
                <pre class="kst-host-pre kst-host-pre--err mono">${stripAnsi(inst.stderr)}</pre>
              `}
              ${!inst.stdout && !inst.stderr && !inst.error && html`
                <div class="kp-roster-sub">출력 없음</div>
              `}
            </div>
          `)}
        </div>
      </details>
    </section>
  `
}
