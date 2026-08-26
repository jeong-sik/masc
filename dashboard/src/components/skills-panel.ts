// Skills Panel — the published skill snapshot, with what a turn makes of it.
//
// One row per effective skill: the kind a keeper turn parses it as, the tool
// a composition skill became, body size, source, and how many of the last N
// recorded tool calls used it. A workspace with no published snapshot shows
// its state by name, because that is what an operator needs to read.
import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  fetchSkills,
  type SkillSnapshotEntry,
  type SkillUsage,
  type SkillsResponse,
} from '../api/dashboard-skills'
import { SurfaceCard } from './common/card'
import { EmptyState, ErrorState, LoadingState } from './common/feedback-state'

const POLL_INTERVAL_MS = 30_000

export function isAbortError(e: unknown): boolean {
  return e instanceof Error && e.name === 'AbortError'
}

export interface SkillRow {
  name: string
  description: string
  source: string
  body_bytes: number
  diagnostics: string[]
  usage: SkillUsage | null
}

/** Effective skills joined to their usage by name; a skill the turn parser
 *  refused keeps its row with the refusal, never a guessed kind. */
export function mergeSkillRows(
  entries: readonly SkillSnapshotEntry[],
  usage: readonly SkillUsage[] = [],
): SkillRow[] {
  const byName = new Map<string, SkillUsage>()
  for (const u of usage) byName.set(u.name, u)
  return entries.map(entry => ({
    name: entry.identity.name,
    description: entry.description,
    source: `${entry.identity.source_id}/${entry.identity.package_id}`,
    body_bytes: entry.body_bytes,
    diagnostics: entry.diagnostics ?? [],
    usage: byName.get(entry.identity.name) ?? null,
  }))
}

export function useCount(usage: SkillUsage | null): number {
  return usage && usage.kind !== 'unparsed' ? usage.recent_use_count : 0
}

/** Most used first, then by name; stable for equal counts. */
export function sortSkillRows(rows: readonly SkillRow[]): SkillRow[] {
  return [...rows].sort(
    (a, b) => useCount(b.usage) - useCount(a.usage) || a.name.localeCompare(b.name),
  )
}

export function kindLabel(usage: SkillUsage | null): string {
  if (!usage) return 'not in usage'
  switch (usage.kind) {
    case 'composition':
      return `composition · ${usage.execution}`
    case 'instruction':
      return 'instruction'
    case 'unparsed':
      return `unparsed: ${usage.error}`
  }
}

/** "in the last N calls" — the window rides with the response. */
export function usageLabel(usage: SkillUsage | null, windowRows?: number): string {
  if (!usage || usage.kind === 'unparsed') return '—'
  if (windowRows === undefined) return `${usage.recent_use_count} (window unreported)`
  return `${usage.recent_use_count} in last ${windowRows} calls`
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  return `${(bytes / 1024).toFixed(1)} KB`
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
  const rows = sortSkillRows(mergeSkillRows(res.snapshot.skills, res.usage))
  if (rows.length === 0) {
    return html`<${EmptyState} message="The published snapshot lists no skills." />`
  }
  return html`
    <${SurfaceCard} testId="skills-panel">
      <div class="ss-muted" data-testid="skills-revision">
        snapshot ${res.snapshot.snapshot_revision.slice(0, 12)} · catalog ${res.snapshot.catalog_revision.slice(0, 12)}
        ${res.snapshot.rejections.length > 0
          ? html` · ${res.snapshot.rejections.length} rejected`
          : null}
      </div>
      <table class="ss-table" data-testid="skills-table">
        <thead>
          <tr>
            <th>skill</th><th>kind</th><th>tool</th><th>used</th><th>body</th><th>source</th>
          </tr>
        </thead>
        <tbody>
          ${rows.map(
            row => html`
              <tr key=${row.name} data-testid=${`skill-row-${row.name}`}>
                <td>
                  <strong>${row.name}</strong><div class="ss-muted">${row.description}</div>
                  ${row.diagnostics.map(
                    diagnostic => html`<div class="mt-1 text-3xs text-[var(--color-status-warn)]">⚠ ${diagnostic}</div>`,
                  )}
                </td>
                <td>${kindLabel(row.usage)}</td>
                <td class="mono">${row.usage?.kind === 'composition' ? row.usage.tool_name : '—'}</td>
                <td>${usageLabel(row.usage, res.recent_window_rows)}</td>
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
