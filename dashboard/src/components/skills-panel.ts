// Skills Panel — the published skill snapshot and exact parser-derived surface.
import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  classifySkillEditorError,
  createSkill,
  fetchAsyncRequestObservation,
  fetchSkills,
  fetchSkillEvidence,
  fetchWritableSkillSources,
  previewSkillSource,
  readSkillSource,
  saveSkillSource,
  type SkillEvidenceResponse,
  type SkillCompositionEvidence,
  type SkillEditorLoaded,
  type SkillEditorPreview,
  type AsyncRequestObservation,
  type SkillIdentity,
  type SkillReference,
  type SkillSnapshotConfig,
  type SkillSnapshotEntry,
  type SkillSurface,
  type SkillSurfaceProfile,
  type SkillsResponse,
} from '../api/dashboard-skills'
import { SurfaceCard } from './common/card'
import { EmptyState, ErrorState, LoadingState } from './common/feedback-state'

const POLL_INTERVAL_MS = 30_000

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
  return `${formatBytes(context.discovery_bytes)} discovery · ${formatBytes(context.eager_body_bytes)} eager · ${formatBytes(context.body_bytes)} body`
}

export function usageLabel(surface: SkillSurface | null): string {
  const usage = surface?.usage ?? []
  if (usage.length === 0) return 'unused in current sessions'
  return usage
    .map(row => `${row.keeper} ${row.invocations}×/${row.deliveries} delivered/${row.actions} actions · last ${row.last_used_at}`)
    .join(' · ')
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

function SkillFlowView({ profile }: { profile: SkillSurfaceProfile }) {
  const flow = profile.flow
  if (!flow) {
    return html`<div class="ss-muted">Instruction body → keeper_skill → model-orchestrated tools</div>`
  }
  return html`
    <div class="mt-2 flex items-stretch gap-2 overflow-x-auto pb-2" data-testid="skill-flow">
      ${flow.batches.map((batch, index) => html`
        <div class="flex items-center gap-2" key=${batch.index}>
          <div class="min-w-48 rounded border border-[var(--color-border)] bg-[var(--color-surface-raised)] p-2">
            <div class="mb-2 text-3xs uppercase tracking-wide text-[var(--color-text-muted)]">
              batch ${batch.index} · ${batch.execution_mode}
            </div>
            <div class="space-y-1">
              ${batch.node_ids.map(nodeId => {
                const node = flow.nodes.find(candidate => candidate.id === nodeId)
                if (!node) return null
                const dependency = node.dependencies.length === 0
                  ? 'root'
                  : node.dependencies.map(edge => `${edge.node_id}:${edge.kind}`).join(', ')
                return html`
                  <div class="rounded border border-[var(--color-border-subtle)] px-2 py-1" key=${node.id}>
                    <div class="font-semibold">${node.id}</div>
                    <div class="mono text-3xs">${node.tool_name}</div>
                    <div class="ss-muted text-3xs">depends ${dependency}</div>
                  </div>
                `
              })}
            </div>
          </div>
          ${index < flow.batches.length - 1 ? html`<span class="text-lg text-[var(--color-accent)]">→</span>` : null}
        </div>
      `)}
    </div>
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

function compositionNodes(composition: SkillCompositionEvidence): readonly Record<string, unknown>[] {
  return composition.executor_settlements
}

function compositionCoverageLabel(scope: SkillEvidenceResponse['coverage']['composition_scope']): string {
  switch (scope) {
    case 'exact_reference_latest_completed':
      return 'composition exact-reference latest completed authority'
    case 'unavailable':
      return 'composition exact-reference latest-completed authority unavailable'
  }
}

function SkillEvidenceView({ result }: { result: SkillEvidenceResponse | null }) {
  if (!result) return html`<div class="ss-muted">Load retained exact-revision evidence.</div>`
  const activationGapCount = result.coverage.activation_gaps.length
  const coverageSummary = html`${result.coverage.activation_sessions_inspected} retained sessions inspected · ${result.coverage.activation_ledgers_loaded} activation ledgers loaded · ${activationGapCount} activation gaps · ${result.coverage.activation_owner_gap_count} owner gaps · ${result.coverage.composition_records_read} composition records read · ${compositionCoverageLabel(result.coverage.composition_scope)}`
  if (result.status === 'not_observed_in_retained_coverage') {
    return html`
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
  const compositionNodeCount = composition ? compositionNodes(composition).length : 0
  const output = composition?.result.data
  return html`
    <div class="space-y-2" data-testid="skill-retained-evidence">
      ${activationEvidence.map((item, index) => {
        const activation = item.activation
        const actions = Array.isArray(activation.actions) ? activation.actions.length : 0
        const delivered = activation.delivery !== null && activation.delivery !== undefined
        const ownerClaims = item.owner.claims.map(claim => claim.keeper).join(', ') || 'unclaimed'
        return html`
          <div>
            <div class="font-semibold">${delivered ? '✓ delivered' : '◌ invoked'} · ${ownerClaims} · ${actions} actions${activationEvidence.length > 1 ? ` · equal-time candidate ${index + 1}/${activationEvidence.length}` : ''}</div>
            <div class="ss-muted mono">${runField(activation, 'activated_at')} · tool use ${runField(activation, 'skill_tool_use_id')} · trace ${item.trace_id} · owner ${item.owner.status}</div>
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
          <pre class="mt-2 max-h-56 overflow-auto whitespace-pre-wrap rounded bg-[var(--color-surface-raised)] p-2 text-3xs">${runOutput(output)}</pre>
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
}: {
  observation: AsyncRequestObservation | null
  error: string | null
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
            <div class="mono text-3xs" key=${request.request_id}>
              ${request.request_id} · ${request.keeper_name} · ${request.status}
              · ${request.elapsed_sec === undefined ? '?s' : `${request.elapsed_sec.toFixed(1)}s`}
              · ${request.worker_ownership}
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
}

const REVISION_CONFLICT_GUIDANCE = 'This Skill changed after you loaded it. Copy this draft, reload the Skills workspace, then reapply it to the latest revision before saving.'

function editorPreviewSummary(preview: SkillEditorPreview): string {
  const profile = preview.profile
  return `${profile.kind} · ${profile.execution} · ${profile.plan.node_count} nodes · revision ${profile.reference.content_revision.slice(0, 12)}`
}

export function SkillSourceEditor({ reference, onPublished }: SkillSourceEditorProps) {
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
      && currentReference !== undefined
      && referenceKey(currentReference.identity, currentReference.content_revision)
        === referenceKey(requestedReference.identity, requestedReference.content_revision)
      && referenceIdentity
        === referenceKey(requestedReference.identity, requestedReference.content_revision)
      && (requestedSource === undefined || draft.value === requestedSource)
  }

  const load = async () => {
    const generation = nextRequestGeneration()
    const requestedReference = reference
    open.value = true
    busy.value = 'load'
    status.value = null
    conflict.value = false
    reloadRequired.value = false
    try {
      const result = await readSkillSource(requestedReference)
      if (generation !== requestGeneration.value) return
      loaded.value = result
      draft.value = result.source_text
      preview.value = null
      previewedSource.value = null
    } catch (cause) {
      if (generation !== requestGeneration.value) return
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
                          const requestedReference = loaded.value?.reference
                          if (!requestedReference) return
                          const requestedSource = draft.value
                          const generation = nextRequestGeneration()
                          busy.value = 'save'
                          status.value = null
                          conflict.value = false
                          try {
                            const receipt = await saveSkillSource(
                              requestedReference,
                              requestedSource,
                            )
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

function skillTemplate(kind: 'instruction' | 'composition', name: string, description: string, body: string): string {
  const frontmatter = `---\nname: ${name}\ndescription: ${JSON.stringify(description)}\n---\n\n`
  if (kind === 'instruction') return `${frontmatter}# ${name}\n\n${body}\n`
  return `${frontmatter}# ${name}\n\n${body}\n\n\`\`\`toml composition\n[[compositions]]\nname = ${JSON.stringify(name)}\ndescription = ${JSON.stringify(description)}\nexecution = "inline"\n\n[[compositions.nodes]]\nid = "clock"\ntool = "keeper_time_now"\n[compositions.nodes.input]\nkind = "literal"\nvalue = {}\n\`\`\`\n`
}

export function SkillsPanel() {
  const response = useSignal<SkillsResponse | null>(null)
  const loading = useSignal(true)
  const error = useSignal<string | null>(null)
  const asyncObservation = useSignal<AsyncRequestObservation | null>(null)
  const asyncObservationError = useSignal<string | null>(null)
  const expanded = useSignal<string | null>(null)
  const evidence = useSignal<Record<string, SkillEvidenceResponse>>({})
  const evidenceLoading = useSignal<string | null>(null)
  const createOpen = useSignal(false)
  const createKind = useSignal<'instruction' | 'composition'>('instruction')
  const createName = useSignal('')
  const createDescription = useSignal('')
  const createBody = useSignal('Write the repeatable procedure and success criteria here.')
  const writableSources = useSignal<readonly { source_id: string }[]>([])
  const createSource = useSignal('')
  const createStatus = useSignal<string | null>(null)
  const editorNotice = useSignal<string | null>(null)

  useEffect(() => {
    let cancelled = false
    const ctl = new AbortController()
    const load = async () => {
      try {
        const res = await fetchSkills({ signal: ctl.signal })
        if (cancelled) return
        response.value = res
        error.value = null
      } catch (e) {
        if (cancelled || isAbortError(e)) return
        error.value = (e as Error).message || 'skills fetch failed'
      } finally {
        if (!cancelled) loading.value = false
      }
    }
    const loadAsyncObservation = async () => {
      try {
        const observation = await fetchAsyncRequestObservation({ signal: ctl.signal })
        if (cancelled) return
        asyncObservation.value = observation
        asyncObservationError.value = null
      } catch (e) {
        if (cancelled || isAbortError(e)) return
        asyncObservationError.value = (e as Error).message || 'async observation fetch failed'
      }
    }
    load()
    loadAsyncObservation()
    const iv = window.setInterval(() => {
      load()
      loadAsyncObservation()
    }, POLL_INTERVAL_MS)
    return () => {
      cancelled = true
      ctl.abort()
      window.clearInterval(iv)
    }
  }, [])

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
  const rows = sortSkillRows(mergeSkillRows(res.snapshot.skills, res.surfaces))
  if (rows.length === 0) {
    return html`<${EmptyState} message="The published snapshot lists no skills." />`
  }
  return html`
    <${SurfaceCard} testId="skills-panel">
      <div class="mb-3 flex items-center justify-between gap-2">
        <strong>Skill Studio</strong>
        <button class="ss-btn" type="button" onClick=${async () => {
          createOpen.value = !createOpen.value
          if (createOpen.value && writableSources.value.length === 0) {
            try {
              writableSources.value = await fetchWritableSkillSources()
              createSource.value = writableSources.value[0]?.source_id ?? ''
            } catch (cause) {
              createStatus.value = cause instanceof Error ? cause.message : String(cause)
            }
          }
        }}>+ New Skill</button>
      </div>
      ${createOpen.value ? html`
        <form class="mb-4 grid gap-2 rounded border border-[var(--color-border)] p-3" data-testid="skill-create" onSubmit=${async (event: SubmitEvent) => {
          event.preventDefault()
          createStatus.value = 'Validating and publishing…'
          try {
            const sourceText = skillTemplate(createKind.value, createName.value, createDescription.value, createBody.value)
            const receipt = await createSkill({
              source_id: createSource.value,
              package_id: createName.value,
              source_text: sourceText,
            })
            createStatus.value = receipt.status === 'created_and_published'
              ? 'created and published'
              : `created but NOT published: ${receipt.reason}`
            response.value = await fetchSkills()
          } catch (cause) {
            createStatus.value = cause instanceof Error ? cause.message : String(cause)
          }
        }}>
          <div class="grid gap-2 md:grid-cols-3">
            <select class="ss-input" value=${createSource.value} onChange=${(event: Event) => { createSource.value = (event.currentTarget as HTMLSelectElement).value }} required>
              ${writableSources.value.map(source => html`<option value=${source.source_id}>${source.source_id}</option>`)}
            </select>
            <select class="ss-input" value=${createKind.value} onChange=${(event: Event) => { createKind.value = (event.currentTarget as HTMLSelectElement).value as 'instruction' | 'composition' }}>
              <option value="instruction">Instruction · on demand</option>
              <option value="composition">Composition · tool flow</option>
            </select>
            <input class="ss-input mono" value=${createName.value} pattern="[a-z0-9-]+" placeholder="skill-name" onInput=${(event: Event) => { createName.value = (event.currentTarget as HTMLInputElement).value }} required />
          </div>
          <input class="ss-input" value=${createDescription.value} placeholder="When should an agent use this?" onInput=${(event: Event) => { createDescription.value = (event.currentTarget as HTMLInputElement).value }} required />
          <textarea class="ss-input min-h-24" value=${createBody.value} onInput=${(event: Event) => { createBody.value = (event.currentTarget as HTMLTextAreaElement).value }} />
          ${createKind.value === 'composition' ? html`<div class="ss-muted">Starter flow: keeper_time_now. Create it, then use Edit to add validated nodes/dependencies or switch execution to async.</div>` : null}
          <div class="flex items-center gap-2"><button class="ss-btn" type="submit" disabled=${!createSource.value}>Create + publish</button><span class="ss-muted">${createStatus.value}</span></div>
        </form>
      ` : null}
      ${editorNotice.value ? html`
        <div class="mb-3 text-[var(--color-status-good)]" data-testid="skill-editor-notice">
          ${editorNotice.value}
        </div>
      ` : null}
      <${AsyncRequestObservationView} observation=${asyncObservation.value} error=${asyncObservationError.value} />
      <div class="ss-muted" data-testid="skills-revision">
        snapshot ${res.snapshot.snapshot_revision.slice(0, 12)} · catalog ${res.snapshot.catalog_revision.slice(0, 12)}
        · ${resourceReadBoundLabel(res.snapshot.config)}
        ${res.snapshot.rejections.length > 0
          ? html` · ${res.snapshot.rejections.length} rejected`
          : null}
      </div>
      <table class="ss-table" data-testid="skills-table">
        <thead>
          <tr>
            <th>skill</th><th>capability</th><th>context</th><th>current users</th><th>source</th>
          </tr>
        </thead>
        <tbody>
          ${rows.map(row => {
            const rowKey = skillRowKey(row)
            const isExpanded = expanded.value === rowKey
            return html`
              <tr key=${rowKey} data-testid=${`skill-row-${row.name}`}>
                <td>
                  <button class="text-left" type="button" onClick=${() => { expanded.value = isExpanded ? null : rowKey }}><strong>${isExpanded ? '▾' : '▸'} ${row.name}</strong></button><div class="ss-muted">${row.description}</div>
                  ${row.diagnostics.map(
                    diagnostic => html`<div class="mt-1 text-3xs text-[var(--color-status-warn)]">⚠ ${diagnostic}</div>`,
                  )}
                </td>
                <td>
                  ${capabilityLabel(row.surface)}
                  <div class="ss-muted mono">${row.surface && row.surface.kind !== 'unavailable' ? row.surface.profile.activation_tool : 'unavailable'}</div>
                </td>
                <td>${contextLabel(row.surface, row.body_bytes)}</td>
                <td>${usageLabel(row.surface)}</td>
                <td class="mono">${row.source}</td>
              </tr>
              ${isExpanded ? html`
                <tr key=${`${rowKey}-detail`}><td colspan="5">
                  <div class="grid gap-3 p-2 lg:grid-cols-[minmax(0,2fr)_minmax(18rem,1fr)]">
                    <div><strong>Execution flow</strong>${row.surface && row.surface.kind !== 'unavailable' ? html`<${SkillFlowView} profile=${row.surface.profile} />` : html`<div class="ss-muted">No profile</div>`}</div>
                    <div>
                      <div class="mb-2 flex items-center justify-between"><strong>Retained evidence</strong><button class="ss-btn" type="button" disabled=${evidenceLoading.value === rowKey} onClick=${async () => {
                        if (!row.surface) return
                        evidenceLoading.value = rowKey
                        try { evidence.value = { ...evidence.value, [rowKey]: await fetchSkillEvidence(row.surface.reference) } }
                        finally { evidenceLoading.value = null }
                      }}>${evidenceLoading.value === rowKey ? 'Loading…' : 'Load'}</button></div>
                      <${SkillEvidenceView} result=${evidence.value[rowKey] ?? null} />
                    </div>
                  </div>
                  ${row.surface ? html`
                    <${SkillSourceEditor}
                      reference=${row.surface.reference}
                      onPublished=${async (message: string) => {
                        editorNotice.value = message
                        try {
                          response.value = await fetchSkills()
                        } catch (cause) {
                          editorNotice.value = `${message} Catalog refresh failed: ${cause instanceof Error ? cause.message : String(cause)}`
                        }
                      }}
                    />
                  ` : null}
                </td></tr>
              ` : null}
            `
          })}
        </tbody>
      </table>
    <//>
  `
}
