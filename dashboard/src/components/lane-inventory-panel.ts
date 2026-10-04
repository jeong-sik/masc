import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { fetchLaneInventory, type LaneInventory, type LaneInventoryRow } from '../api/lane-inventory'
import { executionWorkspaceAuthority, refreshExecution, type ExecutionWorkspaceAuthority } from '../store'
import { RouteLink } from './common/route-link'

const button = 'rounded border border-[var(--color-border-default)] px-3 py-2 disabled:opacity-50'
function stateLines(row: LaneInventoryRow, snapshot: LaneInventory): string[] {
  const state = row.state
  switch (state.kind) {
    case 'exact': {
      const selection = row.selection
      const lane = selection.kind === 'exact'
        ? snapshot.exact_snapshot.lanes.find(item => item.laneId === selection.lane_id) : undefined
      const config = state.configuration
      return [config.kind === 'configured'
        ? `${config.admitted_slots.length} HTTP · ${config.cli_slots.length} CLI admitted`
        : config.kind === 'off' ? 'Off · candidate configuration retained; accepted runs finish'
          : `${config.kind}: ${config.detail}`,
      ...(lane ? [`${lane.status} · ${lane.runningCount} running · ${lane.retainedRunCount} retained runs`] : [])]
    }
    case 'browser_clients': return [`${state.connected_clients} connected clients`]
    case 'browser_executor': return [state.registered ? 'Executor registered · session activity unverified' : 'Executor not registered']
    case 'machine': return [{ no_screen: 'No screen observed', stable: 'Stable screen published', running: 'Machine running' }[state.publication]]
    case 'package': {
      const declared = state.declaration
      const desired = declared === null ? 'Manual attachment'
        : declared.kind === 'valid' ? declared.enabled ? 'Configured on'
          : state.instances.length ? 'Off requested · cleanup unconfirmed' : 'Configured off · no worker observed'
          : declared.kind === 'invalid' ? `Invalid declaration: ${declared.messages.join('; ')}`
            : declared.kind === 'absent' ? 'Declaration absent · cleanup unconfirmed' : 'Declaration not observed'
      return [desired, ...state.instances.map(instance => `${instance.presence} ${instance.phase.kind} · ${instance.instance_id}`
        + (instance.phase.kind === 'failed' ? ` · ${instance.phase.message}` : ''))]
    }
  }
}

function LaneDetails({ row, snapshot }: { row: LaneInventoryRow; snapshot: LaneInventory }) {
  const selection = row.selection
  return html`<section aria-label=${`Details for ${row.label}`} class="rounded border border-[var(--color-border-default)] p-4 space-y-3">
    <h3 class="font-semibold">${row.label}</h3><p>${row.purpose}</p><code class="break-all">${row.id}</code>
    ${stateLines(row, snapshot).map(line => html`<p>${line}</p>`)}
    ${selection.kind === 'exact' ? html`<div class="flex flex-wrap gap-3">
      <${RouteLink} tab="monitoring" params=${{ section: 'internal-agents' }}>Exact runs and diagnostics<//>
      <${RouteLink} tab="monitoring" params=${{ section: 'runtime', view: 'config' }}>Runtime settings · Lane candidates<//>
    </div>` : selection.kind === 'declaration' || selection.kind === 'manual_instance' ? html`<div class="space-y-2">
      ${selection.kind === 'declaration' ? html`<p class="break-all">${selection.source_path}</p>` : html`<p>Incarnation: ${selection.incarnation}</p>`}
      <${RouteLink} tab="monitoring" params=${{ section: 'lane-addons' }}>Manage package declarations and retained observations<//>
    </div>` : html`<p>Manage this ${selection.kind === 'browser' ? 'Browser backend' : 'machine'} through its TUI detail or operator tools.</p>`}
    <details><summary>Observed configuration and worker details</summary>
      <pre class="whitespace-pre-wrap break-all">${JSON.stringify(row.state, null, 2)}</pre>
    </details>
    ${selection.kind === 'exact' ? html`<details><summary>Exact retained reading</summary>
      <pre class="whitespace-pre-wrap break-all">${JSON.stringify(snapshot.exact_snapshot.lanes.find(lane => lane.laneId === selection.lane_id), null, 2)}</pre>
    </details>` : null}
  </section>`
}

