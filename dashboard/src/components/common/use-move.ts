// use-move.ts — drag delta tracking for ResizablePanel
//
// Kimi design system sec01 1.5: useMove tracks Δx, Δy across pointer
// devices. Emits move start / move / move end callbacks.

import { useRef, useState, useCallback } from 'preact/hooks'

export interface MoveResult {
  moving: boolean
  moveProps: {
    onPointerDown: (e: PointerEvent) => void
    'data-moving': string | undefined
  }
}

export interface MoveOptions {
  onMoveStart?: () => void
  onMove?: (dx: number, dy: number) => void
  onMoveEnd?: () => void
}

export function useMove({ onMoveStart, onMove, onMoveEnd }: MoveOptions = {}): MoveResult {
  const [moving, setMoving] = useState(false)
  const movingRef = useRef(false)
  const origin = useRef({ x: 0, y: 0 })
  const last = useRef({ x: 0, y: 0 })
  const elRef = useRef<HTMLElement | null>(null)

  const handlePointerMove = useCallback(
    (e: PointerEvent) => {
      if (!movingRef.current) return
      const dx = e.clientX - last.current.x
      const dy = e.clientY - last.current.y
      last.current = { x: e.clientX, y: e.clientY }
      onMove?.(dx, dy)
    },
    [onMove]
  )

  const handlePointerUp = useCallback(() => {
    if (!movingRef.current) return
    movingRef.current = false
    setMoving(false)
    window.removeEventListener('pointermove', handlePointerMove)
    window.removeEventListener('pointerup', handlePointerUp)
    onMoveEnd?.()
  }, [handlePointerMove, onMoveEnd])

  const handlePointerDown = useCallback(
    (e: PointerEvent) => {
      // Only left mouse button or touch/pen primary
      if (e.button !== 0) return
      elRef.current = e.currentTarget as HTMLElement
      origin.current = { x: e.clientX, y: e.clientY }
      last.current = { x: e.clientX, y: e.clientY }
      movingRef.current = true
      setMoving(true)
      onMoveStart?.()
      window.addEventListener('pointermove', handlePointerMove)
      window.addEventListener('pointerup', handlePointerUp)
    },
    [handlePointerMove, handlePointerUp, onMoveStart]
  )

  return {
    moving,
    moveProps: {
      onPointerDown: handlePointerDown,
      'data-moving': moving ? 'true' : undefined,
    },
  }
}
