/**
 * SplitPane — framework-agnostic resizable splitter (RFC 0004).
 *
 * Implements the headless splitter that IdePlane (Stage 5),
 * Inspector resize, and Drawer width-snap consume. Pointer + keyboard
 * driven; persists to localStorage; exposes role=separator with
 * aria-valuenow/min/max as integer percent.
 *
 * MVP scope (RFC 0004 §3, §4, §5):
 *   - direction horizontal / vertical
 *   - clamped ratio in [minRatio, maxRatio] (defaults 0.1, 0.9, 0.5)
 *   - localStorage persistKey: read on construct, write on
 *     pointerUp / keyDown / setRatio
 *   - splitter ARIA props: role=separator + aria-orientation +
 *     aria-valuenow/min/max as integer percent
 *   - keyboard: Arrow step 0.02, Shift+Arrow coarse 0.10, Home/End
 *     clamp, Enter toggle collapse with prevRatio restoration
 *   - subscribe with leak-safe disposers
 *
 * Out of scope (RFC 0004 §10):
 *   - 3-pane = consumer composes two SplitPanes
 *   - touch / pen / mouse-button distinctions (single pointer stream)
 *   - render markup
 */

export type SplitDirection = 'horizontal' | 'vertical'

export interface SplitPaneOptions {
  direction: SplitDirection
  defaultRatio?: number
  minRatio?: number
  maxRatio?: number
  /** localStorage key. Convention: "masc.split-pane.<id>". */
  persistKey?: string
  onResize?: (ratio: number) => void
  ariaLabel?: string
  /** Storage adapter — defaults to global localStorage when present.
   *  Tests inject a mock to keep the suite environment-independent. */
  storage?: SplitStorage
}

export interface SplitStorage {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
}

export interface SplitterProps {
  readonly role: 'separator'
  readonly 'aria-label': string
  readonly 'aria-orientation': SplitDirection
  readonly 'aria-valuenow': number
  readonly 'aria-valuemin': number
  readonly 'aria-valuemax': number
  readonly tabIndex: 0
}

export interface SplitKeyEvent {
  readonly key: string
  readonly shiftKey?: boolean
  preventDefault(): void
}

export interface SplitPointerEvent {
  readonly clientX: number
  readonly clientY: number
}

export interface SplitPane {
  getRatio(): number
  setRatio(value: number): void
  isCollapsed(): boolean
  collapse(side: 'first' | 'second'): void
  expand(): void

  getSplitterProps(): SplitterProps

  setContainerSize(px: number): void

  handlePointerDown(event: SplitPointerEvent): void
  handlePointerMove(event: SplitPointerEvent): void
  handlePointerUp(): void
  handleKeyDown(event: SplitKeyEvent): void

  subscribe(listener: (ratio: number, collapsed: boolean) => void): () => void
}

const DEFAULT_DEFAULT_RATIO = 0.5
const DEFAULT_MIN_RATIO = 0.1
const DEFAULT_MAX_RATIO = 0.9
const STEP = 0.02
const COARSE_STEP = 0.1

function inferStorage(): SplitStorage | null {
  try {
    if (typeof globalThis.localStorage !== 'undefined') {
      return globalThis.localStorage as SplitStorage
    }
  } catch {
    // SSR / sandbox — no storage available.
  }
  return null
}

