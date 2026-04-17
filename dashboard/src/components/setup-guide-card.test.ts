import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import { SetupGuideCard, resetSetupGuideExpansionState } from './setup-guide-card'

async function flushUi(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

describe('SetupGuideCard', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    resetSetupGuideExpansionState()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    resetSetupGuideExpansionState()
  })

  it('renders nothing when the connectorId has no guide', () => {
    render(html`<${SetupGuideCard} connectorId="unknown-bridge" />`, container)
    expect(container.textContent ?? '').toBe('')
  })

  it('renders a collapsed toggle by default for a known connector', () => {
    render(html`<${SetupGuideCard} connectorId="discord" />`, container)

    const toggle = container.querySelector('button[aria-expanded]')
    expect(toggle).not.toBeNull()
    expect(toggle?.getAttribute('aria-expanded')).toBe('false')
    // Steps body should not be in the DOM yet.
    expect(container.querySelector('ol')).toBeNull()
    // Header still shows the guide title and step count.
    expect(container.textContent).toContain('Discord 봇 등록')
    expect(container.textContent).toMatch(/\d+ steps/)
  })

  it('expands the steps list when the toggle is clicked', async () => {
    render(html`<${SetupGuideCard} connectorId="discord" />`, container)
    const toggle = container.querySelector('button[aria-expanded]') as HTMLButtonElement
    toggle.click()
    await flushUi()

    const reToggle = container.querySelector('button[aria-expanded]')
    expect(reToggle?.getAttribute('aria-expanded')).toBe('true')
    const ol = container.querySelector('ol')
    expect(ol).not.toBeNull()
    expect(ol?.querySelectorAll('li').length).toBeGreaterThan(0)
    // Discord guide includes a Developer Portal external link.
    const links = container.querySelectorAll('a[target="_blank"]')
    expect(links.length).toBeGreaterThan(0)
    links.forEach(link => {
      expect(link.getAttribute('rel')).toBe('noopener noreferrer')
    })
  })

  it('collapses again on second click', async () => {
    render(html`<${SetupGuideCard} connectorId="slack" />`, container)
    const toggle = container.querySelector('button[aria-expanded]') as HTMLButtonElement
    toggle.click()
    await flushUi()
    toggle.click()
    await flushUi()
    const reToggle = container.querySelector('button[aria-expanded]')
    expect(reToggle?.getAttribute('aria-expanded')).toBe('false')
    expect(container.querySelector('ol')).toBeNull()
  })

  it('keeps expand state independent per connectorId', async () => {
    // Open Discord card
    render(html`<${SetupGuideCard} connectorId="discord" />`, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    expect(container.querySelector('button[aria-expanded]')?.getAttribute('aria-expanded')).toBe('true')

    // Switch to Telegram card — should render collapsed regardless of Discord state.
    render(html`<${SetupGuideCard} connectorId="telegram" />`, container)
    await flushUi()
    expect(container.querySelector('button[aria-expanded]')?.getAttribute('aria-expanded')).toBe('false')
  })
})
