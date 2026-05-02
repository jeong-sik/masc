// TlcResultsPanel — surfaces last-known TLC model-checking evidence.
//
// Consumes:
//   GET /api/v1/verification/tlc-results
//
// The backend may legitimately have no TLC output yet. This panel keeps that
// absence visible so operators can distinguish "not checked" from "passed".

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import {
  fetchTlcResults,
  type TlaSpecCategory,
  type TlcResultEntry,
  type TlcResultsResponse,
  type TlcResultStatus,
} from '../api/dashboard'
import { Btn } from './btn'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { ErrorState, LoadingState } from './common/feedback-state'
import { FilterChips } from './common/filter-chips'
import { StatusChip } from './common/status-chip'
import type { ManagedAsyncResource } from '../lib/async-state'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'

function ThCell({ children }: { children: unknown }) {
  return html`<th scope="col" class="py-1 pr-4">${children}</th>`
}

type StatusFilter = 'all' | TlcResultStatus

const statusFilter = signal<StatusFilter>('all')

const STATUS_ORDER: TlcResultStatus[] = [
  'violated',
  'error',
  'running',
  'queued',
  'not_run',
  'passed',
]

async function loadTlcResults(resource: ManagedAsyncResource<TlcResultsResponse>) {
  await resource.load(async (signal) => fetchTlcResults({ signal }))
}

function categoryLabel(cat: TlaSpecCategory): string {
  switch (cat) {
    case 'boundary':
      return '경계'
    case 'bug-models':
      return '버그 모델'
    default:
      return '기타'
  }
}

function categoryTone(cat: TlaSpecCategory): 'ok' | 'warn' | 'neutral' {
  switch (cat) {
    case 'boundary':
      return 'ok'
    case 'bug-models':
      return 'warn'
    default:
      return 'neutral'
  }
}

export function tlcStatusLabel(status: TlcResultStatus): string {
  switch (status) {
    case 'passed':
      return '통과'
    case 'violated':
      return '위반'
    case 'running':
      return '실행 중'
    case 'queued':
      return '대기'
    case 'error':
      return '오류'
    case 'not_run':
      return '미실행'
  }
}

export function tlcStatusTone(status: TlcResultStatus): 'ok' | 'warn' | 'bad' | 'info' | 'neutral' {
  switch (status) {
    case 'passed':
      return 'ok'
    case 'violated':
      return 'bad'
    case 'running':
      return 'info'
    case 'error':
      return 'warn'
    case 'queued':
    case 'not_run':
      return 'neutral'
  }
}

export function formatTlcMetric(value: number | null): string {
  return value == null ? '-' : value.toLocaleString('ko-KR')
}

export function formatTlcTimestamp(value: string | null): string {
  return value ? value.slice(0, 19).replace('T', ' ') : '기록 없음'
}

export function hasTlcEvidence(entry: TlcResultEntry): boolean {
  return entry.status !== 'not_run'
    || entry.last_run_at != null
    || entry.states_explored != null
    || entry.distinct_states != null
    || entry.diameter != null
    || entry.violation != null
    || entry.log_path != null
}

export function filterTlcEntries(entries: TlcResultEntry[], filter: StatusFilter): TlcResultEntry[] {
  const filtered = filter === 'all'
    ? entries
    : entries.filter((entry) => entry.status === filter)
  return [...filtered].sort((a, b) => {
    const at = a.last_run_at ?? ''
    const bt = b.last_run_at ?? ''
    if (at !== bt) return bt.localeCompare(at)
    return `${a.spec_name}/${a.cfg_name}`.localeCompare(`${b.spec_name}/${b.cfg_name}`)
  })
}

export function __resetTlcResultsPanelForTest(): void {
  statusFilter.value = 'all'
}

function EvidenceCell({ entry }: { entry: TlcResultEntry }) {
  if (entry.violation) {
    return html`
      <span
        class="block max-w-[22rem] truncate text-[var(--bad-light)]"
        title=${entry.violation}
      >
        ${entry.violation}
      </span>
    `
  }
  if (entry.log_path) {
    return html`
      <span
        class="block max-w-[22rem] truncate font-mono text-[var(--color-fg-muted)]"
        title=${entry.log_path}
      >
        ${entry.log_path}
      </span>
    `
  }
  return html`<span class="text-[var(--color-fg-disabled)]">증거 없음</span>`
}