/** The operator inventory is a separate read; displaying it never starts workers. */
export function LaneInventoryPanel() {
  const authority = executionWorkspaceAuthority.value
  const [reading, setReading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [received, setReceived] = useState<{ authority: ExecutionWorkspaceAuthority; value: LaneInventory } | null>(null)
  const [verifying, setVerifying] = useState(false)
  const [query, setQuery] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const request = useRef<AbortController | null>(null)
  const details = useRef<HTMLDivElement | null>(null)
  const snapshot = received?.authority === authority ? received.value : null
  async function verifyWorkspace() {
    const requested = executionWorkspaceAuthority.peek()
    setVerifying(true); setError(null)
    try { await refreshExecution({ force: true }) }
    catch (failure) {
      if (executionWorkspaceAuthority.peek() === requested) setError(String(failure))
    } finally { setVerifying(false) }
  }
  async function refresh() {
    request.current?.abort()
    const requestedAuthority = executionWorkspaceAuthority.peek()
    if (requestedAuthority === null) return
    const controller = new AbortController(); request.current = controller
    setReading(true); setError(null)
    try {
      const value = await fetchLaneInventory(controller.signal)
      if (!controller.signal.aborted && executionWorkspaceAuthority.peek() === requestedAuthority) {
        setReceived({ authority: requestedAuthority, value })
      }
    } catch (failure) {
      if (!controller.signal.aborted && executionWorkspaceAuthority.peek() === requestedAuthority) {
        setError(failure instanceof Error ? failure.message : String(failure))
      }
    } finally {
      if (!controller.signal.aborted && executionWorkspaceAuthority.peek() === requestedAuthority) setReading(false)
    }
  }
  useEffect(() => {
    request.current?.abort(); setSelected(null); setQuery(''); setError(null); setReading(false)
    if (authority !== null) void refresh()
    return () => request.current?.abort()
  }, [authority])
  const search = query.trim().toLocaleLowerCase()
  const rows = snapshot?.rows.filter(row => [row.id, row.label, row.purpose].some(value => value.toLocaleLowerCase().includes(search))) ?? []
  const detail = snapshot?.rows.find(row => row.id === selected)
  useEffect(() => { if (selected !== null) details.current?.focus() }, [selected])
  return html`<section aria-label="All Lanes" class="space-y-4">
    <header class="flex flex-wrap items-center justify-between gap-3"><div><h2 class="text-xl font-semibold">All Lanes</h2>
      <p>Built-in Lane kinds, package declarations and manual workers.</p></div>
      <button class=${button} onClick=${refresh} disabled=${reading || authority === null}>Refresh Lanes</button></header>
    ${authority === null ? html`<div><p role="status">Verify the current workspace to read its Lanes.</p>
      <button class=${button} onClick=${verifyWorkspace} disabled=${verifying}>${verifying ? 'Verifying workspace…' : 'Verify workspace'}</button></div>` : null}
    ${reading ? html`<p role="status">Reading Lane inventory…</p>` : null}
    ${error ? html`<p role="alert">${error}${snapshot ? ' · Showing the previous reading; current state is unverified.' : ''}</p>` : null}
    ${snapshot ? html`<div class="space-y-2">
      <p>Observed ${new Date(snapshot.observed_at * 1000).toISOString()} · ${snapshot.rows.length} inventory rows</p>
      <p>Package read: ${snapshot.package_read.complete ? 'complete' : 'incomplete'} · ${snapshot.package_read.owner_present ? 'manager present' : 'manager not observed'}</p>
      <p>Exact run reading: ${snapshot.exact_snapshot.exactRunProjectionCount} of ${snapshot.exact_snapshot.exactRunSourceTotal}${snapshot.exact_snapshot.exactRunProjectionTruncated ? ' · truncated' : ''}</p>
      ${snapshot.package_read.issues.map(issue => html`<p role="alert" class="break-all">${issue.source_path}: ${issue.message}</p>`)}
    </div>` : null}
    <label class="block">Find a Lane<input class="block w-full rounded border bg-transparent p-2" type="search" value=${query}
      onInput=${(event: Event) => setQuery((event.currentTarget as HTMLInputElement).value)} /></label>
    ${snapshot && detail ? html`<div ref=${details} tabIndex=${-1}><${LaneDetails} row=${detail} snapshot=${snapshot} /></div>`
      : selected && snapshot ? html`<p role="status">The selected Lane is absent from this reading.</p>` : null}
    ${snapshot && !rows.length ? html`<p>No Lanes match this search.</p>` : null}
    <div class="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-3">
      ${snapshot && rows.map(row => html`<article key=${row.id} class="min-w-0 rounded border border-[var(--color-border-default)] p-4 space-y-2">
        <h3 class="font-semibold">${row.label}</h3><p class="break-all">${row.id}</p><p>${row.purpose}</p>
        ${stateLines(row, snapshot).map(line => html`<p class="break-all">${line}</p>`)}
        <button class=${button} aria-pressed=${selected === row.id} onClick=${() => setSelected(row.id)}>Inspect ${row.label}</button>
      </article>`)}
    </div>
  </section>`
}
