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

export function classifyCoverageError(error: string | null | undefined): CoverageErrorHint | null {
  if (!error) return null
  const lower = error.toLowerCase()
  // RFC-0097: keeper-sandbox container reuse — root fix for the 2026-05-16
  // ENFILE storm that drove Docker_spawn_throttle + container reuse.
  if (
    lower.includes('too many open files')
    || lower.includes('enfile')
    || lower.includes('emfile')
  ) {
    return {
      reason: 'fd_exhaustion',
      label: 'FD exhaustion — see RFC-0097',
      href: 'https://github.com/jeong-sik/masc-mcp/blob/main/docs/rfc/RFC-0097-keeper-sandbox-container-reuse.md',
    }
  }
  return null
}

/**
 * Coverage-gap provenance block. Shared by tool-quality-panel and
 * fleet-health-panel Operations view so the collapsible-error UX is the
 * same regardless of which surface the operator lands on.
 *
 * Visual hierarchy (top → bottom):
 *  1. Warn-tone summary line (`⚠ coverage gaps N: <reason>`)
 *  2. Triage chips (producer / store / surface / trace) — always visible
 *  3. Error blob inside a closed `<details>` (1-line truncated preview
 *     when closed, full `<pre>` block when open)
 *  4. Optional "see RFC-XXXX" anchor when the error matches a known
 *     incident class (see `classifyCoverageError`)
 *
 * Label spans use `${label + ' '}` (not adjacent siblings) so DOM
 * textContent preserves "label value" as a contiguous substring —
 * keeps text-search-based tests stable across format changes.
 */
export function CoverageGapBlock({ display }: { display: CoverageGapDisplay }) {
  const { structured } = display
  const hint = classifyCoverageError(structured.error)
  return html`
    <div class="mt-1 grid gap-1 rounded-[var(--r-1)] border border-[var(--color-status-warn)]/30 bg-[var(--warn-10)]/30 px-2 py-1.5 text-3xs" data-testid="coverage-gap-block">
      <div class="flex items-center gap-1.5 font-medium text-[var(--color-status-warn)]">
        <span aria-hidden="true">⚠</span>
        <span>${display.summary}</span>
      </div>
      ${structured.fields.length > 0 ? html`
        <div class="grid gap-0.5 font-mono">
          ${structured.fields.map(({ label, value }) => html`
            <div class="flex items-baseline">
              <span class="w-16 shrink-0 text-[var(--color-fg-disabled)] uppercase tracking-wide">${label + ' '}</span>
              <span class="min-w-0 break-all text-[var(--color-fg-muted)]">${value}</span>
            </div>
          `)}
        </div>
      ` : null}
      ${structured.error ? html`
        <details class="group">
          <summary class="flex items-baseline cursor-pointer list-none [&::-webkit-details-marker]:hidden font-mono">
            <span class="w-16 shrink-0 uppercase tracking-wide text-[var(--color-fg-disabled)]">error </span>
            <span class="min-w-0 flex-1 truncate text-[var(--color-fg-muted)] group-open:hidden">${structured.error}</span>
            <span class="ml-2 shrink-0 text-[var(--color-fg-disabled)]" aria-hidden="true">
              <span class="group-open:hidden">▸</span>
              <span class="hidden group-open:inline">▾</span>
            </span>
          </summary>
          <pre class="mt-1 ml-16 max-h-32 overflow-auto rounded-[var(--r-1)] bg-[var(--bg-deepest)] p-2 font-mono text-3xs leading-snug text-[var(--color-fg-muted)] whitespace-pre-wrap break-all">${structured.error}</pre>
        </details>
      ` : null}
      ${hint ? html`
        <a
          href=${hint.href}
          target="_blank"
          rel="noopener noreferrer"
          class="ml-16 inline-flex items-center gap-1 self-start rounded-[var(--r-1)] border border-[var(--color-status-warn)]/40 bg-[var(--warn-10)] px-1.5 py-0.5 font-medium text-[var(--color-status-warn)] hover:bg-[var(--warn-20)]"
          data-testid=${`coverage-gap-hint-${hint.reason}`}
        >
          <span aria-hidden="true">💡</span>
          <span>${hint.label}</span>
          <span aria-hidden="true">↗</span>
        </a>
      ` : null}
    </div>
  `
}
