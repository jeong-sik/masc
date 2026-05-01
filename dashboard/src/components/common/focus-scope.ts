// focus-scope.ts — tabbable element collection + cyclic focus management
//
// Kimi design system sec01 1.3.1: createFocusScope for focus traps in dialogs,
// drawers, and modals. Returns first/last refs and a cycle() handler for Tab.

const TABBABLE_SELECTOR =
  'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'

export interface FocusScope {
  first: HTMLElement | undefined
  last: HTMLElement | undefined
  cycle(event: KeyboardEvent): void
  focusFirst(): void
}

function sameElement(
  a: Element | null,
  b: HTMLElement | undefined,
): boolean {
  if (!a || !b) return false
  return a === b || a.isSameNode(b)
}

export function createFocusScope(container: HTMLElement): FocusScope {
  const elements = Array.from(
    container.querySelectorAll<HTMLElement>(TABBABLE_SELECTOR),
  )
  const first = elements[0]
  const last = elements[elements.length - 1]

  return {
    first,
    last,
    cycle(event: KeyboardEvent) {
      if (event.key !== 'Tab') return
      if (event.shiftKey && sameElement(document.activeElement, first)) {
        event.preventDefault()
        last?.focus()
      } else if (!event.shiftKey && sameElement(document.activeElement, last)) {
        event.preventDefault()
        first?.focus()
      }
    },
    focusFirst() {
      first?.focus()
    },
  }
}
