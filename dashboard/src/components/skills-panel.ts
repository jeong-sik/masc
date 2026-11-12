import { selectObservationReadFailure, setupObservationRefresh } from '../lib/observation-refresh'
// Skills Panel — the published skill snapshot and exact parser-derived surface.
import { html } from 'htm/preact'
import { useEffect, useMemo, useRef } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { SkillSourceInspector } from './skill-source-inspector'
import { SkillAsyncEvidenceView } from './skill-async-evidence-view'
import { SkillNodeEvidenceView } from './skill-node-evidence-view'
import { SkillFlowView } from './skill-flow-view'
import { SkillRunHistory } from './skill-run-history'
import { SkillCreateForm, createReceiptMessage } from './skill-create-form'
import { AsyncRequestDetails } from './composition-observation-view'
import type { AsyncRequestIdentity } from '../api/composition-observation'
import {
  classifySkillEditorError,
  fetchAsyncRequestObservation,
  fetchKeeperSkillUsage,
  fetchSkills,
  fetchSkillEvidence,
  previewSkillSource,
  readSkillSource,
  saveSkillSource,
  type SkillCreateReceipt,
  type SkillEvidenceResponse,
  type SkillEditorLoaded,
  type SkillEditorPreview,
  type SkillEditorSaveReceipt,
  type AsyncRequestObservation,
  type KeeperSkillUsage,
  type SkillIdentity,
  type SkillReference,
  type SkillSnapshotConfig,
  type SkillSnapshotEntry,
  type SkillSnapshotRejection,
  type SkillSurface,
  type SkillSurfaceProfile,
  type SkillUsage,
  type SkillsResponse,
} from '../api/dashboard-skills'
import { SurfaceCard } from './common/card'
import { EmptyState, ErrorState, LoadingState } from './common/feedback-state'
import { storedTokenRevision } from '../api/token-revision'
import { dashboardActorRevision, managedDashboardActorRevision } from '../lib/dashboard-session-actor'
import { captureDashboardObservationOwner, dashboardObservationOwnerHasWorkspace,
  dashboardObservationOwnerIsCurrent, type DashboardObservationOwner } from '../lib/observation-read-owner'
import {
  executionLoaded,
  executionWorkspaceAuthority,
  keepers,
} from '../store'


export function isAbortError(e: unknown): boolean {
  return e instanceof Error && e.name === 'AbortError'
}

export interface SkillRow {
  identity: SkillIdentity
  content_revision: string
  name: string
  description: string
  source: string
  body_bytes: number
  diagnostics: string[]
  surface: SkillSurface | null
}

type NameSelection =
  | { kind: 'effective' }
  | { kind: 'shadowed'; winner: SkillIdentity }
  | { kind: 'unavailable' }

function identityKey(identity: SkillIdentity): string {
  return JSON.stringify([identity.source_id, identity.package_id, identity.name])
}

function referenceKey(identity: SkillIdentity, contentRevision: string): string {
  return [identity.source_id, identity.package_id, identity.name, contentRevision].join('\u0000')
}

export function mergeSkillRows(
  entries: readonly SkillSnapshotEntry[],
  surfaces: readonly SkillSurface[],
): SkillRow[] {
  const byReference = new Map<string, SkillSurface>()
  for (const surface of surfaces) {
    byReference.set(
      referenceKey(surface.reference.identity, surface.reference.content_revision),
      surface,
    )
  }
  return entries.map(entry => {
    const surface = byReference.get(referenceKey(entry.identity, entry.content_revision)) ?? null
    return {
      identity: entry.identity,
      content_revision: entry.content_revision,
      name: entry.identity.name,
      description: entry.description,
      source: `${entry.identity.source_id}/${entry.identity.package_id}`,
      body_bytes: entry.body_bytes,
      diagnostics: [...new Set(surface?.diagnostics ?? [])],
      surface,
    }
  })
}

export function skillRowKey(row: SkillRow): string {
  return referenceKey(row.identity, row.content_revision)
}

function compareText(left: string, right: string): number {
  if (left < right) return -1
  if (left > right) return 1
  return 0
}

export function sortSkillRows(rows: readonly SkillRow[]): SkillRow[] {
  return [...rows].sort((left, right) =>
    compareText(left.identity.source_id, right.identity.source_id)
    || compareText(left.identity.package_id, right.identity.package_id)
    || compareText(left.identity.name, right.identity.name)
    || compareText(left.content_revision, right.content_revision),
  )
}

export function rejectionDiagnostics(rejection: SkillSnapshotRejection): string[] {
  switch (rejection.reason.kind) {
    case 'document_rejected':
      return rejection.reason.diagnostics.map(
        diagnostic => `${diagnostic.code}: ${diagnostic.message}`,
      )
    case 'document_unreadable':
    case 'exact_identity_duplicate':
    case 'invalid_package_id':
      return [rejection.reason.kind]
  }
}

export function kindLabel(surface: SkillSurface | null): string {
  if (!surface) return 'surface unavailable'
  switch (surface.kind) {
    case 'composition':
      return `composition · ${surface.profile.execution}`
    case 'instruction':
      return 'instruction'
    case 'unavailable':
      return `unavailable: ${surface.error}`
  }
}

export function capabilityLabel(surface: SkillSurface | null): string {
  if (!surface || surface.kind === 'unavailable') return kindLabel(surface)
  const profile = surface.profile
  if (surface.kind === 'instruction') return 'on-demand · model orchestrated'
  const flags = [profile.execution, `${profile.plan.node_count} nodes`]
  if (profile.capabilities.batch) flags.push(`${profile.plan.batch_count} batches`)
  if (profile.capabilities.parallel) flags.push(`parallel ×${profile.plan.max_parallelism}`)
  return flags.join(' · ')
}

export function contextLabel(surface: SkillSurface | null, bodyBytes: number): string {
  const context = surface && surface.kind !== 'unavailable'
    ? surface.profile.context
    : null
  if (!context) return `${formatBytes(bodyBytes)} body`
  return `${formatBytes(context.discovery_bytes)} discovery · ${formatBytes(context.body_bytes)} body`
}

export function usageLabel(usage: readonly SkillUsage[] | null): string {
  if (usage === null) return 'Usage observation unavailable'
  if (usage.length === 0) return 'No invocation observed in retained sessions'
  return usage
    .map(row => `${row.keeper} ${row.invocations} invoked / ${row.deliveries} received / ${row.actions} observed actions · last activation ${row.last_used_at}`)
    .join(' · ')
}

/** Every Keeper's usage, joined to the catalog by exact Skill reference. */
export interface KeeperUsageReading {
  byReference: ReadonlyMap<string, readonly SkillUsage[]>
  ledgersRead: number
  unavailable: readonly string[]
}

/** The Keepers' usage rows for one exact Skill reference. */
export function usageFor(reading: KeeperUsageReading, reference: SkillReference): readonly SkillUsage[] {
  return reading.byReference.get(referenceKey(reference.identity, reference.content_revision)) ?? []
}

