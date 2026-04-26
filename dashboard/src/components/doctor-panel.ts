// Doctor panel — surfaces `/api/v1/dashboard/doctor` envelope in the dashboard.
//
// Types + pure helpers + async loader are used both by the `<DoctorPanel />`
// component below and (in the future) by SSE-refresh wiring and CI smoke
// tooling that consumes the same envelope shape.
// Backend contract: see `docs/DOCTOR-ARCHITECTURE.md` "Backend endpoint" section.

import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
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

// ── Payload extractors (runtime type guards) ───────────────────────────
// Payload is `unknown` at the envelope layer because config and sidecar
// Doctors have different shapes. The extractors below defensively pull the
// few fields the drill-down UI consumes.

export interface SidecarCheckView {
  name: string
  severity: string
  message?: string
  detail?: string
  hint?: string
  /** 백엔드 envelope 의 `auto_fix.callback_available === true` 일 때만 true.
   * UI 는 "자동 치유 가능" 배지로 노출. 실제 trigger 는 CLI 경유
   * (`masc-mcp doctor sidecar <name> --fix`). */
  autofix_available?: boolean
  /** `auto_fix.description` — 자동 치유가 시도할 동작의 사람용 설명.
   * 배지 hover/툴팁용. */
  autofix_description?: string
}

export function extractSidecarChecks(payload: unknown): SidecarCheckView[] {
  if (!payload || typeof payload !== 'object') return []
  const p = payload as Record<string, unknown>
  if (!Array.isArray(p.checks)) return []
  const out: SidecarCheckView[] = []
  for (const raw of p.checks) {
    if (!raw || typeof raw !== 'object') continue
    const c = raw as Record<string, unknown>
    if (typeof c.name !== 'string' || typeof c.severity !== 'string') continue
    const view: SidecarCheckView = { name: c.name, severity: c.severity }
    if (typeof c.message === 'string' && c.message !== '') view.message = c.message
    if (typeof c.detail === 'string' && c.detail !== '') view.detail = c.detail
    if (typeof c.hint === 'string' && c.hint !== '') view.hint = c.hint
    if (c.auto_fix && typeof c.auto_fix === 'object') {
      const af = c.auto_fix as Record<string, unknown>
      if (af.callback_available === true) view.autofix_available = true
      if (typeof af.description === 'string' && af.description !== '')
        view.autofix_description = af.description
    }
    out.push(view)
  }
  return out
}

export interface ConfigNotesView {
  warnings: string[]
  next_actions: string[]
}

export function extractConfigNotes(payload: unknown): ConfigNotesView {
  const empty: ConfigNotesView = { warnings: [], next_actions: [] }
  if (!payload || typeof payload !== 'object') return empty
  const p = payload as Record<string, unknown>
  const filterStrings = (arr: unknown): string[] =>
    Array.isArray(arr) ? arr.filter((x): x is string => typeof x === 'string') : []
  return {
    warnings: filterStrings(p.warnings),
    next_actions: filterStrings(p.next_actions),
  }
}

// Map per-check severity strings (Python's Severity enum) to the shared
// ok/warn/error chip palette used by doctor exit codes.
function chipClassForSidecarSeverity(severity: string): string {
  switch (severity) {
    case 'ok':
    case 'info':
      return severityChipClass(0)
    case 'warn':
    case 'skip':
      return severityChipClass(1)
    case 'error':
      return severityChipClass(2)
    default:
      return severityChipClass(2)
  }
}

// ── Component ──────────────────────────────────────────────────────────

