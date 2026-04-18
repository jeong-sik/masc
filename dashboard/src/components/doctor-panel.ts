// Doctor panel — surfaces `/api/v1/dashboard/doctor` envelope in the dashboard.
//
// Phase 1 skeleton: types + pure helpers + async resource loader. The actual
// DOM component wires in a follow-up so this PR is reviewable on its own.
// Backend contract: see `docs/DOCTOR-ARCHITECTURE.md` "Backend endpoint" section.

import { get } from '../api/core'
import { createAsyncResource, type AsyncResource } from '../lib/async-state'

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
