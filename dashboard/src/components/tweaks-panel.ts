// TweaksPanel — MASC Dashboard Tweaks Panel, 100% aligned with Keeper Agent v2 standalone spec.
import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useCallback, useEffect, useRef } from 'preact/hooks'
import { persistentSignal } from '../lib/persistent-signal'
import { chatShowInternal, chatShowMetadata } from '../lib/chat-view-prefs'
import { ringFocusClasses } from './common/ring'
import { Settings2, X } from 'lucide-preact'

export type Density = 'spacious' | 'regular' | 'compact'
export type Motion = 'lively' | 'subtle' | 'off'
export type Bubble = 'card' | 'flat'
export type Theme = 'dark' | 'paper'
export type Volt = 'brass' | 'blood' | 'ice'

const DENSITY_OPTIONS: readonly (Density | { value: Density; label: string })[] = [
  { value: 'spacious', label: '여유' },
  { value: 'regular', label: '균형' },
  { value: 'compact', label: '압축' }
]

const MOTION_OPTIONS: readonly (Motion | { value: Motion; label: string })[] = [
  { value: 'lively', label: '생동' },
  { value: 'subtle', label: '절제' },
  { value: 'off', label: '끕' }
]

const BUBBLE_OPTIONS: readonly (Bubble | { value: Bubble; label: string })[] = [
  { value: 'card', label: '카드' },
  { value: 'flat', label: '플랫' }
]

const THEME_OPTIONS: readonly (Theme | { value: Theme; label: string })[] = [
  { value: 'dark', label: '다크' },
  { value: 'paper', label: '페이퍼' }
]

const VOLT_OPTIONS: readonly Volt[] = ['brass', 'blood', 'ice']

// persistent signals for all 9 preferences
export const tweaksDensity = persistentSignal<Density>({
  key: 'dashboard:tweaks:density-v2',
  // Prototype boots at spacious (keeper-v2/app.jsx:9 "density": "spacious"), and
  // craft.css density rules (e.g. .kp-row 11px, .ctx-card 14/15px) are authored
  // to that baseline. Defaulting to 'regular' rendered every surface tighter than
  // the design SSOT; align the unset default to spacious. Users keep 'regular'/
  // 'compact' via the Tweaks panel.
  defaultValue: 'spacious',
})

export const tweaksMotion = persistentSignal<Motion>({
  key: 'dashboard:tweaks:motion-v2',
  defaultValue: 'subtle',
})

export const tweaksBubble = persistentSignal<Bubble>({
  key: 'dashboard:tweaks:bubble-v2',
  defaultValue: 'card',
})

export const tweaksTheme = persistentSignal<Theme>({
  key: 'dashboard:tweaks:theme-v2',
  defaultValue: 'dark',
})

export const tweaksVolt = persistentSignal<Volt>({
  key: 'dashboard:tweaks:volt-v2',
  defaultValue: 'brass',
})

export const tweaksThreadW = persistentSignal<number>({
  key: 'dashboard:tweaks:thread-w-v2',
  defaultValue: 980,
})

export const tweaksRosterOpen = persistentSignal<boolean>({
  key: 'dashboard:tweaks:roster-open-v2',
  defaultValue: true,
})

export const tweaksCtxOpen = persistentSignal<boolean>({
  key: 'dashboard:tweaks:ctx-open-v2',
  defaultValue: true,
})

export const tweaksFontScale = persistentSignal<number>({
  key: 'dashboard:tweaks:font-scale-v2', // v2: 80 ~ 140
  defaultValue: 100,
})

export const tweaksOpen = signal(false)

function clamp(n: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, n))
}

