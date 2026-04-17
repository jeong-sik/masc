// SetupGuideCard — collapsible "처음 설치하나요?" card rendered next to a
// sidecar's lifecycle commands when the bridge is offline. Data source:
// CONNECTOR_SETUP_GUIDES.

import { html } from 'htm/preact'
import { ChevronRight, ExternalLink } from 'lucide-preact'
import { signal } from '@preact/signals'
import { CONNECTOR_SETUP_GUIDES } from './connector-setup-guides'

// Per-connector expand state — keyed so jumping between bridge sub-sections
// doesn't carry over an open card.
const expandedFor = signal<Record<string, boolean>>({})

// Per-connector per-step completion (indexed by step position in
// CONNECTOR_SETUP_GUIDES). In-memory only; the guide changes rarely
// enough that session-scoped tracking is fine, and a fresh reload
// resetting to 0% matches "picking up the setup again" semantics.
//
// Reference — Stripe Dashboard onboarding + GitHub "set up your
// account" checklist: each platform step is a checkbox the operator
// ticks as they go, with a progress count in the header so the
// operator can tell at a glance how far they are.
const completedSteps = signal<Record<string, Record<number, boolean>>>({})

/** Pure: render "5 steps" when nothing done, "3 of 5 done" once any
    step is checked. Exposed so tests can pin the copy without mounting
    a DOM. Rich Hickey: make the presentation layer not have to re-
    derive what the data layer already knows. */
export function stepCompletionSummary(completed: number, total: number): string {
  if (completed <= 0) return `${total} steps`
  return `${completed} of ${total} done`
}

/** Pure: count the `true` entries in a per-step completion map. Guards
    against stale indices (step removed from the guide but still tracked
    as complete) by capping at `total`. */
export function countCompletedSteps(
  completedMap: Record<number, boolean> | undefined,
  total: number,
): number {
  if (completedMap === undefined) return 0
  let n = 0
  for (let i = 0; i < total; i++) {
    if (completedMap[i] === true) n++
  }
  return n
}

function toggleStepCompletion(connectorId: string, stepIndex: number) {
  const cur = completedSteps.value[connectorId] ?? {}
  const next = { ...cur, [stepIndex]: !cur[stepIndex] }
  completedSteps.value = { ...completedSteps.value, [connectorId]: next }
}

function ExternalLinkChip({ href, label }: { href: string; label: string }) {
  return html`
    <a
      href=${href}
      target="_blank"
      rel="noopener noreferrer"
      class="inline-flex items-center gap-1 rounded border border-[var(--white-8)] bg-[var(--white-2)] px-1.5 py-0.5 text-[10px] text-[var(--text-body)] transition-colors hover:bg-[var(--white-8)]"
    >
      ${label}
      <${ExternalLink} size=${10} />
    </a>
  `
}

export function SetupGuideCard({ connectorId }: { connectorId: string }) {
  const guide = CONNECTOR_SETUP_GUIDES[connectorId]
  if (!guide) return null

  const isOpen = expandedFor.value[connectorId] === true
  const toggle = () => {
    expandedFor.value = { ...expandedFor.value, [connectorId]: !isOpen }
  }
  const completedMap = completedSteps.value[connectorId]
  const doneCount = countCompletedSteps(completedMap, guide.steps.length)

  return html`
    <div class="mt-2 rounded-md border border-[var(--white-8)] bg-[var(--white-2)]">
      <button
        type="button"
        class="flex w-full cursor-pointer items-center justify-between gap-2 px-3 py-2 text-left text-[12px] text-[var(--text-body)] hover:bg-[var(--white-4)]"
        aria-expanded=${isOpen}
        aria-controls=${`setup-guide-${connectorId}`}
        onClick=${toggle}
      >
        <div class="flex items-center gap-2">
          <span class=${`inline-block transition-transform ${isOpen ? 'rotate-90' : ''}`}>
            <${ChevronRight} size=${14} />
          </span>
          <span class="font-medium">처음 설치하나요? · ${guide.title}</span>
        </div>
        <span
          class=${`text-[10px] uppercase tracking-[0.14em] ${doneCount > 0 ? 'text-emerald-300/80' : 'text-[var(--text-dim)]'}`}
          data-setup-progress=${connectorId}
        >${stepCompletionSummary(doneCount, guide.steps.length)}</span>
      </button>

      ${isOpen
        ? html`
            <div id=${`setup-guide-${connectorId}`} class="border-t border-[var(--white-8)] px-3 py-2.5 text-[11px] text-[var(--text-body)]">
              <p class="mb-2 text-[var(--text-dim)]">${guide.intro}</p>
              <ol class="ml-4 list-none space-y-1.5">
                ${guide.steps.map((step, idx) => {
                  const done = completedMap?.[idx] === true
                  return html`
                    <li class="flex items-start gap-2">
                      <input
                        type="checkbox"
                        class="mt-[3px] shrink-0 cursor-pointer accent-emerald-400"
                        id=${`setup-step-${connectorId}-${idx}`}
                        data-setup-step=${`${connectorId}:${idx}`}
                        checked=${done}
                        onClick=${(ev: Event) => {
                          ev.stopPropagation()
                          toggleStepCompletion(connectorId, idx)
                        }}
                        aria-label=${`step ${idx + 1} done`}
                      />
                      <label
                        for=${`setup-step-${connectorId}-${idx}`}
                        class=${`min-w-0 flex-1 cursor-pointer ${done ? 'text-[var(--text-dim)] line-through decoration-[var(--white-10)]' : ''}`}
                      >
                        <span>${step.text}</span>
                        ${step.link
                          ? html`<span class="ml-1.5"><${ExternalLinkChip} href=${step.link.href} label=${step.link.label} /></span>`
                          : null}
                      </label>
                    </li>
                  `
                })}
              </ol>
              ${guide.references.length > 0
                ? html`
                    <div class="mt-3 flex flex-wrap items-center gap-1.5 border-t border-[var(--white-8)] pt-2">
                      <span class="text-[10px] uppercase tracking-[0.14em] text-[var(--text-dim)]">refs</span>
                      ${guide.references.map(ref => html`<${ExternalLinkChip} href=${ref.href} label=${ref.label} />`)}
                    </div>
                  `
                : null}
            </div>
          `
        : null}
    </div>
  `
}

export function resetSetupGuideExpansionState() {
  expandedFor.value = {}
  completedSteps.value = {}
}
