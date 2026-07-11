// SurfaceHeaderActions — the copy-section-link + open-in-solo-view affordances
// that a surface's own primary header carries. Extracted from the former
// generic SurfaceLead (removed in the single-source header refactor) so that
// each surface owns its header while the shared utility affordances live in one
// place. Reads the live route to derive the share/solo URLs for the current
// surface+section, so it works regardless of which surface header hosts it.
import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { ExternalLink } from 'lucide-preact'
import { route } from '../../router'
import { widgetSoloUrlForRoute } from '../widget-solo'
import { CopyIdButton } from './copy-id-button'
import { ringFocusClasses } from './ring'

// window.location is the truth source (the router writes to it already), so the
// copied link never diverges from the address bar. Returns '' when window is
// unavailable (SSR / happy-dom without location) so the caller hides the
// share affordance gracefully.
function currentShareUrl(): string {
  if (typeof window === 'undefined' || window.location === undefined) {
    return ''
  }
  return window.location.href
}

export function SurfaceHeaderActions({ label }: { label: string }): VNode {
  const soloUrl = widgetSoloUrlForRoute(route.value)
  const shareUrl = currentShareUrl()
  return html`
    <div class="v2-surface-header-actions inline-flex items-center gap-2">
      ${shareUrl !== ''
        ? html`<${CopyIdButton}
            value=${shareUrl}
            label=${`Section link (${label})`}
            ariaLabel="Copy current section URL"
            size=${14}
          />`
        : null}
      <a
        href=${soloUrl}
        target="_blank"
        rel="noopener noreferrer"
        class=${`v2-shell-action v2-mobile-operator-target inline-flex size-7 items-center justify-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-secondary)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'page' })}`}
        title="Open this surface in a solo view"
        aria-label="Open this surface in a solo view"
        data-testid="dashboard-widget-solo-link"
      >
        <${ExternalLink} size=${14} aria-hidden="true" />
      </a>
    </div>
  `
}
