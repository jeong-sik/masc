// TweaksPanel — keeper-v2 craft controls ported to the MASC dashboard.
//
// Exposes four taste axes as persistent UI preferences:
//   density   — compact / regular / spacious
//   motion    — off / subtle / lively
//   bubble    — flat / card
//   fontScale — 80% – 125%
//
// Values are mirrored to the app root via data-* attributes so
// craft-v2.css can drive spacing, motion and message styling without
// re-rendering individual components. The panel itself is a floating,
// draggable chrome surface scoped to its own CSS class names.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useCallback, useEffect, useRef } from 'preact/hooks'
import { persistentSignal } from '../lib/persistent-signal'
import { ringFocusClasses } from './common/ring'
import { Settings2, X } from 'lucide-preact'

export type Density = 'compact' | 'regular' | 'spacious'
export type Motion = 'off' | 'subtle' | 'lively'
export type Bubble = 'flat' | 'card'

const DENSITY_OPTIONS: Density[] = ['compact', 'regular', 'spacious']
const MOTION_OPTIONS: Motion[] = ['off', 'subtle', 'lively']
const BUBBLE_OPTIONS: Bubble[] = ['flat', 'card']

const densitySignal = persistentSignal<Density>({
  key: 'dashboard:tweaks:density',
  defaultValue: 'regular',
})

const motionSignal = persistentSignal<Motion>({
  key: 'dashboard:tweaks:motion',
  defaultValue: 'subtle',
})

const bubbleSignal = persistentSignal<Bubble>({
  key: 'dashboard:tweaks:bubble',
  defaultValue: 'card',
})

const fontScaleSignal = persistentSignal<number>({
  key: 'dashboard:tweaks:font-scale',
  defaultValue: 100,
})

/** Readable exports for consumers that need to react in signals. */
export const tweaksDensity = densitySignal
export const tweaksMotion = motionSignal
export const tweaksBubble = bubbleSignal
export const tweaksFontScale = fontScaleSignal

/** Panel open/closed state (not persisted — starts closed). */
export const tweaksOpen = signal(false)

function clamp(n: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, n))
}

function formatLabel(key: string): string {
  return key.charAt(0).toUpperCase() + key.slice(1)
}

interface SegmentedControlProps<T extends string> {
  value: T
  options: readonly T[]
  onChange: (value: T) => void
  'aria-label'?: string
}

function SegmentedControl<T extends string>({
  value,
  options,
  onChange,
  'aria-label': ariaLabel,
}: SegmentedControlProps<T>) {
  return html`
    <div
      class="twk-seg"
      role="radiogroup"
      aria-label=${ariaLabel}
      data-testid="twk-seg"
    >
      ${options.map((o) => html`
        <button
          type="button"
          key=${o}
          role="radio"
          class=${`twk-seg-b ${value === o ? 'on' : ''}`}
          aria-checked=${value === o}
          data-active=${value === o ? 'true' : 'false'}
          data-value=${o}
          onClick=${() => onChange(o)}
        >
          ${formatLabel(o)}
        </button>
      `)}
    </div>
  `
}

interface SliderProps {
  value: number
  min: number
  max: number
  step?: number
  suffix?: string
  'aria-label'?: string
  onChange: (value: number) => void
}

function Slider({
  value,
  min,
  max,
  step = 1,
  suffix = '',
  'aria-label': ariaLabel,
  onChange,
}: SliderProps) {
  return html`
    <div class="twk-slider-row" data-testid="twk-slider">
      <input
        type="range"
        class="twk-slider"
        min=${min}
        max=${max}
        step=${step}
        value=${value}
        aria-label=${ariaLabel}
        onInput=${(e: Event) => onChange(Number((e.target as HTMLInputElement).value))}
      />
      <span class="twk-slider-val" aria-hidden="true">${value}${suffix}</span>
    </div>
  `
}

interface RowProps {
  label: string
  hint?: string
  children: unknown
}

function Row({ label, hint, children }: RowProps) {
  return html`
    <div class="twk-row" data-testid="twk-row">
      <div class="twk-row-l">
        <div class="twk-row-label">${label}</div>
        ${hint ? html`<div class="twk-row-hint">${hint}</div>` : null}
      </div>
      <div class="twk-row-c">${children}</div>
    </div>
  `
}