const __TWEAKS_STYLE = `
  .twk-panel {
    position: fixed;
    z-index: 2147483646;
    width: 280px;
    max-height: calc(100vh - 32px);
    display: flex;
    flex-direction: column;
    background: rgba(26, 27, 37, 0.88);
    color: #e3dacb;
    -webkit-backdrop-filter: blur(24px) saturate(160%);
    backdrop-filter: blur(24px) saturate(160%);
    border: .5px solid rgba(255, 255, 255, 0.08);
    border-radius: 12px;
    box-shadow: 0 1px 0 rgba(255, 255, 255, 0.05) inset, 0 12px 40px rgba(0, 0, 0, 0.55);
    font: 11.5px/1.4 ui-sans-serif, system-ui, -apple-system, sans-serif;
    overflow: hidden;
  }
  [data-theme="paper"] .twk-panel {
    background: rgba(245, 242, 234, 0.88);
    color: #151515;
    border: .5px solid rgba(0, 0, 0, 0.08);
    box-shadow: 0 1px 0 rgba(255, 255, 255, 0.5) inset, 0 12px 40px rgba(0, 0, 0, 0.15);
  }
  .twk-hd {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 8px 10px 14px;
    cursor: move;
    user-select: none;
    border-bottom: 0.5px solid rgba(255, 255, 255, 0.05);
  }
  [data-theme="paper"] .twk-hd {
    border-bottom: 0.5px solid rgba(0, 0, 0, 0.05);
  }
  .twk-hd b {
    font-size: 12px;
    font-weight: 600;
    letter-spacing: .01em;
  }
  .twk-x {
    appearance: none;
    border: 0;
    background: transparent;
    color: rgba(227, 218, 203, 0.55);
    width: 22px;
    height: 22px;
    border-radius: 6px;
    cursor: default;
    font-size: 13px;
    line-height: 1;
    display: flex;
    align-items: center;
    justify-content: center;
  }
  [data-theme="paper"] .twk-x {
    color: rgba(21, 21, 21, 0.55);
  }
  .twk-x:hover {
    background: rgba(255, 255, 255, 0.06);
    color: #f7f1e6;
  }
  [data-theme="paper"] .twk-x:hover {
    background: rgba(0, 0, 0, 0.06);
    color: #151515;
  }
  .twk-body {
    padding: 10px 14px 14px;
    display: flex;
    flex-direction: column;
    gap: 10px;
    overflow-y: auto;
    overflow-x: hidden;
    min-height: 0;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.15) transparent;
  }
  [data-theme="paper"] .twk-body {
    scrollbar-color: rgba(0, 0, 0, 0.15) transparent;
  }
  .twk-body::-webkit-scrollbar {
    width: 8px;
  }
  .twk-body::-webkit-scrollbar-thumb {
    background: rgba(255, 255, 255, 0.15);
    border-radius: 4px;
    border: 2px solid transparent;
    background-clip: content-box;
  }
  [data-theme="paper"] .twk-body::-webkit-scrollbar-thumb {
    background: rgba(0, 0, 0, 0.15);
  }
  .twk-row {
    display: flex;
    flex-direction: column;
    gap: 5px;
  }
  .twk-row-h {
    flex-direction: row;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
  }
  .twk-lbl {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    color: rgba(227, 218, 203, 0.72);
  }
  [data-theme="paper"] .twk-lbl {
    color: rgba(21, 21, 21, 0.72);
  }
  .twk-lbl > span:first-child {
    font-weight: 500;
  }
  .twk-val {
    color: rgba(227, 218, 203, 0.5);
    font-variant-numeric: tabular-nums;
  }
  [data-theme="paper"] .twk-val {
    color: rgba(21, 21, 21, 0.5);
  }
  .twk-sect {
    font-size: 10px;
    font-weight: 600;
    letter-spacing: .06em;
    text-transform: uppercase;
    color: rgba(227, 218, 203, 0.45);
    padding: 10px 0 2px;
    border-bottom: 0.5px solid rgba(255, 255, 255, 0.05);
  }
  [data-theme="paper"] .twk-sect {
    color: rgba(21, 21, 21, 0.45);
    border-bottom: 0.5px solid rgba(0, 0, 0, 0.05);
  }
  .twk-sect:first-child {
    padding-top: 0;
  }
  .twk-slider {
    appearance: none;
    -webkit-appearance: none;
    width: 100%;
    height: 4px;
    margin: 6px 0;
    border-radius: 999px;
    background: rgba(255, 255, 255, 0.12);
    outline: none;
  }
  [data-theme="paper"] .twk-slider {
    background: rgba(0, 0, 0, 0.12);
  }
  .twk-slider::-webkit-slider-thumb {
    -webkit-appearance: none;
    appearance: none;
    width: 14px;
    height: 14px;
    border-radius: 50%;
    background: #fff;
    border: .5px solid rgba(0, 0, 0, 0.12);
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.2);
    cursor: default;
  }
  .twk-slider::-moz-range-thumb {
    width: 14px;
    height: 14px;
    border-radius: 50%;
    background: #fff;
    border: .5px solid rgba(0, 0, 0, 0.12);
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.2);
    cursor: default;
  }
  .twk-seg {
    position: relative;
    display: flex;
    padding: 2px;
    border-radius: 8px;
    background: rgba(255, 255, 255, 0.06);
    user-select: none;
    gap: 2px;
  }
  [data-theme="paper"] .twk-seg {
    background: rgba(0, 0, 0, 0.06);
  }
  .twk-seg button {
    appearance: none;
    position: relative;
    z-index: 1;
    flex: 1;
    border: 0;
    background: transparent;
    color: inherit;
    font: inherit;
    font-weight: 500;
    min-height: 22px;
    border-radius: 6px;
    cursor: default;
    padding: 4px 6px;
    line-height: 1.2;
    overflow-wrap: anywhere;
    transition: background 0.14s, color 0.14s;
  }
  .twk-seg button.on {
    background: rgba(255, 255, 255, 0.95);
    color: #111;
    box-shadow: 0 1px 2px rgba(0, 0, 0, 0.15);
  }
  [data-theme="paper"] .twk-seg button.on {
    background: #111;
    color: #fff;
  }
  .twk-toggle {
    position: relative;
    width: 32px;
    height: 18px;
    border: 0;
    border-radius: 999px;
    background: rgba(255, 255, 255, 0.15);
    transition: background .15s;
    cursor: default;
    padding: 0;
  }
  [data-theme="paper"] .twk-toggle {
    background: rgba(0, 0, 0, 0.15);
  }
  .twk-toggle[data-on="1"] {
    background: #46c66a;
  }
  .twk-toggle i {
    position: absolute;
    top: 2px;
    left: 2px;
    width: 14px;
    height: 14px;
    border-radius: 50%;
    background: #fff;
    box-shadow: 0 1px 2px rgba(0, 0, 0, 0.25);
    transition: transform .15s;
  }
  .twk-toggle[data-on="1"] i {
    transform: translateX(14px);
  }
`

