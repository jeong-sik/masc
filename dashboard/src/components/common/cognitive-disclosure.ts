import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

export type CognitiveDisclosureLevel = 'perceive' | 'comprehend' | 'project'

export interface CognitiveDisclosureItem {
  level: CognitiveDisclosureLevel
  title: ComponentChildren
  summary: ComponentChildren
  detail?: ComponentChildren
  metric?: ComponentChildren
  defaultOpen?: boolean
}

export interface CognitiveDisclosureSummary {
  total: number
  byLevel: Record<CognitiveDisclosureLevel, number>
  openDefaultLevel: CognitiveDisclosureLevel | null
  complete: boolean
}

interface CognitiveDisclosureProps {
  items: readonly CognitiveDisclosureItem[]
  title?: ComponentChildren
  testId?: string
  class?: string
}

const LEVEL_ORDER: CognitiveDisclosureLevel[] = ['perceive', 'comprehend', 'project']

const LEVEL_META: Record<CognitiveDisclosureLevel, { label: string; caption: string }> = {
  perceive: {
    label: 'Perceive',
    caption: 'Direct signal',
  },
  comprehend: {
    label: 'Comprehend',
    caption: 'Grouped meaning',
  },
  project: {
    label: 'Project',
    caption: 'Forward state',
  },
}

export function summarizeCognitiveDisclosure(
  items: readonly CognitiveDisclosureItem[],
): CognitiveDisclosureSummary {
  const byLevel: Record<CognitiveDisclosureLevel, number> = {
    perceive: 0,
    comprehend: 0,
    project: 0,
  }
  let openDefaultLevel: CognitiveDisclosureLevel | null = null

  for (const item of items) {
    byLevel[item.level] += 1
    if (item.defaultOpen && openDefaultLevel == null) openDefaultLevel = item.level
  }

  return {
    total: items.length,
    byLevel,
    openDefaultLevel,
    complete: LEVEL_ORDER.every(level => byLevel[level] > 0),
  }
}

function levelItems(
  items: readonly CognitiveDisclosureItem[],
  level: CognitiveDisclosureLevel,
): CognitiveDisclosureItem[] {
  return items.filter(item => item.level === level)
}

export function CognitiveDisclosure({
  items,
  title = 'Cognitive Disclosure',
  testId = 'cognitive-disclosure',
  class: cx,
}: CognitiveDisclosureProps) {
  const summary = summarizeCognitiveDisclosure(items)

  return html`
    <section
      class="border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] ${cx ?? ''}"
      aria-label="Cognitive disclosure"
      data-testid=${testId}
      data-cognitive-total=${summary.total}
      data-cognitive-complete=${summary.complete ? 'true' : 'false'}
      data-cognitive-open-default=${summary.openDefaultLevel ?? ''}
    >
      <div class="flex flex-wrap items-center justify-between gap-2 border-b border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2.5">
        <h2 class="text-sm font-semibold text-[var(--color-fg-primary)]">${title}</h2>
        <span class="font-mono text-3xs text-[var(--color-fg-muted)]">
          ${summary.total} signals
        </span>
      </div>

      <div class="grid grid-cols-1 divide-y divide-[var(--color-border-default)] lg:grid-cols-3 lg:divide-x lg:divide-y-0">
        ${LEVEL_ORDER.map((level, index) => {
          const meta = LEVEL_META[level]
          const entries = levelItems(items, level)

          return html`
            <div
              key=${level}
              class="min-w-0"
              data-cognitive-level=${level}
              data-cognitive-count=${entries.length}
            >
              <div class="flex items-start gap-2 px-3 py-3">
                <span class="inline-flex h-6 w-7 shrink-0 items-center justify-center border border-[var(--color-border-default)] bg-[var(--color-bg-page)] font-mono text-3xs text-[var(--color-fg-muted)]">
                  L${index + 1}
                </span>
                <div class="min-w-0">
                  <h3 class="text-xs font-semibold text-[var(--color-fg-primary)]">${meta.label}</h3>
                  <p class="mt-0.5 text-3xs uppercase tracking-normal text-[var(--color-fg-muted)]">${meta.caption}</p>
                </div>
              </div>

              <div class="divide-y divide-[var(--color-border-default)] border-t border-[var(--color-border-default)]">
                ${entries.map((entry, entryIndex) => html`
                  <details
                    key=${`${level}:${entryIndex}`}
                    open=${entry.defaultOpen}
                    class="group"
                    data-cognitive-has-detail=${entry.detail == null ? 'false' : 'true'}
                  >
                    <summary class="grid cursor-pointer grid-cols-[minmax(0,1fr)_auto] gap-2 px-3 py-2.5 text-left text-xs text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-elevated)]">
                      <span class="min-w-0 font-medium text-[var(--color-fg-primary)]">${entry.title}</span>
                      ${entry.metric != null
                        ? html`<span class="font-mono text-3xs text-[var(--color-fg-muted)]">${entry.metric}</span>`
                        : null}
                      <span class="col-span-2 min-w-0 text-[var(--color-fg-muted)]">${entry.summary}</span>
                    </summary>
                    ${entry.detail != null
                      ? html`<div class="px-3 pb-3 text-xs leading-relaxed text-[var(--color-fg-secondary)]">${entry.detail}</div>`
                      : null}
                  </details>
                `)}
              </div>
            </div>
          `
        })}
      </div>
    </section>
  `
}
