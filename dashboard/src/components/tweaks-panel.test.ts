// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { fireEvent } from '@testing-library/preact'
import {
  TweakRadio,
  TweaksPanel,
  TweaksPanelToggle,
  tweaksBubble,
  tweaksDensity,
  tweaksFontScale,
  tweaksMotion,
  tweaksOpen,
} from './tweaks-panel'
import { chatShowAutonomous } from '../lib/chat-view-prefs'

describe('TweaksPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    tweaksOpen.value = false
    tweaksDensity.value = 'regular'
    tweaksMotion.value = 'subtle'
    tweaksBubble.value = 'card'
    tweaksFontScale.value = 100
    chatShowAutonomous.value = true
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('toggle button opens and closes the panel', async () => {
    render(html`<${TweaksPanelToggle} />`, container)

    const btn = container.querySelector('[data-testid="tweaks-panel-toggle"]') as HTMLButtonElement
    expect(btn).not.toBeNull()
    expect(btn.getAttribute('aria-expanded')).toBe('false')

    await fireEvent.click(btn)
    expect(tweaksOpen.value).toBe(true)

    render(html`<${TweaksPanelToggle} />`, container)
    expect(btn.getAttribute('aria-expanded')).toBe('true')

    await fireEvent.click(btn)
    expect(tweaksOpen.value).toBe(false)
  })

  it('renders controls when open', () => {
    tweaksOpen.value = true
    render(html`<${TweaksPanel} />`, container)

    const panel = container.querySelector('[data-testid="tweaks-panel"]')
    expect(panel).not.toBeNull()
    expect(container.querySelectorAll('[data-testid="twk-seg"]').length).toBeGreaterThanOrEqual(3)
    expect(container.querySelector('[data-testid="twk-slider"]')).not.toBeNull()
  })

  it('does not render when closed', () => {
    tweaksOpen.value = false
    render(html`<${TweaksPanel} />`, container)
    expect(container.querySelector('[data-testid="tweaks-panel"]')).toBeNull()
  })

  it('density control updates the signal', async () => {
    tweaksOpen.value = true
    render(html`<${TweaksPanel} />`, container)

    const seg = container.querySelector('[data-testid="twk-seg"]') as HTMLElement
    const compactBtn = Array.from(seg.querySelectorAll('button')).find(
      b => b.getAttribute('data-value') === 'compact',
    ) as HTMLButtonElement

    expect(compactBtn).not.toBeNull()
    await fireEvent.click(compactBtn)
    expect(tweaksDensity.value).toBe('compact')
    expect(compactBtn.getAttribute('aria-checked')).toBe('true')
  })

  it('motion control updates the signal', async () => {
    tweaksOpen.value = true
    render(html`<${TweaksPanel} />`, container)

    const seg = container.querySelectorAll('[data-testid="twk-seg"]')[1] as HTMLElement
    const livelyBtn = Array.from(seg.querySelectorAll('button')).find(
      b => b.getAttribute('data-value') === 'lively',
    ) as HTMLButtonElement

    await fireEvent.click(livelyBtn)
    expect(tweaksMotion.value).toBe('lively')
  })

  it('bubble control updates the signal', async () => {
    tweaksOpen.value = true
    render(html`<${TweaksPanel} />`, container)

    const seg = container.querySelectorAll('[data-testid="twk-seg"]')[2] as HTMLElement
    const flatBtn = Array.from(seg.querySelectorAll('button')).find(
      b => b.getAttribute('data-value') === 'flat',
    ) as HTMLButtonElement

    await fireEvent.click(flatBtn)
    expect(tweaksBubble.value).toBe('flat')
  })

  it('font scale slider updates the signal', async () => {
    tweaksOpen.value = true
    render(html`<${TweaksPanel} />`, container)

    const slider = container.querySelector('[data-testid="twk-slider"] input') as HTMLInputElement
    slider.value = '110'
    await fireEvent.input(slider)

    expect(tweaksFontScale.value).toBe(110)
  })

  it('close button hides the panel', async () => {
    tweaksOpen.value = true
    render(html`<${TweaksPanel} />`, container)

    const close = container.querySelector('[data-testid="tweaks-panel-close"]') as HTMLButtonElement
    await fireEvent.click(close)

    expect(tweaksOpen.value).toBe(false)
  })

  it('autonomous-turn toggle updates the chat view pref', async () => {
    tweaksOpen.value = true
    chatShowAutonomous.value = true
    render(html`<${TweaksPanel} />`, container)

    const row = Array.from(container.querySelectorAll('.twk-row')).find(
      el => el.textContent?.includes('자율턴'),
    ) as HTMLElement
    expect(row).not.toBeUndefined()
    const toggle = row.querySelector('button[role="switch"]') as HTMLButtonElement
    expect(toggle.getAttribute('aria-checked')).toBe('true')

    await fireEvent.click(toggle)
    expect(chatShowAutonomous.value).toBe(false)
  })

  it('renders the design seg thumb over the selected segment and moves it on change', async () => {
    tweaksOpen.value = true
    tweaksDensity.value = 'regular'
    render(html`<${TweaksPanel} />`, container)

    const seg = container.querySelector('[data-testid="twk-seg"]') as HTMLElement
    const thumb = seg.querySelector('.twk-seg-thumb') as HTMLElement
    expect(thumb).not.toBeNull()
    // 'regular' is index 1 of 3 — design formula 2px + idx * (100% - 4px) / n,
    // distributed: idx * 100/n % + (2 - idx * 4/n) px.
    expect(thumb.style.left).toBe(`calc(${100 / 3}% + ${2 - 4 / 3}px)`)
    expect(thumb.style.width).toBe(`calc(${100 / 3}% - ${4 / 3}px)`)

    const compactBtn = Array.from(seg.querySelectorAll('button')).find(
      b => b.getAttribute('data-value') === 'compact',
    ) as HTMLButtonElement
    await fireEvent.click(compactBtn)
    render(html`<${TweaksPanel} />`, container)
    const thumbAfter = container.querySelector('[data-testid="twk-seg"] .twk-seg-thumb') as HTMLElement
    expect(thumbAfter.style.left).toBe(`calc(${(2 * 100) / 3}% + ${2 - (2 * 4) / 3}px)`)
  })

  it('falls back to a select.twk-field when segment labels exceed the design budget', async () => {
    // Design budget (tweaks-panel.jsx): 3 options fit ~10 chars each; a longer
    // label renders TweakSelect instead of wrapping mid-word.
    render(html`
      <${TweakRadio}
        label="테스트"
        value=${'a'}
        options=${[
          { value: 'a', label: '아주아주긴옵션레이블' },
          { value: 'b', label: '또다른아주긴옵션레이블' },
          { value: 'c', label: '세번째아주긴옵션레이블' },
        ]}
        onChange=${() => {}}
      />
    `, container)

    const select = container.querySelector('select.twk-field') as HTMLSelectElement
    expect(select).not.toBeNull()
    expect(select.querySelectorAll('option').length).toBe(3)
    expect(container.querySelector('[data-testid="twk-seg"]')).toBeNull()
  })
})
// Keeper Agent v2 sync: coverage ratchet trigger