function TweakSection({ label }: { label: string }) {
  return html`<div class="twk-sect">${label}</div>`
}

interface TweakRowProps {
  label: string
  value?: string | number
  children: unknown
  inline?: boolean
}

function TweakRow({ label, value, children, inline = false }: TweakRowProps) {
  return html`
    <div class=${inline ? 'twk-row twk-row-h' : 'twk-row'}>
      <div class="twk-lbl">
        <span>${label}</span>
        ${value !== undefined ? html`<span class="twk-val">${value}</span>` : null}
      </div>
      ${children}
    </div>
  `
}

interface TweakRadioProps<T extends string> {
  label: string
  value: T
  options: readonly (T | { value: T; label: string })[]
  onChange: (value: T) => void
}

function TweakRadio<T extends string>({ label, value, options, onChange }: TweakRadioProps<T>) {
  const normalizedOpts = options.map((o) => (typeof o === 'object' && o !== null ? o : { value: o, label: o }))
  return html`
    <${TweakRow} label=${label}>
      <div class="twk-seg" role="radiogroup" data-testid="twk-seg">
        ${normalizedOpts.map((o) => html`
          <button
            type="button"
            key=${o.value}
            role="radio"
            class=${`twk-seg-b ${value === o.value ? 'on' : ''}`}
            aria-checked=${value === o.value}
            data-value=${o.value}
            onClick=${() => onChange(o.value)}
          >
            ${o.label}
          </button>
        `)}
      </div>
    <//>
  `
}

interface TweakSliderProps {
  label: string
  value: number
  min: number
  max: number
  step?: number
  unit?: string
  displayValue?: string
  testid?: string
  onChange: (value: number) => void
}

function TweakSlider({ label, value, min, max, step = 1, unit = '', displayValue, testid, onChange }: TweakSliderProps) {
  const renderedVal = displayValue !== undefined ? displayValue : `${value}${unit}`
  return html`
    <${TweakRow} label=${label} value=${renderedVal}>
      <div data-testid=${testid}>
        <input
          type="range"
          class="twk-slider"
          min=${min}
          max=${max}
          step=${step}
          value=${value}
          onInput=${(e: Event) => onChange(Number((e.target as HTMLInputElement).value))}
        />
      </div>
    <//>
  `
}

interface TweakToggleProps {
  label: string
  value: boolean
  onChange: (value: boolean) => void
}