/** Header toggle button for the top bar. */
export function TweaksPanelToggle() {
  const open = tweaksOpen.value
  const title = open
    ? 'Close display tweaks'
    : 'Open display tweaks (density, motion, bubbles, font scale)'
  return html`
    <button
      type="button"
      class=${`v2-shell-action flex items-center justify-center gap-1.5 cursor-pointer rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2.5 py-[5px] text-2xs text-[var(--color-fg-muted)] transition-colors duration-[var(--t-med)] hover:border-[var(--accent-20)] hover:text-[var(--color-fg-secondary)] ${open ? 'border-[var(--color-accent-fg)] text-[var(--color-accent-fg)]' : ''} ${ringFocusClasses({ tone: 'accent-medium', width: 2, offset: 2, offsetSurface: 'page' })}`}
      aria-label=${title}
      title=${title}
      aria-expanded=${open}
      data-testid="tweaks-panel-toggle"
      onClick=${() => { tweaksOpen.value = !tweaksOpen.value }}
    >
      <${Settings2} size=${14} />
      <span class="max-[1080px]:hidden">Tweaks</span>
    </button>
  `
}

/** Floating tweaks panel. */
export function TweaksPanel() {
  const open = tweaksOpen.value
  const dragRef = useRef<HTMLDivElement>(null)
  const offsetRef = useRef({ x: 16, y: 16 })
  const PAD = 16

  const clampToViewport = useCallback(() => {
    const panel = dragRef.current
    if (!panel) return
    const w = panel.offsetWidth
    const h = panel.offsetHeight
    const maxRight = Math.max(PAD, window.innerWidth - w - PAD)
    const maxBottom = Math.max(PAD, window.innerHeight - h - PAD)
    offsetRef.current = {
      x: clamp(offsetRef.current.x, PAD, maxRight),
      y: clamp(offsetRef.current.y, PAD, maxBottom),
    }
    panel.style.right = `${offsetRef.current.x}px`
    panel.style.bottom = `${offsetRef.current.y}px`
  }, [])

  useEffect(() => {
    if (!open) return
    clampToViewport()
    const ro = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(clampToViewport) : null
    if (ro) ro.observe(document.documentElement)
    else window.addEventListener('resize', clampToViewport)
    return () => {
      if (ro) ro.disconnect()
      else window.removeEventListener('resize', clampToViewport)
    }
  }, [open, clampToViewport])

  const onDragStart = useCallback((e: MouseEvent) => {
    const panel = dragRef.current
    if (!panel) return
    const r = panel.getBoundingClientRect()
    const sx = e.clientX
    const sy = e.clientY
    const startRight = window.innerWidth - r.right
    const startBottom = window.innerHeight - r.bottom
    const move = (ev: MouseEvent) => {
      offsetRef.current = {
        x: startRight - (ev.clientX - sx),
        y: startBottom - (ev.clientY - sy),
      }
      clampToViewport()
    }
    const up = () => {
      window.removeEventListener('mousemove', move)
      window.removeEventListener('mouseup', up)
    }
    window.addEventListener('mousemove', move)
    window.addEventListener('mouseup', up)
  }, [clampToViewport])

  if (!open) return null

  return html`
    <div
      ref=${dragRef}
      class="twk-panel"
      data-testid="tweaks-panel"
      style=${{ right: `${offsetRef.current.x}px`, bottom: `${offsetRef.current.y}px` }}
    >
      <div
        class="twk-panel-hd"
        onMouseDown=${onDragStart}
        data-testid="tweaks-panel-header"
      >
        <b>Display tweaks</b>
        <button
          type="button"
          class="twk-panel-close"
          aria-label="Close tweaks"
          data-testid="tweaks-panel-close"
          onMouseDown=${(e: MouseEvent) => e.stopPropagation()}
          onClick=${() => { tweaksOpen.value = false }}
        >
          <${X} size=${14} />
        </button>
      </div>
      <div class="twk-panel-body">
        <${Row} label="Density" hint="Spacing across lists and cards">
          <${SegmentedControl}
            value=${densitySignal.value}
            options=${DENSITY_OPTIONS}
            aria-label="Density"
            onChange=${(v: Density) => { densitySignal.value = v }}
          />
        <//>
        <${Row} label="Motion" hint="Transitions and micro-animations">
          <${SegmentedControl}
            value=${motionSignal.value}
            options=${MOTION_OPTIONS}
            aria-label="Motion"
            onChange=${(v: Motion) => { motionSignal.value = v }}
          />
        <//>
        <${Row} label="Bubble" hint="Message bubble style">
          <${SegmentedControl}
            value=${bubbleSignal.value}
            options=${BUBBLE_OPTIONS}
            aria-label="Bubble style"
            onChange=${(v: Bubble) => { bubbleSignal.value = v }}
          />
        <//>
        <${Row} label="Font scale" hint="Base text size">
          <${Slider}
            value=${fontScaleSignal.value}
            min=${80}
            max=${125}
            step=${5}
            suffix="%"
            aria-label="Font scale"
            onChange=${(v: number) => { fontScaleSignal.value = v }}
          />
        <//>
      </div>
    </div>
  `
}
