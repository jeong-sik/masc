import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import {
  attachLaneAddon, detachLaneAddon, fetchLaneAddons, fetchLaneAddonSlice,
  observeLaneAddon, preserveLaneAddonEvidence,
  fetchLaneAddonAction, requestLaneAddonAction,
  type LaneAddonSnapshot, type LaneAddonSlice, type LaneAddonInstance,
  type LaneAddonActionReceipt, type LaneAddonActionRequest,
} from '../api/lane-addons'
import { isRecord } from './common/normalize'
import { LaneAddonsTimeline, formatLaneTime } from './lane-addons-timeline'
import { LaneDeclarationEditor, type LaneDeclarationEditorTarget } from './lane-declaration-editor'
import type { LaneDeclarationDocument } from '../api/lane-declarations'

const inputClass = 'border border-[var(--border)] rounded px-2 py-1 bg-transparent'
const buttonClass = `${inputClass} cursor-pointer disabled:opacity-50`
const message = (error: unknown) => error instanceof Error ? error.message : String(error)

type TrackedAction = {
  request: LaneAddonActionRequest
  receipt: LaneAddonActionReceipt | null
  submitting: boolean
  checking: boolean
  error: string | null
}
const actionStates: Record<LaneAddonActionReceipt['state'], string> = {
  queued: 'Queued', running: 'Running', confirmed: 'Package confirmed returned result',
  failed_before_effect: 'Failed before effect', outcome_unknown: 'Outcome unknown',
}
const instanceBinding = (item: LaneAddonInstance) => `${item.instance_id}:${item.incarnation}`

