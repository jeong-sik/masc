// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { EventStream } from './event-stream'

describe('EventStream a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const makeEvents = (): import('./event-stream').StreamEvent[] => [
    { id: 'e1', timestamp: Date.now() - 3000, level: 'info', message: 'Agent started', source: 'keeper' },
    { id: 'e2', timestamp: Date.now() - 2000, level: 'warn', message: 'High latency detected', source: 'monitor' },
    { id: 'e3', timestamp: Date.now() - 1000, level: 'error', message: 'Connection timeout', source: 'network' },
  ]

  it('renders accessibly with events', async () => {
    render(html`<${EventStream} events=${makeEvents()} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with empty events', async () => {
    render(html`<${EventStream} events=${[]} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with maxItems', async () => {
    render(html`<${EventStream} events=${makeEvents()} maxItems=${2} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has log role with aria-live', () => {
    render(html`<${EventStream} events=${makeEvents()} />`, container)
    const log = container.querySelector('[role="log"]') as HTMLElement
    expect(log).not.toBeNull()
    expect(log?.getAttribute('aria-live')).toBe('polite')
    expect(log?.getAttribute('aria-label')).toContain('이벤트 스트림')
    expect(log.dataset.eventStreamStatus).toBe('error')
    expect(log.dataset.eventStreamVisibleCount).toBe('3')
  })

  it('renders event messages', () => {
    render(html`<${EventStream} events=${makeEvents()} />`, container)
    expect(container.textContent).toContain('Agent started')
    expect(container.textContent).toContain('High latency detected')
    expect(container.textContent).toContain('Connection timeout')
  })

  it('shows sources', () => {
    render(html`<${EventStream} events=${makeEvents()} />`, container)
    expect(container.textContent).toContain('keeper')
    expect(container.textContent).toContain('monitor')
  })

  it('marks each visible event with level metadata', () => {
    render(html`<${EventStream} events=${makeEvents()} maxItems=${2} />`, container)
    const items = container.querySelectorAll('[data-stream-event-id]')
    expect(items.length).toBe(2)
    expect((items[0] as HTMLElement).dataset.streamEventLevel).toBe('error')
    expect((items[1] as HTMLElement).dataset.streamEventLevel).toBe('warn')
    expect(container.querySelector('time')?.getAttribute('datetime')).toBeTruthy()
  })
})
