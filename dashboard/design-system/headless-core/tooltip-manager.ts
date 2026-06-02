/**
 * TooltipManager — singleton "one-at-a-time" registry for tooltips.
 *
 * Per RFC 0006 §3.2. Multiple tooltip controllers can register against
 * the same manager; whenever a tooltip opens, the manager hides any
 * previously open peer. A skip-window (default 100 ms) suppresses the
 * old tooltip's hide animation when the new one arrives within the
 * window — prevents the visual flash on quick trigger switches.
 *
 * The manager doesn't know about DOM. It calls `hide()` on the prior
 * controller, which fires through the same lifecycle the prior
 * controller would have fired anyway — ensuring `onOpenChange(false)`
 * still fires for caller-side cleanup.
 *
 * For testability, getTooltipManager() returns a fresh instance each
 * call. Production code typically allocates one at app boot and
 * passes it via React/Preact context. There is no module-level
 * singleton — that would make tests brittle and forbid multi-page
 * setups.
 */

import type { TooltipController } from './tooltip'

export interface TooltipManagerOptions {
  /** ms — if a new tooltip opens within this window of a prior close,
   *  suppress the prior's hide animation (consumer-side concern; the
   *  manager only signals via the skip flag in the close event). */
  skipWindowMs?: number
}

export interface TooltipCloseEvent {
  readonly id: string
  /** True when this close was caused by another tooltip opening
   *  within the skip window. Consumer may skip exit animation. */
  readonly skip: boolean
}

export interface TooltipManager {
  /** Lifecycle notifications from individual controllers. */
  notifyOpened(controller: TooltipController): void
  notifyClosed(controller: TooltipController): void

  /** Force-close any open tooltip. Used on app blur, route change. */
  closeAll(): void

  /** Currently open tooltip controller, or null. */
  active(): TooltipController | null

  subscribeClose(listener: (event: TooltipCloseEvent) => void): () => void
}

const DEFAULT_SKIP_WINDOW_MS = 100

export function createTooltipManager(opts?: TooltipManagerOptions): TooltipManager {
  const skipWindowMs = opts?.skipWindowMs ?? DEFAULT_SKIP_WINDOW_MS

  let activeController: TooltipController | null = null
  let lastCloseAt = 0

  const closeListeners = new Set<(event: TooltipCloseEvent) => void>()

  function emitClose(id: string, skip: boolean): void {
    const event: TooltipCloseEvent = Object.freeze({ id, skip })
    for (const listener of closeListeners) listener(event)
  }

  return {
    notifyOpened(controller: TooltipController): void {
      const prior = activeController
      if (prior !== null && prior !== controller) {
        // Calculate skip flag for the prior's close.
        const now = Date.now()
        const skip = now - lastCloseAt <= skipWindowMs
        // Hide prior; this triggers prior.notifyClosed -> our own hook
        // below which sets activeController = null (we'll re-set it
        // below).
        prior.hide()
        // notifyClosed will have fired emitClose with skip=false; but
        // for this dismissal we want skip=true if within window. Emit
        // an additional event so consumers can override animations.
        if (skip) emitClose(prior.id, true)
      }
      activeController = controller
    },

    notifyClosed(controller: TooltipController): void {
      if (activeController === controller) {
        activeController = null
        lastCloseAt = Date.now()
        emitClose(controller.id, false)
      }
    },

    closeAll(): void {
      const prior = activeController
      if (prior === null) return
      activeController = null
      prior.hide()
      // notifyClosed already fired during hide(); no extra emit.
    },

    active(): TooltipController | null {
      return activeController
    },

    subscribeClose(listener: (event: TooltipCloseEvent) => void): () => void {
      closeListeners.add(listener)
      return () => {
        closeListeners.delete(listener)
      }
    },
  }
}
