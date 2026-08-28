// Skills Panel — the published skill snapshot and exact parser-derived surface.
import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  createSkill,
  fetchAsyncRequestObservation,
  fetchSkills,
  fetchSkillEvidence,
  fetchWritableSkillSources,
  type SkillEvidenceResponse,
  type AsyncRequestObservation,
  type SkillIdentity,
  type SkillProfile,
  type SkillSnapshotConfig,
  type SkillSnapshotEntry,
  type SkillSurface,
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
      diagnostics: [...new Set([...(entry.diagnostics ?? []), ...(surface?.diagnostics ?? [])])],
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
      return `composition · ${surface.execution}`
    case 'instruction':
      return 'instruction'
    case 'unavailable':
      return `unavailable: ${surface.error}`
  }
}

export function capabilityLabel(surface: SkillSurface | null): string {
  const profile = surface?.profile
  if (!profile) return kindLabel(surface)
  if (profile.kind === 'instruction') return 'on-demand · model orchestrated'
  const flags = [profile.execution, `${profile.plan.node_count} nodes`]
  if (profile.capabilities.batch) flags.push(`${profile.plan.batch_count} batches`)
  if (profile.capabilities.parallel) flags.push(`parallel ×${profile.plan.max_parallelism}`)
  return flags.join(' · ')
}

export function contextLabel(surface: SkillSurface | null, bodyBytes: number): string {
  const context = surface?.profile?.context
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

function SkillFlowView({ profile }: { profile: SkillProfile }) {
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

function SkillEvidenceView({ result }: { result: SkillEvidenceResponse | null }) {
  if (!result) return html`<div class="ss-muted">Load the latest exact-revision result.</div>`
  if (result.status === 'never_observed') {
    return html`
      <div class="text-[var(--color-status-warn)]">No exact-revision activation or composition run was observed.</div>
      <div class="ss-muted text-3xs">${result.coverage.instruction_ledgers_loaded} ledgers · ${result.coverage.composition_rows_scanned}/${result.coverage.composition_scan_limit} log rows</div>
    `
  }
  const activation = result.activation?.activation ?? null
  const actions = Array.isArray(activation?.actions) ? activation.actions.length : 0
  const delivered = activation?.delivery !== null && activation?.delivery !== undefined
  const composition = result.composition
  const output = composition?.run.output
  return html`
    <div class="space-y-2" data-testid="skill-latest-evidence">
      ${activation ? html`
        <div>
          <div class="font-semibold">${delivered ? '✓ delivered' : '◌ invoked'} · ${result.activation?.keeper} · ${actions} actions</div>
          <div class="ss-muted mono">${runField(activation, 'activated_at')} · tool use ${runField(activation, 'skill_tool_use_id')}</div>
        </div>
      ` : null}
      ${composition ? html`
        <div>
          <div class="font-semibold">
            ${runField(composition.run, 'success') === 'true' ? '✓ completed' : '✗ failed'}
            · ${runDuration(composition.run)}
            · ${runField(composition.run, 'keeper')}
          </div>
          <div class="ss-muted mono">${runField(composition.run, 'composition_run_id')} · ${composition.nodes.length} node rows</div>
          <pre class="mt-2 max-h-56 overflow-auto whitespace-pre-wrap rounded bg-[var(--color-surface-raised)] p-2 text-3xs">${runOutput(output)}</pre>
        </div>
      ` : null}
      <div class="ss-muted text-3xs">
        coverage ${result.coverage.instruction_ledgers_loaded} ledgers · ${result.coverage.composition_rows_scanned}/${result.coverage.composition_scan_limit} log rows
        ${result.coverage.unavailable.length > 0 ? html` · ⚠ ${result.coverage.unavailable.join(' · ')}` : null}
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
                  <div class="ss-muted mono">${row.surface?.profile?.activation_tool ?? (row.surface?.kind === 'composition' ? row.surface.tool_name : 'keeper_skill')}</div>
                </td>
                <td>${contextLabel(row.surface, row.body_bytes)}</td>
                <td>${usageLabel(row.surface)}</td>
                <td class="mono">${row.source}</td>
              </tr>
              ${isExpanded ? html`
                <tr key=${`${rowKey}-detail`}><td colspan="5">
                  <div class="grid gap-3 p-2 lg:grid-cols-[minmax(0,2fr)_minmax(18rem,1fr)]">
                    <div><strong>Execution flow</strong>${row.surface?.profile ? html`<${SkillFlowView} profile=${row.surface.profile} />` : html`<div class="ss-muted">No profile</div>`}</div>
                    <div>
                      <div class="mb-2 flex items-center justify-between"><strong>Latest evidence</strong><button class="ss-btn" type="button" disabled=${evidenceLoading.value === rowKey} onClick=${async () => {
                        if (!row.surface) return
                        evidenceLoading.value = rowKey
                        try { evidence.value = { ...evidence.value, [rowKey]: await fetchSkillEvidence(row.surface.reference) } }
                        finally { evidenceLoading.value = null }
                      }}>${evidenceLoading.value === rowKey ? 'Loading…' : 'Load'}</button></div>
                      <${SkillEvidenceView} result=${evidence.value[rowKey] ?? null} />
                    </div>
                  </div>
                </td></tr>
              ` : null}
            `
          })}
        </tbody>
      </table>
    <//>
  `
}
