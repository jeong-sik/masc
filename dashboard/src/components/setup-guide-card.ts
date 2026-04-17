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
        <span class="text-[10px] uppercase tracking-[0.14em] text-[var(--text-dim)]">${guide.steps.length} steps</span>
      </button>

      ${isOpen
        ? html`
            <div id=${`setup-guide-${connectorId}`} class="border-t border-[var(--white-8)] px-3 py-2.5 text-[11px] text-[var(--text-body)]">
              <p class="mb-2 text-[var(--text-dim)]">${guide.intro}</p>
              <ol class="ml-4 list-decimal space-y-1.5 marker:text-[var(--text-dim)]">
                ${guide.steps.map(step => html`
                  <li>
                    <span>${step.text}</span>
                    ${step.link
                      ? html`<span class="ml-1.5"><${ExternalLinkChip} href=${step.link.href} label=${step.link.label} /></span>`
                      : null}
                  </li>
                `)}
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
}