/** Joins each Keeper's `skill-usage` answer, in Keeper name order. A Keeper
    with no session has nothing to count; one whose ledger or answer could
    not be read is listed as unavailable. */
export function keeperUsageReading(
  readings: readonly { keeper: string; result: PromiseSettledResult<KeeperSkillUsage> }[],
): KeeperUsageReading {
  const byReference = new Map<string, SkillUsage[]>()
  let ledgersRead = 0
  const unavailable: string[] = []
  const ordered = [...readings].sort((left, right) => left.keeper.localeCompare(right.keeper))
  for (const { keeper, result } of ordered) {
    if (result.status === 'rejected') {
      const reason: unknown = result.reason
      unavailable.push(`${keeper}: ${reason instanceof Error ? reason.message : String(reason)}`)
      continue
    }
    const usage = result.value
    switch (usage.state) {
      case 'ready':
        ledgersRead += 1
        for (const row of usage.rows) {
          const key = referenceKey(row.reference.identity, row.reference.content_revision)
          const rows = byReference.get(key) ?? []
          rows.push({
            keeper,
            invocations: row.invocations,
            deliveries: row.deliveries,
            actions: row.actions,
            last_used_at: row.last_used_at,
          })
          byReference.set(key, rows)
        }
        break
      case 'no_catalog':
        ledgersRead += 1
        break
      case 'no_session':
        break
      case 'unavailable':
        unavailable.push(`${keeper}: ${usage.reason} (${usage.detail})`)
        break
      default: {
        const unread: never = usage
        return unread
      }
    }
  }
  return { byReference, ledgersRead, unavailable }
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  return `${(bytes / 1024).toFixed(1)} KB`
}

export function resourceReadBoundLabel(config: SkillSnapshotConfig): string {
  if (config.kind !== 'configured' || config.resource_read_max_bytes === null) {
    return 'resource read max unavailable'
  }
  return `resource read max ${formatBytes(config.resource_read_max_bytes)}`
}


export function stateMessage(state: Exclude<SkillsResponse['state'], 'ready'>): string {
  switch (state) {
    case 'not_registered':
      return 'This workspace has no registered skill snapshot.'
    case 'uninitialized':
      return 'The skill snapshot has not been published yet.'
    case 'invalid_workspace':
      return 'The workspace path could not be resolved.'
  }
}

function SkillIoView({ profile }: { profile: SkillSurfaceProfile }) {
  if (profile.io.kind === 'model_orchestrated') {
    return html`<div class="ss-muted">Normal Skill · instruction/resource input → model-orchestrated tools</div>`
  }
  return html`
    <div class="mt-2 space-y-2">
      <strong>Declared input</strong>
      <pre class="max-h-40 overflow-auto whitespace-pre-wrap rounded bg-[var(--color-bg-elevated)] p-2 text-3xs">${JSON.stringify(profile.io.input_schema, null, 2)}</pre>
      <strong>Declared output</strong>
      ${profile.io.exports.length === 0
        ? html`<div class="ss-muted">Complete execution result (no selected exports)</div>`
        : profile.io.exports.map(route => html`<div class="mono text-3xs" key=${route.name}>${route.name} ← ${route.node_id} · ${route.pointer || '(root)'}</div>`)}
    </div>
  `
}

function recordedTimestamp(value: number | null): string {
  if (value === null) return 'unobserved'
  const date = new Date(value * 1000)
  return Number.isFinite(date.getTime()) ? date.toISOString() : `${value} Unix seconds`
}

function SkillPerformanceView({ statistics, io }: {
  statistics: SkillEvidenceResponse['composition_statistics']
  io: SkillSurfaceProfile['io'] | null
}) {
  const modelOrchestrated = io?.kind === 'model_orchestrated'
  const applicability = modelOrchestrated
    ? html`<p>Executor timing: N/A for this model-orchestrated declaration. Retained executor results, when present, remain evidence below.</p>` : null
  if (modelOrchestrated && (statistics === null || statistics.records === 0)) {
    return html`<section aria-label="Skill performance" class="rounded border border-[var(--color-border-default)] p-3">
      <strong>Executor performance</strong>${applicability}
      <p class="ss-muted">${statistics === null ? 'Retained executor statistics unavailable.' : 'No retained executor runs for this exact revision.'}</p>
    </section>`
  }
  if (!statistics) return null
  const durations = [
    { label: 'Completed', ...statistics.completed, color: 'var(--color-status-ok)' },
    { label: 'Failed', ...statistics.failed, color: 'var(--color-status-err)' },
  ]
  const outcomes = [
    { label: 'Completed', count: statistics.completed.samples, color: 'var(--color-status-ok)' },
    { label: 'Failed', count: statistics.failed.samples, color: 'var(--color-status-err)' },
    { label: 'Deferred', count: statistics.deferred, color: 'var(--color-status-warn)' },
  ]
  return html`
    <section class="space-y-3 rounded border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] p-3" aria-label="Skill performance">
      <div class="flex flex-wrap justify-between gap-2"><strong>Executor performance</strong><span>${statistics.records} retained runs</span></div>
      ${applicability}
      <div class="ss-muted text-3xs">Same revision · all Keepers · one result per original run</div>
      <div class="ss-muted text-3xs">${statistics.recorded_window.first_recorded_at === null
        ? 'Recorded result window: unobserved'
        : `Recorded result window (UTC): ${recordedTimestamp(statistics.recorded_window.first_recorded_at)} → ${recordedTimestamp(statistics.recorded_window.last_recorded_at)}`}</div>
      <div class="overflow-x-auto"><table class="ss-table" aria-label="Executor duration distribution">
        <thead><tr><th>Outcome</th><th>Mean · samples</th><th>P50</th><th>P95</th><th>Min → max</th></tr></thead>
        <tbody>${durations.map(row => html`
          <tr key=${row.label}>
            <th scope="row">${row.label}</th>
            <td class="mono text-3xs">${row.mean_ms === null ? 'unobserved' : `${row.mean_ms.toFixed(1)}ms`} · n=${row.samples}</td>
            <td class="mono text-3xs">${row.p50_ms === null ? '—' : `${row.p50_ms.toFixed(1)}ms`}</td>
            <td class="mono text-3xs">${row.p95_ms === null ? '—' : `${row.p95_ms.toFixed(1)}ms`}</td>
            <td class="mono text-3xs">${row.min_ms === null ? '—' : `${row.min_ms.toFixed(1)} → ${row.max_ms?.toFixed(1)}ms`}</td>
          </tr>
        `)}</tbody>
      </table></div>
      <div class="ss-muted text-3xs">P50/P95: nearest rank of observed samples; recorded timestamps describe stored results, not execution start/end.</div>
      <div class="ss-muted text-3xs">Outcome distribution · retained runs</div>
      ${outcomes.map(row => html`
        <div class="grid grid-cols-[6rem_minmax(0,1fr)_auto] items-center gap-2" key=${row.label}>
          <span>${row.label}</span>
          <div class="h-2 overflow-hidden rounded bg-[var(--color-border-default)]" aria-hidden="true"><div class="h-full rounded" style=${{ width: `${statistics.records > 0 ? row.count / statistics.records * 100 : 0}%`, backgroundColor: row.color }} /></div>
          <span class="mono text-3xs">${row.count} · ${statistics.records > 0 ? (row.count / statistics.records * 100).toFixed(1) : '—'}${statistics.records > 0 ? '%' : ''}</span>
        </div>
      `)}
      <div class="ss-muted text-3xs">Executor outcome is not business verification. Deferred excluded from durations. Queue/dependency waits and model latency are separate.</div>
    </section>
  `
}


