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
  const [container] = useState(() => {
    const el = document.createElement('div')
    el.setAttribute('data-masc-portal', '')
    document.body.appendChild(el)
    return el
  })

  useEffect(() => {
    return () => {
      document.body.removeChild(container)
    }
  }, [container])

  return createPortal(children, container)
}
