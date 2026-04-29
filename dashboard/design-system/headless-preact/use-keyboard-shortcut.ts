/**
 * useKeyboardShortcut + useKeyboardShortcutHost — Preact adapters
 * over headless-core/KeyboardShortcutManager.
 *
 * Per RFC 0012 §3.2. The host hook binds a single document-level
 * keydown listener and delegates to manager.dispatch. The per-shortcut
 * hook registers a chord on mount and disposes on unmount, returning
 * the human-readable + ARIA chord strings for tooltip / aria-keyshortcuts.
 */

import { useEffect, useMemo } from 'preact/hooks'
import type {
  Chord,
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
  useEffect(() => {
    const dispose = manager.register({ id, ...descriptor })
    return dispose
  }, [manager, id, descriptor.chord.key, descriptor.chord.modifiers.join(',')])

  return useMemo(
    () => ({
      display: manager.formatChord(descriptor.chord),
      aria: manager.formatAria(descriptor.chord),
    }),
    [manager, chordKey(descriptor.chord)],
  )
}

function chordKey(chord: Chord): string {
  return `${chord.modifiers.join('+')}+${chord.key}`
}

/**
 * Bind a single global keydown listener. Mount once at the app root.
 * The listener dispatches every event to the manager; matched shortcuts
 * fire their action and prevent default; unmatched fall through.
 */
export function useKeyboardShortcutHost(manager: KeyboardShortcutManager): void {
  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
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
    if (typeof document === 'undefined') return undefined
    document.addEventListener('keydown', handler)
    return () => document.removeEventListener('keydown', handler)
  }, [manager])
}
