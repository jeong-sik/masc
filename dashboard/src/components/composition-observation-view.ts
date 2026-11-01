import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { currentStoredTokenRevision } from '../api/core'
import { storedTokenRevision } from '../api/token-revision'
import { executionWorkspaceAuthority } from '../store'
import { asyncRequestSourceKey, fetchAsyncRequestStatus, fetchOriginalToolResult, ObservationReadError,
  type AsyncRequestIdentity, type AsyncRequestStatus, type NestedReading, type OriginalToolResult } from '../api/composition-observation'

const json = (value: unknown) => JSON.stringify(value, null, 2)

/** Actual retained child observations, shared by async status and original
 * ToolResult reads. A declaration, admission or deferred result is not success. */
export function NestedExecutionView({ reading }: { reading: NestedReading }) {
  switch (reading.kind) {
    case 'absent': return html`<p class="ss-muted">No nested execution metadata in this retained result.</p>`
    case 'invalid': return html`<p role="alert">Nested execution evidence is invalid: ${reading.detail}</p>`
    case 'stored': return html`<p role="status">Nested result manifest ${reading.reference.sha256} has not been verified.</p>`
    case 'observed': return html`<section aria-label="Nested execution results" class="grid gap-2">
      <strong>Nested execution results · ${reading.children.length} children</strong>
      ${reading.children.map((child, index) => html`<article key=${index} class="rounded border border-[var(--color-border)] p-2" data-testid="nested-execution-child">
        <div><strong>${child.alias}</strong> · ${child.execution} · ${child.disposition}</div>
        <div class="mono text-3xs">${child.reference.identity.source_id}/${child.reference.identity.package_id} · ${child.reference.identity.name} · revision ${child.reference.content_revision}</div>
        <div>Admission: ${child.admission.kind}</div>
        ${child.admission.kind === 'recorded' ? html`<details><summary>Original admission receipt · ${child.admission.tool_use_id}</summary>
          <div class="mono text-3xs">frame ${child.admission.frame_sha256}</div>
          <pre class="overflow-auto whitespace-pre-wrap text-3xs">${json(child.admission.activation)}</pre></details>`
          : child.admission.kind === 'rejected' ? html`<pre class="whitespace-pre-wrap text-3xs">${json(child.admission.rejection)}</pre>` : null}
        <details><summary>Declared child arguments</summary><pre class="whitespace-pre-wrap text-3xs">${json(child.arguments)}</pre></details>
        ${child.cause !== null ? html`<div>Cause<pre class="whitespace-pre-wrap text-3xs">${json(child.cause)}</pre></div>` : null}
        ${child.nodes.map(node => html`<div key=${node.node_id} class="mt-1 text-3xs">
          <span class="mono">${node.node_id}</span> · ${'phase' in node.origin ? node.origin.phase : `child node ${node.origin.source}`}
          · ${node.disposition ?? 'not settled'}${node.tool_use_id === null ? '' : ` · occurrence ${node.tool_use_id}`}
          ${node.effect_disposition === null ? null : html`<div>Effect evidence: ${node.effect_disposition}</div>`}
          ${node.validation_error === null ? null : html`<pre class="whitespace-pre-wrap">${json(node.validation_error)}</pre>`}
        </div>`)}
        ${child.exports.map(output => html`<div key=${output.name} class="mt-1 text-3xs">
          <strong>Output ${output.name}</strong> · ${output.node_id} ${output.pointer} · ${output.value.available ? 'available' : 'unavailable'}
          <pre class="overflow-auto whitespace-pre-wrap">${json(output.value.available ? output.value.value : output.value.error)}</pre>
        </div>`)}
      </article>`)}
    </section>`
  }
}

/** No global result cache: the exact target, access revision and accepted
 * workspace object own each request, including its later page/blob fetches. */