function SidecarChecksList({ checks }: { checks: SidecarCheckView[] }) {
  if (checks.length === 0) {
    return html`<div class="text-xs text-[var(--text-muted)]" role="status">세부 검사 없음.</div>`
  }
  return html`
    <ul class="mt-3 space-y-2" aria-label="진단 검사 목록">
      ${checks.map((c) => {
        const chip = chipClassForSidecarSeverity(c.severity)
        return html`
          <li class="rounded border border-[var(--white-8)] bg-[var(--white-3)] p-2">
            <div class="flex items-baseline justify-between gap-2">
              <div class="text-xs font-medium text-[var(--text-strong)]">${c.name}</div>
              <div class="flex items-center gap-1">
                ${c.autofix_available
                  ? html`
                      <span
                        class="rounded-full border border-[var(--accent)]/40 bg-[var(--accent)]/10 px-1.5 py-0.5 text-[10px] text-[var(--accent)]"
                        title=${c.autofix_description
                          ? `자동 치유 시도: ${c.autofix_description} (CLI: masc-mcp doctor --fix)`
                          : '자동 치유 가능 (CLI: masc-mcp doctor --fix)'}
                      >
                        자동 치유
                      </span>
                    `
                  : ''}
                <span class="rounded-full border px-1.5 py-0.5 text-[10px] uppercase tracking-wider ${chip}">
                  ${c.severity}
                </span>
              </div>
            </div>
            ${c.detail ? html`<div class="mt-1 text-[11px] text-[var(--text-muted)]">${c.detail}</div>` : ''}
            ${c.message ? html`<div class="mt-1 text-[11px] text-[var(--text-body)]">↳ ${c.message}</div>` : ''}
            ${c.hint ? html`<div class="mt-1 text-[11px] text-[var(--text-muted)]">hint: ${c.hint}</div>` : ''}
            ${c.autofix_available && c.autofix_description
              ? html`<div class="mt-1 text-[11px] text-[var(--accent)]">fix: ${c.autofix_description}</div>`
              : ''}
          </li>
        `
      })}
    </ul>
  `
}

function ConfigNotesList({ notes }: { notes: ConfigNotesView }) {
  const { warnings, next_actions } = notes
  if (warnings.length === 0 && next_actions.length === 0) {
    return html`<div class="text-xs text-[var(--text-muted)]" role="status">추가 메모 없음.</div>`
  }
  return html`
    <div class="mt-3 space-y-3">
      ${warnings.length > 0
        ? html`
            <div>
              <div class="text-[11px] uppercase tracking-wider text-[var(--text-muted)]">경고</div>
              <ul class="mt-1 list-disc space-y-1 pl-5 text-[11px] text-[var(--text-body)]" aria-label="경고 목록">
                ${warnings.map((w) => html`<li>${w}</li>`)}
              </ul>
            </div>
          `
        : ''}
      ${next_actions.length > 0
        ? html`
            <div>
              <div class="text-[11px] uppercase tracking-wider text-[var(--text-muted)]">다음 조치</div>
              <ul class="mt-1 list-disc space-y-1 pl-5 text-[11px] text-[var(--text-body)]" aria-label="다음 조치 목록">
                ${next_actions.map((a) => html`<li>${a}</li>`)}
              </ul>
            </div>
          `
        : ''}
    </div>
  `
}

function DoctorEntryCard({ entry }: { entry: DoctorEntry }) {
  const label = severityLabel(entry.exit_code)
  const chip = severityChipClass(entry.exit_code)
  const expanded = useSignal(false)
  const onToggle = () => { expanded.value = !expanded.value }
  return html`
    <div class="rounded border border-[var(--white-8)] bg-[var(--white-4)] p-3" role="group" aria-label=${`${doctorHeading(entry)}: ${label}`}>
      <button type="button"
        class="flex w-full items-baseline justify-between gap-2 text-left"
        aria-expanded=${expanded.value}
        aria-controls=${`doctor-detail-${entry.name}`}
        onClick=${onToggle}
      >
        <div class="text-sm font-semibold text-[var(--text-strong)]">
          ${doctorHeading(entry)}
          <span class="ml-2 text-[10px] text-[var(--text-muted)]" aria-hidden="true">${expanded.value ? '▾' : '▸'}</span>
        </div>
        <span class="rounded-full border px-2 py-0.5 text-[10px] uppercase tracking-wider ${chip}">
          ${label}
        </span>
      </button>
      <div class="mt-1 text-xs text-[var(--text-muted)]">
        ${entry.kind === 'config' ? 'Config Doctor' : `${entry.name} sidecar`} · exit ${entry.exit_code}
      </div>
      <div id=${`doctor-detail-${entry.name}`} role="region" aria-label=${`${doctorHeading(entry)} 상세`}>
        ${expanded.value
          ? entry.kind === 'sidecar'
            ? html`<${SidecarChecksList} checks=${extractSidecarChecks(entry.payload)} />`
            : html`<${ConfigNotesList} notes=${extractConfigNotes(entry.payload)} />`
          : ''}
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
      <${Card} title="진단" class="section">
        <${AsyncContainer}
          state=${doctorEnvelope.state}
          loadingMessage="진단 데이터를 불러오는 중..."
          emptyMessage="진단 데이터가 없습니다."
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
                  <button type="button"
                    class="rounded border border-[var(--white-8)] px-2.5 py-1 text-2xs text-[var(--text-muted)] transition-colors hover:border-[var(--accent)] hover:text-[var(--text-body)]"
                    aria-label="진단 결과 새로고침"
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
