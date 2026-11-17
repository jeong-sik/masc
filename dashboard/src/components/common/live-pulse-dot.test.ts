// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { LivePulseDot, classifyLivePulse } from './live-pulse-dot'
import { dashboardObserverReady } from '../../dashboard-observer-state'

describe('classifyLivePulse (pure)', () => {
  it('an admitted observer stream is live', () => {
    expect(classifyLivePulse(true).state).toBe('live')
  })

  it('a stream that is not admitted is idle', () => {
    expect(classifyLivePulse(false).state).toBe('idle')
  })
})

describe('LivePulseDot component', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    dashboardObserverReady.value = false
  })

  const dot = () => container.querySelector('[data-live-pulse-dot]') as HTMLElement

  it('follows the observer stream: pulses while admitted, stands still once it drops', () => {
    dashboardObserverReady.value = true
    render(html`<${LivePulseDot} />`, container)
    expect(dot().getAttribute('data-live-pulse-state')).toBe('live')
    expect(dot().className).toContain('animate-pulse')

    dashboardObserverReady.value = false
    render(html`<${LivePulseDot} />`, container)
    expect(dot().getAttribute('data-live-pulse-state')).toBe('idle')
    expect(dot().className).not.toContain('animate-pulse')
  })

  it('title and aria-label carry the same text', () => {
    render(html`<${LivePulseDot} />`, container)
    expect(dot().getAttribute('title')).toBe(dot().getAttribute('aria-label'))
    expect(dot().getAttribute('role')).toBe('img')
  })

  it('testId renders as data-testid', () => {
    render(html`<${LivePulseDot} testId="overview-strip-live" />`, container)
    expect(container.querySelector('[data-testid="overview-strip-live"]')).toBeTruthy()
  })
})
