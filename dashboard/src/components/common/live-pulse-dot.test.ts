// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { LivePulseDot, classifyLivePulse } from './live-pulse-dot'
import { dashboardObserverPhase, type DashboardObserverPhase } from '../../dashboard-observer-state'

const PHASES: DashboardObserverPhase[] = ['stopped', 'connecting', 'live', 'retrying', 'refused']

describe('classifyLivePulse (pure)', () => {
  it('only an admitted stream is live', () => {
    expect(PHASES.filter(phase => classifyLivePulse(phase).tone === 'live')).toEqual(['live'])
  })

  it('a refused stream and a retrying stream read differently', () => {
    expect(classifyLivePulse('refused').label).not.toBe(classifyLivePulse('retrying').label)
  })

  it('the first connect is not shown as a loss', () => {
    expect(classifyLivePulse('connecting').tone).toBe('waiting')
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
    dashboardObserverPhase.value = 'stopped'
  })

  const dot = () => container.querySelector('[data-live-pulse-dot]') as HTMLElement

  it('re-renders on its own when the observer phase changes', async () => {
    dashboardObserverPhase.value = 'live'
    render(html`<${LivePulseDot} />`, container)
    expect(dot().getAttribute('data-live-pulse-state')).toBe('live')
    expect(dot().className).toContain('animate-pulse')

    dashboardObserverPhase.value = 'retrying'
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(dot().getAttribute('data-live-pulse-state')).toBe('retrying')
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
