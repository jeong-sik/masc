// portal.ts — render children into a document.body-mounted container
//
// Kimi design system sec01 1.2.1: Portal for overlays, modals, and drawers.
// Uses createPortal from preact/compat and cleans up on unmount.

import { createPortal } from 'preact/compat'
import { useEffect, useState } from 'preact/hooks'
import type { ComponentChildren } from 'preact'

interface PortalProps {
  children: ComponentChildren
}

export function Portal({ children }: PortalProps) {
  const [container, setContainer] = useState<HTMLDivElement | null>(null)

  useEffect(() => {
    if (typeof document === 'undefined') return
    const el = document.createElement('div')
    el.setAttribute('data-masc-portal', '')
    document.body.appendChild(el)
    setContainer(el)
    return () => {
      document.body.removeChild(el)
    }
  }, [])

  if (!container) return null
  return createPortal(children, container)
}
