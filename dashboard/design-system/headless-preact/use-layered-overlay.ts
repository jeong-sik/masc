/**
 * useLayeredOverlay — Preact adapter over
 * headless-core/createLayeredOverlay (RFC 0020 §3).
 *
 * Returns the active set as Preact state plus stable callbacks for
 * toggle/clear/isActive. Subscribes to controller changes on mount
 * and disposes the listener on unmount, so callers can mount the
 * IDE toolbar without managing subscription lifecycle themselves.
 */

import { useCallback, useEffect, useState } from 'preact/hooks'
import type { LayeredOverlayController } from '../headless-core/layered-overlay'

export interface UseLayeredOverlay {
  readonly active: ReadonlySet<string>
  readonly toggle: (kind: string) => void
  readonly clear: () => void
  readonly isActive: (kind: string) => boolean
}

export function useLayeredOverlay(controller: LayeredOverlayController): UseLayeredOverlay {
  const [active, setActive] = useState<ReadonlySet<string>>(() => controller.active())

  useEffect(() => {
    setActive(controller.active())
    const dispose = controller.subscribe(next => {
      setActive(next)
    })
    return dispose
  }, [controller])

  const toggle = useCallback(
    (kind: string) => {
      controller.toggle(kind)
    },
    [controller],
  )
  const clear = useCallback(() => {
    controller.clear()
  }, [controller])
  const isActive = useCallback((kind: string) => active.has(kind), [active])

  return { active, toggle, clear, isActive }
}