/** Receipts remain bound to their original instance even after replacement or detach. */
function LaneAddonActions({ instances }: { instances: readonly LaneAddonInstance[] }) {
  const [binding, setBinding] = useState('')
  const [input, setInput] = useState('{}')
  const [error, setError] = useState<string | null>(null)
  const [requests, setRequests] = useState<TrackedAction[]>([])
  const submitting = useRef(false)
  const statusReads = useRef(new Map<string, AbortController>())
  const mounted = useRef(true)
  useEffect(() => {
    mounted.current = true
    const reads = statusReads.current
    return () => { mounted.current = false; for (const read of reads.values()) read.abort() }
  }, [])
  const capable = instances.filter(item => item.action_schema !== null)
  const selected = capable.find(item => instanceBinding(item) === binding)
  const available = selected !== undefined && selected.phase.kind !== 'detaching' && selected.phase.kind !== 'detached'
  const properties = selected?.action_schema?.properties
  const actionSchema = isRecord(properties) ? properties.action : selected?.action_schema

  function update(requestId: string, change: Partial<TrackedAction>) {
    if (mounted.current) setRequests(items => items.map(item => item.request.request_id === requestId ? { ...item, ...change } : item))
  }
  async function submit() {
    if (!selected || !available || submitting.current) return
    setError(null)
    let action: unknown
    try {
      action = JSON.parse(input)
      if (!isRecord(action)) throw new Error('Action must be a JSON object matching the advertised schema.')
    } catch (err) { setError(message(err)); return }
    const request: LaneAddonActionRequest = {
      instance_id: selected.instance_id, expected_incarnation: selected.incarnation,
      request_id: crypto.randomUUID(), action,
    }
    submitting.current = true
    setRequests(items => [...items, { request, receipt: null, submitting: true, checking: false, error: null }])
    try { update(request.request_id, { receipt: await requestLaneAddonAction(request) }) }
    catch (err) { update(request.request_id, { error: message(err) }) }
    finally { submitting.current = false; update(request.request_id, { submitting: false }) }
  }
  async function check(request: LaneAddonActionRequest) {
    if (statusReads.current.has(request.request_id)) return
    const controller = new AbortController()
    statusReads.current.set(request.request_id, controller)
    update(request.request_id, { checking: true, error: null })
    try {
      const receipt = await fetchLaneAddonAction(request, controller.signal)
      if (!controller.signal.aborted) update(request.request_id, { receipt })
    } catch (err) {
      if (!controller.signal.aborted) update(request.request_id, { error: message(err) })
    } finally {
      statusReads.current.delete(request.request_id)
      if (!controller.signal.aborted) update(request.request_id, { checking: false })
    }
  }
  if (capable.length === 0 && requests.length === 0) return null
  return html`<section class="space-y-3" aria-label="Package actions">
    <h3 class="font-semibold">Package actions</h3>
    <p>Submit an action advertised by an installed package. Observations and Keeper work continue independently.</p>
    ${capable.length > 0 && html`<form class="space-y-2" onSubmit=${(event: Event) => { event.preventDefault(); void submit() }}>
      <label>Action instance <select class=${inputClass} value=${binding} onChange=${(event: Event) => { setBinding((event.target as HTMLSelectElement).value); setInput('{}'); setError(null) }}>
        <option value="">Select an installed package</option>
        ${capable.map(item => html`<option key=${instanceBinding(item)} value=${instanceBinding(item)} disabled=${item.phase.kind === 'detaching' || item.phase.kind === 'detached'}>
          ${item.title} · ${item.run_id} · ${item.instance_id}
        </option>`)}
      </select></label>
      ${binding !== '' && !available && html`<p role="status">The selected instance is no longer available for new actions. Select an active instance.</p>`}
      ${selected && html`<div class="space-y-2">
        <p class="break-all">Target: ${selected.instance_id} · incarnation ${selected.incarnation}</p>
        <details><summary>Advertised action schema</summary><pre class="whitespace-pre-wrap break-all">${JSON.stringify(actionSchema, null, 2)}</pre></details>
        <label class="block">Action JSON <textarea class=${`${inputClass} block w-full font-mono`} rows=${5} value=${input}
          onInput=${(event: Event) => setInput((event.target as HTMLTextAreaElement).value)} /></label>
        <button class=${buttonClass} disabled=${!available || requests.some(item => item.submitting)} type="submit">Send new request</button>
      </div>`}
    </form>`}
    ${error && html`<p role="alert">${error}</p>`}
    ${requests.map(item => html`<article key=${item.request.request_id} class="border border-[var(--border)] rounded p-3 space-y-2" aria-label=${`Action request ${item.request.request_id}`}>
      <p role="status">${item.submitting ? 'Awaiting acceptance receipt' : item.error ? 'Current action status unavailable'
        : item.receipt ? actionStates[item.receipt.state] : 'Action status unknown'}</p>
      <p class="break-all">Request ID: ${item.request.request_id}</p>
      <p class="break-all">Target: ${item.request.instance_id} · incarnation ${item.request.expected_incarnation}</p>
      ${item.error && html`<p role="alert">${item.error} The request may have been accepted. Check this request ID before sending another action.</p>`}
      ${item.receipt && html`<div>
        ${item.error && html`<p>Last recorded status: ${actionStates[item.receipt.state]}</p>`}
        <p>Requester: ${item.receipt.requester} · executor: ${item.receipt.executor ?? 'unknown'}</p>
        ${item.receipt.detail !== null && html`<p>${item.receipt.detail}</p>`}
        ${item.receipt.state === 'confirmed' && html`<p>The package returned this result. Completion of the surrounding task requires separate evidence.</p>`}
        ${item.receipt.result !== null && html`<pre class="whitespace-pre-wrap break-all" aria-label="Package returned result">${JSON.stringify(item.receipt.result, null, 2)}</pre>`}
      </div>`}
      <button type="button" class=${buttonClass} disabled=${item.submitting || item.checking} onClick=${() => check(item.request)}>${item.checking ? 'Checking request status…' : 'Check request status'}</button>
      <details><summary>Submitted action and receipt</summary><pre class="whitespace-pre-wrap break-all">${JSON.stringify({ request: item.request, receipt: item.receipt }, null, 2)}</pre></details>
    </article>`)}
  </section>`
}