function runField(run: Record<string, unknown>, name: string): string {
  const value = run[name]
  if (typeof value === 'string') return value
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  return ''
}

function runDuration(run: Record<string, unknown>): string {
  const value = run.duration_ms
  return typeof value === 'number' && Number.isFinite(value)
    ? `${Math.round(value)}ms`
    : '?ms'
}

function runOutput(value: unknown): string {
  if (typeof value !== 'string') return JSON.stringify(value, null, 2)
  try {
    return JSON.stringify(JSON.parse(value), null, 2)
  } catch {
    return value
  }
}

function compositionCoverageLabel(scope: SkillEvidenceResponse['coverage']['composition_scope']): string {
  switch (scope) {
    case 'exact_reference_retained_runs':
      return 'composition exact-reference retained runs'
    case 'unavailable':
      return 'composition exact-reference retained runs unavailable'
  }
}

function SkillEvidenceView({ result, io }: { result: SkillEvidenceResponse | null; io: SkillSurfaceProfile['io'] | null }) {
  if (!result) return html`<div class="ss-muted">Load retained exact-revision evidence.</div>`
  const activationGapCount = result.coverage.activation_gaps.length
  const coverageSummary = html`${result.coverage.activation_sessions_inspected} retained sessions inspected · ${result.coverage.activation_ledgers_loaded} activation ledgers loaded · ${activationGapCount} activation gaps · ${result.coverage.activation_owner_gap_count} owner gaps · ${result.coverage.composition_runs_observed} original composition runs observed · ${compositionCoverageLabel(result.coverage.composition_scope)}`
  if (result.status === 'not_observed_in_retained_coverage') {
    return html`
      <${SkillPerformanceView} statistics=${result.composition_statistics} io=${io} />
      <div class="text-[var(--color-status-warn)]">No exact-revision run was found in the retained coverage. This is not proof that it never ran.</div>
      <div class="ss-muted text-3xs">${coverageSummary} · ${result.coverage.activation_scope}</div>
      ${result.coverage.composition_unavailable.length > 0 ? html`<div class="text-[var(--color-status-warn)] text-3xs">Composition unavailable: ${result.coverage.composition_unavailable.join(' · ')}</div>` : null}
    `
  }
  const activationEvidence = result.activation === null
    ? []
    : result.activation.selection === 'most_recent_observed'
      ? [result.activation.evidence]
      : result.activation.evidence
  const composition = result.composition
  const compositionNodeCount = composition?.executor_settlements.length ?? 0
  const output = composition?.result.data
  return html`
    <div class="space-y-2" data-testid="skill-retained-evidence">
      <${SkillPerformanceView} statistics=${result.composition_statistics} io=${io} />
      ${activationEvidence.map((item, index) => {
        const activation = item.activation
        const actions = Array.isArray(activation.actions) ? activation.actions.length : 0
        const delivered = activation.delivery !== null && activation.delivery !== undefined
        const ownerClaims = item.owner.claims.map(claim => claim.keeper).join(', ') || 'unclaimed'
        return html`
          <div key=${JSON.stringify([item.trace_id, runField(activation, 'skill_tool_use_id')])}>
            <div class="font-semibold">Latest independent activation · ${delivered ? '✓ delivered' : '◌ invoked'} · ${ownerClaims} · ${actions} original-turn actions${activationEvidence.length > 1 ? ` · equal-time candidate ${index + 1}/${activationEvidence.length}` : ''}</div>
            <div class="ss-muted mono">${runField(activation, 'activated_at')} · tool use ${runField(activation, 'skill_tool_use_id')} · trace ${item.trace_id} · owner ${item.owner.status}</div>
            <div class="ss-muted mono">original ${runField(activation, 'turn_ref')} · runtime ${runField(activation, 'runtime_id')}</div>
            <${SkillAsyncEvidenceView} evidence=${item} />
          </div>
        `
      })}
      ${composition ? html`
        <div>
          <div class="font-semibold">
            ${runField(composition.result, 'disposition') === 'completed' ? '✓ completed' : runField(composition.result, 'disposition')}
            · ${runDuration(composition.result)}
            · ${composition.keeper}
          </div>
          <div class="ss-muted mono">${composition.composition_run_id} · ${compositionNodeCount} typed node settlements</div>
          <div class="ss-muted mono text-3xs">Recorded result ${recordedTimestamp(composition.recorded_at)} · ${composition.composition_execution} · request ${composition.request_id ?? 'inline'}
            · parent tool use ${composition.parent_tool_use_id || '(empty)'} · turn ${composition.parent_turn} · planned index ${composition.parent_planned_index}</div>
          ${composition.result.disposition === 'failed' ? html`
            <div class="mt-2 rounded border border-[var(--color-status-err)] p-2" role="note" aria-label="Composition failure">
              <strong>Composition failed</strong>
              <pre class="whitespace-pre-wrap text-3xs">${runField(composition.result, 'message')}</pre>
              <div class="ss-muted text-3xs">Failure class: ${runField(composition.result, 'failure_class')} · effect evidence: ${runField(composition.result, 'effect_disposition')}</div>
            </div>` : null}
          <div class="mt-2 font-semibold">Composition output</div>
          <pre class="mt-2 max-h-56 overflow-auto whitespace-pre-wrap rounded bg-[var(--color-surface-raised)] p-2 text-3xs">${runOutput(output)}</pre>
          <${SkillNodeEvidenceView} nodes=${composition.executor_settlements} />
        </div>
      ` : null}
      <div class="ss-muted text-3xs">
        coverage ${coverageSummary} · ${result.coverage.activation_scope}
        ${result.coverage.composition_unavailable.length > 0 ? html` · ⚠ ${result.coverage.composition_unavailable.join(' · ')}` : null}
      </div>
    </div>
  `
}