type NestedSource = { source: string; reading: NestedReading }
type VerifiedChildren = { source: string; reading: Extract<NestedReading, { kind: 'observed' }> }
function asyncSource(result: AsyncRequestStatus): NestedSource | null {
  if (result.status === 'unavailable' || result.status === 'rejected') {
    throw new Error(`Request ${result.status}: ${result.status === 'unavailable' ? result.detail : result.reason}`)
  }
  return result.status === 'observed' ? { source: asyncRequestSourceKey(result), reading: result.nested } : null
}
function originalSource(result: OriginalToolResult): NestedSource | null {
  return result.state === 'body' ? { source: JSON.stringify([result.source_id, result.body_sha256]), reading: result.nested } : null
}
function originalRefreshFailure(result: OriginalToolResult): string | null {
  return result.state === 'body' ? null
    : `Original result ${result.state}${result.state === 'unavailable' ? `: ${result.reason}` : ''}`
}

function useOwnedObservation<T>(identity: string, fetcher: (signal: AbortSignal) => Promise<T>,
  project: (result: T) => NestedSource | null, isCurrent?: () => boolean,
  refreshFailure?: (result: T) => string | null) {
  const authRevision = storedTokenRevision.value
  const authority = executionWorkspaceAuthority.value
  const owner = useMemo(() => ({ identity, authRevision, authority }), [identity, authRevision, authority])
  const state = useSignal<{ owner: typeof owner; loading: boolean; result: T | null; error: string | null;
    good: VerifiedChildren | null; stale: boolean; resultStale: boolean } | null>(null)
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
    const good = previous?.good ?? null
    state.value = { owner, loading: true, result: previous?.result ?? null, error: null,
      good, stale: good !== null, resultStale: previous?.result != null }
    try {
      const result = await fetcher(requested.signal)
      if (current() && !requested.signal.aborted && token === generation.current) {
        const failure = refreshFailure?.(result)
        // An initial pending/unavailable response remains visible as-is. Once
        // an exact source was verified, either state is a failed refresh.
        if (failure != null && previous?.result != null && project(previous.result) !== null) throw new Error(failure)
        const source = project(result)
        const retained = source?.reading.kind === 'observed' ? { source: source.source, reading: source.reading }
          : source?.reading.kind === 'invalid' && good?.source === source.source ? good : null
        state.value = { owner, loading: false, result, error: null, good: retained,
          stale: source?.reading.kind === 'invalid' && retained !== null, resultStale: false }
      }
    } catch (cause) {
      if (current() && !requested.signal.aborted && token === generation.current) {
        const previousSource = previous?.result == null ? null : project(previous.result)?.source
        const changed = cause instanceof ObservationReadError && previousSource != null && cause.source !== previousSource
        state.value = { owner, loading: false, result: changed ? null : previous?.result ?? null,
          error: cause instanceof Error ? cause.message : String(cause), good: changed ? null : good,
          stale: !changed && good !== null, resultStale: !changed && previous?.result != null }
      }
    }
  }, [owner, fetcher, project, refreshFailure, state])
  return { load, available: authority !== null, state: state.value?.owner === owner ? state.value : null }
}

function RetainedNestedView({ reading, good, stale }: { reading: NestedReading; good: VerifiedChildren | null; stale: boolean }) {
  return html`
    ${stale && good ? html`<p role="status">Showing last verified nested evidence for this exact source; the current read is pending, failed or invalid.</p>` : null}
    ${stale && good && reading.kind === 'invalid' ? html`<${NestedExecutionView} reading=${reading} />` : null}
    <${NestedExecutionView} reading=${stale && good ? good.reading : reading} />
  `
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
      <details><summary>Canonical request and continuation</summary><pre class="overflow-auto whitespace-pre-wrap text-3xs">${json(result.request)}</pre></details>
      <${RetainedNestedView} reading=${result.nested} good=${observation.state?.good ?? null} stale=${observation.state?.stale ?? false} />`
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
      <details><summary>Verified retained original bytes</summary><pre class="overflow-auto whitespace-pre-wrap text-3xs">${result.content}</pre></details>
      <${RetainedNestedView} reading=${result.nested} good=${observation.state?.good ?? null} stale=${observation.state?.stale ?? false} />`
      : result ? html`<p role="status">Original result ${result.state}${result.state === 'unavailable' ? `: ${result.reason}` : ''}</p>` : null}
  </section>`
}