/** This component owns its reads. A slow package never joins the fleet refresh. */
export function LaneAddonsPanel() {
  const [editor, setEditor] = useState<LaneDeclarationEditorTarget | null>(null)
  const [newEditorKey, setNewEditorKey] = useState(() => crypto.randomUUID())
  function editToml(sourcePath: string | null) {
    setEditor({ key: sourcePath ?? newEditorKey, sourcePath })
  }
  const [snapshot, setSnapshot] = useState<LaneAddonSnapshot | null>(null)
  const [slice, setSlice] = useState<LaneAddonSlice | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [receipt, setReceipt] = useState<unknown>(null)
  const [reading, setReading] = useState(false)
  const [manifest, setManifest] = useState('')
  const [run, setRun] = useState('')
  const [binding, setBinding] = useState('{}')
  const [lane, setLane] = useState('')
  const [since, setSince] = useState('')
  const [until, setUntil] = useState('')
  const [instance, setInstance] = useState('')
  const [keeper, setKeeper] = useState('')
  const [selected, setSelected] = useState<string[]>([])
  const reads = useRef<AbortController | null>(null)
  const mounted = useRef(true)

  async function refresh() {
    reads.current?.abort()
    const controller = new AbortController()
    reads.current = controller
    setReading(true)
    setError(null)
    try {
      const result = await fetchLaneAddons(controller.signal)
      if (!controller.signal.aborted && mounted.current) setSnapshot(result)
    } catch (err) {
      if (!controller.signal.aborted && mounted.current) setError(message(err))
    } finally {
      if (!controller.signal.aborted && mounted.current) setReading(false)
    }
  }
  useEffect(() => {
    mounted.current = true
    void refresh()
    return () => { mounted.current = false; reads.current?.abort() }
  }, [])

  async function act(action: () => Promise<unknown>) {
    setError(null)
    try {
      const result = await action()
      if (!mounted.current) return
      setReceipt(result)
      await refresh()
    } catch (err) {
      if (mounted.current) setError(message(err))
    }
  }
  async function query() {
    const from = since === '' ? undefined : Number(since)
    const to = until === '' ? undefined : Number(until)
    if ((from !== undefined && !Number.isFinite(from)) || (to !== undefined && !Number.isFinite(to))
      || (from !== undefined && to !== undefined && from > to)) {
      setError('Use finite Unix seconds with since ≤ until.')
      return
    }
    reads.current?.abort()
    const controller = new AbortController()
    reads.current = controller
    setReading(true)
    setError(null)
    try {
      const result = await fetchLaneAddonSlice({ run_id: run, lane_id: lane, since: from, until: to }, controller.signal)
      if (!controller.signal.aborted && mounted.current) { setSlice(result); setSelected([]) }
    } catch (err) {
      if (!controller.signal.aborted && mounted.current) setError(message(err))
    } finally {
      if (!controller.signal.aborted && mounted.current) setReading(false)
    }
  }
  const rows = slice?.rows ?? snapshot?.rows ?? []
  const coverage = slice?.coverage ?? snapshot?.coverage ?? []
  return html`<section class="space-y-4 p-4" aria-label="Lane Add-ons">
    <header class="flex items-center justify-between gap-4">
      <div><h2 class="text-lg font-semibold">Lane Add-ons</h2>
        <p>Optional observations and relationships. Keeper work continues independently.</p></div>
      <div class="flex gap-2"><button class=${buttonClass} onClick=${() => editToml(null)}>New TOML</button>
      <button class=${buttonClass} onClick=${refresh}>Refresh</button></div>
    </header>
    ${reading && html`<p role="status">Reading retained observations…</p>`}
    ${error && html`<p role="alert" class="text-red-400">${error}</p>`}
    ${snapshot && html`<section class="space-y-2" aria-label="TOML configuration">
      <h3 class="font-semibold">TOML configuration</h3>
      ${snapshot.configuration === null
        ? html`<p>Configuration service has not started.</p>`
        : html`<p class="break-all">Directory: <code>${snapshot.configuration.directory}</code></p>
          <p>Configuration read: ${snapshot.configuration.complete ? 'complete' : 'incomplete'}</p>
          ${snapshot.configuration.issues.map((issue, index) => html`<p key=${index} role="alert" class="text-red-400 break-all">
            <strong>${issue.source_path}</strong>${issue.id !== null && html` · ${issue.id}`} — ${issue.message}
            <button type="button" class=${buttonClass} onClick=${() => editToml(issue.source_path)} aria-label=${`Edit TOML ${issue.source_path}`}>Edit TOML</button>
          </p>`)}
          <div class="overflow-x-auto"><table class="w-full text-left" aria-label="TOML declarations"><thead><tr>
            <th>Declaration / file</th><th>Desired revision</th><th>Applied revision / instance</th><th>Configuration status</th>
          </tr></thead><tbody>${snapshot.configuration.declarations.map(declaration => html`<tr key=${declaration.id}>
            <td>${declaration.id}<div class="break-all">${declaration.source_path}</div>
              <button type="button" class=${buttonClass} onClick=${() => editToml(declaration.source_path)} aria-label=${`Edit TOML ${declaration.source_path}`}>Edit TOML</button></td>
            <td class="break-all">${declaration.desired_revision}</td>
            <td class="break-all">${declaration.applied_revision ?? 'None'}<div>${declaration.instance_id ?? 'No instance'}</div></td>
            <td>${declaration.applied_revision === null ? 'Not yet applied'
              : declaration.applied_revision === declaration.desired_revision ? 'Desired revision applied' : 'Revision change pending'}</td>
          </tr>`)}</tbody></table></div>
          ${snapshot.configuration.declarations.length === 0 && html`<p>No readable TOML declarations.</p>`}
          <p>Configuration status tracks installed revisions. Observation status is shown per instance below.</p>`}
    </section>`}
    <${LaneDeclarationEditor} target=${editor} onClose=${() => setEditor(null)} onSaved=${(key: string, document: LaneDeclarationDocument) => {
      setEditor(current => current?.key === key ? { key: document.source_path, sourcePath: document.source_path } : current)
      setNewEditorKey(current => current === key ? crypto.randomUUID() : current)
      void refresh()
    }} />
    <details><summary>Attach a package</summary>
      <form class="flex flex-wrap gap-2 py-2" onSubmit=${(event: Event) => {
        event.preventDefault()
        void act(async () => {
          const parsed: unknown = JSON.parse(binding)
          if (!isRecord(parsed)) throw new Error('Binding must be a JSON object.')
          return attachLaneAddon(manifest, run, parsed)
        })
      }}>
        <label>Manifest path <input class=${inputClass} required value=${manifest} onInput=${(e: Event) => setManifest((e.target as HTMLInputElement).value)} /></label>
        <label>Run ID <input class=${inputClass} required value=${run} onInput=${(e: Event) => setRun((e.target as HTMLInputElement).value)} /></label>
        <label>Binding JSON <input class=${inputClass} value=${binding} onInput=${(e: Event) => setBinding((e.target as HTMLInputElement).value)} /></label>
        <button class=${buttonClass} type="submit">Attach</button>
      </form>
    </details>
    <div class="overflow-x-auto"><table class="w-full text-left"><thead><tr>
      <th>Instance / package</th><th>Run / revision</th><th>Status</th><th>Cursor / rows</th><th>Actions</th>
    </tr></thead><tbody>${snapshot?.instances.map(item => html`<tr key=${item.instance_id}>
      <td><label><input type="radio" name="addon-instance" checked=${instance === item.instance_id}
        onChange=${() => { setInstance(item.instance_id); setSelected([]) }} /> ${item.title}</label><div>${item.instance_id} · ${item.addon_id}</div>
        ${item.configuration === null ? html`<p>Not managed by TOML</p>` : html`<div class="break-all" aria-label=${`Configuration for ${item.instance_id}`}>
          <p>TOML: ${item.configuration.id}</p><p>${item.configuration.source_path}</p><p>Installed configuration: ${item.configuration.revision}</p>
          <button type="button" class=${buttonClass} onClick=${() => { if (item.configuration !== null) editToml(item.configuration.source_path) }} aria-label=${`Edit TOML for ${item.instance_id}`}>Edit TOML</button>
        </div>`}</td>
      <td>${item.run_id}<div>${item.revision}</div></td>
      <td>${item.phase.kind}${(item.phase.message || item.error) && html`<p role="status">${item.phase.message ?? item.error}</p>`}</td>
      <td>${item.observation_seq} / ${item.rows_count}</td>
      <td class="space-x-2"><button class=${buttonClass} disabled=${item.phase.kind === 'detached' || item.phase.kind === 'detaching' || item.phase.kind === 'observing'} onClick=${() => act(() => observeLaneAddon(item.instance_id))}>Observe</button>
      <button class=${buttonClass} disabled=${item.phase.kind === 'detached'} onClick=${() => act(() => detachLaneAddon(item.instance_id))}>Detach</button></td>
    </tr>`)}</tbody></table></div>
    ${snapshot?.instances.length === 0 && html`<p>No attached packages.</p>`}
    <${LaneAddonActions} instances=${snapshot?.instances ?? []} />
    <${LaneAddonsTimeline} rows=${rows} onWindow=${(from: number, to: number) => { setSince(String(from)); setUntil(String(to)) }} />
    <form class="flex flex-wrap gap-2" onSubmit=${(e: Event) => { e.preventDefault(); void query() }}>
      <label>Run filter <input class=${inputClass} value=${run} onInput=${(e: Event) => setRun((e.target as HTMLInputElement).value)} /></label>
      <label>Lane filter <input class=${inputClass} value=${lane} onInput=${(e: Event) => setLane((e.target as HTMLInputElement).value)} /></label>
      <label>Since (Unix seconds) <input class=${inputClass} value=${since} onInput=${(e: Event) => setSince((e.target as HTMLInputElement).value)} /></label>
      <label>Until (Unix seconds) <input class=${inputClass} value=${until} onInput=${(e: Event) => setUntil((e.target as HTMLInputElement).value)} /></label>
      <button type="submit" class=${buttonClass}>Slice</button>
      <button type="button" class=${buttonClass} onClick=${() => { reads.current?.abort(); setReading(false); setSlice(null); setSelected([]) }}>Clear slice</button>
    </form>
    <div aria-label="Source coverage">${coverage.map(source => html`<p key=${`${source.source_id}:${source.incarnation}`}>
      ${source.source_id} · ${source.incarnation} · cursor ${source.cursor ?? 'unknown'} · ${source.complete ? 'complete' : 'partial'} ${source.detail ?? ''}
    </p>`)}${slice && html`<p>Slice: ${slice.complete ? 'complete within reported coverage' : 'partial'}</p>`}</div>
    <div class="space-y-2" aria-label="Cross-lane observations">${rows.map(row => html`<article key=${row.id} class="border border-[var(--border)] rounded p-3">
      <label><input type="checkbox" checked=${selected.includes(row.id)} onChange=${() => setSelected(ids => ids.includes(row.id) ? ids.filter(id => id !== row.id) : [...ids, row.id])} />
        <strong>${row.title}</strong> · ${row.kind} · ${row.lane_id}</label>
      <p>${formatLaneTime(row.observed_at)} · ${row.subject_id} · actor ${row.actor ?? 'unknown'}</p>
      ${row.clock && html`<p>World time: ${row.clock.domain} ${row.clock.value}</p>`}
      <details><summary>Fields and original evidence · ${row.id}</summary>
        <pre class="whitespace-pre-wrap break-all">${JSON.stringify(row.fields, null, 2)}</pre>
        ${row.evidence.map(evidence => html`<p key=${evidence.uri} class="break-all">${evidence.uri} · sha256 ${evidence.sha256 ?? 'unknown'}</p>`)}
        ${row.related_ids.length > 0 && html`<p>Related: ${row.related_ids.join(', ')}</p>`}
      </details>
    </article>`)}</div>
    <div class="flex flex-wrap gap-2"><label>Keeper (optional) <input class=${inputClass} value=${keeper} onInput=${(e: Event) => setKeeper((e.target as HTMLInputElement).value)} /></label>
      <button class=${buttonClass} disabled=${!instance || selected.length === 0} onClick=${() => act(() => preserveLaneAddonEvidence(instance, selected, keeper || undefined))}>
        ${keeper ? 'Preserve and send selected evidence' : 'Preserve selected evidence'}
      </button></div>
    ${receipt !== null && html`<details open><summary>Last action receipt</summary><pre class="whitespace-pre-wrap break-all">${JSON.stringify(receipt, null, 2)}</pre></details>`}
  </section>`
}
