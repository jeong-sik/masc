import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { currentStoredTokenRevision } from '../api/core'
import { storedTokenRevision } from '../api/token-revision'
import { executionWorkspaceAuthority } from '../store'
import { fetchAsyncRequestStatus, fetchOriginalToolResult,
  type AsyncRequestIdentity, type NestedReading } from '../api/composition-observation'

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
function useOwnedObservation<T>(identity: string, fetcher: (signal: AbortSignal) => Promise<T>, isCurrent?: () => boolean) {
  const authRevision = storedTokenRevision.value
  const authority = executionWorkspaceAuthority.value
  const owner = useMemo(() => ({ identity, authRevision, authority }), [identity, authRevision, authority])
  const state = useSignal<{ owner: typeof owner; loading: boolean; result: T | null; error: string | null } | null>(null)
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
    state.value = { owner, loading: true, result: null, error: null }
    try {
      const result = await fetcher(requested.signal)
      if (current() && !requested.signal.aborted && token === generation.current) state.value = { owner, loading: false, result, error: null }
    } catch (cause) {
      if (current() && !requested.signal.aborted && token === generation.current) state.value = {
        owner, loading: false, result: null, error: cause instanceof Error ? cause.message : String(cause),
      }
    }
  }, [owner, fetcher, state])
  return { load, available: authority !== null, state: state.value?.owner === owner ? state.value : null }
}

export function AsyncRequestDetails({ identity, isCurrent }: { identity: AsyncRequestIdentity; isCurrent: () => boolean }) {
  const { submitted_by, request_id, keeper_name } = identity
  const fetcher = useCallback((signal: AbortSignal) => fetchAsyncRequestStatus({ submitted_by, request_id, keeper_name }, { signal }),
    [submitted_by, request_id, keeper_name])
  const observation = useOwnedObservation(JSON.stringify([submitted_by, request_id, keeper_name]), fetcher, isCurrent)
  useEffect(() => { void observation.load() }, [observation.load])
  const result = observation.state?.result
  return html`<section class="mt-2 rounded border border-[var(--color-border)] p-2" aria-label="Exact async request">
    <div class="mono text-3xs">${submitted_by} · ${keeper_name} · ${request_id}</div>
    ${!observation.available ? html`<p role="status">Confirm the current workspace before reading the request.</p>` : html`
      <button type="button" class="ss-btn" disabled=${observation.state?.loading} onClick=${() => { void observation.load() }}>Refresh exact request</button>`}
    ${observation.state?.loading ? html`<p role="status">Loading exact request…</p>` : null}
    ${observation.state?.error ? html`<p role="alert">${observation.state.error}</p>` : null}
    ${result?.status === 'observed' ? html`<div>Request state: ${String(result.request.status)}</div>
      <details><summary>Canonical request and continuation</summary><pre class="overflow-auto whitespace-pre-wrap text-3xs">${json(result.request)}</pre></details>
      <${NestedExecutionView} reading=${result.nested} />`
      : result ? html`<p role="status">Request ${result.status}${result.status === 'unavailable' ? `: ${result.detail}` : result.status === 'rejected' ? `: ${result.reason}` : ''}</p>` : null}
  </section>`
}

export function OriginalToolResultInspector({ keeper, executionId }: { keeper: string; executionId: string }) {
  const fetcher = useCallback((signal: AbortSignal) => fetchOriginalToolResult(keeper, executionId, { signal }), [keeper, executionId])
  const observation = useOwnedObservation(JSON.stringify([keeper, executionId]), fetcher)
  const result = observation.state?.result
  return html`<section class="mt-2 rounded border border-[var(--color-border)] p-2" aria-label="Original tool result">
    <div class="mono text-3xs">Original execution ${executionId}</div>
    ${!observation.available ? html`<p role="status">Confirm the current workspace before reading the original result.</p>` : html`
      <button type="button" class="ss-btn" disabled=${observation.state?.loading} onClick=${() => { void observation.load() }}>Read original result</button>`}
    ${observation.state?.loading ? html`<p role="status">Reading and verifying original result…</p>` : null}
    ${observation.state?.error ? html`<p role="alert">${observation.state.error}</p>` : null}
    ${result?.state === 'body' ? html`<div class="mono text-3xs">source ${result.source_id} · SHA256 ${result.body_sha256} · ${result.recorded_bytes} recorded bytes · error ${String(result.is_error)}</div>
      <details><summary>Verified retained original bytes</summary><pre class="overflow-auto whitespace-pre-wrap text-3xs">${result.content}</pre></details>
      <${NestedExecutionView} reading=${result.nested} />`
      : result ? html`<p role="status">Original result ${result.state}${result.state === 'unavailable' ? `: ${result.reason}` : ''}</p>` : null}
  </section>`
}
