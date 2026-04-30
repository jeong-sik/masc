// ResizablePanel — split-pane layout molecule
// Kimi sec09 Phase 1: IDE layout split pane with persistent sizing.
//
// ARIA: handle is `role="separator"` with aria-orientation, aria-valuenow,
// aria-valuemin, aria-valuemax. Arrow keys nudge the split 5 %.

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useCallback, useEffect, useRef, useState } from 'preact/hooks'

interface ResizablePanelProps {
  /** Storage key for persisting the split ratio. */
  storageKey: string
  /** Initial split ratio 0–1. Defaults to 0.5. */
  defaultRatio?: number
  /** "horizontal" = left|right, "vertical" = top|bottom */
  direction?: 'horizontal' | 'vertical'
  class?: string
  firstPanelClass?: string
  secondPanelClass?: string
  first: ComponentChildren
  second: ComponentChildren
  /** Minimum size in px for each panel. */
  minSize?: number
}

const KEY_STEP = 0.05
const STORAGE_PREFIX = 'masc-resizable:'

function readRatio(key: string, fallback: number): number {
  try {
    const raw = localStorage.getItem(STORAGE_PREFIX + key)
    if (raw) {
      const n = parseFloat(raw)
      if (!isNaN(n) && n >= 0.05 && n <= 0.95) return n
    }
  } catch {}
  return fallback
}

function writeRatio(key: string, ratio: number) {
  try {
    localStorage.setItem(STORAGE_PREFIX + key, String(ratio))
  } catch {}
}

export function ResizablePanel({
  storageKey,
  defaultRatio = 0.5,
  direction = 'horizontal',
  class: cx,
  firstPanelClass,
  secondPanelClass,
  first,
  second,
  minSize = 120,
}: ResizablePanelProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const [ratio, setRatio] = useState(() => readRatio(storageKey, defaultRatio))
  const [dragging, setDragging] = useState(false)

  const isHorizontal = direction === 'horizontal'

  const updateRatio = useCallback(
    (clientX: number, clientY: number) => {
      const container = containerRef.current
      if (!container) return
      const rect = container.getBoundingClientRect()
      const minRatio = minSize / (isHorizontal ? rect.width : rect.height)
      const maxRatio = 1 - minRatio
      let next = isHorizontal
        ? (clientX - rect.left) / rect.width
        : (clientY - rect.top) / rect.height
      next = Math.max(minRatio, Math.min(maxRatio, next))
      setRatio(next)
      writeRatio(storageKey, next)
    },
    [isHorizontal, minSize, storageKey],
  )

  useEffect(() => {
    if (!dragging) return
    const onMove = (e: MouseEvent) => updateRatio(e.clientX, e.clientY)
    const onUp = () => setDragging(false)
    document.addEventListener('mousemove', onMove)
    document.addEventListener('mouseup', onUp)
    return () => {
      document.removeEventListener('mousemove', onMove)
      document.removeEventListener('mouseup', onUp)
    }
  }, [dragging, updateRatio])

  const handleKeyDown = (e: KeyboardEvent) => {
    let delta = 0
    if (isHorizontal) {
      if (e.key === 'ArrowLeft') delta = -KEY_STEP
      else if (e.key === 'ArrowRight') delta = KEY_STEP
    } else {
      if (e.key === 'ArrowUp') delta = -KEY_STEP
      else if (e.key === 'ArrowDown') delta = KEY_STEP
    }
    if (delta !== 0) {
      e.preventDefault()
      const next = Math.max(0.05, Math.min(0.95, ratio + delta))
      setRatio(next)
      writeRatio(storageKey, next)
    }
  }

  const firstStyle = isHorizontal
    ? `width: ${ratio * 100}%; min-width: ${minSize}px;`
    : `height: ${ratio * 100}%; min-height: ${minSize}px;`

  const secondStyle = isHorizontal
    ? `width: ${(1 - ratio) * 100}%; min-width: ${minSize}px;`
    : `height: ${(1 - ratio) * 100}%; min-height: ${minSize}px;`

  const containerCls =
    'flex overflow-hidden ' +
    (isHorizontal ? 'flex-row' : 'flex-col') +
    (cx ? ` ${cx}` : '')

  const handleCls =
    'shrink-0 flex items-center justify-center ' +
    'bg-[var(--color-border-default)] hover:bg-[var(--color-accent-fg)] ' +
    'transition-colors ' +
    (dragging ? 'bg-[var(--color-accent-fg)] ' : '') +
    (isHorizontal ? 'w-1 cursor-col-resize' : 'h-1 cursor-row-resize')

  const gripCls =
    'rounded-full bg-[var(--color-fg-muted)] ' +
    (isHorizontal ? 'w-0.5 h-6' : 'w-6 h-0.5')

  return html`
    <div ref=${containerRef} class=${containerCls}>
      <div
        class="overflow-auto ${firstPanelClass ?? ''}"
        style=${firstStyle}
      >
        ${first}
      </div>
      <div
        role="separator"
        aria-orientation=${direction}
        aria-valuenow=${Math.round(ratio * 100)}
        aria-valuemin=${5}
        aria-valuemax=${95}
        aria-label="패널 크기 조절"
        tabindex=${0}
        class=${handleCls}
        onMouseDown=${() => setDragging(true)}
        onKeyDown=${handleKeyDown}
        data-dragging=${dragging}
      >
        <div class=${gripCls} />
      </div>
      <div
        class="overflow-auto ${secondPanelClass ?? ''}"
        style=${secondStyle}
      >
        ${second}
      </div>
    </div>
  `
}
