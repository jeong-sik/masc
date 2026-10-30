// RuntimeObservablesPanel — process runtime health from the observables
// store cells (masc#29023): console sink, transition-audit queue, fd
// accounting, on-disk store sizes, event-bus contracts, HTTP pool.
//
// Read-only diagnostic surface for Monitor > Runtime (collapsed by
// default). Values come from GET /api/v1/dashboard/runtime-observables;
// a null cell means the store writer has not landed it, rendered as "—"
// so absence never reads as zero.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  fetchRuntimeObservables,
  type RuntimeObservablesSnapshot,
} from '../api/runtime-observables'
import {
  DEFAULT_PANEL_REFRESH_MS,
  setupVisibleAutoRefresh,
} from '../lib/auto-refresh'

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(2)} MB`
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`
}

function formatCount(value: number | null): string {
  return value === null ? '—' : value.toLocaleString()
}

function formatAge(ageSeconds: number | null): string {
  if (ageSeconds === null) return '샘플 없음'
  if (ageSeconds < 60) return `${Math.round(ageSeconds)}초 전 샘플`
  return `${Math.round(ageSeconds / 60)}분 전 샘플`
}

function Stat({ label, value }: { label: string; value: string }) {
  return html`
    <div
      class="min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] px-3 py-2"
      data-observable-stat=${label}
    >
      <span class="block text-2xs text-[var(--color-fg-muted)]">${label}</span>
      <span class="mt-1 block text-sm font-semibold tabular-nums text-[var(--color-fg-primary)]">${value}</span>
    </div>
  `
}

function StoresTable({ snapshot }: { snapshot: RuntimeObservablesSnapshot }) {
  if (snapshot.stores.length === 0) {
    return html`<div class="text-xs text-[var(--color-fg-muted)]">관측된 스토어 없음</div>`
  }
  return html`
    <table class="w-full text-xs">
      <thead>
        <tr class="text-left text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
          <th class="py-1 pr-2">store</th>
          <th class="py-1 pr-2">bytes</th>
          <th class="py-1">files</th>
        </tr>
      </thead>
      <tbody>
        ${snapshot.stores.map(entry => html`
          <tr key=${entry.store} data-observable-store=${entry.store}>
            <td class="py-1 pr-2 font-mono">${entry.store}</td>
            <td class="py-1 pr-2 tabular-nums">${formatBytes(entry.bytes)}</td>
            <td class="py-1 tabular-nums">${formatCount(entry.files)}</td>
          </tr>
        `)}
      </tbody>
    </table>
  `
}

function BusList({ snapshot }: { snapshot: RuntimeObservablesSnapshot }) {
  if (snapshot.event_bus.length === 0) {
    return html`<div class="text-xs text-[var(--color-fg-muted)]">활성 이벤트 버스 없음</div>`
  }
  return html`
    <div class="flex flex-col gap-2">
      ${snapshot.event_bus.map(bus => html`
        <div key=${bus.bus} data-observable-bus=${bus.bus}>
          <div class="text-xs font-semibold text-[var(--color-fg-primary)]">
            <span class="font-mono">${bus.bus}</span>
            <span class="ml-2 font-normal text-[var(--color-fg-muted)]">구독자 ${bus.subscribers}</span>
          </div>
          ${bus.contracts.length === 0
            ? null
            : html`
              <table class="mt-1 w-full text-xs">
                <thead>
                  <tr class="text-left text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">
                    <th class="py-0.5 pr-2">purpose</th>
                    <th class="py-0.5 pr-2">depth</th>
                    <th class="py-0.5 pr-2">dropped</th>
                    <th class="py-0.5">capacity</th>
                  </tr>
                </thead>
                <tbody>
                  ${bus.contracts.map(contract => html`
                    <tr key=${`${contract.purpose}-${contract.capacity ?? 'na'}-${contract.overflow}`}>
                      <td class="py-0.5 pr-2 font-mono">${contract.purpose}</td>
                      <td class="py-0.5 pr-2 tabular-nums">${contract.depth}</td>
                      <td class="py-0.5 pr-2 tabular-nums">${formatCount(contract.dropped_total)}</td>
                      <td class="py-0.5 tabular-nums">${formatCount(contract.capacity)} · ${contract.overflow}</td>
                    </tr>
                  `)}
                </tbody>
              </table>
            `}
        </div>
      `)}
    </div>
  `
}

function Section({ title, children }: { title: string; children: unknown }) {
  return html`
    <div class="flex min-w-0 flex-col gap-2">
      <div class="text-2xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">${title}</div>
      ${children}
    </div>
  `
}

export function RuntimeObservablesPanel() {
  const [snapshot, setSnapshot] = useState<RuntimeObservablesSnapshot | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    // useEffect is appropriate here: external-system synchronization
    // (periodic HTTP fetch from the MASC API), not derived state.
    const controller = new AbortController()

    const refresh = async () => {
      try {
        const result = await fetchRuntimeObservables()
        if (controller.signal.aborted) return
        setSnapshot(result)
        setError(null)
      } catch (err) {
        if (controller.signal.aborted) return
        setError(err instanceof Error ? err.message : 'runtime observables fetch failed')
      } finally {
        if (!controller.signal.aborted) setLoading(false)
      }
    }

    setLoading(true)
    void refresh()
    const cleanup = setupVisibleAutoRefresh(() => { void refresh() }, DEFAULT_PANEL_REFRESH_MS)

    return () => {
      controller.abort()
      cleanup()
    }
  }, [])

  if (loading && snapshot === null) {
    return html`<div class="text-xs text-[var(--color-fg-muted)]" data-observables-state="loading">프로세스 관측 로딩 중…</div>`
  }
  if (error !== null && snapshot === null) {
    return html`<div class="text-xs text-[var(--color-danger-fg)]" data-observables-state="error">${error}</div>`
  }
  if (snapshot === null) return null

  return html`
    <section
      class="flex flex-col gap-4 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3"
      aria-label="Runtime observables"
      data-observables-state="ready"
    >
      <div class="flex items-baseline justify-between gap-2">
        <div class="text-sm font-semibold text-[var(--color-fg-primary)]">프로세스 관측</div>
        <div class="text-2xs text-[var(--color-fg-muted)]" data-observables-age>${formatAge(snapshot.age_seconds)}</div>
      </div>
      <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
        <${Stat} label="콘솔 싱크 큐" value=${formatCount(snapshot.console_sink.queue_depth)} />
        <${Stat} label="콘솔 싱크 드랍 누계" value=${formatCount(snapshot.console_sink.dropped_total)} />
        <${Stat} label="전이 감사 큐" value=${formatCount(snapshot.transition_audit.queue_depth)} />
        <${Stat} label="FD 사용/한도" value=${`${formatCount(snapshot.fd.open)} / ${formatCount(snapshot.fd.limit)}`} />
        <${Stat} label="HTTP 풀 유휴" value=${formatCount(snapshot.pool.idle)} />
        <${Stat} label="HTTP 풀 사용 중" value=${formatCount(snapshot.pool.inflight)} />
        <${Stat} label="풀 재사용 누계" value=${formatCount(snapshot.pool.reuse_total)} />
        <${Stat} label="풀 방출 누계" value=${formatCount(snapshot.pool.evict_total)} />
      </div>
      <div class="grid gap-4 lg:grid-cols-2">
        <${Section} title="온디스크 스토어">
          <${StoresTable} snapshot=${snapshot} />
        <//>
        <${Section} title="이벤트 버스">
          <${BusList} snapshot=${snapshot} />
        <//>
      </div>
    </section>
  `
}