function AsyncRequestObservationView({
  observation,
  error,
  onInspect,
}: {
  observation: AsyncRequestObservation | null
  error: string | null
  onInspect: (identity: AsyncRequestIdentity) => void
}) {
  if (error) return html`<div class="text-[var(--color-status-error)]">Async broker unavailable: ${error}</div>`
  if (!observation) return html`<div class="ss-muted">Loading async broker observation…</div>`
  if (observation.status === 'unavailable') {
    return html`<div class="text-[var(--color-status-error)]">Durable async inventory is unavailable.</div>`
  }
  const recovery = observation.startup_recovery
  return html`
    <div class="rounded border border-[var(--color-border)] p-3" data-testid="async-request-observation">
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <strong>Async broker</strong>
        <span>${observation.summary.active} active</span>
        <span class="text-[var(--color-status-good)]">${observation.summary.runtime_owned} runtime-owned</span>
        <span class=${observation.summary.ownership_unknown > 0 ? 'text-[var(--color-status-warn)]' : 'ss-muted'}>${observation.summary.ownership_unknown} ownership unknown</span>
        <span class=${observation.summary.record_errors > 0 ? 'text-[var(--color-status-error)]' : 'ss-muted'}>${observation.summary.record_errors} record errors</span>
      </div>
      ${observation.requests.length > 0 ? html`
        <div class="mt-2 grid gap-1">
          ${observation.requests.map(request => html`
            <div class="mono text-3xs" key=${JSON.stringify([request.submitted_by, request.request_id, request.keeper_name])}>
              ${request.request_id} · ${request.keeper_name} · ${request.status}
              · ${request.elapsed_sec === undefined ? '?s' : `${request.elapsed_sec.toFixed(1)}s`}
              · ${request.worker_ownership}
              <button type="button" class="ss-btn ml-2" onClick=${() => onInspect(request)}>Inspect exact request</button>
            </div>
          `)}
        </div>
      ` : html`<div class="mt-1 ss-muted">No durable active requests.</div>`}
      <div class="mt-2 ss-muted text-3xs">
        ${recovery
          ? `startup recovery lost=${recovery.lost} finalized=${recovery.finalized} cleaned=${recovery.cleaned} unreadable=${recovery.unreadable} failed=${recovery.failed}`
          : 'startup recovery was not observed by this process'}
      </div>
    </div>
  `
}

interface SkillSourceEditorProps {
  reference: SkillReference
  onPublished: (message: string) => void | Promise<void>
  onMutation?: (result: SkillMutationResult) => void
  observationCurrent?: () => boolean
}

type SkillMutationResult =
  | { kind: 'created'; identity: SkillIdentity; receipt: SkillCreateReceipt }
  | { kind: 'saved'; reference: SkillReference; receipt: SkillEditorSaveReceipt }
  | { kind: 'request_error'; request: { operation: 'create'; identity: SkillIdentity } | { operation: 'save'; reference: SkillReference }; detail: string }

const REVISION_CONFLICT_GUIDANCE = 'This Skill changed after you loaded it. Copy this draft, reload the Skills workspace, then reapply it to the latest revision before saving.'

function editorPreviewSummary(preview: SkillEditorPreview): string {
  const profile = preview.profile
  return `${profile.kind} · ${profile.execution} · ${profile.plan.node_count} nodes · revision ${profile.reference.content_revision.slice(0, 12)}`
}

