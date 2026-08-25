import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import { ConnectorOnboardingGrid, onboardingStartLabel } from './connector-onboarding'
import { resetSetupGuideExpansionState } from './setup-guide-card'
import { sidecarCommands } from './connector-constants'
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

  it('renders one card per external sidecar in stable order (in-process omitted)', () => {
    render(html`<${ConnectorOnboardingGrid} />`, container)

    expect(container.querySelector('.v2-connector-onboarding')).not.toBeNull()
    const text = container.textContent ?? ''
    // Discord (RFC-0203) and Slack (RFC-0317) are in-process — no onboarding card.
    expect(text).not.toContain('Discord')
    expect(text).not.toContain('Slack')
    expect(text).not.toContain('iMessage')
    expect(text).toContain('Telegram')

    // 1 brand-coloured card now (discord, slack and imessage filtered out).
    const cards = container.querySelectorAll('[style*="linear-gradient"]')
    expect(cards.length).toBe(1)
  })

  it('exposes the start command for each external sidecar (run.sh per bridge)', () => {
    render(html`<${ConnectorOnboardingGrid} />`, container)
    const text = container.textContent ?? ''
    // Discord, Slack and iMessage are omitted from onboarding (in-process) —
    // no run.sh. Telegram is the last external sidecar.
    expect(text).not.toContain('sidecars/imessage-bot')
    expect(text).toContain('cd sidecars/telegram-bot && ./run.sh')
  })

  // Pin the sidecarCommands() shape so a future refactor can't re-introduce
  // the per-bridge pkill fork we just deleted. One external sidecar is left —
  // discord (RFC-0203), slack (RFC-0317) and imessage are in-process.
  it('uses ./run.sh stop for every external bridge (no pkill)', () => {
    for (const id of ['telegram']) {
      const { stop } = sidecarCommands(id)
      expect(stop).toBe(`cd sidecars/${id}-bot && ./run.sh stop`)
      expect(stop).not.toContain('pkill')
    }
  })

  it('embeds a collapsed SetupGuideCard per external onboarding card', () => {
    render(html`<${ConnectorOnboardingGrid} />`, container)
    // 1 setup-guide toggle button (one per remaining onboarding card),
    // collapsed.
    const toggles = container.querySelectorAll('button[aria-expanded]')
    expect(toggles.length).toBe(1)
    toggles.forEach(btn => {
      expect(btn.getAttribute('aria-expanded')).toBe('false')
    })
  })

  it('bulk Start All counts the sidecars it can actually spawn', () => {
    render(html`<${ConnectorOnboardingGrid} />`, container)
    const startAll = container.querySelector('[data-testid="bulk-action-start"]') as HTMLButtonElement
    expect(startAll).toBeTruthy()
    // The count used to say 4 and this comment used to explain why it
    // disagreed with the grid beside it: ConnectorBulkActions counted every
    // known connector, and discord and slack have no sidecar to spawn. The
    // two now agree, and the number is the number of cards — one, now that
    // iMessage runs in-process too.
    expect(startAll.textContent).toContain('(1)')
  })

  it('shows the cold-start heading explaining the empty state', () => {
    render(html`<${ConnectorOnboardingGrid} />`, container)
    expect(container.textContent ?? '').toContain('아직 연결된 사이드카 없음')
  })

  it('renders a per-card Start button with testId for each external sidecar', () => {
    render(html`<${ConnectorOnboardingGrid} />`, container)
    const buttons = container.querySelectorAll('[data-testid^="onboarding-start-"]')
    expect(buttons.length).toBe(1)
    const ids = Array.from(buttons)
      .map(b => b.getAttribute('data-testid')!.replace('onboarding-start-', ''))
    // Discord, Slack and iMessage omitted — KNOWN_CONNECTOR_IDS order with
    // in-process filtered out.
    expect(ids).toEqual(['telegram'])
  })

  it('per-card Start button starts in the idle "Start" label, not inflight', () => {
    render(html`<${ConnectorOnboardingGrid} />`, container)
    // Discord and slack are in-process; use telegram as the representative
    // external sidecar.
    const telegramBtn = container.querySelector('[data-testid="onboarding-start-telegram"]') as HTMLButtonElement
    expect(telegramBtn.textContent).toContain('Start')
    expect(telegramBtn.textContent).not.toContain('Starting')
    // ActionButton omits aria-busy when ariaBusy=false (ARIA default is
    // already "false" — no need to render it). When the inflight state
    // flips, ariaBusy=true would render aria-busy="true" instead.
    expect(telegramBtn.getAttribute('aria-busy')).toBeNull()
    expect(telegramBtn.disabled).toBe(false)
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
