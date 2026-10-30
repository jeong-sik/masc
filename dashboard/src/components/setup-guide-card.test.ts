import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import {
  SetupGuideCard,
  resetSetupGuideExpansionState,
  stepCompletionSummary,
  countCompletedSteps,
  setupGuideProgressPct,
  setupGuideTone,
} from './setup-guide-card'

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

  it('renders the sandbox_hardened guide when requested (non-connector operator guide)', () => {
    render(html`<${SetupGuideCard} connectorId="sandbox_hardened" />`, container)
    const toggle = container.querySelector('button[aria-expanded]')
    expect(toggle).not.toBeNull()
    expect(toggle?.getAttribute('aria-expanded')).toBe('false')
    expect(container.textContent).toContain('Docker Sandbox 프리플라이트')
    expect(container.textContent).toMatch(/\d+ steps/)
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
      expect(link.classList.contains('v2-mobile-operator-target')).toBe(true)
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

  it('checking a step updates the header from "N steps" to "1 of N done"', async () => {
    render(html`<${SetupGuideCard} connectorId="discord" />`, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()

    // Header starts as "N steps"
    const progress = container.querySelector('[data-setup-progress="discord"]')!
    expect(progress.textContent).toMatch(/\d+ steps/)

    const firstCheckbox = container.querySelector('[data-testid="setup-step-discord:0"]') as HTMLInputElement
    expect(firstCheckbox).toBeTruthy()
    firstCheckbox.click()
    await flushUi()

    const progressAfter = container.querySelector('[data-setup-progress="discord"]')!
    expect(progressAfter.textContent).toMatch(/1 of \d+ done/)
  })

  it('renders a Linear-style thin progress bar (progressbar role + aria values)', () => {
    render(html`<${SetupGuideCard} connectorId="discord" />`, container)
    const bar = container.querySelector('[role="progressbar"]')
    expect(bar).toBeTruthy()
    expect(bar!.getAttribute('aria-valuemin')).toBe('0')
    expect(bar!.getAttribute('aria-valuemax')).toBe('100')
    // Initial aria-valuenow = 0 (nothing done yet)
    expect(bar!.getAttribute('aria-valuenow')).toBe('0')
    const fill = bar!.querySelector('[data-setup-progress-bar-fill]') as HTMLElement
    expect(fill).toBeTruthy()
    // Fill width starts at 0%
    expect(fill.style.width).toBe('0%')
  })

  it('progress bar width reflects percentage + tone flips to accent in-progress', async () => {
    render(html`<${SetupGuideCard} connectorId="discord" />`, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    const cb = container.querySelector('[data-testid="setup-step-discord:0"]') as HTMLInputElement
    cb.click()
    await flushUi()

    const bar = container.querySelector('[role="progressbar"]')!
    const now = Number.parseInt(bar.getAttribute('aria-valuenow') ?? '0', 10)
    expect(now).toBeGreaterThan(0)
    expect(now).toBeLessThan(100)

    // Tone tracker on the outer wrapper
    const wrapper = container.querySelector('[data-setup-guide-tone]')!
    expect(wrapper.getAttribute('data-setup-guide-tone')).toBe('in-progress')
    // Count chip carries an accent tone (not text-dim muted)
    const progress = container.querySelector('[data-setup-progress="discord"]')!
    expect(progress.className).toContain('text-[var(--color-accent-fg)]')
  })

  it('renders numbered step circles (Plane step-wizard pattern)', async () => {
    render(html`<${SetupGuideCard} connectorId="discord" />`, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    const circles = container.querySelectorAll('[data-setup-step-circle]')
    expect(circles.length).toBeGreaterThan(0)
    // First circle starts with "1" (pre-checked state)
    const first = circles[0] as HTMLElement
    expect(first.textContent).toBe('1')
  })

  it('step circle swaps to ✓ and turns emerald when the step is complete', async () => {
    render(html`<${SetupGuideCard} connectorId="discord" />`, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    ;(container.querySelector('[data-testid="setup-step-discord:0"]') as HTMLInputElement).click()
    await flushUi()
    const firstCircle = container.querySelector('[data-setup-step-circle="discord:0"]') as HTMLElement
    expect(firstCircle.textContent).toBe('✓')
    expect(firstCircle.className).toContain('border-[var(--ok-20)]')
  })

  it('Complete badge appears + tone flips to complete when all steps done', async () => {
    render(html`<${SetupGuideCard} connectorId="discord" />`, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    const checkboxes = Array.from(container.querySelectorAll('[data-testid^="setup-step-discord:"]')) as HTMLInputElement[]
    for (const cb of checkboxes) {
      cb.click()
      await flushUi()
    }
    const badge = container.querySelector('[data-setup-complete-badge]')
    expect(badge).toBeTruthy()
    expect(badge!.getAttribute('aria-label')).toBe('설정 가이드 완료')
    const wrapper = container.querySelector('[data-setup-guide-tone]')!
    expect(wrapper.getAttribute('data-setup-guide-tone')).toBe('complete')
    const bar = container.querySelector('[role="progressbar"]')!
    expect(bar.getAttribute('aria-valuenow')).toBe('100')
  })

  it('unchecking a step reverts the header copy', async () => {
    render(html`<${SetupGuideCard} connectorId="slack" />`, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    const box = container.querySelector('[data-testid="setup-step-slack:0"]') as HTMLInputElement
    box.click()
    await flushUi()
    expect(container.querySelector('[data-setup-progress="slack"]')!.textContent).toMatch(/1 of \d+ done/)
    box.click()
    await flushUi()
    expect(container.querySelector('[data-setup-progress="slack"]')!.textContent).toMatch(/\d+ steps/)
  })

  it('step completion is keyed per connectorId — Discord progress does not leak into Telegram', async () => {
    // Complete a step on Discord
    render(html`<${SetupGuideCard} connectorId="discord" />`, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    ;(container.querySelector('[data-testid="setup-step-discord:0"]') as HTMLInputElement).click()
    await flushUi()

    // Switch to Telegram — header should still say "N steps" (not "X of N done")
    render(html`<${SetupGuideCard} connectorId="telegram" />`, container)
    await flushUi()
    expect(container.querySelector('[data-setup-progress="telegram"]')!.textContent).toMatch(/\d+ steps/)
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

describe('stepCompletionSummary / countCompletedSteps', () => {
  it('"5 steps" when zero completed, "3 of 5 done" otherwise', () => {
    expect(stepCompletionSummary(0, 5)).toBe('5 steps')
    expect(stepCompletionSummary(1, 5)).toBe('1 of 5 done')
    expect(stepCompletionSummary(3, 5)).toBe('3 of 5 done')
    expect(stepCompletionSummary(5, 5)).toBe('5 of 5 done')
  })

  it('negative completed treated as zero', () => {
    expect(stepCompletionSummary(-1, 5)).toBe('5 steps')
  })

  it('countCompletedSteps returns 0 for undefined map', () => {
    expect(countCompletedSteps(undefined, 5)).toBe(0)
  })

  it('countCompletedSteps counts only indices below total (stale index safety)', () => {
    const m = { 0: true, 2: true, 99: true }
    expect(countCompletedSteps(m, 5)).toBe(2) // 99 is out of bounds
  })

  it('countCompletedSteps ignores false/undefined entries', () => {
    const m = { 0: true, 1: false, 2: true }
    expect(countCompletedSteps(m, 5)).toBe(2)
  })
})

describe('setupGuideProgressPct (pure)', () => {
  it('returns 0 when nothing done', () => {
    expect(setupGuideProgressPct(0, 5)).toBe(0)
  })

  it('returns 100 when all done', () => {
    expect(setupGuideProgressPct(5, 5)).toBe(100)
  })

  it('returns 40 for 2/5', () => {
    expect(setupGuideProgressPct(2, 5)).toBe(40)
  })

  it('rounds to nearest integer (no fractional pixels)', () => {
    // 1/3 = 33.33% → 33. Progress bar CSS width can't resolve sub-%.
    expect(setupGuideProgressPct(1, 3)).toBe(33)
    expect(setupGuideProgressPct(2, 3)).toBe(67)
  })

  it('total=0 returns 0 (div-by-zero guard)', () => {
    expect(setupGuideProgressPct(0, 0)).toBe(0)
    // Even if done is > 0 with empty guide, still 0.
    expect(setupGuideProgressPct(5, 0)).toBe(0)
  })

  it('clamps done > total to 100 (stale state safety)', () => {
    // If a step was completed then removed from the guide, the tracker
    // might have more `true` entries than the guide has steps. Progress
    // must still cap at 100, never 120%.
    expect(setupGuideProgressPct(7, 5)).toBe(100)
  })
})

describe('setupGuideTone (pure)', () => {
  it('idle when nothing done', () => {
    expect(setupGuideTone(0, 5)).toBe('idle')
  })

  it('in-progress when some done, not all', () => {
    expect(setupGuideTone(2, 5)).toBe('in-progress')
    expect(setupGuideTone(4, 5)).toBe('in-progress')
  })

  it('complete when all done', () => {
    expect(setupGuideTone(5, 5)).toBe('complete')
  })

  it('complete when done > total (safety catches stale tracker)', () => {
    expect(setupGuideTone(7, 5)).toBe('complete')
  })

  it('idle when total = 0 (empty guide edge)', () => {
    expect(setupGuideTone(0, 0)).toBe('idle')
    expect(setupGuideTone(3, 0)).toBe('idle')
  })
})
