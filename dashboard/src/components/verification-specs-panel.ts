// VerificationSpecsPanel — enumerates TLA+ specs with cfg coverage + mtime.
//
// Consumes:
//   GET /api/v1/verification/specs — dashboard_tla_specs.specs_json
//
// Surfaces formal verification coverage on the dashboard: which specs exist,
// which have clean + buggy configs (bug-model pattern), and when they were
// last modified.  Mirrors the managed-async-resource pattern used by
// cascade-config-panel.ts.

import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import {
  fetchTlaSpecs,
  type TlaSpecEntry,
  type TlaSpecsResponse,
} from '../api/dashboard'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { ErrorState, LoadingState } from './common/feedback-state'
import { StatusChip } from './common/status-chip'
import { createManagedAsyncResource, type ManagedAsyncResource } from '../lib/async-state'

async function loadSpecs(resource: ManagedAsyncResource<TlaSpecsResponse>) {
  await resource.load(async (signal) => fetchTlaSpecs({ signal }))
}

function categoryLabel(cat: TlaSpecEntry['category']): string {
  switch (cat) {
    case 'boundary':
      return '경계'
    case 'bug-models':
      return '버그 모델'
    default:
      return '기타'
  }
}

function categoryTone(cat: TlaSpecEntry['category']): 'ok' | 'warn' | 'neutral' {
  switch (cat) {
    case 'boundary':
      return 'ok'
    case 'bug-models':
      return 'warn'
    default:
      return 'neutral'
  }
}

function cfgCoverage(entry: TlaSpecEntry): { label: string; tone: 'ok' | 'warn' | 'err' } {
  if (entry.has_clean_cfg && entry.has_buggy_cfg) {
    return { label: 'clean + buggy', tone: 'ok' }
  }
  if (entry.has_clean_cfg) {
    return { label: 'clean only', tone: 'warn' }
  }
  if (entry.has_buggy_cfg) {
    return { label: 'buggy only', tone: 'warn' }
  }
  return { label: 'no cfg', tone: 'err' }
}

function shortMtime(iso: string): string {
  return iso.slice(0, 10)
}

function SpecsTable({ entries }: { entries: TlaSpecEntry[] }) {
  return html`
    <div class="overflow-x-auto">
      <table class="w-full text-xs tabular-nums">
        <thead class="text-left text-slate-400">
          <tr>
            <th class="py-1 pr-4">Spec</th>
            <th class="py-1 pr-4">Category</th>
            <th class="py-1 pr-4">Cfg</th>
            <th class="py-1 pr-4">Path</th>
            <th class="py-1">Modified</th>
          </tr>
        </thead>
        <tbody>
          ${entries.map((entry: TlaSpecEntry) => {
            const cov = cfgCoverage(entry)
            return html`
              <tr class="border-t border-slate-800">
                <td class="py-1 pr-4 font-medium text-slate-100">${entry.name}</td>
                <td class="py-1 pr-4">
                  <${StatusChip} tone=${categoryTone(entry.category)} label=${categoryLabel(entry.category)} />
                </td>
                <td class="py-1 pr-4">
                  <${StatusChip} tone=${cov.tone} label=${cov.label} />
                </td>
                <td class="py-1 pr-4 font-mono text-slate-400">${entry.path}</td>
                <td class="py-1 text-slate-400">${shortMtime(entry.mtime_iso)}</td>
              </tr>
            `
          })}
        </tbody>
      </table>
    </div>
  `
}

export function VerificationSpecsPanel() {
  const resourceRef = useRef<ManagedAsyncResource<TlaSpecsResponse> | null>(null)
  if (resourceRef.current === null) {
    resourceRef.current = createManagedAsyncResource<TlaSpecsResponse>()
  }
  const resource = resourceRef.current

  useEffect(() => {
    void loadSpecs(resource)
    const id = setInterval(() => void loadSpecs(resource), 60_000)
    return () => { clearInterval(id); resource.cancel() }
  }, [resource])

  const current = resource.state.value
  const data = current.data
  const boundaryCount = data?.entries.filter((e: TlaSpecEntry) => e.category === 'boundary').length ?? 0
  const bugModelCount = data?.entries.filter((e: TlaSpecEntry) => e.category === 'bug-models').length ?? 0
  const dirLabel = data?.specs_dir ?? '(not found)'

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center gap-3 flex-wrap">
        <button
          class="rounded border border-[var(--card-border)] bg-[var(--bg-0)] px-3 py-1 text-xs text-[var(--text-strong)] hover:bg-[var(--bg-panel-hover)]"
          onClick=${() => void loadSpecs(resource)}
        >
          새로고침
        </button>
        ${current.loading ? html`<span class="text-xs text-[var(--text-muted)]">로딩 중...</span>` : null}
        ${data?.updated_at
          ? html`<span class="text-xs text-[var(--text-muted)]">specs · ${data.updated_at}</span>`
          : null}
      </div>

      ${current.error ? html`<${ErrorState} message=${current.error} />` : null}

      ${current.loading && !data
        ? html`<${LoadingState}>TLA+ 스펙 목록 불러오는 중...<//>`
        : null}

      <${Card} title="Formal Specs">
        <div class="mb-2 text-xs text-slate-400">
          ${data?.count ?? 0} specs · boundary ${boundaryCount} · bug-models ${bugModelCount}
          · <span class="font-mono">${dirLabel}</span>
        </div>
        ${!data || data.entries.length === 0
          ? html`<${EmptyState} message="TLA+ 스펙을 찾지 못했습니다 (MASC_SPECS_DIR 확인)" />`
          : html`<${SpecsTable} entries=${data.entries} />`}
      <//>
    </div>
  `
}
