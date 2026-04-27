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
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import {
  fetchTlaSpecs,
  type TlaSpecCategory,
  type TlaSpecEntry,
  type TlaSpecsResponse,
} from '../api/dashboard'
import { Btn } from './btn'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { ErrorState, LoadingState } from './common/feedback-state'
import { StatusChip } from './common/status-chip'
import { FilterChips } from './common/filter-chips'
import { TextInput } from './common/input'
import type { ManagedAsyncResource } from '../lib/async-state'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'

type CategoryFilter = 'all' | TlaSpecCategory
const categoryFilter = signal<CategoryFilter>('all')
const searchQuery = signal('')

async function loadSpecs(resource: ManagedAsyncResource<TlaSpecsResponse>) {
  await resource.load(async (signal) => fetchTlaSpecs({ signal }))
}

export function categoryLabel(cat: TlaSpecEntry['category']): string {
  switch (cat) {
    case 'boundary':
      return '경계'
    case 'bug-models':
      return '버그 모델'
    default:
      return '기타'
  }
}

export function categoryTone(cat: TlaSpecEntry['category']): 'ok' | 'warn' | 'neutral' {
  switch (cat) {
    case 'boundary':
      return 'ok'
    case 'bug-models':
      return 'warn'
    default:
      return 'neutral'
  }
}

export function cfgCoverage(entry: TlaSpecEntry): { label: string; tone: 'ok' | 'warn' | 'err' } {
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

export function shortMtime(iso: string): string {
  return iso.slice(0, 10)
}

function SpecsTable({ entries }: { entries: TlaSpecEntry[] }) {
  return html`
    <div class="overflow-x-auto">
      <table class="w-full text-xs tabular-nums" aria-label="TLA+ 스펙 목록">
        <thead class="text-left text-slate-400">
          <tr>
            <th scope="col" class="py-1 pr-4">사양</th>
            <th scope="col" class="py-1 pr-4">분류</th>
            <th scope="col" class="py-1 pr-4">Cfg</th>
            <th scope="col" class="py-1 pr-4">경로</th>
            <th scope="col" class="py-1">수정일</th>
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
  const resource = useManagedAsyncResource<TlaSpecsResponse>()

  useEffect(() => {
    void loadSpecs(resource)
    const id = setInterval(() => void loadSpecs(resource), 60_000)
    return () => { clearInterval(id); resource.cancel() }
  }, [resource])

  const current = resource.state.value
  const data = current.data
  const dirLabel = data?.specs_dir ?? '(not found)'

  const allEntries = data?.entries ?? []
  const filtered = allEntries.filter((e: TlaSpecEntry) => {
    if (categoryFilter.value !== 'all' && e.category !== categoryFilter.value) return false
    if (searchQuery.value) {
      const q = searchQuery.value.toLowerCase()
      if (!e.name.toLowerCase().includes(q) && !e.path.toLowerCase().includes(q)) return false
    }
    return true
  })

  const boundaryCount = allEntries.filter((e: TlaSpecEntry) => e.category === 'boundary').length
  const bugModelCount = allEntries.filter((e: TlaSpecEntry) => e.category === 'bug-models').length
  const otherCount = allEntries.filter((e: TlaSpecEntry) => e.category === 'other').length

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center gap-3 flex-wrap">
        <${Btn} onClick=${() => void loadSpecs(resource)}>
          새로고침
        <//>
        ${current.loading ? html`<span class="text-xs text-[var(--color-fg-muted)]" role="status">로딩 중...</span>` : null}
        ${data?.updated_at
          ? html`<span class="text-xs text-[var(--color-fg-muted)]">specs · ${data.updated_at}</span>`
          : null}
        ${data
          ? html`<span class="text-xs text-[var(--color-fg-muted)]">
              ${categoryFilter.value === 'all' && !searchQuery.value
                ? `총 ${data.count}건`
                : `${filtered.length} / ${data.count}건`}
            </span>`
          : null}
      </div>

      <div class="flex flex-wrap gap-3 items-center">
        <${FilterChips}
          chips=${[
            { key: 'all' as CategoryFilter, label: '전체', count: allEntries.length },
            { key: 'boundary' as CategoryFilter, label: '경계', count: boundaryCount },
            { key: 'bug-models' as CategoryFilter, label: '버그 모델', count: bugModelCount },
            { key: 'other' as CategoryFilter, label: '기타', count: otherCount },
          ]}
          active=${categoryFilter}
          size="sm"
          tone="accent"
        />
        <${TextInput}
          class="max-w-50"
          name="spec_search"
          ariaLabel="스펙 검색"
          autoComplete="off"
          placeholder="스펙 이름 검색..."
          value=${searchQuery.value}
          onInput=${(e: Event) => { searchQuery.value = (e.target as HTMLInputElement).value }}
        />
      </div>

      ${current.error ? html`<${ErrorState} message=${current.error} />` : null}

      ${current.loading && !data
        ? html`<${LoadingState}>TLA+ 스펙 목록 불러오는 중...<//>`
        : null}

      <${Card} title="형식 명세">
        <div class="mb-2 text-xs text-slate-400">
          <span class="font-mono">${dirLabel}</span>
        </div>
        ${filtered.length === 0
          ? html`<${EmptyState} message=${categoryFilter.value === 'all' && !searchQuery.value
              ? 'TLA+ 스펙을 찾지 못했습니다 (MASC_SPECS_DIR 확인)'
              : '조건에 맞는 스펙이 없습니다.'} />`
          : html`<${SpecsTable} entries=${filtered} />`}
      <//>
    </div>
  `
}
