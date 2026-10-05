import { html } from 'htm/preact'
import { useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks'
import {
  attachLaneAddon, detachLaneAddon, fetchLaneAddons, fetchLaneAddonSlice,
  observeLaneAddon, preserveLaneAddonEvidence,
  fetchLaneAddonAction, requestLaneAddonAction,
  type LaneAddonSnapshot, type LaneAddonSlice, type LaneAddonInstance,
  type LaneAddonActionReceipt, type LaneAddonActionRequest,
} from '../api/lane-addons'
import { isRecord } from './common/normalize'
import { LaneAddonsTimeline, formatLaneTime } from './lane-addons-timeline'
import { LaneAddonReadings } from './lane-addon-readings'
import { LaneDeclarationEditor } from './lane-declaration-editor'
import { LanePackageInstaller } from './lane-package-installer'
import { LanePackageActivityPanel } from './lane-package-activity-panel'
import { laneDeclarationSessionFor } from '../lib/lane-declaration-sessions'
import { lanePackageActivityObservationRevision } from '../lib/lane-package-activity-session'
import { useLaneNavigation, LaneNavigationNotice, clearLaneNavigation } from './lane-navigation'
import { declarationIdentity, laneTargetLabel, type LaneNavigationTarget } from '../lib/lane-navigation'
import { executionWorkspaceAuthority, refreshExecution, type ExecutionWorkspaceAuthority } from '../store'

const inputClass = 'border border-[var(--border)] rounded px-2 py-1 bg-transparent'
const buttonClass = `${inputClass} cursor-pointer disabled:opacity-50`
const message = (error: unknown) => error instanceof Error ? error.message : String(error)
const currentAuthority = (authority: ExecutionWorkspaceAuthority | null): authority is ExecutionWorkspaceAuthority =>
  authority !== null && executionWorkspaceAuthority.peek() === authority
const sameWorkspace = (left: ExecutionWorkspaceAuthority, right: ExecutionWorkspaceAuthority) =>
  left.workspaceRoot === right.workspaceRoot && left.epoch === right.epoch
type Owned<T> = { authority: ExecutionWorkspaceAuthority; value: T }

function rawFieldsText(fields: Record<string, unknown>): string {
  try {
    return JSON.stringify(fields, null, 2)
  } catch (error) {
    if (!(error instanceof RangeError)) throw error
    return 'Raw fields display unavailable: JSON nesting exceeds this browser’s formatter capacity.'
  }
}

function isDeclarationFile(directory: string, sourcePath: string): boolean {
  const fileName = sourcePath.slice(sourcePath.lastIndexOf('/') + 1)
  const expectedPath = `${directory}${directory.endsWith('/') ? '' : '/'}${fileName}`
  return sourcePath === expectedPath && fileName.length >= '.toml'.length
    && fileName.endsWith('.toml') && !fileName.includes('\\') && !fileName.includes('\0')
}

function staleRemoval(configuration: LaneAddonSnapshot['configuration'], item: LaneAddonInstance): boolean {
  const owner = item.configuration
  if (owner === null) return false
  if (configuration === null || !configuration.complete) return true
  const matches = configuration.declarations.filter(current => current.id === owner.id)
  const conflicts = configuration.issues.filter(issue => issue.id === owner.id)
  if (conflicts.length > 0 || matches.length > 1) return true
  if (matches.length === 1) return matches[0]!.desired_revision !== owner.revision
  return configuration.declarations.some(current => current.source_path === owner.source_path)
    || configuration.issues.some(issue => issue.source_path === owner.source_path)
}

function hasCurrentDeclaration(configuration: LaneAddonSnapshot['configuration'], item: LaneAddonInstance): boolean {
  const source = item.configuration
  if (configuration === null || source === null || !isDeclarationFile(configuration.directory, source.source_path)) return false
  return configuration.declarations.some(current => current.source_path === source.source_path && current.id === source.id)
    || configuration.issues.some(issue => issue.source_path === source.source_path
      && (issue.id === source.id || issue.id === null && item.phase.kind !== 'detached'))
}

type TrackedAction = {
  authority: ExecutionWorkspaceAuthority;
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
function LaneAddonActions({ instances, authority }: {
  instances: readonly LaneAddonInstance[]; authority: ExecutionWorkspaceAuthority | null;
}) {
  const [binding, setBinding] = useState('')
  const [input, setInput] = useState('{}')
  const [error, setError] = useState<string | null>(null)
  const [requests, setRequests] = useState<TrackedAction[]>([])
  const inputAuthority = useRef(authority)
  const submitting = useRef(new Set<ExecutionWorkspaceAuthority>())
  const statusReads = useRef(new Map<string, AbortController>())
  const mounted = useRef(true)

  useEffect(() => {
    mounted.current = true
    const reads = statusReads.current
    return () => { mounted.current = false; for (const read of reads.values()) read.abort() }
  }, [])
  useEffect(() => {
    inputAuthority.current = authority
    const pending = new Set(statusReads.current.keys())
    for (const read of statusReads.current.values()) read.abort()
    statusReads.current.clear()
    if (pending.size) setRequests(items => items.map(item => pending.has(item.request.request_id)
      ? { ...item, checking: false } : item))
    setBinding(''); setInput('{}'); setError(null)
  }, [authority])

  const visibleRequests = authority === null ? [] : requests.filter(item => sameWorkspace(item.authority, authority))
  const capable = instances.filter(item => item.action_schema !== null)
  const draftCurrent = inputAuthority.current === authority
  const selected = draftCurrent ? capable.find(item => instanceBinding(item) === binding) : undefined
  const available = selected !== undefined && selected.phase.kind !== 'detaching' && selected.phase.kind !== 'detached'
  const properties = selected?.action_schema?.properties
  const actionSchema = isRecord(properties) ? properties.action : selected?.action_schema

  function update(requestId: string, owner: ExecutionWorkspaceAuthority, change: Partial<TrackedAction>) {
    if (mounted.current) setRequests(items => items.map(item => item.request.request_id === requestId && item.authority === owner
      ? { ...item, ...change } : item))
  }
  async function submit() {
    if (!currentAuthority(authority) || !selected || !available
      || [...submitting.current].some(owner => sameWorkspace(owner, authority))) return
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
    submitting.current.add(authority)
    setRequests(items => [...items, { authority, request, receipt: null, submitting: true, checking: false, error: null }])
    // An accepted request may finish after navigation. Settle only its original
    // journal row; switching workspaces must not lose an uncertain request ID.
    try { update(request.request_id, authority, { receipt: await requestLaneAddonAction(request) }) }
    catch (err) { update(request.request_id, authority, { error: message(err) }) }
    finally { submitting.current.delete(authority); update(request.request_id, authority, { submitting: false }) }
  }
  async function check(item: TrackedAction) {
    if (!currentAuthority(authority) || !sameWorkspace(item.authority, authority)) return
    const { request } = item
    if (statusReads.current.has(request.request_id)) return
    const controller = new AbortController()
    statusReads.current.set(request.request_id, controller)
    update(request.request_id, item.authority, { checking: true, error: null })
    try {
      const receipt = await fetchLaneAddonAction(request, controller.signal)
      if (!controller.signal.aborted && currentAuthority(authority)) update(request.request_id, item.authority, { receipt })
    } catch (err) {
      if (!controller.signal.aborted && currentAuthority(authority)) update(request.request_id, item.authority, { error: message(err) })
    } finally {
      if (statusReads.current.get(request.request_id) === controller) {
        statusReads.current.delete(request.request_id)
        update(request.request_id, item.authority, { checking: false })
      }
    }
  }
  if (capable.length === 0 && visibleRequests.length === 0) return null
  return html`<section class="space-y-3" aria-label="Package actions">
    <h3 class="font-semibold">Package actions</h3>
    <p>Submit an action advertised by an installed package. Observations and Keeper work continue independently.</p>
    ${capable.length > 0 && html`<form class="space-y-2" onSubmit=${(event: Event) => { event.preventDefault(); void submit() }}>
      <label>Action instance <select class=${inputClass} value=${draftCurrent ? binding : ''} onChange=${(event: Event) => {
        if (!currentAuthority(authority)) return
        inputAuthority.current = authority
        setBinding((event.target as HTMLSelectElement).value); setInput('{}'); setError(null)
      }}>
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
        <button class=${buttonClass} disabled=${!available || visibleRequests.some(item => item.submitting)} type="submit">Send new request</button>
      </div>`}
    </form>`}
    ${draftCurrent && error && html`<p role="alert">${error}</p>`}
    ${visibleRequests.map(item => html`<article key=${item.request.request_id} class="border border-[var(--border)] rounded p-3 space-y-2" aria-label=${`Action request ${item.request.request_id}`}>
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
      <button type="button" class=${buttonClass} disabled=${item.submitting || item.checking} onClick=${() => check(item)}>${item.checking ? 'Checking request status…' : 'Check request status'}</button>
      <details><summary>Submitted action and receipt</summary><pre class="whitespace-pre-wrap break-all">${JSON.stringify({ request: item.request, receipt: item.receipt }, null, 2)}</pre></details>
    </article>`)}
  </section>`
}

/** This component owns its reads. A slow package never joins the fleet refresh. */
export function LaneAddonsPanel() {
  const navigation = useLaneNavigation(['declaration', 'instance'])
  if (navigation.error || navigation.pending) return html`<${LaneNavigationNotice}
    message=${navigation.error ?? 'Verify the workspace before opening this Lane target.'} pending=${navigation.pending} />`
  const target = navigation.target
  return html`<${LaneAddonsPanelContent} navigationTarget=${target && (target.kind === 'declaration' || target.kind === 'instance') ? target : undefined} />`
}

function LaneAddonsPanelContent({ navigationTarget }: { navigationTarget?: Extract<LaneNavigationTarget, { kind: 'declaration' | 'instance' }> }) {
  const authority = executionWorkspaceAuthority.value
  const [recoveringAuthority, setRecoveringAuthority] = useState(false)
  const [authorityError, setAuthorityError] = useState<string | null>(null)
  function releaseTarget() { if (navigationTarget) clearLaneNavigation() }
  function editToml(sourcePath: string | null) {
    releaseTarget()
    if (session && authority) session.open(sourcePath, authority)
  }
  const [received, setReceived] = useState<Owned<LaneAddonSnapshot> | null>(null)
  const [receivedSlice, setReceivedSlice] = useState<Owned<LaneAddonSlice> | null>(null)
  const snapshot = received?.authority === authority ? received.value : null
  // The navigation target that was selected when the retained inventory was
  // read. A target chosen after that reading is validated only against a read
  // that began once it was selected; until then it is pending, not absent.
  const [inventoryTarget, setInventoryTarget] = useState<typeof navigationTarget>(undefined)
  const inventoryCurrent = navigationTarget === undefined || inventoryTarget === navigationTarget
  const slice = receivedSlice?.authority === authority ? receivedSlice.value : null
  const [receivedError, setReceivedError] = useState<Owned<string> | null>(null)
  const error = receivedError?.authority === authority ? receivedError.value : null
  function setError(value: string | null) {
    setReceivedError(value === null || authority === null ? null : { authority, value })
  }
  const [receivedReceipt, setReceivedReceipt] = useState<Owned<unknown> | null>(null)
  const receipt = receivedReceipt?.authority === authority ? receivedReceipt.value : null
  const [reading, setReading] = useState(false)
  const [manifest, setManifest] = useState('')
  const [run, setRun] = useState('')
  const [binding, setBinding] = useState('{}')
  const [lane, setLane] = useState('')
  const [since, setSince] = useState('')
  const [until, setUntil] = useState('')
  const [instanceValue, setInstance] = useState('')
  const [keeper, setKeeper] = useState('')
  const [focusedRowValue, setFocusedRow] = useState<string | null>(null)
  const [selectedValue, setSelected] = useState<string[]>([])
  const [evidenceAuthority, setEvidenceAuthority] = useState(authority)
  const evidenceCurrent = evidenceAuthority === authority
  const navigationInstanceMissing = navigationTarget?.kind === 'instance' && snapshot !== null && inventoryCurrent
    && !snapshot.instances.some(item => item.instance_id === navigationTarget.instance && item.incarnation === navigationTarget.incarnation && item.phase.kind !== 'detached')
  const instance = evidenceCurrent && !navigationInstanceMissing ? instanceValue : ''
  const focusedRow = evidenceCurrent ? focusedRowValue : null
  const selected = evidenceCurrent ? selectedValue : []
  useLayoutEffect(() => {
    setEvidenceAuthority(authority)
    setReceivedSlice(null); setInstance(''); setFocusedRow(null); setSelected([]); setReceivedReceipt(null)
  }, [authority])
  const reads = useRef<AbortController | null>(null)
  const mounted = useRef(true)
  const activityRevision = lanePackageActivityObservationRevision(authority)
  const lastActivityRead = useRef({ authority, revision: activityRevision })

  async function refresh() {
    if (!mounted.current || !currentAuthority(authority)) return
    const requestedAuthority = authority
    const requestedTarget = currentNavigation.current.target
    reads.current?.abort()
    const controller = new AbortController()
    reads.current = controller
    setReading(true)
    setError(null)
    try {
      const result = await fetchLaneAddons(controller.signal)
      if (!controller.signal.aborted && mounted.current && executionWorkspaceAuthority.peek() === requestedAuthority) {
        setReceived({ authority: requestedAuthority, value: result })
        setInventoryTarget(requestedTarget)
      }
    } catch (err) {
      if (!controller.signal.aborted && mounted.current && executionWorkspaceAuthority.peek() === requestedAuthority) setError(message(err))
    } finally {
      if (!controller.signal.aborted && mounted.current && executionWorkspaceAuthority.peek() === requestedAuthority) setReading(false)
    }
  }
  useEffect(() => {
    mounted.current = true
    setReading(false); setError(null); setAuthorityError(null)
    setInstance(''); setSelected([]); setFocusedRow(null)
    setManifest(''); setRun(''); setBinding('{}'); setLane(''); setSince(''); setUntil(''); setKeeper('')
    void refresh()
    return () => { mounted.current = false; reads.current?.abort() }
  }, [authority])

  useEffect(() => {
    const before = lastActivityRead.current
    lastActivityRead.current = { authority, revision: activityRevision }
    // Authority changes already trigger the mount read above. A completed
    // activity save only refreshes observations; selections and forms survive.
    if (before.authority === authority && before.revision !== activityRevision) void refresh()
  }, [authority, activityRevision])

  async function recoverAuthority() {
    if (recoveringAuthority) return
    const requestedAuthority = executionWorkspaceAuthority.peek()
    setRecoveringAuthority(true)
    setAuthorityError(null)
    try { await refreshExecution({ force: true }) }
    catch (err) {
      if (mounted.current && executionWorkspaceAuthority.peek() === requestedAuthority) setAuthorityError(message(err))
    } finally { if (mounted.current) setRecoveringAuthority(false) }
  }

  async function act(action: () => Promise<unknown>) {
    if (!mounted.current || !currentAuthority(authority) || snapshot === null) return
    setError(null)
    try {
      const result = await action()
      if (!mounted.current || !currentAuthority(authority)) return
      setReceivedReceipt({ authority, value: result })
      await refresh()
    } catch (err) {
      if (mounted.current && currentAuthority(authority)) setError(message(err))
    }
  }
  async function query() {
    if (!mounted.current || !currentAuthority(authority)) return
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
      if (!controller.signal.aborted && mounted.current && currentAuthority(authority)) {
        setReceivedSlice({ authority, value: result }); setSelected([])
      }
    } catch (err) {
      if (!controller.signal.aborted && mounted.current && currentAuthority(authority)) setError(message(err))
    } finally {
      if (!controller.signal.aborted && mounted.current && currentAuthority(authority)) setReading(false)
    }
  }
  const configuration = snapshot?.configuration ?? null
  const session = authority !== null && snapshot !== null && configuration !== null
    ? laneDeclarationSessionFor(authority, configuration.directory) : null
  const [navigationAttempt, setNavigationAttempt] = useState(0)
  type NavigationReading = { authority: ExecutionWorkspaceAuthority; target: typeof navigationTarget; attempt: number }
  const handledNavigation = useRef<NavigationReading | null>(null)
  const focusedNavigation = useRef<NavigationReading | null>(null)
  const currentNavigation = useRef({ authority, target: navigationTarget, attempt: navigationAttempt })
  currentNavigation.current = { authority, target: navigationTarget, attempt: navigationAttempt }
  const [fileCheck, setFileCheck] = useState<(NavigationReading & { error: string | null }) | null>(null)
  const fileChecked = fileCheck?.authority === authority && fileCheck?.target === navigationTarget && fileCheck?.attempt === navigationAttempt
  const targetDraft = navigationTarget?.kind === 'declaration' ? session?.state.value.drafts[navigationTarget.path] : undefined
  const declarationFocus = useRef<HTMLDivElement>(null), instanceFocus = useRef<HTMLTableRowElement>(null)
  let snapshotTargetError: string | null = null
  if (navigationTarget && snapshot && inventoryCurrent) {
    if (navigationTarget.kind === 'instance') {
      if (navigationInstanceMissing) snapshotTargetError = 'The selected worker is absent or its incarnation changed. No replacement worker was selected.'
    } else {
      const declaration = configuration?.declarations.find(item => item.source_path === navigationTarget.path)
      const issue = configuration?.issues.find(item => item.source_path === navigationTarget.path)
      if (!configuration || !isDeclarationFile(configuration.directory, navigationTarget.path)) snapshotTargetError = 'The selected file is outside the current declaration directory.'
      else if (declaration && navigationTarget.installation !== null && declaration.id !== navigationTarget.installation)
        snapshotTargetError = 'The selected file now belongs to a different installation. Its replacement was not opened.'
      else if (!declaration && (!issue || navigationTarget.installation !== null && issue.id !== navigationTarget.installation))
        snapshotTargetError = configuration.complete ? 'The selected declaration is absent from this reading.' : 'The declaration reading is incomplete; the selected target is not confirmed.'
    }
  }
  useEffect(() => {
    if (!navigationTarget || !authority || !snapshot || !inventoryCurrent || snapshotTargetError) return
    const previous = handledNavigation.current
    if (previous?.target === navigationTarget && previous.authority === authority && previous.attempt === navigationAttempt) return
    if (navigationTarget.kind === 'declaration') {
      // Wait for an existing read/save to settle, then read the selected file.
      // The session retains the draft and its original CAS basis separately.
      if (!session || targetDraft && targetDraft.phase !== 'idle') return
      const reading = { authority, target: navigationTarget, attempt: navigationAttempt }
      handledNavigation.current = reading
      session.closeActivity(authority)
      void session.open(navigationTarget.path, authority, true).then(document => {
        const current = currentNavigation.current
        if (!mounted.current || current.authority !== authority || current.target !== navigationTarget || current.attempt !== navigationAttempt) return
        setFileCheck({ ...reading, error: document ? null
          : session.state.peek().drafts[navigationTarget.path]?.error ?? 'The selected file could not be read. Retry to confirm it.' })
      })
    } else {
      setInstance(navigationTarget.instance); setSelected([])
      session?.close(); session?.closeActivity(authority)
      handledNavigation.current = { authority, target: navigationTarget, attempt: navigationAttempt }
    }
  }, [navigationTarget, authority, snapshot, inventoryCurrent, session, snapshotTargetError, navigationAttempt, targetDraft?.phase])
  let targetError = snapshotTargetError ?? (fileChecked ? fileCheck?.error ?? null : null)
  const loaded = targetDraft?.current ?? targetDraft?.document
  if (!targetError && fileChecked && navigationTarget?.kind === 'declaration' && navigationTarget.installation !== null && loaded) {
    try {
      if (declarationIdentity(loaded.source_text) !== navigationTarget.installation)
        targetError = 'The file read belongs to a different installation. The replacement was not opened.'
    } catch { targetError = 'The file read cannot confirm the selected installation ID. Open the file explicitly from the current workspace to repair it.' }
  }
  const targetPending = !inventoryCurrent || navigationTarget?.kind === 'declaration' && !fileChecked
  // A target selected while this panel stays mounted reads the inventory
  // again; the mount read above already serves the first target.
  const lastTargetRead = useRef(navigationTarget)
  useEffect(() => {
    if (lastTargetRead.current === navigationTarget) return
    lastTargetRead.current = navigationTarget
    if (navigationTarget) void refresh()
  }, [navigationTarget])
  useEffect(() => {
    if (!navigationTarget || !authority || !snapshot || targetError || targetPending) return
    const previous = focusedNavigation.current
    if (previous?.target === navigationTarget && previous.authority === authority && previous.attempt === navigationAttempt) return
    const element = navigationTarget.kind === 'declaration' ? declarationFocus.current : instanceFocus.current
    if (element) { element.focus(); focusedNavigation.current = { authority, target: navigationTarget, attempt: navigationAttempt } }
  }, [navigationTarget, authority, snapshot, targetError, targetPending, navigationAttempt])
  function retryTarget() { setNavigationAttempt(value => value + 1); void refresh() }
  const rows = slice?.rows ?? snapshot?.rows ?? []
  const selectionOwned = instance !== '' && selected.length > 0 && selected.every(id =>
    rows.some(row => row.id === id && row.lane_id.startsWith(`${instance}/`)))
  const focused = rows.find(row => row.id === focusedRow)
  const coverage = slice?.coverage ?? snapshot?.coverage ?? []
  if (navigationTarget && targetError) return html`<${LaneNavigationNotice} message=${targetError} onRetry=${retryTarget} />`
  if (navigationTarget && (!snapshot || targetPending)) return html`<${LaneNavigationNotice}
    message=${error ?? 'Reading the selected Lane target in the current workspace…'}
    onRetry=${reading || targetDraft && targetDraft.phase !== 'idle' ? undefined : retryTarget} />`
  return html`<section class="space-y-4 p-4" aria-label="Lane Add-ons">
    ${navigationTarget && html`<p role="status" class="break-all">Selected: ${laneTargetLabel(navigationTarget)}</p>`}
    <header class="flex items-center justify-between gap-4">
      <div><h2 class="text-lg font-semibold">Lane Add-ons</h2>
        <p>Optional observations and relationships. Keeper work continues independently.</p></div>
      <div class="flex gap-2"><button class=${buttonClass} disabled=${session === null} onClick=${() => editToml(null)}>New TOML</button>
      <button class=${buttonClass} disabled=${authority === null} onClick=${refresh}>Refresh</button></div>
    </header>
    ${reading && html`<p role="status">Reading retained observations…</p>`}
    ${error && html`<p role="alert" class="text-red-400">${error}</p>`}
    ${slice && html`<p role="status">Frozen slice: Refresh updates installation status only. Use Slice to query again, or Clear slice to show the latest snapshot.</p>`}
    ${error && snapshot && html`<p role="status">Showing retained data after a failed request; current state is unverified.</p>`}
    ${snapshot !== null || slice !== null ? html`<${LaneAddonsTimeline} rows=${rows} instances=${snapshot?.instances ?? []} selectedId=${focused?.id}
      onSelect=${(row: { id: string }) => setFocusedRow(row.id)}
      onWindow=${(from: number, to: number) => { setSince(String(from)); setUntil(String(to)) }} />`
      : html`<p role="status">No observations loaded for the current workspace.</p>`}
    ${focused && html`<section class="border border-[var(--border)] rounded p-4 space-y-2" aria-label="Selected Lane event">
      <h3 class="font-semibold">Selected: ${focused.title}</h3>
      <p>${focused.lane_id} · ${formatLaneTime(focused.observed_at)}</p>
      <p>Actor: ${focused.actor ?? 'not recorded'} · Subject: ${focused.subject_id}</p>
      <${LaneAddonReadings} row=${focused} instances=${snapshot?.instances ?? []} />
      <pre class="whitespace-pre-wrap break-all">${rawFieldsText(focused.fields)}</pre>
      <h4>Original evidence</h4>
      ${focused.evidence.length === 0 ? html`<p>No original evidence recorded.</p>` : focused.evidence.map(evidence => html`<p class="break-all" key=${evidence.uri}>${evidence.uri} · sha256 ${evidence.sha256 ?? 'not recorded'}</p>`)}
      ${focused.related_ids.length > 0 && html`<div>Recorded relationships: ${focused.related_ids.map(id => {
        const related = rows.find(row => row.id === id)
        return related ? html`<button type="button" class=${buttonClass} key=${id} onClick=${() => setFocusedRow(id)}>Inspect related: ${related.title}</button>`
          : html`<span key=${id}>${id} (outside this view) </span>`
      })}</div>`}
      <button type="button" class=${buttonClass} onClick=${() => {
        const owner = snapshot?.instances.find(item => focused.lane_id.startsWith(`${item.instance_id}/`))
        if (owner) { releaseTarget(); setInstance(owner.instance_id); setSelected([focused.id]) }
      }} disabled=${!snapshot?.instances.some(item => focused.lane_id.startsWith(`${item.instance_id}/`))}>Select this evidence and its instance</button>
      <button type="button" class=${buttonClass} onClick=${() => setFocusedRow(null)}>Close event</button>
    </section>`}
    ${snapshot && html`<section class="space-y-2" aria-label="TOML configuration">
      <h3 class="font-semibold">TOML configuration</h3>
      ${configuration === null
        ? html`<p>Configuration service has not started.</p>`
        : html`<p class="break-all">Directory: <code>${configuration.directory}</code></p>
          <p>Configuration read: ${configuration.complete ? 'complete' : 'incomplete'}</p>
          ${configuration.issues.map((issue, index) => html`<p key=${index} role="alert" class="text-red-400 break-all">
            <strong>${issue.source_path}</strong>${issue.id !== null && html` · ${issue.id}`} — ${issue.message}
            ${isDeclarationFile(configuration.directory, issue.source_path) && html`<button type="button" class=${buttonClass} disabled=${session === null}
              onClick=${() => editToml(issue.source_path)} aria-label=${`Edit TOML ${issue.source_path}`}>Edit TOML</button>`}
          </p>`)}
          <div class="overflow-x-auto"><table class="w-full text-left" aria-label="TOML declarations"><thead><tr>
            <th>Declaration / file</th><th>Desired revision</th><th>Applied revision / instance</th><th>Configuration status</th>
          </tr></thead><tbody>${configuration.declarations.map(declaration => html`<tr key=${declaration.id}>
            <td>${declaration.id}<div class="break-all">${declaration.source_path}</div>
              <button type="button" class=${buttonClass} disabled=${session === null} onClick=${() => editToml(declaration.source_path)} aria-label=${`Edit TOML ${declaration.source_path}`}>Edit TOML</button>
              <button type="button" class=${buttonClass} disabled=${session === null || authority === null}
                onClick=${() => { if (session && authority) { releaseTarget(); session.openActivity(declaration.source_path, declaration.id, authority) } }}
                aria-label=${`Configure activity for ${declaration.id}`}>On / off</button></td>
            <td class="break-all">${declaration.desired_revision}</td>
            <td class="break-all">${declaration.applied_revision ?? 'None'}<div>${declaration.instance_id ?? 'No instance'}</div></td>
            <td>${!declaration.enabled
              ? declaration.instance_id === null ? 'Configured off · no current worker observed' : 'Off requested · worker cleanup not yet confirmed'
              : declaration.applied_revision === null ? 'Not yet applied'
                : declaration.applied_revision === declaration.desired_revision ? 'Desired revision applied' : 'Revision change pending'}</td>
          </tr>`)}</tbody></table></div>
          ${configuration.declarations.length === 0 && html`<p>No readable TOML declarations.</p>`}
          <p>Configuration status tracks installed revisions. Observation status is shown per instance below.</p>`}
    </section>`}
    ${authority === null ? html`<div class="space-y-2">
      <p role="status">Workspace authority is being verified. Lane reads and actions are unavailable until the workspace is confirmed; your retained TOML drafts are unchanged.</p>
      <button type="button" class=${buttonClass} disabled=${recoveringAuthority} onClick=${recoverAuthority}>${recoveringAuthority ? 'Checking workspace…' : 'Verify workspace'}</button>
      ${authorityError && html`<p role="alert">${authorityError} Workspace verification can be retried.</p>`}
    </div>` : session === null && html`<p role="status">${reading
      ? 'Reading the current workspace’s TOML configuration before opening retained drafts…'
      : 'Current workspace TOML configuration is unavailable. Refresh to retry; your retained drafts are unchanged.'}</p>`}
    ${session !== null && authority !== null && snapshot !== null && html`<${LanePackageActivityPanel}
      documents=${session} authority=${authority} snapshot=${snapshot} onRefresh=${() => {
        if (mounted.current && executionWorkspaceAuthority.peek() === authority) void refresh()
      }} />`}
    ${session !== null && authority !== null && snapshot !== null && html`<${LanePackageInstaller}
      key=${JSON.stringify([authority.workspaceRoot, authority.epoch, session.directory])}
      authority=${authority} documents=${session} snapshot=${snapshot} onSelectionChange=${releaseTarget} />`}
    <div ref=${declarationFocus} tabIndex=${-1} aria-label="Selected declaration settings">${session !== null && authority !== null && html`<${LaneDeclarationEditor} session=${session} authority=${authority} onSelectionChange=${releaseTarget} onSaved=${() => {
      if (mounted.current && executionWorkspaceAuthority.peek() === authority) void refresh()
    }} />`}</div>
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
        <button class=${buttonClass} type="submit" disabled=${authority === null || snapshot === null}>Attach</button>
      </form>
    </details>
    <div class="overflow-x-auto"><table class="w-full text-left"><thead><tr>
      <th>Instance / package</th><th>Run / revision</th><th>Status</th><th>Cursor / rows</th><th>Actions</th>
    </tr></thead><tbody>${snapshot?.instances.map(item => html`<tr key=${item.instance_id}
      ref=${navigationTarget?.kind === 'instance' && item.instance_id === navigationTarget.instance && item.incarnation === navigationTarget.incarnation ? instanceFocus : undefined}
      tabIndex=${navigationTarget?.kind === 'instance' && item.instance_id === navigationTarget.instance && item.incarnation === navigationTarget.incarnation ? -1 : undefined}
      aria-label=${`Worker ${item.instance_id} · incarnation ${item.incarnation}`}>
      <td><label><input type="radio" name="addon-instance" checked=${instance === item.instance_id}
        onChange=${() => { releaseTarget(); setInstance(item.instance_id); setSelected([]) }} /> ${item.title}</label><div>${item.instance_id} · ${item.addon_id}</div>
        ${item.configuration === null ? html`<p>Not managed by TOML</p>` : html`<div class="break-all" aria-label=${`Configuration for ${item.instance_id}`}>
          <p>TOML: ${item.configuration.id}</p><p>${item.configuration.source_path}</p><p>Installed configuration: ${item.configuration.revision}</p>
          ${hasCurrentDeclaration(configuration, item) && html`<button type="button" class=${buttonClass} disabled=${session === null}
            onClick=${() => { if (item.configuration !== null) editToml(item.configuration.source_path) }} aria-label=${`Edit TOML for ${item.instance_id}`}>Edit TOML</button>`}
        </div>`}
        ${item.package.presentation.description !== null && html`<p>${item.package.presentation.description}</p>`}
        <details><summary>Package input and display contracts</summary>
          <pre class="whitespace-pre-wrap break-all">${JSON.stringify({ binding_schema: item.package.binding_schema,
            presentation: item.package.presentation }, null, 2)}</pre>
        </details>
        <div aria-label=${`Output ports for ${item.instance_id}`}>
          ${Object.entries(item.package.outputs).map(([id, selection]) => html`<p key=${id}>
            Output ${id}: ${selection.all_lanes === true ? 'all package lanes' : selection.lanes.join(', ')}
          </p>`)}
        </div></td>
      <td>${item.run_id}<div>${item.revision}</div></td>
      <td>${item.phase.kind}${(item.phase.message || item.error) && html`<p role="status">${item.phase.message ?? item.error}</p>`}</td>
      <td>${item.observation_seq} / ${item.rows_count}</td>
      <td class="space-x-2"><button class=${buttonClass} disabled=${item.phase.kind === 'detached' || item.phase.kind === 'detaching' || item.phase.kind === 'observing'} onClick=${() => act(() => observeLaneAddon(item.instance_id))}>Observe</button>
      <button class=${buttonClass} disabled=${item.phase.kind === 'detached' || staleRemoval(configuration, item)} onClick=${() => { if (!staleRemoval(configuration, item)) act(() => detachLaneAddon(item.instance_id)) }}>${staleRemoval(configuration, item) ? 'Resolve TOML before removal' : item.configuration === null ? 'Remove worker' : 'Remove TOML + worker'}</button>
      <p class="mt-2 max-w-sm text-sm">${staleRemoval(configuration, item)
        ? 'Resolve the changed declaration with Edit TOML, then Refresh until its revision is applied before removing this installation. No TOML or worker has been removed.'
        : item.configuration === null
        ? 'Cleans up this worker and its owned resources. Retained observations and evidence remain.'
        : 'Deletes the matching installation TOML from disk and cleans up its worker. Retained observations and evidence remain.'}</p></td>
    </tr>`)}</tbody></table></div>
    ${snapshot?.instances.length === 0 && html`<p>No attached packages.</p>`}
    <${LaneAddonActions} instances=${snapshot?.instances ?? []} authority=${authority} />
    <form class="flex flex-wrap gap-2" onSubmit=${(e: Event) => { e.preventDefault(); void query() }}>
      <label>Run filter <input class=${inputClass} value=${run} onInput=${(e: Event) => setRun((e.target as HTMLInputElement).value)} /></label>
      <label>Lane filter <input class=${inputClass} value=${lane} onInput=${(e: Event) => setLane((e.target as HTMLInputElement).value)} /></label>
      <label>Since (Unix seconds) <input class=${inputClass} value=${since} onInput=${(e: Event) => setSince((e.target as HTMLInputElement).value)} /></label>
      <label>Until (Unix seconds) <input class=${inputClass} value=${until} onInput=${(e: Event) => setUntil((e.target as HTMLInputElement).value)} /></label>
      <button type="submit" class=${buttonClass} disabled=${authority === null}>Slice</button>
      <button type="button" class=${buttonClass} onClick=${() => { reads.current?.abort(); setReading(false); setReceivedSlice(null); setSelected([]) }}>Clear slice</button>
    </form>
    <div aria-label="Source coverage">${coverage.map(source => html`<p key=${`${source.source_id}:${source.incarnation}`}>
      ${source.source_id} · ${source.incarnation} · cursor ${source.cursor ?? 'unknown'} · ${source.complete ? 'complete' : 'partial'} ${source.detail ?? ''}
    </p>`)}${slice && html`<p>Slice: ${slice.complete ? 'complete within reported coverage' : 'partial'}</p>`}</div>
    <div class="space-y-2" aria-label="Cross-lane observations">${rows.map(row => html`<article key=${row.id} class="border border-[var(--border)] rounded p-3">
      <label class="v2-mobile-operator-target inline-flex items-center gap-2"><input type="checkbox" checked=${selected.includes(row.id)} onChange=${() => setSelected(ids => ids.includes(row.id) ? ids.filter(id => id !== row.id) : [...ids, row.id])} />
        <strong>${row.title}</strong> · ${row.kind} · ${row.lane_id}</label>
      <p>${formatLaneTime(row.observed_at)} · ${row.subject_id} · actor ${row.actor ?? 'unknown'}</p>
      ${row.clock && html`<p>World time: ${row.clock.domain} ${row.clock.value}</p>`}
      <${LaneAddonReadings} row=${row} instances=${snapshot?.instances ?? []} />
      <details><summary>Fields and original evidence · ${row.id}</summary>
        <pre class="whitespace-pre-wrap break-all">${rawFieldsText(row.fields)}</pre>
        ${row.evidence.map(evidence => html`<p key=${evidence.uri} class="break-all">${evidence.uri} · sha256 ${evidence.sha256 ?? 'unknown'}</p>`)}
        ${row.related_ids.length > 0 && html`<p>Related: ${row.related_ids.join(', ')}</p>`}
      </details>
    </article>`)}</div>
    <div class="flex flex-wrap gap-2"><label>Keeper (optional) <input class=${inputClass} value=${keeper} onInput=${(e: Event) => setKeeper((e.target as HTMLInputElement).value)} /></label>
      <button class=${buttonClass} disabled=${!selectionOwned} onClick=${() => { if (selectionOwned) void act(() => preserveLaneAddonEvidence(instance, selected, keeper || undefined)) }}>
        ${keeper ? 'Preserve and send selected evidence' : 'Preserve selected evidence'}
      </button></div>
    ${selected.length > 0 && !selectionOwned && html`<p role="status">Select evidence belonging to the selected instance. Mixed or unresolved owners cannot be preserved together.</p>`}
    ${receipt !== null && html`<details open><summary>Last action receipt</summary><pre class="whitespace-pre-wrap break-all">${JSON.stringify(receipt, null, 2)}</pre></details>`}
  </section>`
}
