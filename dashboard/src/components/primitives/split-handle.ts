/**
 * Reusable zero-rerender resizable split handle (`vertical` | `horizontal`).
 *
 * - Writes CSS custom property directly on `targetRef.current` during `pointermove`
 *   so heavy sibling subtrees never re-render at 60fps.
 * - Commits the final size once on `pointerup` / `pointercancel` to a `persistentSignal`
 *   keyed by `masc:split:<id>:v1`.
 * - Full keyboard accessibility: `role="separator"`, `tabIndex={0}`, `aria-orientation`,
 *   `aria-valuemin/max/now`, `Arrow` (±16px), `Shift+Arrow` (±48px), `Home`/`End`,
 *   `Enter` / double-click to reset to default.
 */

import { html } from 'htm/preact'
import type { Signal } from '@preact/signals'
import { useCallback, useEffect, useRef } from 'preact/hooks'
import { persistentSignal } from '../../lib/persistent-signal'

export type SplitOrientation = 'vertical' | 'horizontal'

export interface UseSplitSizeOptions {
  readonly id: string
  readonly defaultSize: number
  readonly min: number
  readonly max: number
}

export interface SplitSizeHandle {
  readonly size: number
  readonly setSize: (next: number) => void
  readonly resetSize: () => void
}

export interface SplitHandleProps {
  readonly id: string
  readonly orientation: SplitOrientation
  readonly value: number
  readonly defaultSize: number
  readonly min: number
  readonly max: number
  readonly cssVar: string
  readonly targetRef: { readonly current: HTMLElement | null }
  readonly onChange: (next: number) => void
  readonly label: string
  /** Invert pointer/keyboard delta (e.g. left-edge handle of a right-docked drawer). */
  readonly reverse?: boolean
  readonly className?: string
  readonly testId?: string
}

const KEYBOARD_STEP_PX = 16
const KEYBOARD_SHIFT_STEP_PX = 48

const splitSignalCache = new Map<string, Signal<number>>()

export function clampSplitSize(value: unknown, min: number, max: number, fallback: number): number {
  const safeMin = Number.isFinite(min) ? Math.round(min) : 0
  const safeMax = Number.isFinite(max) ? Math.max(safeMin, Math.round(max)) : safeMin
  const safeFallback = Math.max(safeMin, Math.min(safeMax, Math.round(Number.isFinite(fallback) ? fallback : safeMin)))
  if (typeof value !== 'number' || !Number.isFinite(value)) return safeFallback
  return Math.max(safeMin, Math.min(safeMax, Math.round(value)))
}

export function splitStorageKey(id: string): string {
  return `masc:split:${id}:v1`
}

function getOrCreateSplitSignal(id: string, defaultSize: number, min: number, max: number): Signal<number> {
  const existing = splitSignalCache.get(id)
  if (existing) return existing
  const clampedDefault = clampSplitSize(defaultSize, min, max, min)
  const sig = persistentSignal<number>({
    key: splitStorageKey(id),
    defaultValue: clampedDefault,
    deserialize: (raw) => {
      const parsed: unknown = JSON.parse(raw)
      return clampSplitSize(parsed, min, max, clampedDefault)
    },
  })
  splitSignalCache.set(id, sig)
  return sig
}

/** Test-only helper to clear cached per-id split signals between isolated tests. */
export function resetSplitSizeCacheForTests(): void {
  splitSignalCache.clear()
}

export function useSplitSize(options: UseSplitSizeOptions): SplitSizeHandle {
  const { id, defaultSize, min, max } = options
  const sig = getOrCreateSplitSignal(id, defaultSize, min, max)
  const size = clampSplitSize(sig.value, min, max, defaultSize)

  const setSize = useCallback(
    (next: number) => {
      sig.value = clampSplitSize(next, min, max, defaultSize)
    },
    [sig, min, max, defaultSize],
  )

  const resetSize = useCallback(() => {
    sig.value = clampSplitSize(defaultSize, min, max, min)
  }, [sig, defaultSize, min, max])

  return { size, setSize, resetSize }
}

