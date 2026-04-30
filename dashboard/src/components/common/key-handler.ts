// key-handler.ts — keyboard event normalization for headless primitives
//
// Kimi design system sec08 8.1.1: ESC, Enter, Space, Arrow key
// normalization. Provides type-safe key matchers that work across
// browser inconsistencies (e.g. ' ' vs 'Spacebar' in legacy IE).

export type NormalizedKey =
  | 'Enter'
  | 'Escape'
  | 'Space'
  | 'ArrowUp'
  | 'ArrowDown'
  | 'ArrowLeft'
  | 'ArrowRight'
  | 'Home'
  | 'End'
  | 'Tab'
  | 'Backspace'
  | 'Delete'

/** Map raw event.key values to normalized names. */
const KEY_MAP: Record<string, NormalizedKey | undefined> = {
  Enter: 'Enter',
  ' ': 'Space',
  Spacebar: 'Space', // Legacy IE
  Escape: 'Escape',
  Esc: 'Escape', // Older browsers
  ArrowUp: 'ArrowUp',
  ArrowDown: 'ArrowDown',
  ArrowLeft: 'ArrowLeft',
  ArrowRight: 'ArrowRight',
  Home: 'Home',
  End: 'End',
  Tab: 'Tab',
  Backspace: 'Backspace',
  Delete: 'Delete',
  Del: 'Delete', // Older macOS
}

/** Normalize a KeyboardEvent.key value. */
export function normalizeKey(key: string): NormalizedKey | undefined {
  return KEY_MAP[key]
}

/** Check if the event matches a normalized key. */
export function isKey(event: { key: string }, normalized: NormalizedKey): boolean {
  return normalizeKey(event.key) === normalized
}

/** Return the normalized key or undefined if unrecognized. */
export function getNormalizedKey(event: { key: string }): NormalizedKey | undefined {
  return normalizeKey(event.key)
}

/** Grouped matcher for common action keys. */
export const KeyMatcher = {
  isEnter: (e: { key: string }) => isKey(e, 'Enter'),
  isSpace: (e: { key: string }) => isKey(e, 'Space'),
  isEscape: (e: { key: string }) => isKey(e, 'Escape'),
  isArrowUp: (e: { key: string }) => isKey(e, 'ArrowUp'),
  isArrowDown: (e: { key: string }) => isKey(e, 'ArrowDown'),
  isArrowLeft: (e: { key: string }) => isKey(e, 'ArrowLeft'),
  isArrowRight: (e: { key: string }) => isKey(e, 'ArrowRight'),
  isHome: (e: { key: string }) => isKey(e, 'Home'),
  isEnd: (e: { key: string }) => isKey(e, 'End'),
  isTab: (e: { key: string }) => isKey(e, 'Tab'),
  isBackspace: (e: { key: string }) => isKey(e, 'Backspace'),
  isDelete: (e: { key: string }) => isKey(e, 'Delete'),
}

/** Callback map for declarative key handling. */
export interface KeyHandlerMap {
  onEnter?: (e: Event) => void
  onSpace?: (e: Event) => void
  onEscape?: (e: Event) => void
  onArrowUp?: (e: Event) => void
  onArrowDown?: (e: Event) => void
  onArrowLeft?: (e: Event) => void
  onArrowRight?: (e: Event) => void
  onHome?: (e: Event) => void
  onEnd?: (e: Event) => void
  onTab?: (e: Event) => void
}

/** Create a single keydown handler from a declarative map. */
export function createKeyHandler(handlers: KeyHandlerMap): (e: KeyboardEvent) => void {
  return (e: KeyboardEvent) => {
    const key = getNormalizedKey(e)
    if (!key) return
    switch (key) {
      case 'Enter':
        handlers.onEnter?.(e)
        return
      case 'Space':
        handlers.onSpace?.(e)
        return
      case 'Escape':
        handlers.onEscape?.(e)
        return
      case 'ArrowUp':
        handlers.onArrowUp?.(e)
        return
      case 'ArrowDown':
        handlers.onArrowDown?.(e)
        return
      case 'ArrowLeft':
        handlers.onArrowLeft?.(e)
        return
      case 'ArrowRight':
        handlers.onArrowRight?.(e)
        return
      case 'Home':
        handlers.onHome?.(e)
        return
      case 'End':
        handlers.onEnd?.(e)
        return
      case 'Tab':
        handlers.onTab?.(e)
        return
    }
  }
}