function ResultsTable({ entries }: { entries: TlcResultEntry[] }) {
  return html`
    <div class="overflow-x-auto">
      <table class="w-full text-xs tabular-nums" aria-label="TLC 실행 결과">
        <thead class="text-left text-[var(--color-fg-muted)]">
          <tr>
            <${ThCell}>사양</${ThCell}>
            <${ThCell}>Cfg</${ThCell}>
            <${ThCell}>분류</${ThCell}>
            <${ThCell}>상태</${ThCell}>
            <th scope="col" class="py-1 pr-4 text-right">States</th>
            <th scope="col" class="py-1 pr-4 text-right">Distinct</th>
            <th scope="col" class="py-1 pr-4 text-right">Diameter</th>
            <${ThCell}>마지막 실행</${ThCell}>
            <th scope="col" class="py-1">증거</th>
          </tr>
        </thead>
        <tbody>
          ${entries.map((entry) => html`
            <tr class="border-t border-[var(--white-10)]">
              <td class="py-1 pr-4 font-medium text-[var(--color-fg-primary)]">${entry.spec_name}</td>
              <td class="py-1 pr-4 font-mono text-[var(--color-fg-muted)]">${entry.cfg_name}</td>
              <td class="py-1 pr-4">
                <${StatusChip} tone=${categoryTone(entry.category)} label=${categoryLabel(entry.category)} />
              </td>
              <td class="py-1 pr-4">
                <${StatusChip} tone=${tlcStatusTone(entry.status)} label=${tlcStatusLabel(entry.status)} />
              </td>
              <td class="py-1 pr-4 text-right text-[var(--color-fg-secondary)]">${formatTlcMetric(entry.states_explored)}</td>
              <td class="py-1 pr-4 text-right text-[var(--color-fg-secondary)]">${formatTlcMetric(entry.distinct_states)}</td>
              <td class="py-1 pr-4 text-right text-[var(--color-fg-secondary)]">${formatTlcMetric(entry.diameter)}</td>
              <td class="py-1 pr-4 text-[var(--color-fg-muted)]">${formatTlcTimestamp(entry.last_run_at)}</td>
              <td class="py-1"><${EvidenceCell} entry=${entry} /></td>
            </tr>
          `)}
        </tbody>
      </table>
    </div>
  `
}

export function TlcResultsPanel() {
  const resource = useManagedAsyncResource<TlcResultsResponse>()

  useEffect(() => {
    void loadTlcResults(resource)
    const id = setInterval(() => void loadTlcResults(resource), 60_000)
    return () => { clearInterval(id); resource.cancel() }
  }, [resource])

  const current = resource.state.value
  const data = current.data
  const allEntries = data?.entries ?? []
  const filtered = filterTlcEntries(allEntries, statusFilter.value)
  const resultsDir = data?.results_dir ?? '(not configured)'
  const hasAnyEvidence = allEntries.some(hasTlcEvidence)

  const statusCounts = new Map<TlcResultStatus, number>()
  for (const status of STATUS_ORDER) statusCounts.set(status, 0)
  for (const entry of allEntries) {
    statusCounts.set(entry.status, (statusCounts.get(entry.status) ?? 0) + 1)
  }

  return html`
    <${Card} title="TLC 결과">
      <div class="flex flex-col gap-3">
        <div class="flex items-center gap-3 flex-wrap">
          <${Btn} onClick=${() => void loadTlcResults(resource)}>
            새로고침
          <//>
          ${current.loading ? html`<span class="text-xs text-[var(--color-fg-muted)]" role="status">로딩 중...</span>` : null}
          ${data?.updated_at
            ? html`<span class="text-xs text-[var(--color-fg-muted)]">tlc · ${data.updated_at}</span>`
            : null}
          ${data
            ? html`<span class="text-xs text-[var(--color-fg-muted)]">
                ${statusFilter.value === 'all'
                  ? `총 ${data.count}건`
                  : `${filtered.length} / ${data.count}건`}
              </span>`
            : null}
        </div>

        <div class="text-xs text-[var(--color-fg-muted)]">
          <span class="font-mono">${resultsDir}</span>
        </div>

        <${FilterChips}
          chips=${[
            { key: 'all' as StatusFilter, label: '전체', count: allEntries.length },
            ...STATUS_ORDER.map((status) => ({
              key: status as StatusFilter,
              label: tlcStatusLabel(status),
              count: statusCounts.get(status) ?? 0,
            })),
          ]}
          active=${statusFilter}
          size="sm"
          tone="accent"
        />

        ${current.error ? html`<${ErrorState} message=${current.error} />` : null}

        ${current.loading && !data
          ? html`<${LoadingState}>TLC 결과 불러오는 중...<//>`
          : null}

        ${data && allEntries.length > 0 && !hasAnyEvidence
          ? html`
            <div
              class="rounded-[var(--r-1)] border border-[var(--warn-20)] bg-[var(--warn-soft)] px-3 py-2 text-xs text-[var(--warn-bright)]"
              role="status"
            >
              TLC 실행 증거 없음: 등록된 항목은 있지만 마지막 실행, 상태 공간, 로그 경로가 아직 없습니다.
            </div>
          `
          : null}

        ${!current.loading && data && allEntries.length === 0
          ? html`<${EmptyState} compact message="TLC 결과 항목이 없습니다 (results_dir 미설정 또는 아직 수집 전)." />`
          : filtered.length === 0 && data
            ? html`<${EmptyState} compact message="선택한 상태의 TLC 결과가 없습니다." />`
            : filtered.length > 0
              ? html`<${ResultsTable} entries=${filtered} />`
              : null}
      </div>
    <//>
  `
}
