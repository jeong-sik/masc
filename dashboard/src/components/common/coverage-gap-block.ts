import { html } from 'htm/preact'
import type { CoverageGapDisplay } from './source-health'

// Operator-actionable error pattern classifier. Returns a hint with a
// canonical RFC link when the error string matches a known incident class.
// Pure function — exported for unit testing in isolation.
//
// Pattern → RFC mapping is the SSOT for "what should an operator do when
// they see this error in the dashboard". Add new patterns here as RFCs
// land for new failure modes.
export type CoverageErrorHint = {
  reason: string
  label: string
  href: string
}

// Substring vocabulary mirrors backend SSOT in
// `lib/keeper_disk_pressure.ml` (`is_disk_exhaustion_text`) so the
// dashboard reaches the same classification the runtime already acts on.
// Add new patterns here only when (a) backend has a matching typed
// detector, and (b) there is a canonical RFC describing the operator
// remediation.
const FD_EXHAUSTION_NEEDLES = [
  'too many open files',
  'enfile',
  'emfile',
] as const

const DISK_EXHAUSTION_NEEDLES = [
  'no space left on device',
  'enospc',
  'disk quota exceeded',
  'quota exceeded',
  'disk full',
  'not enough space',
] as const

export function classifyCoverageError(error: string | null | undefined): CoverageErrorHint | null {
  if (!error) return null
  const lower = error.toLowerCase()
  // RFC-0097: keeper-sandbox container reuse — root fix for the 2026-05-16
  // ENFILE storm. Current FD tracking is observation-only.
  if (FD_EXHAUSTION_NEEDLES.some(needle => lower.includes(needle))) {
    return {
      reason: 'fd_exhaustion',
      label: 'FD exhaustion — see RFC-0097',
      href: 'https://github.com/jeong-sik/masc/blob/main/docs/rfc/RFC-0097-keeper-sandbox-container-reuse.md',
    }
  }
  // RFC-0122: keeper disk pressure circuit breaker — mirrors backend
  // detector at `lib/keeper_disk_pressure.ml:55` which trips spawn slot
  // admission on these substrings.
  if (DISK_EXHAUSTION_NEEDLES.some(needle => lower.includes(needle))) {
    return {
      reason: 'disk_exhaustion',
      label: 'Disk pressure — see RFC-0122',
      href: 'https://github.com/jeong-sik/masc/blob/main/docs/rfc/RFC-0122-keeper-disk-pressure.md',
    }
  }
  return null
}

// RFC-0154 PR-3: typed lookup keyed by backend short tag from
// `System_error_class.to_short_tag`. Lookup-only — no substring matching.
// This is the SSOT for "given a typed error class, what RFC should the
// operator read". Add a new entry here only when the backend variant +
// canonical RFC both exist.
const ERROR_CLASS_HINTS: Record<string, CoverageErrorHint> = {
  fd_exhaustion: {
    reason: 'fd_exhaustion',
    label: 'FD exhaustion — see RFC-0097',
    href: 'https://github.com/jeong-sik/masc/blob/main/docs/rfc/RFC-0097-keeper-sandbox-container-reuse.md',
  },
  disk_exhaustion: {
    reason: 'disk_exhaustion',
    label: 'Disk pressure — see RFC-0122',
    href: 'https://github.com/jeong-sik/masc/blob/main/docs/rfc/RFC-0122-keeper-disk-pressure.md',
  },
}

export function errorHintFromClass(errorClass: string | null | undefined): CoverageErrorHint | null {
  if (!errorClass) return null
  return ERROR_CLASS_HINTS[errorClass] ?? null
}

// Cascading resolver — typed lookup first, substring fallback second.
// Once RFC-0154 PR-2 ships (backend writes `error_class`), the typed path
// satisfies every row; PR-4 removes the fallback once 0 v1-only rows are
// observed for 7 days.
export function errorHintFromGap(display: CoverageGapDisplay): CoverageErrorHint | null {
  return errorHintFromClass(display.structured.errorClass)
    ?? classifyCoverageError(display.structured.error)
}

function causeLabel(display: CoverageGapDisplay, hint: CoverageErrorHint | null): string {
  if (hint) return hint.label.split(' — ')[0] ?? hint.label
  return display.structured.reason.replace(/_/g, ' ')
}

function stateToneClass(stateLabel: string): string {
  switch (stateLabel) {
    case 'active':
      return 'border-[var(--bad)]/40 bg-[var(--bad)]/10 text-[var(--bad-light)]'
    case 'recent':
      return 'border-[var(--color-status-warn)]/40 bg-[var(--warn-10)] text-[var(--color-status-warn)]'
    case 'historical':
      return 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)]'
    default:
      return 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-secondary)]'
  }
}

