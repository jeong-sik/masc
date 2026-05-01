// Slider — ARIA 1.3 range input primitive
//
// Keyboard: ArrowRight/Up increases, ArrowLeft/Down decreases,
// Home jumps to min, End jumps to max.

import { html } from 'htm/preact'
import type { FunctionComponent } from 'preact'
import { useCallback, useEffect, useRef, useState } from 'preact/hooks'

interface SliderProps {
  min?: number
  max?: number
  step?: number
  value?: number
  onChange?: (value: number) => void
  orientation?: 'horizontal' | 'vertical'
  'aria-label'?: string
  disabled?: boolean
  class?: string
}

const TRACK_CLS =
  'relative rounded-full bg-[var(--white-4)] cursor-pointer '

const THUMB_CLS =
  'absolute rounded-full bg-[var(--color-accent-fg)] shadow-md '

export const Slider: FunctionComponent<SliderProps> = ({
  min = 0,
  max = 100,
  step = 1,
  value: controlledValue,
  onChange,
  orientation = 'horizontal',
  'aria-label': ariaLabel,
  disabled,
  class: cx,
}) => {
  const [internalValue, setInternalValue] = useState(min)
  const value = controlledValue ?? internalValue
  const trackRef = useRef<HTMLDivElement>(null)
  const dragging = useRef(false)

  const clamp = (v: number) => Math.max(min, Math.min(max, v))
  const roundStep = (v: number) => {
    const steps = Math.round((v - min) / step)
    return clamp(min + steps * step)
  }

  const setValue = useCallback(
    (v: number) => {
      const next = roundStep(v)
      if (next !== value) {
        setInternalValue(next)
        onChange?.(next)
      }
    },
    [value, onChange, min, max, step],
  )

  const percent = ((value - min) / (max - min)) * 100

  const handleKeyDown = (e: KeyboardEvent) => {
    if (disabled) return
    let next = value
    if (e.key === 'ArrowRight' || e.key === 'ArrowUp') {
      e.preventDefault()
      next = value + step
    } else if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') {
      e.preventDefault()
      next = value - step
    } else if (e.key === 'Home') {
      e.preventDefault()
      next = min
    } else if (e.key === 'End') {
      e.preventDefault()
      next = max
    }
    if (next !== value) setValue(next)
  }

  const pointerToValue = (clientX: number, clientY: number) => {
    const track = trackRef.current
    if (!track) return value
    const rect = track.getBoundingClientRect()
    if (orientation === 'horizontal') {
      const ratio = (clientX - rect.left) / rect.width
      return min + ratio * (max - min)
    } else {
      const ratio = (rect.bottom - clientY) / rect.height
      return min + ratio * (max - min)
    }
  }

  const handlePointerDown = (e: PointerEvent) => {
    if (disabled) return
    dragging.current = true
    setValue(pointerToValue(e.clientX, e.clientY))
  }

  useEffect(() => {
    const onMove = (e: PointerEvent) => {
      if (!dragging.current) return
      setValue(pointerToValue(e.clientX, e.clientY))
    }
    const onUp = () => {
      dragging.current = false
    }
    window.addEventListener('pointermove', onMove)
    window.addEventListener('pointerup', onUp)
    return () => {
      window.removeEventListener('pointermove', onMove)
      window.removeEventListener('pointerup', onUp)
    }
  }, [setValue])

  const trackSize =
    orientation === 'horizontal'
      ? 'w-full h-2'
      : 'h-full w-2'

  const thumbSize = 'w-4 h-4'

  const thumbStyle =
    orientation === 'horizontal'
      ? `left: calc(${percent}% - 8px); top: -4px;`
      : `bottom: calc(${percent}% - 8px); left: -4px;`

  return html`
    <div
      class=${(cx ?? '') + ' ' + (orientation === 'horizontal' ? 'w-full' : 'h-32')}
    >
      <div
        ref=${trackRef}
        role="slider"
        aria-label=${ariaLabel}
        aria-valuemin=${min}
        aria-valuemax=${max}
        aria-valuenow=${value}
        aria-orientation=${orientation}
        aria-disabled=${disabled}
        tabindex=${disabled ? -1 : 0}
        class=${TRACK_CLS + trackSize}
        onKeyDown=${handleKeyDown}
        onPointerDown=${handlePointerDown}
      >
        <div
          class="absolute rounded-full bg-[var(--color-accent-fg)] opacity-30 ${trackSize}"
          style=${orientation === 'horizontal'
            ? `width: ${percent}%;`
            : `height: ${percent}%; bottom: 0;`}
        />
        <div
          class=${THUMB_CLS + thumbSize}
          style=${thumbStyle}
        />
      </div>
    </div>
  `
}