export function SkillSourceEditor({ reference, onPublished, onMutation, observationCurrent }: SkillSourceEditorProps) {
  const referenceIdentity = referenceKey(reference.identity, reference.content_revision)
  const open = useSignal(false)
  const loaded = useSignal<SkillEditorLoaded | null>(null)
  const draft = useSignal('')
  const preview = useSignal<SkillEditorPreview | null>(null)
  const previewedSource = useSignal<string | null>(null)
  const busy = useSignal<'load' | 'preview' | 'save' | null>(null)
  const status = useSignal<string | null>(null)
  const conflict = useSignal(false)
  const reloadRequired = useSignal(false)
  const requestGeneration = useSignal(0)
  const activeReferenceIdentity = useSignal(referenceIdentity)

  useEffect(() => {
    if (activeReferenceIdentity.value !== referenceIdentity) {
      activeReferenceIdentity.value = referenceIdentity
      requestGeneration.value += 1
      open.value = false
      loaded.value = null
      draft.value = ''
      preview.value = null
      previewedSource.value = null
      busy.value = null
      status.value = null
      conflict.value = false
      reloadRequired.value = false
    }
    return () => {
      requestGeneration.value += 1
    }
  }, [referenceIdentity])

  const nextRequestGeneration = (): number => {
    requestGeneration.value += 1
    return requestGeneration.value
  }

  const requestIsCurrent = (
    generation: number,
    requestedReference: SkillReference,
    requestedSource?: string,
  ): boolean => {
    const currentReference = loaded.value?.reference
    return generation === requestGeneration.value
      && (observationCurrent?.() ?? true)
      && currentReference !== undefined
      && referenceKey(currentReference.identity, currentReference.content_revision)
        === referenceKey(requestedReference.identity, requestedReference.content_revision)
      && referenceIdentity
        === referenceKey(requestedReference.identity, requestedReference.content_revision)
      && (requestedSource === undefined || draft.value === requestedSource)
  }

  const load = async () => {
    if (observationCurrent && !observationCurrent()) return
    const generation = nextRequestGeneration()
    const requestedReference = reference
    open.value = true
    busy.value = 'load'
    status.value = null
    conflict.value = false
    reloadRequired.value = false
    try {
      const result = await readSkillSource(requestedReference)
      if (generation !== requestGeneration.value || (observationCurrent && !observationCurrent())) return
      loaded.value = result
      draft.value = result.source_text
      preview.value = null
      previewedSource.value = null
    } catch (cause) {
      if (generation !== requestGeneration.value || (observationCurrent && !observationCurrent())) return
      loaded.value = null
      if (classifySkillEditorError(cause) === 'revision_conflict') {
        conflict.value = true
        status.value = REVISION_CONFLICT_GUIDANCE
      } else {
        status.value = cause instanceof Error ? cause.message : String(cause)
      }
    } finally {
      if (generation === requestGeneration.value) busy.value = null
    }
  }

  if (!open.value) {
    return html`
      <button class="ss-btn" type="button" data-testid="skill-edit-open" onClick=${load}>
        Edit source
      </button>
    `
  }

  const canWrite = loaded.value?.access === 'read_write'
  const previewIsCurrent = preview.value !== null && previewedSource.value === draft.value
  return html`
    <div class="mt-3 grid gap-2 rounded border border-[var(--color-border)] p-3" data-testid="skill-source-editor">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <strong>Source editor</strong>
        <button
          class="ss-btn"
          type="button"
          disabled=${busy.value === 'save'}
          onClick=${() => {
            requestGeneration.value += 1
            busy.value = null
            open.value = false
          }}
        >Close</button>
      </div>
      ${busy.value === 'load'
        ? html`<div class="ss-muted">Loading exact source revision…</div>`
        : loaded.value
          ? html`
              <div class="ss-muted mono text-3xs">
                snapshot ${loaded.value.snapshot_revision.slice(0, 12)} · revision ${loaded.value.reference.content_revision.slice(0, 12)} · ${loaded.value.access}
              </div>
              <textarea
                class="ss-input min-h-64 font-mono text-xs"
                data-testid="skill-source-draft"
                value=${draft.value}
                readOnly=${!canWrite || busy.value === 'save'}
                onInput=${(event: Event) => {
                  if (busy.value === 'save') return
                  draft.value = (event.currentTarget as HTMLTextAreaElement).value
                  preview.value = null
                  previewedSource.value = null
                  conflict.value = false
                  status.value = null
                }}
              />
              ${canWrite
                ? html`
                    <div class="flex flex-wrap items-center gap-2">
                      <button
                        class="ss-btn"
                        type="button"
                        disabled=${busy.value !== null || reloadRequired.value}
                        onClick=${async () => {
                          if (observationCurrent && !observationCurrent()) return
                          const requestedReference = loaded.value?.reference
                          if (!requestedReference) return
                          const requestedSource = draft.value
                          const generation = nextRequestGeneration()
                          busy.value = 'preview'
                          status.value = null
                          conflict.value = false
                          try {
                            const result = await previewSkillSource(
                              requestedReference,
                              requestedSource,
                            )
                            if (!requestIsCurrent(generation, requestedReference, requestedSource)) {
                              return
                            }
                            preview.value = result
                            previewedSource.value = requestedSource
                            status.value = 'Preview valid'
                          } catch (cause) {
                            if (!requestIsCurrent(generation, requestedReference, requestedSource)) {
                              return
                            }
                            preview.value = null
                            previewedSource.value = null
                            if (classifySkillEditorError(cause) === 'revision_conflict') {
                              conflict.value = true
                              status.value = REVISION_CONFLICT_GUIDANCE
                            } else {
                              status.value = cause instanceof Error ? cause.message : String(cause)
                            }
                          } finally {
                            if (generation === requestGeneration.value) busy.value = null
                          }
                        }}
                      >${busy.value === 'preview' ? 'Previewing…' : 'Preview'}</button>
                      <button
                        class="ss-btn"
                        type="button"
                        data-testid="skill-source-save"
                        disabled=${busy.value !== null || !previewIsCurrent || reloadRequired.value}
                        onClick=${async () => {
                          if (observationCurrent && !observationCurrent()) return
                          const requestedReference = loaded.value?.reference
                          if (!requestedReference) return
                          const requestedSource = draft.value
                          const generation = nextRequestGeneration()
                          busy.value = 'save'
                          status.value = null
                          conflict.value = false
                          let received = false
                          try {
                            const receipt = await saveSkillSource(
                              requestedReference,
                              requestedSource,
                            )
                            received = true
                            // A sent mutation's receipt outlives this editor's read owner.
                            onMutation?.({ kind: 'saved', reference: requestedReference, receipt })
                            if (!requestIsCurrent(generation, requestedReference, requestedSource)) {
                              return
                            }
                            if (receipt.status === 'saved_but_unpublished') {
                              reloadRequired.value = true
                              status.value = `Saved to disk but not published: ${receipt.reason}. Reload the Skills workspace after publication recovers.`
                            } else {
                              await onPublished(
                                receipt.status === 'unchanged'
                                  ? 'Skill source was unchanged.'
                                  : `Skill saved and published at ${receipt.preview.profile.reference.content_revision.slice(0, 12)}.`,
                              )
                              if (requestIsCurrent(generation, requestedReference, requestedSource)) {
                                open.value = false
                              }
                            }
                          } catch (cause) {
                            if (!received) onMutation?.({ kind: 'request_error', request: { operation: 'save', reference: requestedReference },
                              detail: cause instanceof Error ? cause.message : String(cause) })
                            if (!requestIsCurrent(generation, requestedReference, requestedSource)) {
                              return
                            }
                            if (classifySkillEditorError(cause) === 'revision_conflict') {
                              conflict.value = true
                              status.value = REVISION_CONFLICT_GUIDANCE
                            } else {
                              status.value = cause instanceof Error ? cause.message : String(cause)
                            }
                          } finally {
                            if (generation === requestGeneration.value) busy.value = null
                          }
                        }}
                      >${busy.value === 'save' ? 'Saving…' : 'Save'}</button>
                      <span class="ss-muted">Preview the current draft before saving.</span>
                    </div>
                  `
                : html`<div class="text-[var(--color-status-warn)]">This Skill source is read-only.</div>`}
              ${preview.value ? html`
                <div class="rounded border border-[var(--color-border-subtle)] p-2" data-testid="skill-source-preview">
                  <div>${editorPreviewSummary(preview.value)}</div>
                  ${preview.value.diagnostics.length > 0
                    ? html`<div class="mt-1 text-[var(--color-status-warn)]">${preview.value.diagnostics.join(' · ')}</div>`
                    : html`<div class="ss-muted">No diagnostics</div>`}
                </div>
              ` : null}
            `
          : null}
      ${status.value ? html`
        <div
          class=${conflict.value ? 'text-[var(--color-status-warn)]' : 'ss-muted'}
          data-testid=${conflict.value ? 'skill-source-conflict' : 'skill-source-status'}
        >${status.value}</div>
      ` : null}
    </div>
  `
}


interface SkillsObservationOwner extends DashboardObservationOwner {
  readonly mount: number
}

function identityLabel(identity: SkillIdentity): string {
  return `${identity.source_id}/${identity.package_id}/${identity.name}`
}

function mutationMessage(result: SkillMutationResult): string {
  switch (result.kind) {
    case 'created': return `Create response for ${identityLabel(result.identity)}: ${createReceiptMessage(result.receipt)}`
    case 'saved': return result.receipt.status === 'saved_but_unpublished'
      ? `Save response for ${identityLabel(result.reference.identity)} @ ${result.reference.content_revision}: saved but not published: ${result.receipt.reason}`
      : `Save response for ${identityLabel(result.reference.identity)} @ ${result.reference.content_revision}: ${result.receipt.status}`
    case 'request_error': {
      const target = result.request.operation === 'create'
        ? identityLabel(result.request.identity)
        : `${identityLabel(result.request.reference.identity)} @ ${result.request.reference.content_revision}`
      return `${result.request.operation} request for ${target} returned an error; effect not confirmed: ${result.detail}`
    }
  }
}

