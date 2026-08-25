// Section navigation strip.
//
// A surface dispatches its sections with `section === 'x' ? html\`...\`` and
// nothing in that shape produces a link: adding a route draws the section once
// you arrive, never a way to get there. #27547 counted 23 sections that were
// routable with no rendered link anywhere in the app, because the nav that
// used to draw section sublists ([SideRail]) was declared and never mounted.
//
// Monitor got a strip of its own first; this is that strip with the tab lifted
// to a prop, so a surface mounts it instead of restating it. The section list
// comes from the same registry the router validates against, so a section
// cannot be routable and unlisted at the same time.
import { html } from 'htm/preact'
import {
  DASHBOARD_SURFACES,
  visibleSectionItemsForTab,
} from '../../config/navigation'
import type { TabId } from '../../types'
import { RouteLink } from './route-link'

function tabLabel(tab: TabId): string {
  return DASHBOARD_SURFACES.find(surface => surface.tabs.includes(tab))?.label ?? tab
}

/**
 * Links to every visible section of `tab`, marking `current` as the page.
 *
 * Renders nothing when the tab has fewer than two visible sections: the tab's
 * own nav entry is then the only way in and already exists.
 */
export function SectionNav({ tab, current }: { tab: TabId, current: string }) {
  const items = visibleSectionItemsForTab(tab)
  if (items.length < 2) return null
  return html`
    <nav
      class="flex flex-wrap items-center gap-1 border-b border-[var(--color-border-divider)] pb-2"
      aria-label="${tabLabel(tab)} sections"
      data-testid="section-nav-${tab}"
    >
      ${items.map(item => {
        const active = item.params.section === current
        return html`
          <${RouteLink}
            tab=${tab}
            params=${item.params}
            title=${item.description}
            ariaCurrent=${active ? 'page' : undefined}
            class="rounded-[var(--r-0)] border px-2 py-0.5 font-mono text-[var(--fs-10)] uppercase leading-5 tracking-[var(--track-sub)] cursor-pointer transition-[background-color,border-color,color] duration-[var(--t-med)] ${active
              ? 'border-[var(--select-20)] bg-[var(--select-10)] !text-[var(--select)]'
              : 'border-transparent !text-[var(--color-fg-muted)] hover:border-[var(--color-border-default)] hover:bg-[var(--color-bg-elevated)] hover:!text-[var(--color-fg-primary)]'}"
          >
            ${item.label}
          <//>
        `
      })}
    </nav>
  `
}
