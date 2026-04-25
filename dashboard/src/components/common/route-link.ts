import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { hashForRoute, navigate } from '../../router'
import type { TabId } from '../../types'

interface RouteLinkProps {
  tab: TabId
  params?: Record<string, string>
  class?: string
  title?: string
  role?: string
  ariaCurrent?: 'page' | 'location' | undefined
  children: ComponentChildren
}

export function RouteLink({
  tab,
  params,
  class: className,
  title,
  role,
  ariaCurrent,
  children,
}: RouteLinkProps) {
  const href = hashForRoute(tab, params)
  const classNameWithFocus = [
    className,
    'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[rgba(71,184,255,0.35)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--bg-1)]',
  ].filter(Boolean).join(' ')

  return html`
    <a
      href=${href}
      class=${classNameWithFocus}
      title=${title}
      role=${role}
      aria-current=${ariaCurrent}
      onClick=${(event: MouseEvent) => {
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
        navigate(tab, params)
      }}
    >
      ${children}
    </a>
  `
}