export function SkillsPanel() {
  const authRevision = storedTokenRevision.value
  const authority = executionWorkspaceAuthority.value
  void dashboardActorRevision.value
  void managedDashboardActorRevision.value
  const observation = captureDashboardObservationOwner()
  const mounts = useRef(0)
  // The ordinal only keys UI lifetime. Authority remains the existing SSOT's
  // object identity, including a new object with otherwise equal fields.
  const owner = useMemo(() => ({ ...observation, mount: ++mounts.current }), [authRevision, authority,
    observation.actor, observation.actorRevision, observation.managed])
  const receipts = useSignal<readonly { owner: SkillsObservationOwner; result: SkillMutationResult }[]>([])
  return html`<div>
    ${receipts.value.length > 0 ? html`<section aria-label="Skill mutation receipts" data-testid="skill-mutation-receipts">
      ${receipts.value.map((receipt, index) => html`<div key=${index}>
        ${mutationMessage(receipt.result)}
        <span class="ss-muted"> · original workspace ${receipt.owner.workspace?.workspaceRoot ?? 'unconfirmed'}
          ${receipt.owner !== owner ? ' · previous access context' : ''}</span>
      </div>`)}
    </section>` : null}
    ${!dashboardObservationOwnerHasWorkspace(owner)
      ? html`<p role="status">Confirm the current workspace before reading Skills.</p>`
      : html`<${SkillsObservationPanel} key=${owner.mount} owner=${owner}
          onMutation=${(result: SkillMutationResult) => { receipts.value = [...receipts.value, { owner, result }] }} />`}
  </div>`
}

function SkillEvidenceLoader({ reference, io, isCurrent }: {
  reference: SkillReference
  io: SkillSurfaceProfile['io'] | null
  isCurrent: () => boolean
}) {
  const result = useSignal<SkillEvidenceResponse | null>(null)
  const error = useSignal<string | null>(null)
  const loading = useSignal(false)
  const active = useRef(true)
  const requestGeneration = useRef(0)
  useEffect(() => () => { active.current = false; requestGeneration.current += 1 }, [])
  const load = async (runId?: string) => {
    if (!active.current || !isCurrent()) return
    const generation = ++requestGeneration.current
    loading.value = true
    error.value = null
    try {
      const evidence = await fetchSkillEvidence(reference, runId)
      if (!active.current || !isCurrent() || generation !== requestGeneration.current) return
      result.value = evidence
    } catch (cause) {
      if (active.current && isCurrent() && generation === requestGeneration.current) {
        error.value = cause instanceof Error ? cause.message : String(cause)
      }
    } finally {
      if (active.current && isCurrent() && generation === requestGeneration.current) loading.value = false
    }
  }
  return html`<div>
    <div class="mb-2 flex items-center justify-between"><strong>Retained evidence</strong>
      <button class="ss-btn" type="button" disabled=${loading.value} onClick=${() => { void load() }}>${loading.value ? 'Loading…' : 'Load'}</button>
    </div>
    ${loading.value && result.value ? html`<p role="status">Loading requested selection; previous observation retained.</p>` : null}
    ${error.value ? html`<div role="alert" class="text-[var(--color-status-err)]">${error.value}</div>` : null}
    ${result.value ? html`<${SkillRunHistory} result=${result.value} onSelect=${(runId?: string) => { void load(runId) }} />` : null}
    <${SkillEvidenceView} result=${result.value} io=${io} />
  </div>`
}

