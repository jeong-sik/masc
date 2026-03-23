// NavItem — sidebar navigation button
// Extracts the 400+ char class strings from dashboard-shell.ts

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

const NAV_BASE = 'w-full flex items-center text-left cursor-pointer border-l-2 border-t-0 border-r-0 border-b-0 border-solid transition-all duration-150'

interface NavItemProps {
  active?: boolean
  icon?: ComponentChildren
  compact?: boolean
  onClick?: () => void
  children: ComponentChildren
}

/** Primary nav item — full size with icon */
export function NavItem({ active, icon, onClick, children }: NavItemProps) {
  const state = active
    ? 'border-l-[var(--accent)] bg-[var(--accent-soft)] text-[var(--accent)]'
    : 'border-l-transparent bg-transparent text-[var(--text-body)] hover:bg-[var(--white-6)] hover:border-l-[var(--white-20)]'
  return html`
    <button type="button" class="${NAV_BASE} gap-2.5 px-3 py-2.5 rounded-lg ${state}" onClick=${onClick}>
      ${icon ? html`<span class="text-sm w-5 text-center shrink-0">${icon}</span>` : null}
      <span class="text-[13px] font-medium truncate">${children}</span>
    </button>
  `
}

/** Sub-nav item — compact, indented */
export function SubNavItem({ active, onClick, children }: NavItemProps) {
  const state = active
    ? 'border-l-[var(--accent)] bg-[var(--accent-soft)] text-[var(--accent)] font-medium'
    : 'border-l-transparent bg-transparent text-[var(--text-muted)] hover:bg-[var(--white-6)] hover:text-[var(--text-body)]'
  return html`
    <button type="button" class="${NAV_BASE} gap-2 px-3 py-2 rounded-md text-[13px] ${state}" onClick=${onClick}>
      ${children}
    </button>
  `
}

/** Section label above nav groups */
export function NavSectionLabel({ children }: { children: ComponentChildren }) {
  return html`
    <div class="text-[10px] font-medium text-[var(--text-muted)] uppercase tracking-[0.1em] px-2 mb-2">${children}</div>
  `
}