function TweakToggle({ label, value, onChange }: TweakToggleProps) {
  return html`
    <div class="twk-row twk-row-h">
      <div class="twk-lbl"><span>${label}</span></div>
      <button
        type="button"
        class="twk-toggle"
        data-on=${value ? '1' : '0'}
        role="switch"
        aria-checked=${value}
        onClick=${() => onChange(!value)}
      >
        <i />
      </button>
    </div>
  `
}

export function TweaksPanelToggle() {
  const open = tweaksOpen.value
  const title = open
    ? 'Close display tweaks'
    : 'Open display tweaks (density, motion, bubbles, font scale, voltage, theme)'
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
    <style>${__TWEAKS_STYLE}</style>
    <div
      ref=${dragRef}
      class="twk-panel"
      data-testid="tweaks-panel"
      style=${{ right: `${offsetRef.current.x}px`, bottom: `${offsetRef.current.y}px` }}
    >
      <div
        class="twk-hd"
        onMouseDown=${onDragStart}
        data-testid="tweaks-panel-header"
      >
        <b>Display tweaks</b>
        <button
          type="button"
          class="twk-x"
          aria-label="Close tweaks"
          data-testid="tweaks-panel-close"
          onMouseDown=${(e: MouseEvent) => e.stopPropagation()}
          onClick=${() => { tweaksOpen.value = false }}
        >
          <${X} size=${14} />
        </button>
      </div>
      <div class="twk-body">
        <${TweakSection} label="만듦새 · 기본 3축" />
        <${TweakRadio}
          label="밀도"
          value=${tweaksDensity.value}
          options=${DENSITY_OPTIONS}
          onChange=${(v: Density) => { tweaksDensity.value = v }}
        />
        <${TweakRadio}
          label="모션"
          value=${tweaksMotion.value}
          options=${MOTION_OPTIONS}
          onChange=${(v: Motion) => { tweaksMotion.value = v }}
        />
        <${TweakRadio}
          label="메시지"
          value=${tweaksBubble.value}
          options=${BUBBLE_OPTIONS}
          onChange=${(v: Bubble) => { tweaksBubble.value = v }}
        />

        <${TweakSection} label="브랜드 · Voltage" />
        <${TweakRadio}
          label="테마"
          value=${tweaksTheme.value}
          options=${THEME_OPTIONS}
          onChange=${(v: Theme) => {
            tweaksTheme.value = v
            document.documentElement.setAttribute('data-theme', v === 'paper' ? 'paper' : '')
          }}
        />
        <${TweakRadio}
          label="Voltage 컬러"
          value=${tweaksVolt.value}
          options=${VOLT_OPTIONS}
          onChange=${(v: Volt) => {
            tweaksVolt.value = v
            document.documentElement.setAttribute('data-volt', v)
          }}
        />

        <${TweakSection} label="레이아웃" />
        <${TweakSlider}
          label="대화 본문 폭"
          value=${tweaksThreadW.value}
          min=${760}
          max=${1320}
          step=${20}
          unit="px"
          onChange=${(v: number) => { tweaksThreadW.value = v }}
        />
        <${TweakToggle}
          label="로스터 레일"
          value=${tweaksRosterOpen.value}
          onChange=${(v: boolean) => { tweaksRosterOpen.value = v }}
        />
        <${TweakToggle}
          label="컨텍스트 레일"
          value=${tweaksCtxOpen.value}
          onChange=${(v: boolean) => { tweaksCtxOpen.value = v }}
        />

        <${TweakSection} label="대화" />
        <${TweakToggle}
          label="메타데이터"
          value=${chatShowMetadata.value}
          onChange=${(v: boolean) => { chatShowMetadata.value = v }}
        />
        <${TweakToggle}
          label="내부 메시지"
          value=${chatShowInternal.value}
          onChange=${(v: boolean) => { chatShowInternal.value = v }}
        />

        <${TweakSection} label="타이포" />
        <${TweakSlider}
          label="가독성 · 본문 배율"
          value=${tweaksFontScale.value}
          min=${90}
          max=${140}
          step=${5}
          displayValue=${`${tweaksFontScale.value / 100}x`}
          testid="twk-slider"
          onChange=${(v: number) => { tweaksFontScale.value = v }}
        />
      </div>
    </div>
  `
}
