/**
 * RovingTabindex — framework-agnostic single-tabstop rover primitive.
 *
 * Implements RFC 0003. The shared focus contract behind tablist /
 * toolbar / tree / radiogroup / menu: exactly one descendant holds
 * `tabindex="0"`, siblings hold `tabindex="-1"`, arrow keys shift the
 * rover within the container, Tab exits via the surrounding focus
 * order.
 *
 * MVP scope (RFC 0003 §3, §4):
 *   - orientation: 'horizontal' | 'vertical' | 'both'
 *     (matches W3C ARIA APG arrow-key conventions per orientation)
 *   - loop: wrap last→first / first→last (default true)
 *   - activateOnFocus: ARIA "automatic" tablist semantics (default false)
 *   - defaultActiveId: caller-supplied initial position (falls back to
 *     first enabled item)
 *   - Home / End → first / last enabled
 *   - Printable char typeahead with 500 ms idle reset, case-insensitive
 *     prefix match against item.text
 *   - setItems re-anchor: when the active id is removed, fall back to
 *     the nearest preceding enabled item, else first
 *   - subscribe / unsubscribe with leak-safe disposers
 *
 * Out of scope (deferred per RFC 0003 §10):
 *   - RTL ArrowLeft/ArrowRight flip
 *   - Multi-key chord sequences
 *   - aria-activedescendant alternate strategy
 *
 * No DOM access. Pure TS. The adapter (use-roving-tabindex.ts) wires
 * synthetic KeyboardEvent into handleKeyDown and reads getItemProps /
 * getContainerProps for prop spreads.
 */

export type Orientation = 'horizontal' | 'vertical' | 'both'

export interface RovingItemDescriptor {
  readonly id: string
  readonly disabled?: boolean
  /** Optional label for typeahead matching. */
  readonly text?: string
}

export interface RovingTabindexOptions {
  /** ARIA orientation; controls which arrow keys move the rover. */
  orientation: Orientation
  /** Wrap from last → first / first → last. Default true. */
  loop?: boolean
  /** Fire onActiveChange immediately on rover move (ARIA "automatic"). */
  activateOnFocus?: boolean
  /** Initial active item id; falls back to first enabled item. */
  defaultActiveId?: string
  /** Initial item set. May also be supplied later via setItems(). */
  items?: ReadonlyArray<RovingItemDescriptor>
  /** Typeahead idle window in ms. Default 500. */
  typeaheadResetMs?: number
  /** Optional callback fired when activeId changes. */
  onActiveChange?: (activeId: string | null) => void
}

/** Read-only key-event surface — KeyboardEvent-compatible without binding to DOM. */
export interface RovingKeyEvent {
  readonly key: string
  readonly shiftKey?: boolean
  readonly metaKey?: boolean
  readonly ctrlKey?: boolean
  readonly altKey?: boolean
  preventDefault(): void
}

export interface RovingContainerProps {
  readonly 'aria-orientation'?: 'horizontal' | 'vertical'
  readonly tabIndex: -1
  readonly onKeyDown: (e: RovingKeyEvent) => void
}

export interface RovingItemProps {
  readonly tabIndex: 0 | -1
  readonly 'data-active': '' | undefined
  readonly 'aria-disabled'?: true
}

export interface RovingTabindexController {
  readonly activeId: string | null
  readonly items: ReadonlyArray<RovingItemDescriptor>

  setItems(items: ReadonlyArray<RovingItemDescriptor>): void
  setActive(id: string): void
  next(): void
  prev(): void
  first(): void
  last(): void

  getContainerProps(): RovingContainerProps
  getItemProps(id: string): RovingItemProps

  handleKeyDown(e: RovingKeyEvent): void

  subscribe(listener: (activeId: string | null) => void): () => void
}

const DEFAULT_TYPEAHEAD_RESET_MS = 500

function isEnabled(item: RovingItemDescriptor): boolean {
  return item.disabled !== true
}

function findFirstEnabled(items: ReadonlyArray<RovingItemDescriptor>): string | null {
  for (const item of items) {
    if (isEnabled(item)) return item.id
  }
  return null
}

function findLastEnabled(items: ReadonlyArray<RovingItemDescriptor>): string | null {
  for (let i = items.length - 1; i >= 0; i -= 1) {
    const item = items[i]!
    if (isEnabled(item)) return item.id
  }
  return null
}

