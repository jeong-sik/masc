/**
 * FocusScope — framework-agnostic focus trap + restore primitive.
 *
 * Replaces the inline `useRef + useEffect + document.addEventListener
 * ("mousedown")` pattern that every Drawer/Popover/Dialog reimplements.
 * Adapters (headless-preact/use-focus-scope.ts, future Bonsai adapter)
 * call activate() on mount and deactivate() on unmount.
 *
 * MVP scope (RFC 0001 §"createFocusScope"):
 *   - Tabbable element collector (a, button, input, select, textarea,
 *     [tabindex] not -1, contenteditable; disabled/hidden filtered out)
 *   - Tab / Shift+Tab cycling within the container
 *   - Focus restoration: stash activeElement on activate, restore on
 *     deactivate
 *   - initialFocus: 'first' | 'container' | () => HTMLElement | null
 *
 * Out of scope (will land later, RFC 0001 §"Open question 1"):
 *   - Roving Tabindex (tablist, radiogroup, toolbar)
 *   - Visibility filter beyond `disabled` + `tabindex="-1"`
 *     (CSS display:none / visibility:hidden / aria-hidden=true detection
 *     is the second iteration)
 *   - Focus guard sentinel pair around the container (used when the
 *     container isn't `position: fixed`); deferred until first consumer
 *     needs it
 */

const TABBABLE_SELECTOR = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled]):not([type="hidden"])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
  '[contenteditable=""]',
  '[contenteditable="true"]',
].join(', ')

export type InitialFocus =
  | 'first'
  | 'container'
  | (() => HTMLElement | null)

export interface FocusScopeOptions {
  /**
   * Returns the container element. Function form (not raw element) lets
   * the caller defer until activate() time, mirroring Preact's nullable
   * `ref.current` pattern.
   */
  containerRef: () => HTMLElement | null
  /** Tab cycles within the container. Default true. */
  loop?: boolean
  /** On deactivate, restore focus to the element focused before activate. Default true. */
  restoreFocus?: boolean
  /** Where to land focus on activate. Default 'first'. */
  initialFocus?: InitialFocus
}

export interface FocusScope {
  activate(): void
  deactivate(): void
  focusFirst(): void
  focusLast(): void
  contains(el: Element): boolean
  /** Snapshot of currently tabbable descendants (debug / test hook). */
  tabbables(): HTMLElement[]
}

function collectTabbables(container: HTMLElement): HTMLElement[] {
  const matches = container.querySelectorAll<HTMLElement>(TABBABLE_SELECTOR)
  // Native-focusable elements (<input>, <button>, <a href>) match the
  // selector even when tabindex="-1" is set on them, because the CSS
  // `:not([tabindex="-1"])` clause only applies to the [tabindex] term,
  // not to the named-element terms. JS post-filter handles that case.
  return Array.from(matches).filter((el) => el.getAttribute('tabindex') !== '-1')
}

function focusElement(el: HTMLElement | null | undefined): void {
  if (el && typeof el.focus === 'function') el.focus()
}

export function createFocusScope(opts: FocusScopeOptions): FocusScope {
  const loop = opts.loop ?? true
  const restoreFocus = opts.restoreFocus ?? true
  const initialFocus: InitialFocus = opts.initialFocus ?? 'first'

  let active = false
  let priorFocus: HTMLElement | null = null
  let keydownHandler: ((e: KeyboardEvent) => void) | null = null
  let attachedTo: HTMLElement | null = null

  function getContainer(): HTMLElement | null {
    return opts.containerRef()
  }

  function applyInitialFocus(container: HTMLElement): void {
    if (typeof initialFocus === 'function') {
      focusElement(initialFocus())
      return
    }
    if (initialFocus === 'container') {
      focusElement(container)
      return
    }
    // 'first'
    const tabbables = collectTabbables(container)
    focusElement(tabbables[0] ?? container)
  }

  function handleKeydown(e: KeyboardEvent): void {
    if (e.key !== 'Tab') return
    const container = getContainer()
    if (!container) return
    const tabbables = collectTabbables(container)
    if (tabbables.length === 0) {
      // Nothing tabbable — pin focus on container itself.
      e.preventDefault()
      focusElement(container)
      return
    }
    const first = tabbables[0]!
    const last = tabbables[tabbables.length - 1]!
    const activeEl = (container.ownerDocument?.activeElement ?? null) as HTMLElement | null

    if (!loop) return

    if (e.shiftKey && activeEl === first) {
      e.preventDefault()
      focusElement(last)
    } else if (!e.shiftKey && activeEl === last) {
      e.preventDefault()
      focusElement(first)
    }
  }

  return {
    activate(): void {
      if (active) return
      const container = getContainer()
      if (!container) return
      const doc = container.ownerDocument ?? document
      priorFocus = (doc.activeElement as HTMLElement | null) ?? null
      keydownHandler = handleKeydown
      container.addEventListener('keydown', keydownHandler)
      attachedTo = container
      applyInitialFocus(container)
      active = true
    },

    deactivate(): void {
      if (!active) return
      if (attachedTo && keydownHandler) {
        attachedTo.removeEventListener('keydown', keydownHandler)
      }
      keydownHandler = null
      attachedTo = null
      if (restoreFocus) focusElement(priorFocus)
      priorFocus = null
      active = false
    },

    focusFirst(): void {
      const container = getContainer()
      if (!container) return
      focusElement(collectTabbables(container)[0])
    },

    focusLast(): void {
      const container = getContainer()
      if (!container) return
      const tabbables = collectTabbables(container)
      focusElement(tabbables[tabbables.length - 1])
    },

    contains(el: Element): boolean {
      const container = getContainer()
      return container ? container.contains(el) : false
    },

    tabbables(): HTMLElement[] {
      const container = getContainer()
      return container ? collectTabbables(container) : []
    },
  }
}
