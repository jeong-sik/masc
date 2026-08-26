// Skills Panel — the published skill snapshot and exact parser-derived surface.
import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  fetchSkills,
  type SkillIdentity,
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

export function SkillsPanel() {
  const response = useSignal<SkillsResponse | null>(null)
  const loading = useSignal(true)
  const error = useSignal<string | null>(null)

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
    load()
    const iv = window.setInterval(load, POLL_INTERVAL_MS)
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
            <th>skill</th><th>kind</th><th>tool</th><th>body</th><th>source</th>
          </tr>
        </thead>
        <tbody>
          ${rows.map(
            row => html`
              <tr key=${skillRowKey(row)} data-testid=${`skill-row-${row.name}`}>
                <td>
                  <strong>${row.name}</strong><div class="ss-muted">${row.description}</div>
                  ${row.diagnostics.map(
                    diagnostic => html`<div class="mt-1 text-3xs text-[var(--color-status-warn)]">⚠ ${diagnostic}</div>`,
                  )}
                </td>
                <td>${kindLabel(row.surface)}</td>
                <td class="mono">${row.surface?.kind === 'composition' ? row.surface.tool_name : '—'}</td>
                <td>${formatBytes(row.body_bytes)}</td>
                <td class="mono">${row.source}</td>
              </tr>
            `,
          )}
        </tbody>
      </table>
    <//>
  `
}
