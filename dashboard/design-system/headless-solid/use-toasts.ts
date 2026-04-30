/**
 * useToasts — SolidJS adapter over headless-core/ToastManager
 * (RFC 0007 §3.3, RFC 0017 PR #2).
 *
 * Mirror of headless-preact/use-toasts.ts. Returns the live queue as
 * a Solid Accessor plus helpers for ARIA props and pause handlers.
 *
 * Pattern note: production allocates one ToastManager at app boot.
 * The Solid app provides it via a `createContext` (introduced when the
 * first Solid island lands). This hook reads from its argument so it
 * can be used with any provider strategy.
 */

import { createSignal, onCleanup, type Accessor } from 'solid-js'
import {
  type Toast,
  type ToastDescriptor,
  type ToastManager,
  type ToastSeverity,
  SEVERITY_TO_ARIA_LIVE,
  SEVERITY_TO_ROLE,
} from '../headless-core/toast-manager'

export interface UseToastsResult {
  readonly toasts: Accessor<ReadonlyArray<Toast>>
  notify: (descriptor: ToastDescriptor) => string
  dismiss: (id: string) => void
}

export function useToasts(manager: ToastManager): UseToastsResult {
  const [toasts, setToasts] = createSignal<ReadonlyArray<Toast>>(manager.getQueue())
  const dispose = manager.subscribe((q) => setToasts(q))
  onCleanup(dispose)
  return {
    toasts,
    notify: (descriptor) => manager.notify(descriptor),
    dismiss: (id) => manager.dismiss(id),
  }
}

/**
 * Region-level prop bundle. Spread onto the container that wraps all
 * rendered toasts, mounted inside `usePortal({ layer: 'toast' })` once
 * a Solid portal adapter ships.
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
 * Per-toast prop bundle. Severity drives both `role` and `aria-live`
 * per RFC 0007 §4.
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
 * Pause/resume handlers for region-level hover/focus. Wire onMouseEnter /
 * onMouseLeave / onFocusIn / onFocusOut on the region container in Solid
 * (Solid uses native event names, not Preact's camelCase 'Capture' suffix).
 */
export function getRegionPauseHandlers(manager: ToastManager): {
  readonly onMouseEnter: () => void
  readonly onMouseLeave: () => void
  readonly onFocusIn: () => void
  readonly onFocusOut: () => void
} {
  return Object.freeze({
    onMouseEnter: () => manager.pauseAll(),
    onMouseLeave: () => manager.resumeAll(),
    onFocusIn: () => manager.pauseAll(),
    onFocusOut: () => manager.resumeAll(),
  })
}
