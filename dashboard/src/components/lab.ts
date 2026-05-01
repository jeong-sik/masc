import { html } from 'htm/preact'
import { route } from '../router'
import { Card, SectionCard } from './common/card'
import { Tools } from './tools'
import { Autoresearch } from './autoresearch'
import { HarnessHealth } from './harness-health'
import { severityToneClass } from './overview/overview'
import type { OperatorAttentionItem } from '../types/dashboard-mission'

type LabSection = 'tools' | 'autoresearch' | 'harness' | 'legacy'

function currentSection(): LabSection {
  const section = route.value.params.section
  if (section === 'autoresearch' || section === 'harness' || section === 'legacy') {
    return section
  }
  return 'tools'
}

function Highlight({ attention }: { attention: OperatorAttentionItem | null }) {
  if (!attention) {
    return html`
      <${SectionCard} title="Legacy Highlight" data-testid="overview-highlight-empty">
        <p class="text-2xs text-[var(--color-fg-muted)] italic">No critical attention items (Preview Mode)</p>
      <//>
    `
  }
  return html`
    <${SectionCard} title="Legacy Highlight" data-testid="overview-highlight">
      <div class="flex items-center gap-3">
        <span class="flex-shrink-0 flex h-2 w-2 rounded-full bg-[var(--color-status-err)] animate-pulse" />
        <div class="flex-1 min-w-0">
          <p class="text-xs font-medium truncate ${severityToneClass(attention.severity)}">${attention.summary}</p>
          <p class="text-2xs text-[var(--color-fg-secondary)] truncate">
            ${attention.actor ?? attention.target_id ?? attention.target_type}
          </p>
        </div>
      </div>
    <//>
  `
}

export function Lab() {
  const section = currentSection()

  return html`
    <div class="space-y-6">
      ${section === 'tools' ? html`
        <${Tools} />
      ` : null}

      ${section === 'autoresearch' ? html`
        <${Card} title="오토리서치" class="section mb-4">
          <${Autoresearch} />
        <//>
      ` : null}

      ${section === 'harness' ? html`
        <${HarnessHealth} />
      ` : null}

      ${section === 'legacy' ? html`
        <div class="space-y-4">
          <header class="flex items-center justify-between">
            <h2 class="text-sm font-bold uppercase tracking-wider text-[var(--color-fg-muted)]">Legacy / Hidden Widgets</h2>
          </header>
          <${Highlight} attention=${null} />
          <p class="text-2xs text-[var(--color-fg-muted)] italic">
            This widget was removed from the main Overview tab to reduce clutter.
          </p>
        </div>
      ` : null}
    </div>
  `
}
