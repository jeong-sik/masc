import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { currentStoredTokenRevision } from '../api/core'
import { storedTokenRevision } from '../api/token-revision'
import { executionWorkspaceAuthority } from '../store'
import { asyncRequestSourceKey, fetchAsyncRequestStatus, fetchOriginalToolResult, ObservationReadError,
  type AsyncRequestIdentity, type AsyncRequestStatus, type OriginalToolResult } from '../api/composition-observation'

const json = (value: unknown) => JSON.stringify(value, null, 2)

/** No global result cache: the exact target, access revision and accepted
 * workspace object own each request, including its later page fetches. */
function asyncSource(result: AsyncRequestStatus): string | null {
  if (result.status === 'unavailable' || result.status === 'rejected') {
    throw new Error(`Request ${result.status}: ${result.status === 'unavailable' ? result.detail : result.reason}`)
  }
  return result.status === 'observed' ? asyncRequestSourceKey(result) : null
}
function originalSource(result: OriginalToolResult): string | null {
  return result.state === 'body' ? JSON.stringify([result.source_id, result.body_sha256]) : null
}
function originalRefreshFailure(result: OriginalToolResult): string | null {
  return result.state === 'body' ? null
    : `Original result ${result.state}${result.state === 'unavailable' ? `: ${result.reason}` : ''}`
}

function useOwnedObservation<T>(identity: string, fetcher: (signal: AbortSignal) => Promise<T>,
  project: (result: T) => string | null, isCurrent?: () => boolean,
  refreshFailure?: (result: T) => string | null) {
  const authRevision = storedTokenRevision.value
  const authority = executionWorkspaceAuthority.value
  const owner = useMemo(() => ({ identity, authRevision, authority }), [identity, authRevision, authority])
  const state = useSignal<{ owner: typeof owner; loading: boolean; result: T | null; error: string | null;
    resultStale: boolean } | null>(null)
  const controller = useRef<AbortController | null>(null)
  const generation = useRef(0)
  const parentCurrent = useRef(isCurrent)
  parentCurrent.current = isCurrent
  useEffect(() => () => { generation.current += 1; controller.current?.abort() }, [owner])
  const load = useCallback(async () => {
    const current = () => owner.authority !== null
      && currentStoredTokenRevision() === owner.authRevision
      && executionWorkspaceAuthority.peek() === owner.authority && (parentCurrent.current?.() ?? true)
    if (!current()) return
    controller.current?.abort()
    const requested = new AbortController()
    controller.current = requested
    const token = ++generation.current
    const previous = state.peek()?.owner === owner ? state.peek() : null
    state.value = { owner, loading: true, result: previous?.result ?? null, error: null,
      resultStale: previous?.result != null }
    try {
      const result = await fetcher(requested.signal)
      if (current() && !requested.signal.aborted && token === generation.current) {
        const failure = refreshFailure?.(result)
        // An initial pending/unavailable response remains visible as-is. Once
        // an exact source was verified, either state is a failed refresh.
        if (failure != null && previous?.result != null && project(previous.result) !== null) throw new Error(failure)
        state.value = { owner, loading: false, result, error: null, resultStale: false }
      }
    } catch (cause) {
      if (current() && !requested.signal.aborted && token === generation.current) {
        const previousSource = previous?.result == null ? null : project(previous.result)
        const changed = cause instanceof ObservationReadError && previousSource != null && cause.source !== previousSource
        state.value = { owner, loading: false, result: changed ? null : previous?.result ?? null,
          error: cause instanceof Error ? cause.message : String(cause),
          resultStale: !changed && previous?.result != null }
      }
    }
  }, [owner, fetcher, project, refreshFailure, state])
  return { load, available: authority !== null, state: state.value?.owner === owner ? state.value : null }
}

export function AsyncRequestDetails({ identity, isCurrent }: { identity: AsyncRequestIdentity; isCurrent: () => boolean }) {
  const { submitted_by, request_id, keeper_name } = identity
  const fetcher = useCallback((signal: AbortSignal) => fetchAsyncRequestStatus({ submitted_by, request_id, keeper_name }, { signal }),
    [submitted_by, request_id, keeper_name])
  const observation = useOwnedObservation(JSON.stringify([submitted_by, request_id, keeper_name]), fetcher, asyncSource, isCurrent)
  useEffect(() => { void observation.load() }, [observation.load])
  const result = observation.state?.result
  return html`<section class="mt-2 rounded border border-[var(--color-border)] p-2" aria-label="Exact async request">
    <div class="mono text-3xs">${submitted_by} · ${keeper_name} · ${request_id}</div>
    ${!observation.available ? html`<p role="status">Confirm the current workspace before reading the request.</p>` : html`
      <button type="button" class="ss-btn" disabled=${observation.state?.loading} onClick=${() => { void observation.load() }}>Refresh exact request</button>`}
    ${observation.state?.loading ? html`<p role="status">Loading exact request…</p>` : null}
    ${observation.state?.error ? html`<p role="alert">${observation.state.error}</p>` : null}
    ${observation.state?.resultStale ? html`<p role="status">The retained physical request snapshot is stale.</p>` : null}
    ${result?.status === 'observed' ? html`<div>Request state: ${String(result.request.status)}</div>
      <details><summary>Canonical request and continuation</summary><pre class="overflow-auto whitespace-pre-wrap text-3xs">${json(result.request)}</pre></details>`
      : result ? html`<p role="status">Request ${result.status}${result.status === 'unavailable' ? `: ${result.detail}` : result.status === 'rejected' ? `: ${result.reason}` : ''}</p>` : null}
  </section>`
}

export function OriginalToolResultInspector({ keeper, executionId }: { keeper: string; executionId: string }) {
  const fetcher = useCallback((signal: AbortSignal) => fetchOriginalToolResult(keeper, executionId, { signal }), [keeper, executionId])
  const observation = useOwnedObservation(JSON.stringify([keeper, executionId]), fetcher, originalSource, undefined, originalRefreshFailure)
  const result = observation.state?.result
  return html`<section class="mt-2 rounded border border-[var(--color-border)] p-2" aria-label="Original tool result">
    <div class="mono text-3xs">Original execution ${executionId}</div>
    ${!observation.available ? html`<p role="status">Confirm the current workspace before reading the original result.</p>` : html`
      <button type="button" class="ss-btn" disabled=${observation.state?.loading} onClick=${() => { void observation.load() }}>Read original result</button>`}
    ${observation.state?.loading ? html`<p role="status">Reading and verifying original result…</p>` : null}
    ${observation.state?.error ? html`<p role="alert">${observation.state.error}</p>` : null}
    ${observation.state?.resultStale ? html`<p role="status">The retained original-result snapshot is stale.</p>` : null}
    ${result?.state === 'body' ? html`<div class="mono text-3xs">source ${result.source_id} · SHA256 ${result.body_sha256} · ${result.recorded_bytes} recorded bytes · error ${String(result.is_error)}</div>
      <details><summary>Verified retained original bytes</summary><pre class="overflow-auto whitespace-pre-wrap text-3xs">${result.content}</pre></details>`
      : result ? html`<p role="status">Original result ${result.state}${result.state === 'unavailable' ? `: ${result.reason}` : ''}</p>` : null}
  </section>`
}
