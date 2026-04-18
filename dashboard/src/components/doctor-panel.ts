// Doctor panel — surfaces `/api/v1/dashboard/doctor` envelope in the dashboard.
//
// Types + pure helpers + async loader are used both by the `<DoctorPanel />`
// component below and (in the future) by SSE-refresh wiring and CI smoke
// tooling that consumes the same envelope shape.
// Backend contract: see `docs/DOCTOR-ARCHITECTURE.md` "Backend endpoint" section.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { get } from '../api/core'
import { createAsyncResource, type AsyncResource } from '../lib/async-state'
import { AsyncContainer } from './common/async-container'
import { Card } from './common/card'
import { SectionCap } from './common/section-cap'

export type DoctorKind = 'config' | 'sidecar'

export interface DoctorEntry {
  name: string
  kind: DoctorKind
  exit_code: number
  payload: unknown
}

export interface DoctorSummary {
  total: number
  ok: number
  warn: number
  error: number
}

export interface DoctorEnvelope {
  title: string
  doctors: DoctorEntry[]
  summary: DoctorSummary
  exit_code: number
}

// `doctor all` exit-code contract (shared with OCaml `Doctor_dispatch`):
//   0 = ok, 1 = warn, 2 = error, anything else = treat as error.
export type DoctorSeverity = 'ok' | 'warn' | 'error'

export function severityForExitCode(code: number): DoctorSeverity {
  if (code === 0) return 'ok'
  if (code === 1) return 'warn'
  return 'error'
}

export function severityLabel(code: number): string {
  switch (severityForExitCode(code)) {
    case 'ok':
      return '정상'
    case 'warn':
      return '경고'
    case 'error':
      return '오류'
  }
}

// Tailwind utility class for an inline severity chip — matches the palette
// used by feature-health (ok/warn/bad) so Doctor fits visually.
export function severityChipClass(code: number): string {
  switch (severityForExitCode(code)) {
    case 'ok':
      return 'border-[var(--ok-30)] bg-[var(--ok-12)] text-[var(--ok)]'
    case 'warn':
      return 'border-[var(--warn-30)] bg-[var(--warn-12)] text-[var(--warn)]'
    case 'error':
      return 'border-[var(--bad-30)] bg-[var(--bad-12)] text-[var(--bad)]'
  }
}

// Human-readable heading for a doctor entry — sidecar names get capitalised
// for display; config stays as "Config".
export function doctorHeading(entry: DoctorEntry): string {
  if (entry.kind === 'config') return 'Config'
  return entry.name.charAt(0).toUpperCase() + entry.name.slice(1)
}

// Aggregate breakdown string, e.g. "6 Doctor · 정상 3 · 경고 2 · 오류 1".
// Korean separator (` · `) matches the CLI footer in `doctor all`.
export function summaryLine(summary: DoctorSummary): string {
  return (
    `${summary.total} Doctor · ` +
    `정상 ${summary.ok} · 경고 ${summary.warn} · 오류 ${summary.error}`
  )
}

// Async resource — module-scoped so the same data is shared across any
// surface that mounts the panel (follow-up PR).
export const doctorEnvelope: AsyncResource<DoctorEnvelope> =
  createAsyncResource()

export function loadDoctor(): Promise<void> {
  return doctorEnvelope.load(() =>
    get<DoctorEnvelope>('/api/v1/dashboard/doctor'),
  )
}

export async function refreshDoctor(): Promise<void> {
  await loadDoctor()
}

// ── Component ──────────────────────────────────────────────────────────

function DoctorEntryCard({ entry }: { entry: DoctorEntry }) {
  const label = severityLabel(entry.exit_code)
  const chip = severityChipClass(entry.exit_code)
  return html`
    <div class="rounded border border-[var(--white-8)] bg-[var(--white-4)] p-3">
      <div class="flex items-baseline justify-between gap-2">
        <div class="text-sm font-semibold text-[var(--text-strong)]">
          ${doctorHeading(entry)}
        </div>
        <span class="rounded-full border px-2 py-0.5 text-[10px] uppercase tracking-wider ${chip}">
          ${label}
        </span>
      </div>
      <div class="mt-1 text-xs text-[var(--text-muted)]">
        ${entry.kind === 'config' ? 'Config Doctor' : `${entry.name} sidecar`} · exit ${entry.exit_code}
      </div>
    </div>
  `
}

export function DoctorPanel() {
  useEffect(() => {
    void loadDoctor()
  }, [])

  return html`
    <div class="space-y-4">
      <${Card} title="Doctor" class="section">
        <${AsyncContainer}
          state=${doctorEnvelope.state}
          loadingMessage="Doctor 데이터를 불러오는 중..."
          emptyMessage="Doctor 데이터가 없습니다."
          render=${(data: DoctorEnvelope) => html`
            <div class="space-y-4">
              <div class="rounded border border-[var(--white-8)] bg-[var(--white-4)] p-4">
                <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                  <div>
                    <${SectionCap}>시스템 전반 Doctor<//>
                    <div class="mt-2 text-2xl font-semibold text-[var(--text-strong)]">
                      ${summaryLine(data.summary)}
                    </div>
                    <div class="mt-2 text-sm leading-airy text-[var(--text-body)]">
                      ${data.title} · <code class="text-[var(--text-muted)]">masc-mcp doctor all</code> 과 동일 결과.
                    </div>
                  </div>
                  <button
                    type="button"
                    class="rounded border border-[var(--white-8)] px-2.5 py-1 text-2xs text-[var(--text-muted)] transition-colors hover:border-[var(--accent)] hover:text-[var(--text-body)]"
                    onClick=${() => { void refreshDoctor() }}
                  >새로고침</button>
                </div>
              </div>
              <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
                ${data.doctors.map((entry) => html`<${DoctorEntryCard} entry=${entry} />`)}
              </div>
            </div>
          `}
        />
      </${Card}>
    </div>
  `
}
