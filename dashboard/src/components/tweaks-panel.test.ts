// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { fireEvent } from '@testing-library/preact'
import {
  TweaksPanel,
  TweaksPanelToggle,
  tweaksBubble,
  tweaksDensity,
  tweaksFontScale,
  tweaksMotion,
  tweaksOpen,
} from './tweaks-panel'

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
})
