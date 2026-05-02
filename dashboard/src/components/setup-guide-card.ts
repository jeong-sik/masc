// SetupGuideCard — collapsible "처음 설치하나요?" card rendered next to a
// sidecar's lifecycle commands when the bridge is offline. Data source:
// CONNECTOR_SETUP_GUIDES.

import { html } from 'htm/preact'
import { ChevronRight, ExternalLink } from 'lucide-preact'
import { signal } from '@preact/signals'
import { Checkbox } from './common/checkbox'
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

type SetupGuideTone = 'idle' | 'in-progress' | 'complete'

/** Pure: 0..100 integer progress. Total=0 returns 0 (no div by zero). */
export function setupGuideProgressPct(done: number, total: number): number {
  if (total <= 0) return 0
  return Math.round((Math.min(done, total) / total) * 100)
}

/** Pure: derive tone from progress. Drives the card header gradient
    and celebration badge. Linear / Plane onboarding convention —
    idle muted, in-progress accent, complete emerald. */
export function setupGuideTone(done: number, total: number): SetupGuideTone {
  if (total <= 0 || done <= 0) return 'idle'
  if (done >= total) return 'complete'
  return 'in-progress'
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
      class="inline-flex items-center gap-1 rounded-[var(--r-1)] border border-[var(--white-8)] bg-[var(--white-2)] px-1.5 py-0.5 text-3xs text-[var(--color-fg-primary)] transition-colors hover:bg-[var(--white-8)]"
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
  const pct = setupGuideProgressPct(doneCount, guide.steps.length)
  const tone = setupGuideTone(doneCount, guide.steps.length)
  // Linear / Plane onboarding convention: complete state celebrates
  // with an emerald accent + checkmark badge; in-progress tints the
  // count chip in accent color so scanning a list of cards shows which
  // ones are halfway; idle stays muted.
  const countToneClass =
    tone === 'complete' ? 'text-[var(--color-status-ok)]' :
    tone === 'in-progress' ? 'text-[var(--color-accent-fg)]' :
    'text-[var(--color-fg-disabled)]'
  const progressBarToneClass =
    tone === 'complete' ? 'bg-[var(--ok-10)]' :
    tone === 'in-progress' ? 'bg-[var(--color-accent-fg)]' :
    'bg-[var(--white-10)]'

  return html`
    <div
      class="mt-2 overflow-hidden rounded-[var(--r-1)] border border-[var(--white-8)] bg-[var(--white-2)]"
      data-setup-guide-tone=${tone}
    >
      <button
        type="button"
        class="flex w-full cursor-pointer items-center justify-between gap-2 px-3 py-2 text-left text-xs text-[var(--color-fg-primary)] hover:bg-[var(--white-4)]"
        aria-expanded=${isOpen}
        aria-controls=${`setup-guide-${connectorId}`}
        onClick=${toggle}
      >
        <div class="flex items-center gap-2">
          <span class=${`inline-block transition-transform ${isOpen ? 'rotate-90' : ''}`}>
            <${ChevronRight} size=${14} />
          </span>
          <span class="font-medium">처음 설치하나요? · ${guide.title}</span>
          ${tone === 'complete'
            ? html`
                <span
                  class="inline-flex items-center gap-1 rounded-[var(--r-0)] border border-[var(--ok-20)] bg-[var(--ok-10)] px-1.5 py-0.5 text-3xs font-semibold uppercase tracking-4 text-[var(--color-status-ok)]"
                  aria-label="설정 가이드 완료"
                  data-setup-complete-badge
                >
                  <span aria-hidden="true">✓</span>
                  <span>완료</span>
                </span>
              `
            : null}
        </div>
        <span
          class=${`text-3xs uppercase tracking-4 tabular-nums ${countToneClass}`}
          data-setup-progress=${connectorId}
          data-setup-progress-pct=${pct}
        >${stepCompletionSummary(doneCount, guide.steps.length)}</span>
      </button>

      <!-- Linear-style thin progress bar under the header. 2px tall,
           always visible so the progress signals out even when the
           card is collapsed (operator scanning multiple cards). -->
      <div
        class="h-[2px] w-full bg-[var(--white-4)]"
        role="progressbar"
        aria-valuenow=${pct}
        aria-valuemin=${0}
        aria-valuemax=${100}
        aria-label="설정 가이드 진행률"
        data-setup-progress-bar
      >
        <div
          class=${`h-full transition-all duration-300 ${progressBarToneClass}`}
          style=${`width: ${pct}%`}
          data-setup-progress-bar-fill
        ></div>
      </div>

      ${isOpen
        ? html`
            <div id=${`setup-guide-${connectorId}`} class="border-t border-[var(--white-8)] px-3 py-2.5 text-2xs text-[var(--color-fg-primary)]">
              <p class="mb-2 text-[var(--color-fg-disabled)]">${guide.intro}</p>
              <ol class="list-none space-y-2" data-setup-step-list>
                ${guide.steps.map((step, idx) => {
                  const done = completedMap?.[idx] === true
                  // Plane / Notion step wizard pattern: numbered circle
                  // gutter on the left so the operator reads the flow
                  // as "1. Open Discord dev portal → 2. Create a bot …"
                  // even before checkboxes are ticked. Circle turns
                  // emerald-filled when the step is complete.
                  const circleToneClass = done
                    ? 'border-[var(--ok-20)] bg-[var(--ok-10)] text-[var(--color-status-ok)]'
                    : 'border-[var(--white-10)] bg-[var(--white-4)] text-[var(--color-fg-disabled)]'
                  return html`
                    <li class="flex items-start gap-2.5" data-setup-step-item=${idx}>
                      <span
                        class=${`mt-0.5 inline-flex h-5 w-5 shrink-0 items-center justify-center rounded-[var(--r-0)] border text-3xs font-semibold tabular-nums transition-colors ${circleToneClass}`}
                        aria-hidden="true"
                        data-setup-step-circle=${`${connectorId}:${idx}`}
                      >${done ? '✓' : idx + 1}</span>
                      <${Checkbox}
                        class="mt-[5px] shrink-0 !accent-emerald-400"
                        id=${`setup-step-${connectorId}-${idx}`}
                        testId=${`setup-step-${connectorId}:${idx}`}
                        checked=${done}
                        ariaLabel=${`step ${idx + 1} done`}
                        onClick=${(ev: Event) => {
                          ev.stopPropagation()
                          toggleStepCompletion(connectorId, idx)
                        }}
                      />
                      <label
                        for=${`setup-step-${connectorId}-${idx}`}
                        class=${`min-w-0 flex-1 cursor-pointer ${done ? 'text-[var(--color-fg-disabled)] line-through decoration-[var(--white-10)]' : ''}`}
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
                      <span class="text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)]">refs</span>
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