export function createSplitPane(opts: SplitPaneOptions): SplitPane {
  const direction = opts.direction
  const minRatio = opts.minRatio ?? DEFAULT_MIN_RATIO
  const maxRatio = opts.maxRatio ?? DEFAULT_MAX_RATIO
  const ariaLabel = opts.ariaLabel ?? 'Panel resize handle'
  const storage = opts.storage ?? inferStorage()
  const persistKey = opts.persistKey

  function clamp(v: number): number {
    if (Number.isNaN(v)) return DEFAULT_DEFAULT_RATIO
    return Math.max(minRatio, Math.min(maxRatio, v))
  }

  // Read persisted value.
  let initialRatio = opts.defaultRatio ?? DEFAULT_DEFAULT_RATIO
  if (storage !== null && persistKey !== undefined) {
    const raw = storage.getItem(persistKey)
    if (raw !== null) {
      const parsed = Number.parseFloat(raw)
      if (!Number.isNaN(parsed) && parsed >= minRatio && parsed <= maxRatio) {
        initialRatio = parsed
      }
    }
  }

  let ratio = clamp(initialRatio)
  let prevRatio = ratio
  let collapsed = false
  let containerSize = 0
  let dragging = false
  let dragStartClient = 0
  let dragStartRatio = 0

  const listeners = new Set<(ratio: number, collapsed: boolean) => void>()

  function emit(): void {
    for (const l of listeners) l(ratio, collapsed)
    if (opts.onResize !== undefined) opts.onResize(ratio)
  }

  function persist(): void {
    if (storage === null || persistKey === undefined) return
    storage.setItem(persistKey, String(ratio))
  }

  function setRatioInternal(v: number, opts?: { persist?: boolean }): void {
    const next = clamp(v)
    if (next === ratio) return
    ratio = next
    if (opts?.persist === true) persist()
    emit()
  }

  return {
    getRatio() {
      return ratio
    },

    setRatio(v: number) {
      setRatioInternal(v, { persist: true })
    },

    isCollapsed() {
      return collapsed
    },

    collapse(side: 'first' | 'second') {
      if (!collapsed) prevRatio = ratio
      collapsed = true
      ratio = side === 'first' ? minRatio : maxRatio
      emit()
    },

    expand() {
      if (!collapsed) return
      collapsed = false
      ratio = clamp(prevRatio)
      persist()
      emit()
    },

    getSplitterProps(): SplitterProps {
      return Object.freeze({
        role: 'separator' as const,
        'aria-label': ariaLabel,
        'aria-orientation': direction,
        'aria-valuenow': Math.round(ratio * 100),
        'aria-valuemin': Math.round(minRatio * 100),
        'aria-valuemax': Math.round(maxRatio * 100),
        tabIndex: 0 as const,
      })
    },

    setContainerSize(px: number) {
      containerSize = px
    },

    handlePointerDown(event: SplitPointerEvent) {
      dragging = true
      dragStartClient = direction === 'horizontal' ? event.clientX : event.clientY
      dragStartRatio = ratio
    },

    handlePointerMove(event: SplitPointerEvent) {
      if (!dragging) return
      if (containerSize <= 0) return
      const client = direction === 'horizontal' ? event.clientX : event.clientY
      const delta = (client - dragStartClient) / containerSize
      // For horizontal, increasing client.x widens the FIRST pane.
      // For vertical, increasing client.y widens the FIRST pane (top).
      setRatioInternal(dragStartRatio + delta)
    },

    handlePointerUp() {
      if (!dragging) return
      dragging = false
      persist()
    },

    handleKeyDown(event: SplitKeyEvent) {
      const step = event.shiftKey === true ? COARSE_STEP : STEP
      const isHorizontal = direction === 'horizontal'
      switch (event.key) {
        case 'ArrowRight':
          if (isHorizontal) {
            event.preventDefault()
            setRatioInternal(ratio + step, { persist: true })
          }
          return
        case 'ArrowLeft':
          if (isHorizontal) {
            event.preventDefault()
            setRatioInternal(ratio - step, { persist: true })
          }
          return
        case 'ArrowDown':
          if (!isHorizontal) {
            event.preventDefault()
            setRatioInternal(ratio + step, { persist: true })
          }
          return
        case 'ArrowUp':
          if (!isHorizontal) {
            event.preventDefault()
            setRatioInternal(ratio - step, { persist: true })
          }
          return
        case 'Home':
          event.preventDefault()
          setRatioInternal(minRatio, { persist: true })
          return
        case 'End':
          event.preventDefault()
          setRatioInternal(maxRatio, { persist: true })
          return
        case 'Enter':
        case ' ':
          event.preventDefault()
          // RFC 0004 §10.2 tie-break: collapse to whichever side is
          // closer. ratio < (min+max)/2 -> collapse first; else second.
          if (collapsed) {
            this.expand()
          } else {
            const midpoint = (minRatio + maxRatio) / 2
            this.collapse(ratio < midpoint ? 'first' : 'second')
          }
          return
        default:
          return
      }
    },

    subscribe(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
  }
}