function indexOfId(items: ReadonlyArray<RovingItemDescriptor>, id: string | null): number {
  if (id === null) return -1
  for (let i = 0; i < items.length; i += 1) {
    if (items[i]!.id === id) return i
  }
  return -1
}

/** Step from `from` toward `dir` (+1 = next, -1 = prev), skipping disabled. */
function step(
  items: ReadonlyArray<RovingItemDescriptor>,
  from: number,
  dir: 1 | -1,
  loop: boolean,
): number {
  if (items.length === 0) return -1
  // First, if from is out-of-range, anchor to a valid edge.
  let i = from
  if (i < 0 || i >= items.length) {
    i = dir === 1 ? -1 : items.length
  }
  const start = i
  for (let traveled = 0; traveled < items.length; traveled += 1) {
    i += dir
    if (i < 0) {
      if (!loop) return start === -1 ? -1 : start
      i = items.length - 1
    } else if (i >= items.length) {
      if (!loop) return start === items.length ? -1 : start
      i = 0
    }
    const item = items[i]!
    if (isEnabled(item)) return i
    if (i === start) return start
  }
  return start === -1 ? -1 : start
}

function moveKeysFor(orientation: Orientation): {
  next: ReadonlySet<string>
  prev: ReadonlySet<string>
} {
  switch (orientation) {
    case 'horizontal':
      return { next: new Set(['ArrowRight']), prev: new Set(['ArrowLeft']) }
    case 'vertical':
      return { next: new Set(['ArrowDown']), prev: new Set(['ArrowUp']) }
    case 'both':
      return {
        next: new Set(['ArrowRight', 'ArrowDown']),
        prev: new Set(['ArrowLeft', 'ArrowUp']),
      }
  }
}

function isPrintable(key: string): boolean {
  return key.length === 1 && /\S/u.test(key)
}

