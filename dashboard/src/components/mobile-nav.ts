// DashboardNavRail — responsive shell navigation rail.
//
// The keeper-v2 prototype uses one NavRail component whose CSS morphs from a
// left rail into a mobile bottom tab bar at 900px. The dashboard still needs a
// richer operational drawer for secondary sections, but one component now owns
// the desktop rail, mobile drawer, and mobile tab strip instead of app.ts
// stitching together separate navigation surfaces.

import { html } from 'htm/preact'
import { Fragment } from 'preact'
import { Menu } from 'lucide-preact'
import { RouteLink } from './common/route-link'
import { SurfaceIcon } from './surface-icon'
import { PRIMARY_DASHBOARD_NAV_ITEMS } from '../config/navigation'
import { ringFocusClasses } from './common/ring'
import { SideRail } from './dashboard-shell'
import type { TabId } from '../types'

// Keep the mobile bar aligned with the keeper-v2 prototype's primary surfaces:
// Overview, Work, Keepers, and Board. Operational lanes remain in More.
const MOBILE_PRIMARY_TAB_IDS: ReadonlyArray<TabId> = [
  'overview',
  'workspace',
  'keepers',
  'board',
]

const mobilePrimaryItems = MOBILE_PRIMARY_TAB_IDS.flatMap(id => {
  const item = PRIMARY_DASHBOARD_NAV_ITEMS.find(navItem => navItem.id === id)
  return item ? [item] : []
})

interface MobileNavRailTabsProps {
  currentTab: TabId
  onMenuToggle: () => void
}

interface DashboardNavRailProps {
  currentTab: TabId
  mobile: boolean
  drawerOpen: boolean
  keeperDetailMode: boolean
  collapsed: boolean
  onToggleCollapsed: () => void
  onToggleDrawer: () => void
  onCloseDrawer: () => void
}

export function DashboardNavRail({
  currentTab,
  mobile,
  drawerOpen,
  keeperDetailMode,
  collapsed,
  onToggleCollapsed,
  onToggleDrawer,
  onCloseDrawer,
}: DashboardNavRailProps) {
  const effectiveCollapsed = mobile ? false : collapsed
  const sideRailWidthClass = mobile ? 'w-72' : (collapsed ? 'w-14' : 'w-55')
  const sideRailResponsiveClass = mobile
    ? drawerOpen
      ? 'block fixed inset-y-0 left-0 z-50 m-0 max-h-none rounded-none border-r'
      : 'hidden'
    : 'max-[1100px]:hidden'

  return html`
    <${Fragment}>
      ${drawerOpen && mobile ? html`
        <button
          type="button"
          aria-label="Close navigation"
          tabindex=${-1}
          data-testid="dashboard-nav-rail-overlay"
          class="fixed inset-0 z-40 cursor-pointer bg-black/50"
          onClick=${onCloseDrawer}
        ></button>
      ` : null}
      <aside
        id="dashboard-side-rail"
        aria-label="Sidebar navigation"
        data-testid="dashboard-nav-rail"
        class="v2-shell-rail ${sideRailWidthClass} shrink-0 overflow-hidden rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--shell-rail-bg)] backdrop-blur-xl transition-[width] duration-[var(--t-slow)] ease-[var(--ease)] ${sideRailResponsiveClass}"
      >
        <${SideRail} collapsed=${effectiveCollapsed} onToggle=${onToggleCollapsed} primaryOnly=${!mobile} />
      </aside>
      ${mobile && !drawerOpen && !keeperDetailMode
        ? html`<${MobileNavRailTabs} currentTab=${currentTab} onMenuToggle=${onToggleDrawer} />`
        : null}
    <//>
  `
}

function MobileNavRailTabs({ currentTab, onMenuToggle }: MobileNavRailTabsProps) {
  return html`
    <nav
      class="v2-shell-surface v2-mobile-bottom-bar fixed inset-x-0 bottom-0 z-40 items-stretch border-t border-[var(--color-border-strong)] bg-[var(--shell-header-bg)] backdrop-blur-xl"
      style=${{ paddingBottom: 'env(safe-area-inset-bottom, 0px)' }}
      aria-label="Primary mobile navigation"
      data-testid="dashboard-nav-rail-mobile-tabs"
    >
      ${mobilePrimaryItems.map(item => {
        const active = item.id === currentTab
        return html`
          <${RouteLink}
            tab=${item.id}
            params=${item.defaultParams}
            ariaCurrent=${active ? 'page' : undefined}
            'aria-label'=${item.label}
            class=${`flex min-h-[44px] flex-1 flex-col items-center justify-center gap-0.5 px-1 transition-colors ${
              active
                ? 'text-[var(--select)]'
                : 'text-[var(--color-fg-muted)] hover:text-[var(--color-fg-secondary)]'
            }`}
          >
            <${SurfaceIcon} icon=${item.icon} size=${20} />
            <span class="font-mono text-3xs uppercase leading-none tracking-[var(--track-caps)]">${item.label}</span>
          <//>
        `
      })}
      <button
        type="button"
        'aria-label'="Open full navigation"
        class=${`v2-shell-action flex min-h-[44px] flex-col items-center justify-center gap-0.5 px-3 text-[var(--color-fg-muted)] cursor-pointer transition-colors hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-secondary)] ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'page' })}`}
        onClick=${onMenuToggle}
      >
        <${Menu} size=${20} />
        <span class="font-mono text-3xs uppercase leading-none tracking-[var(--track-caps)]">More</span>
      </button>
    </nav>
  `
}