export function SplitHandle(props: SplitHandleProps) {
  const {
    id,
    orientation,
    value,
    defaultSize,
    min,
    max,
    cssVar,
    targetRef,
    onChange,
    label,
    reverse = false,
    className,
    testId,
  } = props

  const handleRef = useRef<HTMLDivElement>(null)
  const cleanupDragRef = useRef<(() => void) | null>(null)
  const latestPropsRef = useRef(props)
  latestPropsRef.current = props

  useEffect(() => {
    return () => {
      cleanupDragRef.current?.()
      cleanupDragRef.current = null
    }
  }, [])

  const applyImmediate = useCallback(
    (next: number) => {
      const clamped = clampSplitSize(next, min, max, defaultSize)
      targetRef.current?.style.setProperty(cssVar, `${clamped}px`)
      handleRef.current?.setAttribute('aria-valuenow', String(clamped))
      onChange(clamped)
    },
    [min, max, defaultSize, targetRef, cssVar, onChange],
  )

  const handlePointerDown = useCallback((event: PointerEvent) => {
    if (event.button !== 0) return
    event.preventDefault()

    cleanupDragRef.current?.()

    const cur = latestPropsRef.current
    const el = handleRef.current
    const dir = cur.reverse ? -1 : 1
    const startPos = cur.orientation === 'vertical' ? event.clientX : event.clientY
    const startSize = clampSplitSize(cur.value, cur.min, cur.max, cur.defaultSize)
    const pointerId = event.pointerId
    let latest = startSize
    let finished = false

    try {
      el?.setPointerCapture?.(pointerId)
    } catch {
      // Synthetic PointerEvents in test environments may not register a pointerId.
    }

    if (typeof document !== 'undefined') {
      document.body.dataset.resizing = cur.orientation === 'vertical' ? 'col' : 'row'
    }

    const onMove = (ev: PointerEvent) => {
      const p = latestPropsRef.current
      const pos = p.orientation === 'vertical' ? ev.clientX : ev.clientY
      latest = clampSplitSize(startSize + dir * (pos - startPos), p.min, p.max, p.defaultSize)
      p.targetRef.current?.style.setProperty(p.cssVar, `${latest}px`)
      handleRef.current?.setAttribute('aria-valuenow', String(latest))
    }

    const teardown = (commit: boolean) => {
      if (finished) return
      finished = true
      window.removeEventListener('pointermove', onMove)
      window.removeEventListener('pointerup', onFinish)
      window.removeEventListener('pointercancel', onFinish)
      if (typeof document !== 'undefined') {
        delete document.body.dataset.resizing
      }
      try {
        if (el?.hasPointerCapture?.(pointerId)) {
          el.releasePointerCapture(pointerId)
        }
      } catch {
        // Ignore release errors if pointer capture was already released.
      }
      cleanupDragRef.current = null
      if (commit) {
        latestPropsRef.current.onChange(latest)
      }
    }

    const onFinish = () => teardown(true)

    cleanupDragRef.current = () => teardown(false)
    window.addEventListener('pointermove', onMove)
    window.addEventListener('pointerup', onFinish)
    window.addEventListener('pointercancel', onFinish)
  }, [])

  const handleKeyDown = useCallback(
    (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return
      const step = event.shiftKey ? KEYBOARD_SHIFT_STEP_PX : KEYBOARD_STEP_PX
      const dir = reverse ? -1 : 1

      if (orientation === 'vertical') {
        if (event.key === 'ArrowRight') {
          event.preventDefault()
          applyImmediate(value + dir * step)
          return
        }
        if (event.key === 'ArrowLeft') {
          event.preventDefault()
          applyImmediate(value - dir * step)
          return
        }
      } else {
        if (event.key === 'ArrowDown') {
          event.preventDefault()
          applyImmediate(value + dir * step)
          return
        }
        if (event.key === 'ArrowUp') {
          event.preventDefault()
          applyImmediate(value - dir * step)
          return
        }
      }

      if (event.key === 'Home') {
        event.preventDefault()
        applyImmediate(min)
        return
      }
      if (event.key === 'End') {
        event.preventDefault()
        applyImmediate(max)
        return
      }
      if (event.key === 'Enter') {
        event.preventDefault()
        applyImmediate(defaultSize)
      }
    },
    [orientation, reverse, value, min, max, defaultSize, applyImmediate],
  )

  const handleDoubleClick = useCallback(() => {
    applyImmediate(defaultSize)
  }, [applyImmediate, defaultSize])

  const clampedValue = clampSplitSize(value, min, max, defaultSize)

  return html`
    <div
      ref=${handleRef}
      role="separator"
      tabIndex=${0}
      aria-orientation=${orientation}
      aria-valuemin=${min}
      aria-valuemax=${max}
      aria-valuenow=${clampedValue}
      aria-label=${label}
      data-orientation=${orientation}
      data-split-id=${id}
      data-testid=${testId ?? `split-handle-${id}`}
      class=${`split-handle ${className ?? ''}`.trim()}
      title=${`${label} (드래그 또는 방향키로 조절, 더블클릭/Enter로 기본값 복원)`}
      onPointerDown=${handlePointerDown}
      onKeyDown=${handleKeyDown}
      onDblClick=${handleDoubleClick}
    >
      <span class="split-handle-grip" aria-hidden="true" />
    </div>
  `
}