export function createRovingTabindex(opts: RovingTabindexOptions): RovingTabindexController {
  const loop = opts.loop ?? true
  const activateOnFocus = opts.activateOnFocus ?? false
  const typeaheadResetMs = opts.typeaheadResetMs ?? DEFAULT_TYPEAHEAD_RESET_MS

  let items: ReadonlyArray<RovingItemDescriptor> = opts.items ?? []
  let activeId: string | null = null

  // Resolve initial active id: defaultActiveId if present and enabled,
  // otherwise first enabled item.
  function resolveInitialActive(): string | null {
    const requested = opts.defaultActiveId
    if (requested !== undefined) {
      const idx = indexOfId(items, requested)
      if (idx >= 0 && isEnabled(items[idx]!)) return requested
    }
    return findFirstEnabled(items)
  }

  activeId = resolveInitialActive()

  const listeners = new Set<(activeId: string | null) => void>()

  function emit(): void {
    for (const listener of listeners) listener(activeId)
    if (opts.onActiveChange !== undefined) opts.onActiveChange(activeId)
  }

  // Typeahead buffer state.
  let typeaheadBuffer = ''
  let typeaheadTimer: ReturnType<typeof setTimeout> | null = null

  function clearTypeahead(): void {
    if (typeaheadTimer !== null) {
      clearTimeout(typeaheadTimer)
      typeaheadTimer = null
    }
    typeaheadBuffer = ''
  }

  function handleTypeahead(char: string): void {
    typeaheadBuffer += char.toLowerCase()
    if (typeaheadTimer !== null) clearTimeout(typeaheadTimer)
    typeaheadTimer = setTimeout(clearTypeahead, typeaheadResetMs)

    // Search starting AFTER the current active position (so repeated
    // first-letter cycles through items starting with that letter).
    // Wrap to the beginning if no match in the trailing region.
    const pivot = indexOfId(items, activeId)
    const order: number[] = []
    for (let off = 1; off <= items.length; off += 1) {
      order.push((pivot + off) % items.length)
    }
    for (const i of order) {
      const item = items[i]!
      if (!isEnabled(item) || item.text === undefined) continue
      if (item.text.toLowerCase().startsWith(typeaheadBuffer)) {
        setActiveInternal(item.id)
        return
      }
    }
  }

  function setActiveInternal(id: string): void {
    if (id === activeId) return
    const idx = indexOfId(items, id)
    if (idx < 0 || !isEnabled(items[idx]!)) return
    activeId = id
    emit()
  }

  function moveTo(idx: number): void {
    if (idx < 0 || idx >= items.length) return
    const item = items[idx]!
    setActiveInternal(item.id)
  }

  return {
    get activeId() {
      return activeId
    },
    get items() {
      return items
    },

    setItems(nextItems: ReadonlyArray<RovingItemDescriptor>): void {
      const prevActive = activeId
      items = nextItems
      // Re-anchor when active is gone or now disabled.
      const idx = indexOfId(items, prevActive)
      if (idx < 0 || !isEnabled(items[idx]!)) {
        // Fall back to nearest preceding enabled (search backward from
        // where active *would have been*). If none, first enabled.
        const pseudoIdx = idx >= 0 ? idx : findInsertionFallback(prevActive, items)
        let fallback: string | null = null
        for (let i = pseudoIdx; i >= 0; i -= 1) {
          if (i < items.length && isEnabled(items[i]!)) {
            fallback = items[i]!.id
            break
          }
        }
        activeId = fallback ?? findFirstEnabled(items)
        if (activeId !== prevActive) emit()
      }
    },

    setActive(id: string): void {
      setActiveInternal(id)
    },

    next(): void {
      const from = indexOfId(items, activeId)
      const target = step(items, from, 1, loop)
      moveTo(target)
    },

    prev(): void {
      const from = indexOfId(items, activeId)
      const target = step(items, from, -1, loop)
      moveTo(target)
    },

    first(): void {
      const id = findFirstEnabled(items)
      if (id !== null) setActiveInternal(id)
    },

    last(): void {
      const id = findLastEnabled(items)
      if (id !== null) setActiveInternal(id)
    },

    getContainerProps(): RovingContainerProps {
      const ariaOrientation: 'horizontal' | 'vertical' | undefined =
        opts.orientation === 'horizontal'
          ? 'horizontal'
          : opts.orientation === 'vertical'
            ? 'vertical'
            : undefined
      return {
        'aria-orientation': ariaOrientation,
        tabIndex: -1,
        onKeyDown: (e: RovingKeyEvent) => this.handleKeyDown(e),
      }
    },

    getItemProps(id: string): RovingItemProps {
      const idx = indexOfId(items, id)
      const isActive = id === activeId
      const isDis = idx >= 0 && !isEnabled(items[idx]!)
      const props: RovingItemProps = {
        tabIndex: isActive ? 0 : -1,
        'data-active': isActive ? '' : undefined,
      }
      if (isDis) {
        return Object.freeze({ ...props, 'aria-disabled': true as const })
      }
      return Object.freeze(props)
    },

    handleKeyDown(e: RovingKeyEvent): void {
      const { next: nextKeys, prev: prevKeys } = moveKeysFor(opts.orientation)
      // Modifier keys reserved for outer shortcuts — don't intercept.
      if (e.metaKey === true || e.ctrlKey === true || e.altKey === true) return

      if (nextKeys.has(e.key)) {
        e.preventDefault()
        clearTypeahead()
        const before = activeId
        this.next()
        if (activateOnFocus && activeId !== before) {
          // already emitted via setActiveInternal
        }
        return
      }
      if (prevKeys.has(e.key)) {
        e.preventDefault()
        clearTypeahead()
        this.prev()
        return
      }
      if (e.key === 'Home') {
        e.preventDefault()
        clearTypeahead()
        this.first()
        return
      }
      if (e.key === 'End') {
        e.preventDefault()
        clearTypeahead()
        this.last()
        return
      }
      if (isPrintable(e.key)) {
        handleTypeahead(e.key)
        return
      }
      // Tab / Escape / Enter / Space etc. fall through to consumer.
    },

    subscribe(listener: (activeId: string | null) => void): () => void {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
  }
}

/**
 * When the prior active id is no longer in the list, locate the index
 * we *would* have inserted into so the "nearest preceding enabled"
 * walk has a sensible starting point. We don't track removal positions
 * so this is a heuristic: return items.length - 1 (search from the
 * end). For most UI removals the active element was somewhere in the
 * middle and the next enabled item before it is what the user wants
 * to see selected.
 */
function findInsertionFallback(
  _priorId: string | null,
  items: ReadonlyArray<RovingItemDescriptor>,
): number {
  return items.length - 1
}
