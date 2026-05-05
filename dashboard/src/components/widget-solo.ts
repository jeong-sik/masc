import { html } from 'htm/preact'
import type { RouteState } from '../types'
import { hashForRoute } from '../router'
import { DASHBOARD_NAV_ITEMS, currentSectionForRoute } from '../config/navigation'
import { RouteLink } from './common/route-link'
import { ringFocusClasses } from './common/ring'

export const WIDGET_SOLO_PARAM = 'solo'

interface LocationLike {
  pathname: string
  search: string
}

export function isWidgetSoloRoute(routeState: Pick<RouteState, 'params'>): boolean {
  return routeState.params[WIDGET_SOLO_PARAM] === '1'
}

export function withWidgetSoloParam(params: Record<string, string>): Record<string, string> {
  return { ...params, [WIDGET_SOLO_PARAM]: '1' }
}

export function withoutWidgetSoloParam(params: Record<string, string>): Record<string, string> {
  const next = { ...params }
  delete next[WIDGET_SOLO_PARAM]
  return next
}

export function widgetSoloHashForRoute(routeState: RouteState): string {
  return hashForRoute(routeState.tab, withWidgetSoloParam(routeState.params))
}

export function widgetSoloExitHashForRoute(routeState: RouteState): string {
  return hashForRoute(routeState.tab, withoutWidgetSoloParam(routeState.params))
}

export function widgetSoloUrlForRoute(
  routeState: RouteState,
  locationLike: LocationLike = window.location,
): string {
  return `${locationLike.pathname}${locationLike.search}${widgetSoloHashForRoute(routeState)}`
}

export function widgetSoloLabelForRoute(routeState: RouteState): { title: string; id: string } {
  const currentView = DASHBOARD_NAV_ITEMS.find(item => item.id === routeState.tab)
  const currentSection = currentSectionForRoute(routeState)
  const title = currentSection?.label ?? currentView?.label ?? routeState.tab
  const idParts = [
    routeState.tab,
    currentSection?.id,
    routeState.params.view,
  ].filter(Boolean)
  return { title, id: idParts.join(':') }
}

export function WidgetSoloBar({ routeState }: { routeState: RouteState }) {
  const label = widgetSoloLabelForRoute(routeState)

  return html`
    <div
      class="flex h-9 shrink-0 items-center gap-3 border-b border-[var(--color-border-default)] bg-[var(--shell-header-bg)] px-3 font-mono text-xs text-[var(--color-fg-muted)]"
      data-testid="dashboard-widget-solo-bar"
    >
      <span class="size-2 shrink-0 rounded-full bg-[var(--brass-1)] shadow-[0_0_8px_rgb(var(--accent-glow)/0.5)]" aria-hidden="true"></span>
      <span class="min-w-0 truncate font-semibold text-[var(--color-fg-secondary)]">${label.title}</span>
      <span class="shrink-0 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-1.5 py-0.5 text-3xs uppercase text-[var(--color-fg-muted)] max-[520px]:hidden">${label.id}</span>
      <span class="flex-1"></span>
      <${RouteLink}
        tab=${routeState.tab}
        params=${withoutWidgetSoloParam(routeState.params)}
        class=${`inline-flex h-6 shrink-0 items-center rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 text-3xs uppercase text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-secondary)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'page' })}`}
        aria-label="Return to full dashboard"
      >
        Full dashboard
      <//>
    </div>
  `
}
