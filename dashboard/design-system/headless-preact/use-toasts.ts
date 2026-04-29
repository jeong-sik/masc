/**
 * useToasts — Preact adapter over headless-core/ToastManager.
 *
 * Per RFC 0007 §3.3. Returns the live queue + helpers for region
 * / item ARIA props. Subscribes to manager mutations and bumps a
 * render counter on each change.
 *
 * Pattern note: there is no module-level singleton — production
 * code allocates one ToastManager at app boot and provides it via
 * Preact context (see `dashboard/src/contexts/toast-context.ts` —
 * follow-up consumer migration). This hook reads a manager from
 * its argument so it can be used with any provider strategy.
 */

import { useEffect, useState } from 'preact/hooks'
import {
  type Toast,
  type ToastDescriptor,
  type ToastManager,
  type ToastSeverity,
  SEVERITY_TO_ARIA_LIVE,
  SEVERITY_TO_ROLE,
} from '../headless-core/toast-manager'

export interface UseToastsResult {
  readonly toasts: ReadonlyArray<Toast>
  notify: (descriptor: ToastDescriptor) => string
  dismiss: (id: string) => void
}

export function useToasts(manager: ToastManager): UseToastsResult {
  const [snapshot, setSnapshot] = useState<ReadonlyArray<Toast>>(() => manager.getQueue())

  useEffect(() => {
    const dispose = manager.subscribe((q) => setSnapshot(q))
    return dispose
  }, [manager])

  return {
    toasts: snapshot,
    notify: (descriptor) => manager.notify(descriptor),
    dismiss: (id) => manager.dismiss(id),
  }
}

/**
 * Region-level prop bundle. Spread onto the container that wraps
 * all rendered toasts, mounted inside `usePortal({ layer: 'toast' })`.
 */
export function getToastRegionProps(): {
  readonly role: 'region'
  readonly 'aria-label': 'Notifications'
  readonly 'aria-live': 'polite'
  readonly 'aria-atomic': 'false'
} {
  return Object.freeze({
    role: 'region' as const,
    'aria-label': 'Notifications' as const,
    'aria-live': 'polite' as const,
    'aria-atomic': 'false' as const,
  })
}

/**
 * Per-toast prop bundle. Spread onto each individual toast item.
 * Severity drives both `role` and `aria-live` per RFC 0007 §4.
 */
export function getToastItemProps(toast: Toast): {
  readonly id: string
  readonly role: 'status' | 'alert'
  readonly 'aria-live': 'polite' | 'assertive'
  readonly 'data-severity': ToastSeverity
  readonly 'data-state': 'queued' | 'visible' | 'dismissed'
} {
  return Object.freeze({
    id: toast.id,
    role: SEVERITY_TO_ROLE[toast.severity],
    'aria-live': SEVERITY_TO_ARIA_LIVE[toast.severity],
    'data-severity': toast.severity,
    'data-state': toast.state,
  })
}

/**
 * Convenience: pause/resume handlers for region-level hover/focus.
 * Wire onPointerEnter / onFocusCapture / onPointerLeave / onBlurCapture
 * on the region container.
 */
export function getRegionPauseHandlers(manager: ToastManager): {
  readonly onPointerEnter: () => void
  readonly onPointerLeave: () => void
  readonly onFocusCapture: () => void
  readonly onBlurCapture: () => void
} {
  return Object.freeze({
    onPointerEnter: () => manager.pauseAll(),
    onPointerLeave: () => manager.resumeAll(),
    onFocusCapture: () => manager.pauseAll(),
    onBlurCapture: () => manager.resumeAll(),
  })
}