/**
 * Coverage-gap provenance block. Shared by tool-quality-panel and
 * fleet-health-panel Operations view so the collapsible-error UX is the
 * same regardless of which surface the operator lands on.
 *
 * Visual hierarchy (top → bottom):
 *  1. Incident title + active/recent/historical chip.
 *  2. Operator summary (cause / impact / latest / store).
 *  3. Optional runbook link when the error maps to a known incident class.
 *  4. Collapsed raw evidence (reason / producer / surface / trace / error).
 *
 * Label spans use `${label + ' '}` (not adjacent siblings) so DOM
 * textContent preserves "label value" as a contiguous substring —
 * keeps text-search-based tests stable across format changes.
 */
export function CoverageGapBlock({ display }: { display: CoverageGapDisplay }) {
  const { structured } = display
  const hint = errorHintFromGap(display)
  const summaryRows = [
    { label: 'cause', value: causeLabel(display, hint) },
    { label: 'impact', value: structured.impact },
    { label: 'latest', value: structured.latest },
    { label: 'store', value: structured.store },
  ].filter((row): row is { label: string; value: string } => !!row.value)
  const evidenceRows = [
    { label: 'reason', value: structured.reason },
    { label: 'producer', value: structured.producer },
    { label: 'surface', value: structured.surface },
    { label: 'trace', value: structured.trace },
  ].filter((row): row is { label: string; value: string } => !!row.value)
  return html`
    <div class="mt-1 grid gap-2 rounded-[var(--r-1)] border border-[var(--color-status-warn)]/30 bg-[var(--warn-10)]/25 px-2.5 py-2 text-3xs" data-testid="coverage-gap-block">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="flex min-w-0 items-center gap-1.5 font-medium text-[var(--color-status-warn)]">
          <span aria-hidden="true">⚠</span>
          <span class="min-w-0">${display.summary}</span>
        </div>
        <span class=${`shrink-0 rounded-[var(--r-1)] border px-1.5 py-0.5 font-mono uppercase tracking-wide ${stateToneClass(structured.stateLabel)}`}>
          ${structured.stateLabel}
        </span>
      </div>
      <div class="grid gap-1 md:grid-cols-2">
        ${summaryRows.map(({ label, value }) => html`
          <div class="flex items-baseline gap-2">
            <span class="w-14 shrink-0 text-[var(--color-fg-disabled)] uppercase tracking-wide">${label + ' '}</span>
            <span class="min-w-0 break-words text-[var(--color-fg-muted)]">${value}</span>
          </div>
        `)}
      </div>
      ${hint ? html`
        <a
          href=${hint.href}
          target="_blank"
          rel="noopener noreferrer"
          class="v2-mobile-operator-target inline-flex items-center gap-1 self-start rounded-[var(--r-1)] border border-[var(--color-status-warn)]/40 bg-[var(--warn-10)] px-1.5 py-0.5 font-medium text-[var(--color-status-warn)] hover:bg-[var(--warn-20)]"
          data-testid=${`coverage-gap-hint-${hint.reason}`}
        >
          <span>${hint.label}</span>
          <span aria-hidden="true">↗</span>
        </a>
      ` : null}
      ${(evidenceRows.length > 0 || structured.error) ? html`
        <details class="group">
          <summary class="flex cursor-pointer items-center gap-1.5 list-none text-[var(--color-fg-secondary)] [&::-webkit-details-marker]:hidden">
            <span class="font-medium">Evidence</span>
            ${structured.trace ? html`<span class="min-w-0 truncate font-mono text-[var(--color-fg-disabled)]">${structured.trace}</span>` : null}
            <span class="ml-auto shrink-0 text-[var(--color-fg-disabled)]" aria-hidden="true">
              <span class="group-open:hidden">▸</span>
              <span class="hidden group-open:inline">▾</span>
            </span>
          </summary>
          <div class="mt-1 grid gap-0.5 font-mono">
            ${evidenceRows.map(({ label, value }) => html`
              <div class="flex items-baseline gap-2">
                <span class="w-20 shrink-0 text-[var(--color-fg-disabled)] uppercase tracking-wide">${label + ' '}</span>
                <span class="min-w-0 break-all text-[var(--color-fg-muted)]">${value}</span>
              </div>
            `)}
            ${structured.error ? html`
              <div>
                <div class="text-[var(--color-fg-disabled)] uppercase tracking-wide">error </div>
                <pre class="mt-1 max-h-32 overflow-auto rounded-[var(--r-1)] bg-[var(--bg-deepest)] p-2 font-mono text-3xs leading-snug text-[var(--color-fg-muted)] whitespace-pre-wrap break-all">${structured.error}</pre>
              </div>
            ` : null}
          </div>
        </details>
      ` : null}
    </div>
  `
}
