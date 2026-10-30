import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { hashForRoute, navigate } from '../../router'
import type { TabId } from '../../types'
import { ringFocusClasses } from './ring'

interface RouteLinkProps {
  id?: string
  tab: TabId
  params?: Record<string, string>
  class?: string
  role?: string
  title?: string
  tabIndex?: number
  'aria-label'?: string
  ariaControls?: string
  ariaCurrent?: 'page' | 'location' | undefined
  ariaSelected?: boolean | 'true' | 'false'
  'data-testid'?: string
  onKeyDown?: (event: KeyboardEvent) => void
  children: ComponentChildren
}

export function RouteLink({
  id,
  tab,
  params,
  class: className,
  role,
  title,
  tabIndex,
  'aria-label': ariaLabel,
  ariaControls,
  ariaCurrent,
  ariaSelected,
  'data-testid': dataTestId,
  onKeyDown,
  children,
}: RouteLinkProps) {
  const href = hashForRoute(tab, params)
  const classNameWithFocus = [
    'v2-mobile-operator-target',
    className,
    ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'surface' }),
  ].filter(Boolean).join(' ')

  return html`
    <a
      id=${id}
      href=${href}
      class=${classNameWithFocus}
      role=${role}
      title=${title}
      tabindex=${tabIndex}
      aria-label=${ariaLabel}
      aria-controls=${ariaControls}
      aria-current=${ariaCurrent}
      aria-selected=${ariaSelected}
      data-testid=${dataTestId}
      onKeyDown=${onKeyDown}
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
