import { useEffect } from 'preact/hooks'

/** Subscribe a handler to window 'keydown' that ignores presses while
    the user is typing in form fields, contenteditable elements, or
    holding a modifier (Cmd/Ctrl/Alt). The handler runs only for plain
    key presses outside text input contexts.

    Pass `match` to filter which key(s) trigger the handler. Return
    `true` from match to fire `handler`; the hook calls
    `event.preventDefault()` on a successful match. */
export function useGlobalShortcut(
  match: (ev: KeyboardEvent) => boolean,
  handler: (ev: KeyboardEvent) => void,
  deps: ReadonlyArray<unknown> = [],
): void {
  useEffect(() => {
    if (typeof window === 'undefined') return undefined
    const onKey = (ev: KeyboardEvent) => {
      if (ev.metaKey || ev.ctrlKey || ev.altKey) return
      const target = ev.target as HTMLElement | null
      if (target) {
        const tag = target.tagName
        if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return
        if (target.isContentEditable) return
      }
      if (!match(ev)) return
      ev.preventDefault()
      handler(ev)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)
}