function SkillsObservationPanel({ owner, onMutation }: {
  owner: SkillsObservationOwner
  onMutation: (result: SkillMutationResult) => void
}) {
  const response = useSignal<SkillsResponse | null>(null)
  const keeperUsage = useSignal<KeeperUsageReading | null>(null)
  const usageController = useRef<AbortController | null>(null)
  const loading = useSignal(true)
  const error = useSignal<string | null>(null)
  const asyncObservation = useSignal<AsyncRequestObservation | null>(null)
  const asyncObservationError = useSignal<string | null>(null)
  const catalogReadError = useRef<unknown | null>(null)
  const asyncReadError = useRef<unknown | null>(null)
  const asyncSubmitter = useSignal('')
  const asyncKeeper = useSignal('')
  const asyncRequestId = useSignal('')
  const asyncSelection = useSignal<{ identity: AsyncRequestIdentity; visit: number } | null>(null)
  const asyncVisits = useRef(0)
  const expanded = useSignal<string | null>(null)
  const search = useSignal('')
  const sourceFilter = useSignal('')
  const kindFilter = useSignal('')
  const nameSelectionFilter = useSignal('')
  const createOpen = useSignal(false)
  const createMounted = useSignal(false)
  const editorNotice = useSignal<string | null>(null)
  const active = useRef(true)
  const catalogGeneration = useRef(0)
  const asyncGeneration = useRef(0)
  const current = () => active.current && dashboardObservationOwnerIsCurrent(owner)
    && dashboardObservationOwnerHasWorkspace(owner)

  const inspectAsync = (identity: AsyncRequestIdentity) => {
    if (!current()) return
    asyncSubmitter.value = identity.submitted_by
    asyncKeeper.value = identity.keeper_name
    asyncRequestId.value = identity.request_id
    asyncSelection.value = { identity: { submitted_by: identity.submitted_by,
      request_id: identity.request_id, keeper_name: identity.keeper_name }, visit: ++asyncVisits.current }
  }

  // Each Keeper's usage is its own read (RFC-0483), so reading every Keeper
  // does not carry every ledger. The catalog read does not wait for them, and
  // a newer round cancels the older one.
  const usageReadError = useRef<unknown | null>(null)
  const loadUsage = async (signal?: AbortSignal) => {
    usageReadError.current = null
    if (!current() || signal?.aborted) return
    usageController.current?.abort()
    usageController.current = null
    if (!executionLoaded.peek()) {
      // The roster is not read yet: an empty answer would read as "no Keeper
      // used it" when no Keeper was asked.
      keeperUsage.value = null
      return
    }
    const controller = new AbortController()
    usageController.current = controller
    const readSignal = signal ? AbortSignal.any([signal, controller.signal]) : controller.signal
    const names = keepers.peek().map(keeper => keeper.name)
    const settled = await Promise.allSettled(
      names.map(name => fetchKeeperSkillUsage(name, { signal: readSignal })),
    )
    if (!current() || readSignal.aborted) return
    usageReadError.current = selectObservationReadFailure(settled.map(result => result.status === 'rejected' ? result.reason : null))
    keeperUsage.value = keeperUsageReading(
      names.map((keeper, index) => ({ keeper, result: settled[index]! })),
    )
  }

  const load = async (signal?: AbortSignal) => {
    if (!current() || signal?.aborted) return
    catalogReadError.current = null
    const generation = ++catalogGeneration.current
    try {
      const res = await fetchSkills({ signal })
      if (!current() || signal?.aborted || generation !== catalogGeneration.current) return
      response.value = res
      error.value = null
      if (res.state === 'ready') await loadUsage(signal)
    } catch (cause) {
      if (!current() || signal?.aborted || generation !== catalogGeneration.current || isAbortError(cause)) return
      catalogReadError.current = cause
      error.value = cause instanceof Error ? cause.message : 'skills fetch failed'
    } finally {
      if (current() && !signal?.aborted && generation === catalogGeneration.current) loading.value = false
    }
  }

  useEffect(() => {
    const loadAsyncObservation = async (signal: AbortSignal) => {
      if (!current() || signal.aborted) return
      asyncReadError.current = null
      const generation = ++asyncGeneration.current
      try {
        const observation = await fetchAsyncRequestObservation({ signal: signal })
        if (!current() || signal.aborted || generation !== asyncGeneration.current) return
        asyncObservation.value = observation
        asyncObservationError.value = null
      } catch (e) {
        if (!current() || signal.aborted || generation !== asyncGeneration.current || isAbortError(e)) return
        asyncReadError.current = e
        asyncObservationError.value = (e as Error).message || 'async observation fetch failed'
      }
    }
    const dispose = setupObservationRefresh(signal => Promise.all([
      load(signal), loadAsyncObservation(signal),
    ]), { topics: ['skills', 'async_requests', 'skill_usage'], readError: () => selectObservationReadFailure([
      catalogReadError.current, asyncReadError.current, usageReadError.current,
    ]), resetRead: () => {
      usageController.current?.abort()
      catalogReadError.current = null
      asyncReadError.current = null
      usageReadError.current = null
      response.value = null
      keeperUsage.value = null
      asyncObservation.value = null
      error.value = null
      asyncObservationError.value = null
      loading.value = true
    } })
    return () => {
      active.current = false
      usageController.current?.abort()
      dispose()
    }
  }, [])

  // The roster can arrive after the catalog; its arrival reads the usage.
  const rosterLoaded = executionLoaded.value
  useEffect(() => {
    if (rosterLoaded && response.peek()?.state === 'ready') void loadUsage()
  }, [rosterLoaded])

  if (loading.value && !response.value) {
    return html`<${LoadingState}>Loading skills...<//>`
  }
  if (error.value && !response.value) {
    return html`<${ErrorState} message=${error.value} />`
  }
  const res = response.value
  if (!res) return null
  if (res.state !== 'ready') {
    return html`<${EmptyState} message=${stateMessage(res.state)} />`
  }
  const effectiveIdentities = new Set(res.snapshot.effective_skills.map(identityKey))
  const winners = new Map(res.snapshot.shadows.map(shadow => [identityKey(shadow.shadowed), shadow.winner]))
  const rows = sortSkillRows(mergeSkillRows(res.snapshot.skills, res.surfaces)).map(row => {
    const key = identityKey(row.identity)
    const winner = winners.get(key)
    const effective = effectiveIdentities.has(key)
    const selection: NameSelection = effective && !winner ? { kind: 'effective' }
      : !effective && winner ? { kind: 'shadowed', winner } : { kind: 'unavailable' }
    return { ...row, selection }
  })
  const sourceIds = [...new Set(rows.map(row => row.identity.source_id))]
  const query = search.value.trim().toLocaleLowerCase()
  const visibleRows = rows.filter(row =>
    (!sourceFilter.value || row.identity.source_id === sourceFilter.value)
    && (!kindFilter.value || (row.surface?.kind ?? 'unavailable') === kindFilter.value)
    && (!nameSelectionFilter.value || row.selection.kind === nameSelectionFilter.value)
    && (!query || [row.name, row.description, row.source]
      .some(value => value.toLocaleLowerCase().includes(query))),
  )
  const visibleKeys = new Set(visibleRows.map(skillRowKey))
  return html`
    <${SurfaceCard} testId="skills-panel">
      ${error.value ? html`<div role="alert">Catalog refresh failed: ${error.value}</div>` : null}
      <div class="mb-3 flex items-center justify-between gap-2">
        <strong>Skill Studio</strong>
        <button class="ss-btn" type="button" aria-expanded=${createOpen.value} onClick=${() => {
          createMounted.value = true
          createOpen.value = !createOpen.value
        }}>+ New Skill</button>
      </div>
      ${createMounted.value ? html`<div hidden=${!createOpen.value}>
        <${SkillCreateForm} isCurrent=${current} onPublished=${load}
          onReceipt=${(identity: SkillIdentity, receipt: SkillCreateReceipt) => onMutation({ kind: 'created', identity, receipt })}
          onRequestError=${(identity: SkillIdentity, detail: string) => onMutation({ kind: 'request_error', request: { operation: 'create', identity }, detail })} />
      </div>` : null}
      ${editorNotice.value ? html`
        <div class="mb-3 text-[var(--color-status-good)]" data-testid="skill-editor-notice">
          ${editorNotice.value}
        </div>
      ` : null}
      <${AsyncRequestObservationView} observation=${asyncObservation.value} error=${asyncObservationError.value} onInspect=${inspectAsync} />
      <form class="my-2 flex flex-wrap items-end gap-2" aria-label="Retained async request lookup" onSubmit=${(event: SubmitEvent) => {
        event.preventDefault()
        inspectAsync({ submitted_by: asyncSubmitter.value, keeper_name: asyncKeeper.value, request_id: asyncRequestId.value })
      }}>
        <label>Request submitter<input class="ss-input" required value=${asyncSubmitter.value} onInput=${(event: Event) => { asyncSubmitter.value = (event.currentTarget as HTMLInputElement).value }} /></label>
        <label>Request Keeper<input class="ss-input" required value=${asyncKeeper.value} onInput=${(event: Event) => { asyncKeeper.value = (event.currentTarget as HTMLInputElement).value }} /></label>
        <label>Request ID<input class="ss-input mono" required value=${asyncRequestId.value} onInput=${(event: Event) => { asyncRequestId.value = (event.currentTarget as HTMLInputElement).value }} /></label>
        <button type="submit" class="ss-btn">Look up exact request</button>
      </form>
      ${asyncSelection.value ? html`<${AsyncRequestDetails} key=${asyncSelection.value.visit} identity=${asyncSelection.value.identity} isCurrent=${current} />` : null}
      <div class="ss-muted" data-testid="skills-revision">
        snapshot ${res.snapshot.snapshot_revision.slice(0, 12)} · catalog ${res.snapshot.catalog_revision.slice(0, 12)}
        · ${resourceReadBoundLabel(res.snapshot.config)}
        ${res.snapshot.rejections.length > 0
          ? html` · ${res.snapshot.rejections.length} rejected`
          : null}
      </div>
      <div class="ss-muted my-2" data-testid="skill-usage-coverage">
        Usage scope: exact revision · retained current Keeper sessions.
        ${keeperUsage.value ? html`
          ${keeperUsage.value.ledgersRead} ledgers read · ${keeperUsage.value.unavailable.length} unavailable.
          ${keeperUsage.value.unavailable.length > 0 ? html`<details class="text-[var(--color-status-warn)]"><summary>Incomplete session coverage</summary>
            ${keeperUsage.value.unavailable.map(detail => html`<div key=${detail}>${detail}</div>`)}
          </details>` : null}
        ` : html`Coverage unavailable; displayed users cannot establish fleet-wide usage.`}
        Received counts invocations handed to a provider/client, including asynchronous results. Actions are counted per Skill invocation; one tool call may contribute to several invocations. An observed action does not imply completion.
      </div>
      ${rows.length > 0 ? html`<div class="my-3 flex flex-wrap items-end gap-2" aria-label="Skill filters">
        <label>Find Skill<input class="ss-input" type="search" value=${search.value}
          placeholder="Name, purpose or source" onInput=${(event: Event) => { search.value = (event.currentTarget as HTMLInputElement).value }} /></label>
        <label>Source<select class="ss-input" value=${sourceFilter.value}
          onChange=${(event: Event) => { sourceFilter.value = (event.currentTarget as HTMLSelectElement).value }}>
          <option value="">All sources</option>
          ${sourceIds.map(source => html`<option value=${source} key=${source}>${source}</option>`)}
        </select></label>
        <label>Kind<select class="ss-input" value=${kindFilter.value}
          onChange=${(event: Event) => { kindFilter.value = (event.currentTarget as HTMLSelectElement).value }}>
          <option value="">All kinds</option><option value="instruction">Instruction</option>
          <option value="composition">Composition</option><option value="unavailable">Surface unavailable</option>
        </select></label>
        <label>Name selection<select class="ss-input" value=${nameSelectionFilter.value}
          onChange=${(event: Event) => { nameSelectionFilter.value = (event.currentTarget as HTMLSelectElement).value }}>
          <option value="">All name selections</option><option value="effective">Effective by name</option>
          <option value="shadowed">Shadowed</option><option value="unavailable">Selection unavailable</option>
        </select></label>
        <button class="ss-btn" type="button" onClick=${() => { search.value = ''; sourceFilter.value = ''; kindFilter.value = ''; nameSelectionFilter.value = '' }}>Clear filters</button>
        <span role="status">${visibleRows.length} of ${rows.length} published Skills</span>
        <div class="ss-muted text-3xs">Name selection follows catalog source precedence. Keeper configuration can further limit activation.</div>
      </div>` : null}
      ${rows.length > 0 ? html`<table hidden=${visibleRows.length === 0} class="ss-table" data-testid="skills-table">
        <thead>
          <tr>
            <th>skill</th><th>capability</th><th>context</th><th>Session usage</th><th>source</th>
          </tr>
        </thead>
        <tbody>
          ${rows.map(row => {
            const rowKey = skillRowKey(row)
            const isExpanded = expanded.value === rowKey
            const filtered = !visibleKeys.has(rowKey)
            return html`
              <tr hidden=${filtered} key=${rowKey} data-testid=${`skill-row-${row.name}`}>
                <td>
                  <button class="text-left" type="button" aria-expanded=${isExpanded} aria-label=${`Read instructions for ${row.name}`} onClick=${() => { expanded.value = isExpanded ? null : rowKey }}><strong>${isExpanded ? '▾' : '▸'} ${row.name}</strong><span class="ss-muted ml-2">Read instructions</span></button><div class="ss-muted">${row.description}</div>
                  ${row.selection.kind === 'effective' ? html`<div class="ss-muted text-3xs">Effective by name</div>`
                    : row.selection.kind === 'shadowed' ? html`<div class="text-3xs text-[var(--color-status-warn)]">Shadowed by ${row.selection.winner.source_id}/${row.selection.winner.package_id}</div>`
                      : html`<div class="text-3xs text-[var(--color-status-warn)]">Name selection unavailable</div>`}
                  ${row.diagnostics.map(
                    diagnostic => html`<div class="mt-1 text-3xs text-[var(--color-status-warn)]">⚠ ${diagnostic}</div>`,
                  )}
                </td>
                <td>
                  ${capabilityLabel(row.surface)}
                  <div class="ss-muted mono">${row.surface && row.surface.kind !== 'unavailable' ? row.surface.profile.activation_tool : 'unavailable'}</div>
                </td>
                <td>${contextLabel(row.surface, row.body_bytes)}</td>
                <td>${usageLabel(row.surface && keeperUsage.value
                  ? usageFor(keeperUsage.value, row.surface.reference)
                  : null)}</td>
                <td class="mono">${row.source}</td>
              </tr>
              ${isExpanded ? html`
                <tr hidden=${filtered} key=${`${rowKey}-detail`}><td colspan="5">
                  ${row.surface ? html`<${SkillSourceInspector} reference=${row.surface.reference} />`
                    : html`<p role="status">Exact source unavailable: this Skill has no published source reference.</p>`}
                  <div class="grid min-w-0 gap-3 p-2">
                    <div><strong>Execution flow</strong>${row.surface && row.surface.kind !== 'unavailable' ? html`<${SkillFlowView} profile=${row.surface.profile} /><${SkillIoView} profile=${row.surface.profile} />` : html`<div class="ss-muted">No profile</div>`}</div>
                    ${row.surface ? html`<${SkillEvidenceLoader} key=${rowKey}
                      reference=${row.surface.reference} io=${row.surface.kind === 'unavailable' ? null : row.surface.profile.io} isCurrent=${current} />` : null}
                  </div>
                  ${row.surface ? html`
                    <${SkillSourceEditor}
                      reference=${row.surface.reference}
                      onMutation=${onMutation}
                      observationCurrent=${current}
                      onPublished=${async (message: string) => {
                        if (!current()) return
                        editorNotice.value = message
                        await load()
                      }}
                    />
                  ` : null}
                </td></tr>
              ` : null}
            `
          })}
        </tbody>
      </table>` : res.snapshot.rejections.length > 0
        ? html`<div class="ss-muted py-3" data-testid="skills-no-valid">No valid Skills are published.</div>`
        : html`<${EmptyState} message="The published snapshot lists no skills." />`}
      ${rows.length > 0 && visibleRows.length === 0
        ? html`<p role="status">No published Skills match these filters.</p>` : null}
      ${res.snapshot.rejections.length > 0 ? html`
        <div class="mt-4" data-testid="skill-rejections">
          <strong>Rejected source candidates</strong>
          <table class="ss-table mt-2">
            <thead><tr><th>source</th><th>content revision</th><th>typed reason</th></tr></thead>
            <tbody>
              ${res.snapshot.rejections.map(rejection => html`
                <tr key=${`${rejection.source_id}/${rejection.package_id ?? ''}/${rejection.content_revision ?? ''}`}>
                  <td class="mono">${rejection.source_id}/${rejection.package_id ?? '(invalid package)'}</td>
                  <td class="mono">${rejection.content_revision?.slice(0, 12) ?? 'unavailable'}</td>
                  <td>
                    ${rejectionDiagnostics(rejection).map(diagnostic => html`
                      <div class="text-[var(--color-status-warn)]">${diagnostic}</div>
                    `)}
                  </td>
                </tr>
              `)}
            </tbody>
          </table>
        </div>
      ` : null}
    <//>
  `
}
