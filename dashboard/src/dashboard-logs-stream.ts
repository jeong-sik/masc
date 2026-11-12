import {
  ApiRequestError, currentStoredTokenRevision, subscribeStoredTokenChanges,
} from './api/core'
import { refreshDevTokenAfterAuthError } from './api/dev-token'
import { logsPath, type LogsData, type LogsRequest } from './api/dashboard-logs'
import { LogsSchemaDriftError, type LogsStreamFrame } from './api/schemas/logs'
import { LogsStreamError, readDashboardLogsStream } from './api/dashboard-logs-stream'
import { TRANSPORT_RETRY_BASE_MS, TRANSPORT_RETRY_MAX_MS } from './config/constants'
import { subscribeDashboardObservation } from './lib/observation-refresh'
import { executionWorkspaceAuthority } from './store'

interface LogReader {
  readonly onFrame: (frame: LogsStreamFrame) => void
  readonly onError: (error: LogsStreamError) => void
  readonly onReset: () => void
}

interface SharedLogStream {
  readonly readers: Set<LogReader>
  readonly close: () => void
  readonly replay: (reader: LogReader) => void
}

const streams = new Map<string, SharedLogStream>()

function appendSnapshot(previous: LogsData | null, frame: LogsStreamFrame): LogsData {
  if (frame.reset || previous === null) return frame.data
  const entries = new Map(previous.entries.map(entry => [entry.seq, entry]))
  for (const entry of frame.data.entries) entries.set(entry.seq, entry)
  return {
    ...frame.data,
    entries: [...entries.values()].filter(entry => entry.seq >= frame.data.ring.startSeq)
      .sort((a, b) => b.seq - a.seq).slice(0, frame.limit),
  }
}

function openSharedStream(request: LogsRequest, readers: Set<LogReader>): SharedLogStream {
  let active = true
  let generation = 0
  let controller: AbortController | null = null
  let retryTimer: ReturnType<typeof setTimeout> | null = null
  let retryDelay = TRANSPORT_RETRY_BASE_MS
  let snapshot: LogsStreamFrame | null = null
  let error: LogsStreamError | null = null
  let cursor: number | undefined
  let recoveredTokenRevision: number | null = null
  let refused = false
  let authority = executionWorkspaceAuthority.peek()

  const clearRetry = () => {
    if (retryTimer !== null) clearTimeout(retryTimer)
    retryTimer = null
  }
  const publishError = (cause: unknown) => {
    error = cause instanceof LogsStreamError ? cause
      : new LogsStreamError(cause instanceof Error ? cause.message : String(cause))
    for (const reader of [...readers]) reader.onError(error)
  }
  const connect = async () => {
    const owner = generation
    const readController = new AbortController()
    controller = readController
    const current = () => active && generation === owner && !readController.signal.aborted
    try {
      await readDashboardLogsStream({ ...request, sinceSeq: cursor }, readController.signal, frame => {
        if (!current()) return
        cursor = frame.data.ring.total > 0 ? frame.data.ring.total - 1 : undefined
        snapshot = { ...frame, reset: true, data: appendSnapshot(snapshot?.data ?? null, frame) }
        error = null
        retryDelay = TRANSPORT_RETRY_BASE_MS
        for (const reader of [...readers]) reader.onFrame(frame)
      })
    } catch (cause) {
      if (!current()) return
      refused = cause instanceof ApiRequestError && (cause.status === 401 || cause.status === 403)
      if (cause instanceof ApiRequestError && cause.status === 401
        && recoveredTokenRevision !== currentStoredTokenRevision()) {
        recoveredTokenRevision = currentStoredTokenRevision()
        try {
          // A changed credential opens a new generation through the token
          // listener. The refused generation never opens a second request.
          if (await refreshDevTokenAfterAuthError(cause.authErrorCode)) return
        } catch { /* The original refusal remains the observation. */ }
        if (!current()) return
      }
      publishError(cause)
      if (refused || cause instanceof LogsSchemaDriftError || cause instanceof LogsStreamError) return
      retryTimer = setTimeout(() => {
        retryTimer = null
        if (active && generation === owner) void connect()
      }, retryDelay)
      retryDelay = Math.min(retryDelay * 2, TRANSPORT_RETRY_MAX_MS)
    }
  }
  const restart = () => {
    generation += 1
    clearRetry()
    controller?.abort()
    cursor = undefined
    snapshot = null
    error = null
    retryDelay = TRANSPORT_RETRY_BASE_MS
    refused = false
    for (const reader of [...readers]) reader.onReset()
    void connect()
  }
  const unsubscribeToken = subscribeStoredTokenChanges(restart)
  const unsubscribeWorkspace = executionWorkspaceAuthority.subscribe(next => {
    if (authority === next) return
    authority = next
    restart()
  })
  const recover = () => { if (!refused) restart() }
  const unsubscribeRecovery = subscribeDashboardObservation({ topics: ['logs'] }, () => {}, recover)
  const recoverUnavailable = () => { if (error !== null && !refused) restart() }
  window.addEventListener('online', recover)
  window.addEventListener('focus', recoverUnavailable)
  const initialGeneration = generation
  queueMicrotask(() => {
    if (active && generation === initialGeneration) {
      for (const reader of [...readers]) reader.onReset()
      void connect()
    }
  })
  return {
    readers,
    close: () => {
      active = false
      generation += 1
      clearRetry()
      controller?.abort()
      unsubscribeToken()
      unsubscribeWorkspace()
      unsubscribeRecovery()
      window.removeEventListener('online', recover)
      window.removeEventListener('focus', recoverUnavailable)
    },
    replay: reader => {
      reader.onReset()
      if (snapshot !== null) reader.onFrame(snapshot)
      if (error !== null) reader.onError(error)
    },
  }
}

/** Identical mounted log queries share one native server stream. Last release
 * retires its fetch, parser, recovery listener and pending reconnect. */
export function subscribeDashboardLogsStream(request: LogsRequest, reader: LogReader): () => void {
  const key = logsPath(request, true)
  let stream = streams.get(key)
  if (stream === undefined) {
    stream = openSharedStream(request, new Set([reader]))
    streams.set(key, stream)
  } else {
    stream.readers.add(reader)
    stream.replay(reader)
  }
  const owner = stream
  return () => {
    owner.readers.delete(reader)
    if (owner.readers.size === 0) { owner.close(); if (streams.get(key) === owner) streams.delete(key) }
  }
}
