import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import { ConnectorOnboardingGrid } from './connector-onboarding'
import { resetSetupGuideExpansionState } from './setup-guide-card'
import { sidecarCommands } from './connector-status'

describe('ConnectorOnboardingGrid', () => {
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

  it('shows the cold-start heading explaining the empty state', () => {
    render(html`<${ConnectorOnboardingGrid} />`, container)
    expect(container.textContent ?? '').toContain('아직 연결된 sidecar가 없습니다')
  })
})
