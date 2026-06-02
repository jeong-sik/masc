/**
 * useKeyboardShortcut + useKeyboardShortcutHost — SolidJS adapters
 * over headless-core/KeyboardShortcutManager
 * (RFC 0012 §3.2, RFC 0017 PR #2.5).
 *
 * - useKeyboardShortcut registers a chord under its createRoot scope
 *   and returns the human-readable + ARIA chord strings.
 * - useKeyboardShortcutHost binds a single document keydown listener
 *   that dispatches to the manager. Mount once at app root.
 */

import { onCleanup } from 'solid-js'
import type {
  KeyboardShortcutManager,
  ShortcutDescriptor,
  ShortcutKeyEvent,
} from '../headless-core/keyboard-shortcuts'

export interface UseKeyboardShortcutResult {
  readonly display: string
  readonly aria: string
}

export function useKeyboardShortcut(
  manager: KeyboardShortcutManager,
  descriptor: Omit<ShortcutDescriptor, 'id'>,
  id: string,
): UseKeyboardShortcutResult {
  const dispose = manager.register({ id, ...descriptor })
  onCleanup(dispose)
  return {
    display: manager.formatChord(descriptor.chord),
    aria: manager.formatAria(descriptor.chord),
  }
}

/**
 * Bind a single global keydown listener. Mount once at the app root.
 * Matched shortcuts fire their action and prevent default; unmatched
 * fall through.
 */
export function useKeyboardShortcutHost(manager: KeyboardShortcutManager): void {
  if (typeof document === 'undefined') return
  const handler = (event: KeyboardEvent): void => {
    const adapted: ShortcutKeyEvent = {
      key: event.key,
      metaKey: event.metaKey,
      ctrlKey: event.ctrlKey,
      shiftKey: event.shiftKey,
      altKey: event.altKey,
      target: event.target as ShortcutKeyEvent['target'],
      preventDefault: () => event.preventDefault(),
      stopPropagation: () => event.stopPropagation(),
    }
    const matched = manager.dispatch(adapted)
    if (matched) {
      event.preventDefault()
      event.stopPropagation()
    }
  }
  document.addEventListener('keydown', handler)
  onCleanup(() => document.removeEventListener('keydown', handler))
}
