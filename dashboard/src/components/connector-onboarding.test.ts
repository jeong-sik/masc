import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import { ConnectorOnboardingGrid, onboardingStartLabel } from './connector-onboarding'
import { resetSetupGuideExpansionState } from './setup-guide-card'
import { sidecarCommands } from './connector-status'
import { _testResetBulkInflight } from './connector-overview-strip'

describe('ConnectorOnboardingGrid', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    resetSetupGuideExpansionState()
    _testResetBulkInflight()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    resetSetupGuideExpansionState()
  })

  it('renders one card per known sidecar in stable order', () => {
    render(html`<${ConnectorOnboardingGrid} />`, container)

    const text = container.textContent ?? ''
    expect(text).toContain('Discord')
    expect(text).toContain('iMessage')
    expect(text).toContain('Slack')
    expect(text).toContain('Telegram')

    // Each card has its own brand-colored container (4 cards).
    const cards = container.querySelectorAll('[style*="linear-gradient"]')
    expect(cards.length).toBe(4)
  })

  it('exposes the start command for each sidecar (run.sh per bridge)', () => {
    render(html`<${ConnectorOnboardingGrid} />`, container)
    const text = container.textContent ?? ''
    expect(text).toContain('cd sidecars/discord-bot && ./run.sh')
    expect(text).toContain('cd sidecars/imessage-bot && ./run.sh')
    expect(text).toContain('cd sidecars/slack-bot && ./run.sh')
    expect(text).toContain('cd sidecars/telegram-bot && ./run.sh')
  })

  // Pin the sidecarCommands() shape so a future refactor can't re-introduce
  // the per-bridge pkill fork we just deleted.
  it('uses ./run.sh stop for every bridge (no pkill)', () => {
    for (const id of ['discord', 'imessage', 'slack', 'telegram']) {
      const { stop } = sidecarCommands(id)
      expect(stop).toBe(`cd sidecars/${id}-bot && ./run.sh stop`)
      expect(stop).not.toContain('pkill')
    }
  })

  it('embeds a collapsed SetupGuideCard per known connector', () => {
    render(html`<${ConnectorOnboardingGrid} />`, container)
    // 4 setup-guide toggle buttons (one per onboarding card), all collapsed.
    const toggles = container.querySelectorAll('button[aria-expanded]')
    expect(toggles.length).toBe(4)
    toggles.forEach(btn => {
      expect(btn.getAttribute('aria-expanded')).toBe('false')
    })
  })

  it('includes bulk Start All action for cold-start spawn of all 4 at once', () => {
    render(html`<${ConnectorOnboardingGrid} />`, container)
    const startAll = container.querySelector('[data-bulk-action="start"]') as HTMLButtonElement
    expect(startAll).toBeTruthy()
    // With zero registered connectors, all 4 count as "down".
    expect(startAll.textContent).toContain('(4)')
  })

  it('shows the cold-start heading explaining the empty state', () => {
    render(html`<${ConnectorOnboardingGrid} />`, container)
    expect(container.textContent ?? '').toContain('아직 연결된 사이드카가 없습니다')
  })

  it('renders a per-card Start button with data-onboarding-start matching each connector id', () => {
    render(html`<${ConnectorOnboardingGrid} />`, container)
    const buttons = container.querySelectorAll('[data-onboarding-start]')
    expect(buttons.length).toBe(4)
    const ids = Array.from(buttons).map(b => b.getAttribute('data-onboarding-start'))
    expect(ids).toEqual(['discord', 'imessage', 'slack', 'telegram'])
  })

  it('per-card Start button starts in the idle "Start" label, not inflight', () => {
    render(html`<${ConnectorOnboardingGrid} />`, container)
    const discordBtn = container.querySelector('[data-onboarding-start="discord"]') as HTMLButtonElement
    expect(discordBtn.textContent).toContain('Start')
    expect(discordBtn.textContent).not.toContain('Starting')
    expect(discordBtn.getAttribute('aria-busy')).toBe('false')
    expect(discordBtn.disabled).toBe(false)
  })
})

describe('onboardingStartLabel', () => {
  it('returns "Start" when idle', () => {
    expect(onboardingStartLabel(false)).toBe('Start')
  })

  it('returns "Starting…" when in flight (gerund, not imperative)', () => {
    expect(onboardingStartLabel(true)).toBe('Starting…')
  })
})
