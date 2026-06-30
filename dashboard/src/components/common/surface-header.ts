// SurfaceHeader — generic per-surface header for surfaces that do not render a
// richer bespoke header of their own (monitoring, board, command, lab). Shows
// the current section/surface title + description (from the nav registry) plus
// the shared header actions. Surfaces opt in by rendering <SurfaceHeader/> at
// the top of their body.
//
// This replaces the former shell-level SurfaceLead, which decided per-surface
// whether to render a generic lead via a hand-maintained allow-list
// (SURFACE_OWN_LEAD_IDS) — an N-of-M list the compiler could not enforce.
// Now each surface owns the decision to render its header (bespoke or this
// generic one) at the call site, so there is a single, co-located source for
// every surface's title.
import { html } from 'htm/preact'
import type { VNode } from 'preact'
import type { TabId } from '../../types'
import { hashForRoute, navigate, route } from '../../router'
import { DASHBOARD_NAV_ITEMS, currentSectionForRoute } from '../../config/navigation'
import { isWidgetSoloRoute } from '../widget-solo'
import { Breadcrumb } from './breadcrumb'
import type { BreadcrumbItem } from './breadcrumb'
import { SurfaceHeaderActions } from './surface-header-actions'

interface BreadcrumbCrumb {
  label: string
  navigableTab: TabId | null
}

function deriveBreadcrumbTrail(
  tabLabel: string | null,
  sectionLabel: string | null,
  tabId: TabId | null,
): BreadcrumbCrumb[] {
  if (tabLabel === null && sectionLabel === null) return []
  if (sectionLabel === null) {
    return tabLabel !== null ? [{ label: tabLabel, navigableTab: null }] : []
  }
  if (tabLabel === null) {
    return [{ label: sectionLabel, navigableTab: null }]
  }
  return [
    { label: tabLabel, navigableTab: tabId },
    { label: sectionLabel, navigableTab: null },
  ]
}

function navigateCrumb(event: MouseEvent, tab: TabId): void {
  if (
    event.defaultPrevented
    || event.button !== 0
    || event.metaKey
    || event.ctrlKey
    || event.shiftKey
    || event.altKey
  ) {
    return
  }
  event.preventDefault()
  navigate(tab)
}

function breadcrumbItemsForTrail(trail: BreadcrumbCrumb[]): BreadcrumbItem[] {
  return trail.map((crumb, index) => {
    const current = index === trail.length - 1
    if (crumb.navigableTab !== null && !current) {
      return {
        label: crumb.label,
        href: hashForRoute(crumb.navigableTab),
        onClick: (event: MouseEvent) => navigateCrumb(event, crumb.navigableTab!),
      }
    }
    return { label: crumb.label, current }
  })
}

export function SurfaceHeader(): VNode | null {
  if (isWidgetSoloRoute(route.value)) return null

  const currentTab = route.value.tab
  const currentView = DASHBOARD_NAV_ITEMS.find(item => item.id === currentTab)
  const currentSection = currentSectionForRoute(route.value)
  const title = currentSection?.label ?? currentView?.label ?? 'Home'
  const description = currentSection?.description ?? currentView?.description ?? null
  const trail = currentSection !== null
    ? deriveBreadcrumbTrail(currentView?.label ?? null, currentSection.label, currentTab)
    : []
  return html`
    <header class="v2-surface-header mb-3 flex flex-col gap-1.5" data-testid="surface-header">
      ${trail.length > 0
        ? html`<${Breadcrumb}
            items=${breadcrumbItemsForTrail(trail)}
            ariaLabel="Breadcrumb"
            testId="surface-breadcrumb"
            dataSurfaceBreadcrumb=${true}
          />`
        : null}
      <div class="flex items-center gap-2">
        <div role="heading" aria-level="1" class="text-lg font-semibold leading-tight tracking-normal normal-case text-[var(--color-fg-secondary)]" style="text-shadow: none;">
          ${title}
        </div>
        <${SurfaceHeaderActions} label=${title} />
      </div>
      ${description
        ? html`<p class="m-0 max-w-[72rem] text-xs leading-[var(--lh-body)] text-[var(--color-fg-muted)]">${description}</p>`
        : null}
    </header>
  `
}
