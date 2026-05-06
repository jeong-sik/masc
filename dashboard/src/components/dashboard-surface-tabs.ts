import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { SurfaceIcon } from './surface-icon'
import { RouteLink } from './common/route-link'
import type { DashboardSurfaceIcon } from '../config/navigation'
import type { TabId } from '../types'

interface DashboardSurfaceTabItem {
  readonly id: TabId
  readonly label: string
  readonly icon: DashboardSurfaceIcon
  readonly description: string
  readonly defaultParams?: Record<string, string>
}

interface DashboardSurfaceTabsProps {
  readonly items: ReadonlyArray<DashboardSurfaceTabItem>
  readonly currentTab: TabId
}

export function DashboardSurfaceTabs({ items, currentTab }: DashboardSurfaceTabsProps) {
  useEffect(() => {
    document
      .getElementById(dashboardSurfaceTabId(currentTab))
      ?.scrollIntoView({ block: 'nearest', inline: 'center' })
  }, [currentTab])

  return html`
    <nav class="min-w-0 flex-1 overflow-x-auto [scrollbar-width:none] max-[520px]:w-full" aria-label="Dashboard surfaces">
      <div
        role="tablist"
        aria-label="Dashboard surfaces"
        class="inline-flex min-w-max items-center gap-0.5 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] p-0.5"
      >
        ${items.map(item => {
          const active = item.id === currentTab
          return html`
            <${RouteLink}
              id=${dashboardSurfaceTabId(item.id)}
              role="tab"
              tab=${item.id}
              params=${item.defaultParams}
              tabIndex=${active ? 0 : -1}
              ariaControls="main-content"
              ariaCurrent=${active ? 'page' : undefined}
              ariaSelected=${active ? 'true' : 'false'}
              title=${item.description}
              onKeyDown=${handleSurfaceTabKeyDown}
              class=${`inline-flex h-7 items-center gap-1.5 whitespace-nowrap rounded-[var(--radius-sm)] border px-2 font-mono text-3xs uppercase leading-none tracking-[var(--track-caps)] transition-colors ${
                active
                  ? 'border-[var(--brass-3)] bg-[var(--accent-22)] text-[var(--brass-1)] shadow-[inset_0_-1px_0_var(--brass-3)]'
                  : 'border-transparent text-[var(--color-fg-muted)] hover:border-[var(--color-border-strong)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-secondary)]'
              }`}
            >
              <${SurfaceIcon} icon=${item.icon} size=${13} />
              <span>${item.label}</span>
            <//>
          `
        })}
      </div>
    </nav>
  `
}

export function dashboardSurfaceTabId(tab: TabId): string {
  return `dashboard-surface-tab-${tab}`
}

function handleSurfaceTabKeyDown(event: KeyboardEvent): void {
  const direction = surfaceTabKeyboardDirection(event.key)
  if (direction === null) return

  const current = event.currentTarget as HTMLElement | null
  const tablist = current?.closest('[role="tablist"]')
  if (!current || !tablist) return

  const tabs = Array.from(tablist.querySelectorAll<HTMLElement>('[role="tab"]'))
  const currentIndex = tabs.indexOf(current)
  if (currentIndex === -1 || tabs.length === 0) return

  event.preventDefault()
  const nextIndex = nextSurfaceTabIndex(currentIndex, tabs.length, direction)
  const next = tabs[nextIndex]
  if (!next) return
  next.focus()
  next.click()
}

type SurfaceTabKeyboardDirection = 'next' | 'previous' | 'first' | 'last'

function surfaceTabKeyboardDirection(key: string): SurfaceTabKeyboardDirection | null {
  switch (key) {
    case 'ArrowRight':
    case 'ArrowDown':
      return 'next'
    case 'ArrowLeft':
    case 'ArrowUp':
      return 'previous'
    case 'Home':
      return 'first'
    case 'End':
      return 'last'
    default:
      return null
  }
}

function nextSurfaceTabIndex(
  currentIndex: number,
  count: number,
  direction: SurfaceTabKeyboardDirection,
): number {
  switch (direction) {
    case 'next':
      return (currentIndex + 1) % count
    case 'previous':
      return (currentIndex - 1 + count) % count
    case 'first':
      return 0
    case 'last':
      return count - 1
  }
}
