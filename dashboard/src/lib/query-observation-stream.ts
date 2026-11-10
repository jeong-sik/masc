import { ApiRequestError, currentStoredTokenRevision, subscribeStoredTokenChanges } from '../api/core'
import { refreshDevTokenAfterAuthError } from '../api/dev-token'
import { TRANSPORT_RETRY_BASE_MS, TRANSPORT_RETRY_MAX_MS } from '../config/constants'
import { executionWorkspaceAuthority } from '../store'
import { subscribeDashboardObservation, type DashboardObservationTopic } from './observation-refresh'

export type QueryStreamReset = 'initial' | 'authority' | 'recovery'

export interface QueryStreamReader<Frame, Failure extends Error> {
  readonly onFrame: (frame: Frame) => void
  readonly onError: (error: Failure) => void
  readonly onReset: (reason: QueryStreamReset) => void
}

interface QueryStreamAdapter<Request, Frame, Failure extends Error> {
  readonly key: (request: Request) => string
  readonly recoveryTopics: readonly DashboardObservationTopic[]
  readonly read: (request: Request, previous: Frame | null, signal: AbortSignal,
    onFrame: (frame: Frame) => void, onActivity: () => void) => Promise<void>
  readonly merge: (previous: Frame | null, frame: Frame) => Frame
  readonly failure: (cause: unknown) => Failure
  readonly terminal: (cause: unknown) => boolean
}

/** Shared lifetime for read-only native query streams. The adapter owns the
 * wire projection; this owner fences credentials, authority and late frames. */
export function createQueryObservationStream<Request, Frame, Failure extends Error>(
  adapter: QueryStreamAdapter<Request, Frame, Failure>,
): (request: Request, reader: QueryStreamReader<Frame, Failure>) => () => void {
  type Reader = QueryStreamReader<Frame, Failure>
  interface Shared {
    readonly readers: Set<Reader>
    readonly close: () => void
    readonly replay: (reader: Reader) => void
  }
  const streams = new Map<string, Shared>()
  const open = (request: Request, readers: Set<Reader>): Shared => {
    let active = true
    let generation = 0
    let controller: AbortController | null = null
    let retryTimer: ReturnType<typeof setTimeout> | null = null
    let retryDelay = TRANSPORT_RETRY_BASE_MS
    let snapshot: Frame | null = null
    let error: Failure | null = null
    let recoveredTokenRevision: number | null = null
    let refused = false
    let authority = executionWorkspaceAuthority.peek()
    const clearRetry = () => {
      if (retryTimer !== null) clearTimeout(retryTimer)
      retryTimer = null
    }
    const connect = async () => {
      if (!active) return
      const owner = generation
      const readController = new AbortController()
      controller = readController
      const current = () => active && generation === owner && !readController.signal.aborted
      const activity = () => { if (current()) retryDelay = TRANSPORT_RETRY_BASE_MS }
      try {
        await adapter.read(request, snapshot, readController.signal, frame => {
          if (!current()) return
          snapshot = adapter.merge(snapshot, frame)
          error = null
          activity()
          for (const reader of [...readers]) reader.onFrame(frame)
        }, activity)
        if (current()) throw new Error('Observation stream ended before cancellation')
      } catch (cause) {
        if (!current()) return
        refused = cause instanceof ApiRequestError && (cause.status === 401 || cause.status === 403)
        if (cause instanceof ApiRequestError && cause.status === 401
          && recoveredTokenRevision !== currentStoredTokenRevision()) {
          recoveredTokenRevision = currentStoredTokenRevision()
          try { if (await refreshDevTokenAfterAuthError(cause.authErrorCode)) return }
          catch { /* Preserve the refused request's observation. */ }
          if (!current()) return
        }
        error = adapter.failure(cause)
        for (const reader of [...readers]) reader.onError(error)
        if (refused || adapter.terminal(cause)) return
        retryTimer = setTimeout(() => {
          retryTimer = null
          if (active && generation === owner) void connect()
        }, retryDelay)
        retryDelay = Math.min(retryDelay * 2, TRANSPORT_RETRY_MAX_MS)
      }
    }
    const restart = (reason: QueryStreamReset) => {
      if (!active) return
      generation += 1
      clearRetry()
      controller?.abort()
      snapshot = null
      error = null
      retryDelay = TRANSPORT_RETRY_BASE_MS
      refused = false
      for (const reader of [...readers]) reader.onReset(reason)
      void connect()
    }
    const unsubscribeToken = subscribeStoredTokenChanges(() => restart('authority'))
    const unsubscribeWorkspace = executionWorkspaceAuthority.subscribe(next => {
      if (authority === next) return
      authority = next
      restart('authority')
    })
    const recover = () => { if (!refused) restart('recovery') }
    const unsubscribeRecovery = subscribeDashboardObservation({ topics: adapter.recoveryTopics }, () => {}, recover)
    const recoverUnavailable = () => { if (error !== null && !refused) restart('recovery') }
    window.addEventListener('online', recover)
    window.addEventListener('focus', recoverUnavailable)
    const initialGeneration = generation
    queueMicrotask(() => {
      if (active && generation === initialGeneration) {
        for (const reader of [...readers]) reader.onReset('initial')
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
        reader.onReset('initial')
        if (snapshot !== null) reader.onFrame(snapshot)
        if (error !== null) reader.onError(error)
      },
    }
  }
  return (request, reader) => {
    const key = adapter.key(request)
    let stream = streams.get(key)
    if (stream === undefined) {
      stream = open(request, new Set([reader]))
      streams.set(key, stream)
    } else {
      stream.readers.add(reader)
      stream.replay(reader)
    }
    const owner = stream
    let released = false
    return () => {
      if (released) return
      released = true
      owner.readers.delete(reader)
      if (owner.readers.size === 0) {
        owner.close()
        if (streams.get(key) === owner) streams.delete(key)
      }
    }
  }
}
